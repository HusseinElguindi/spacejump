// spacejump — direct keyboard jumps to a specific macOS Desktop, no animation.
//
// Switching is done with the private SkyLight WindowManager bridge operations
// (SLSBridgedShowSpacesOperation / SLSBridgedHideSpacesOperation /
// SLSBridgedManagedDisplaySetCurrentSpaceOperation), NOT by synthesising a Dock
// swipe gesture. That matters:
//
//   * A Dock swipe is inherently *relative*, so "jump to Desktop 7" would mean
//     replaying N swipes and guessing when they land.
//   * The swipe path is what breaks on macOS 27 (the Dock stopped reading the
//     private CGEvent gesture fields; the data now has to be smuggled in as a
//     serialized IOHID payload), and what causes the WindowServer surface-purge
//     race that leaves the menu bar or wallpaper unrendered when the gesture is
//     given near-zero duration.
//
// The bridge operations sidestep all of that: no gesture, no animation to
// suppress, no Accessibility permission (we register real hotkeys rather than
// tapping the event stream), and SIP stays on.
//
// Operation ABIs and the three-step activation order are as documented by
// Fjx-dylanZ/native-space-kit, verified on macOS 27 RC (26A428), arm64, SIP on.
//
// Build: make
// SPDX-License-Identifier: MIT

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>

static NSString *const kProgramName = @"spacejump";
static NSString *const kVersion = @"0.1.0";

// MARK: - Private SkyLight

typedef int SLSConnectionID;
static SLSConnectionID gConnection;
static CFArrayRef (*gCopyManagedDisplaySpaces)(SLSConnectionID);
static SEL gPerform;

// Every bridge operation is: alloc, init with its own selector, then
// -performWithWMBridgeDelegate. Resolve defensively — these are private classes
// and a macOS update may rename or reshape them; we want a clear diagnostic, not
// an unrecognised-selector crash.
static Class ResolveOperationClass(const char *name, const char *initSelector) {
    Class cls = objc_getClass(name);
    if (!cls) return Nil;
    if (![cls instancesRespondToSelector:sel_registerName(initSelector)]) return Nil;
    if (![cls instancesRespondToSelector:gPerform]) return Nil;
    return cls;
}

// +1 that ARC does not track, so it can be passed through objc_msgSend safely.
static CFTypeRef Allocate(Class cls) {
    return (__bridge_retained CFTypeRef)[cls alloc];
}

static BOOL LoadSkyLight(NSError **error) {
    static BOOL loaded = NO;
    if (loaded) return YES;

    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!handle) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"SkyLight.framework could not be loaded."}];
        return NO;
    }
    SLSConnectionID (*mainConnection)(void) = dlsym(handle, "SLSMainConnectionID");
    gCopyManagedDisplaySpaces = dlsym(handle, "SLSCopyManagedDisplaySpaces");
    if (!mainConnection || !gCopyManagedDisplaySpaces) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"SkyLight is missing the space symbols this build expects."}];
        return NO;
    }
    gConnection = mainConnection();
    gPerform = sel_registerName("performWithWMBridgeDelegate");
    loaded = YES;
    return YES;
}

// MARK: - Desktop enumeration

// One ordinary Desktop. `number` is the 1-based position used by the keybinds,
// counted across displays in the order SkyLight reports them, which is the same
// left-to-right order Mission Control shows.
@interface SJDesktop : NSObject
@property (nonatomic) uint64_t spaceID;
@property (nonatomic, copy) NSString *displayIdentifier;
@property (nonatomic) NSUInteger number;
@property (nonatomic) BOOL active;
@end
@implementation SJDesktop
@end

// Reads the managed-space census. Only type 0 (ordinary Desktop) entries are
// numbered: fullscreen and tiled Spaces appear in this list too, but they are
// not what "Desktop 3" means to anyone, and activating one is out of contract.
static NSArray<SJDesktop *> *ReadDesktops(NSError **error) {
    if (!LoadSkyLight(error)) return nil;

    CFArrayRef raw = gCopyManagedDisplaySpaces(gConnection);
    NSArray *displays = CFBridgingRelease(raw);
    if (![displays isKindOfClass:NSArray.class] || displays.count == 0) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"The managed-space list was empty or not in the expected shape."}];
        return nil;
    }

    NSMutableArray<SJDesktop *> *desktops = [NSMutableArray array];
    for (id display in displays) {
        if (![display isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = display[@"Display Identifier"];
        NSArray *members = display[@"Spaces"];
        NSDictionary *current = display[@"Current Space"];
        if (![identifier isKindOfClass:NSString.class] || ![members isKindOfClass:NSArray.class]) continue;

        uint64_t currentID = 0;
        if ([current isKindOfClass:NSDictionary.class]) {
            NSNumber *n = current[@"id64"];
            if ([n isKindOfClass:NSNumber.class]) currentID = n.unsignedLongLongValue;
        }

        for (id member in members) {
            if (![member isKindOfClass:NSDictionary.class]) continue;
            NSNumber *spaceID = member[@"id64"];
            NSNumber *type = member[@"type"];
            if (![spaceID isKindOfClass:NSNumber.class] || ![type isKindOfClass:NSNumber.class]) continue;
            if (type.intValue != 0) continue;  // skip fullscreen / tiled
            if (spaceID.unsignedLongLongValue == 0) continue;

            SJDesktop *desktop = [SJDesktop new];
            desktop.spaceID = spaceID.unsignedLongLongValue;
            desktop.displayIdentifier = identifier;
            desktop.active = (desktop.spaceID == currentID);
            desktop.number = desktops.count + 1;
            [desktops addObject:desktop];
        }
    }

    if (desktops.count == 0) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"No ordinary Desktops were found."}];
        return nil;
    }
    return desktops;
}

// MARK: - Activation

// How long to wait for an activation to be observed before calling it failed.
static const CFTimeInterval kActivationTimeout = 2.0;

// Setting the current Space on its own updates the census but leaves the old
// Desktop's windows composited on screen. The working order is: show the target,
// hide its siblings on that display, then set current.
static BOOL ActivateDesktop(SJDesktop *target, NSArray<SJDesktop *> *all, NSError **error) {
    if (!LoadSkyLight(error)) return NO;

    Class showClass = ResolveOperationClass("SLSBridgedShowSpacesOperation", "initWithSpaces:");
    Class hideClass = ResolveOperationClass("SLSBridgedHideSpacesOperation", "initWithSpaces:");
    Class currentClass = ResolveOperationClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                               "initWithDisplayIdentifier:spaceID:");
    if (!showClass || !hideClass || !currentClass) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"The SkyLight bridge operations are unavailable or their ABI changed "
                                       @"on this macOS build. spacejump cannot switch Desktops here."}];
        return NO;
    }

    NSMutableArray<NSNumber *> *siblings = [NSMutableArray array];
    for (SJDesktop *desktop in all) {
        if (desktop.spaceID != target.spaceID &&
            [desktop.displayIdentifier isEqualToString:target.displayIdentifier]) {
            [siblings addObject:@(desktop.spaceID)];
        }
    }

    // ARC pitfall: objc_msgSend cast to return `id` is not recognised as part of
    // the init family, so ARC mismanages the +1 that alloc/init returns. Route
    // the unretained hop through CFTypeRef and hand ownership back with
    // __bridge_transfer, which is what ARC can actually reason about.
    id show = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(
        Allocate(showClass), sel_registerName("initWithSpaces:"), @[@(target.spaceID)]);
    id hide = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(
        Allocate(hideClass), sel_registerName("initWithSpaces:"), siblings);
    id setCurrent = (__bridge_transfer id)((CFTypeRef (*)(CFTypeRef, SEL, id, uint64_t))objc_msgSend)(
        Allocate(currentClass), sel_registerName("initWithDisplayIdentifier:spaceID:"),
        target.displayIdentifier, target.spaceID);

    if (!show || !hide || !setCurrent) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:6 userInfo:@{
            NSLocalizedDescriptionKey: @"Could not construct the activation operations."}];
        return NO;
    }

    ((void (*)(id, SEL))objc_msgSend)(show, gPerform);
    ((void (*)(id, SEL))objc_msgSend)(hide, gPerform);
    ((void (*)(id, SEL))objc_msgSend)(setCurrent, gPerform);

    // The bridge operations are asynchronous: -performWithWMBridgeDelegate
    // returns void and the work lands later. Poll the census until the target
    // reads as active, pumping the run loop each round so the operations get
    // serviced -- a short-lived CLI process would otherwise exit before the
    // switch happened, and report success for a switch that never occurred.
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + kActivationTimeout;
    do {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        NSArray<SJDesktop *> *now = ReadDesktops(NULL);
        for (SJDesktop *desktop in now) {
            if (desktop.spaceID == target.spaceID && desktop.active) return YES;
        }
    } while (CFAbsoluteTimeGetCurrent() < deadline);

    if (error) *error = [NSError errorWithDomain:kProgramName code:19 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"Desktop %lu did not become active within %.1fs.",
            (unsigned long)target.number, kActivationTimeout]}];
    return NO;
}

// Jump to a 1-based Desktop number. Re-reads the census every time: Desktops are
// added, removed and reordered behind our back, so a cached map goes stale.
static BOOL JumpToDesktopNumber(NSUInteger number, NSError **error) {
    NSArray<SJDesktop *> *desktops = ReadDesktops(error);
    if (!desktops) return NO;

    if (number < 1 || number > desktops.count) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:7 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Desktop %lu does not exist (there %@ %lu).", (unsigned long)number,
                desktops.count == 1 ? @"is" : @"are", (unsigned long)desktops.count]}];
        return NO;
    }

    SJDesktop *target = desktops[number - 1];
    if (target.active) return YES;  // already there; nothing to do
    return ActivateDesktop(target, desktops, error);
}

// MARK: - Key names

// Carbon virtual key codes are positional, not character-based: kVK_ANSI_1 is
// "the key where 1 sits on an ANSI board". Names below follow what a user would
// type in the config, not the Carbon spelling.
static NSDictionary<NSString *, NSNumber *> *KeyCodeTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2), @"3": @(kVK_ANSI_3),
            @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5), @"6": @(kVK_ANSI_6),
            @"7": @(kVK_ANSI_7), @"8": @(kVK_ANSI_8), @"9": @(kVK_ANSI_9),
            @"0": @(kVK_ANSI_0),
            @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C),
            @"d": @(kVK_ANSI_D), @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F),
            @"g": @(kVK_ANSI_G), @"h": @(kVK_ANSI_H), @"i": @(kVK_ANSI_I),
            @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L),
            @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N), @"o": @(kVK_ANSI_O),
            @"p": @(kVK_ANSI_P), @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R),
            @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T), @"u": @(kVK_ANSI_U),
            @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X),
            @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
            @"f1": @(kVK_F1), @"f2": @(kVK_F2), @"f3": @(kVK_F3), @"f4": @(kVK_F4),
            @"f5": @(kVK_F5), @"f6": @(kVK_F6), @"f7": @(kVK_F7), @"f8": @(kVK_F8),
            @"f9": @(kVK_F9), @"f10": @(kVK_F10), @"f11": @(kVK_F11), @"f12": @(kVK_F12),
            @"f13": @(kVK_F13), @"f14": @(kVK_F14), @"f15": @(kVK_F15), @"f16": @(kVK_F16),
            @"f17": @(kVK_F17), @"f18": @(kVK_F18), @"f19": @(kVK_F19), @"f20": @(kVK_F20),
            @"left": @(kVK_LeftArrow), @"right": @(kVK_RightArrow),
            @"up": @(kVK_UpArrow), @"down": @(kVK_DownArrow),
            @"space": @(kVK_Space), @"tab": @(kVK_Tab), @"return": @(kVK_Return),
            @"escape": @(kVK_Escape), @"grave": @(kVK_ANSI_Grave),
            @"minus": @(kVK_ANSI_Minus), @"equal": @(kVK_ANSI_Equal),
            @"leftbracket": @(kVK_ANSI_LeftBracket), @"rightbracket": @(kVK_ANSI_RightBracket),
            @"keypad1": @(kVK_ANSI_Keypad1), @"keypad2": @(kVK_ANSI_Keypad2),
            @"keypad3": @(kVK_ANSI_Keypad3), @"keypad4": @(kVK_ANSI_Keypad4),
            @"keypad5": @(kVK_ANSI_Keypad5), @"keypad6": @(kVK_ANSI_Keypad6),
            @"keypad7": @(kVK_ANSI_Keypad7), @"keypad8": @(kVK_ANSI_Keypad8),
            @"keypad9": @(kVK_ANSI_Keypad9), @"keypad0": @(kVK_ANSI_Keypad0),
        };
    });
    return table;
}

// "ctrl+shift+3" -> keyCode + Carbon modifier mask. Order is free; the key is
// whichever token is not a modifier, and there must be exactly one.
static BOOL ParseCombination(NSString *spec, UInt32 *outKeyCode, UInt32 *outModifiers, NSError **error) {
    NSArray<NSString *> *tokens = [spec.lowercaseString componentsSeparatedByString:@"+"];
    UInt32 modifiers = 0;
    NSString *keyToken = nil;

    for (NSString *rawToken in tokens) {
        NSString *token = [rawToken stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (token.length == 0) continue;

        if ([token isEqualToString:@"cmd"] || [token isEqualToString:@"command"]) modifiers |= cmdKey;
        else if ([token isEqualToString:@"opt"] || [token isEqualToString:@"option"] ||
                 [token isEqualToString:@"alt"]) modifiers |= optionKey;
        else if ([token isEqualToString:@"ctrl"] || [token isEqualToString:@"control"]) modifiers |= controlKey;
        else if ([token isEqualToString:@"shift"]) modifiers |= shiftKey;
        else if (keyToken) {
            if (error) *error = [NSError errorWithDomain:kProgramName code:8 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"\"%@\" names more than one non-modifier key.", spec]}];
            return NO;
        } else keyToken = token;
    }

    if (!keyToken) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:9 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"\"%@\" has no key, only modifiers.", spec]}];
        return NO;
    }
    NSNumber *keyCode = KeyCodeTable()[keyToken];
    if (!keyCode) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:10 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"\"%@\" is not a key name spacejump knows.", keyToken]}];
        return NO;
    }
    // A bare key with no modifiers would swallow that key system-wide.
    if (modifiers == 0) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:11 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"\"%@\" has no modifier; that would capture the key everywhere.", spec]}];
        return NO;
    }

    *outKeyCode = keyCode.unsignedIntValue;
    *outModifiers = modifiers;
    return YES;
}

// MARK: - Configuration

@interface SJBinding : NSObject
@property (nonatomic) NSUInteger desktopNumber;
@property (nonatomic) UInt32 keyCode;
@property (nonatomic) UInt32 modifiers;
@property (nonatomic, copy) NSString *spec;
@end
@implementation SJBinding
@end

static NSString *ConfigPath(void) {
    NSString *base = NSProcessInfo.processInfo.environment[@"XDG_CONFIG_HOME"];
    if (base.length == 0) base = [NSHomeDirectory() stringByAppendingPathComponent:@".config"];
    return [[base stringByAppendingPathComponent:kProgramName]
            stringByAppendingPathComponent:@"config.json"];
}

static NSString *DefaultConfigJSON(void) {
    // ctrl+opt+N rather than ctrl+N: macOS ships "Switch to Desktop N" on
    // ctrl+N and, when those are enabled, they already own the combination, so
    // RegisterEventHotKey would fail and nothing would work out of the box.
    return @"{\n"
            "  \"bindings\": {\n"
            "    \"space1\": \"ctrl+opt+1\",\n"
            "    \"space2\": \"ctrl+opt+2\",\n"
            "    \"space3\": \"ctrl+opt+3\",\n"
            "    \"space4\": \"ctrl+opt+4\",\n"
            "    \"space5\": \"ctrl+opt+5\"\n"
            "  }\n"
            "}\n";
}

// Accepts "space3" or plain "3" as the binding name.
static BOOL ParseDesktopKey(NSString *key, NSUInteger *outNumber) {
    NSString *digits = key.lowercaseString;
    if ([digits hasPrefix:@"space"]) digits = [digits substringFromIndex:5];
    if (digits.length == 0) return NO;
    for (NSUInteger i = 0; i < digits.length; i++) {
        unichar c = [digits characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    NSInteger value = digits.integerValue;
    if (value < 1) return NO;
    *outNumber = (NSUInteger)value;
    return YES;
}

static NSArray<SJBinding *> *LoadBindings(NSError **error) {
    NSString *path = ConfigPath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:12 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"No config at %@. Run `%@ init` to write a starting one.", path, kProgramName]}];
        return nil;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:13 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a JSON object%@.", path,
                jsonError ? [@": " stringByAppendingString:jsonError.localizedDescription] : @""]}];
        return nil;
    }
    id bindings = root[@"bindings"];
    if (![bindings isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:14 userInfo:@{
            NSLocalizedDescriptionKey: @"The config needs a \"bindings\" object."}];
        return nil;
    }

    NSMutableArray<SJBinding *> *parsed = [NSMutableArray array];
    // Sorted so that reporting and hotkey ids are stable between runs.
    NSArray *keys = [[bindings allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        NSUInteger number = 0;
        if (![key isKindOfClass:NSString.class] || !ParseDesktopKey(key, &number)) {
            if (error) *error = [NSError errorWithDomain:kProgramName code:15 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"\"%@\" is not a Desktop name; use \"space3\" or \"3\".", key]}];
            return nil;
        }
        id spec = bindings[key];
        if (![spec isKindOfClass:NSString.class]) {
            if (error) *error = [NSError errorWithDomain:kProgramName code:16 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"The binding for \"%@\" must be a string like \"ctrl+3\".", key]}];
            return nil;
        }
        UInt32 keyCode = 0, modifiers = 0;
        if (!ParseCombination(spec, &keyCode, &modifiers, error)) return nil;

        SJBinding *binding = [SJBinding new];
        binding.desktopNumber = number;
        binding.keyCode = keyCode;
        binding.modifiers = modifiers;
        binding.spec = spec;
        [parsed addObject:binding];
    }

    if (parsed.count == 0) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:17 userInfo:@{
            NSLocalizedDescriptionKey: @"No bindings are configured."}];
        return nil;
    }
    return parsed;
}

// MARK: - Daemon

static NSMutableArray *gHotKeyRefs;          // boxed EventHotKeyRef
static NSMutableDictionary<NSNumber *, SJBinding *> *gBindingsByHotKeyID;
static EventHandlerRef gHotKeyHandler;

static void LogLine(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LogLine(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "%s: %s\n", kProgramName.UTF8String, message.UTF8String);
}

static void UnregisterAllHotKeys(void) {
    for (id boxed in gHotKeyRefs) {
        EventHotKeyRef ref = NULL;
        [(NSValue *)boxed getValue:&ref];
        if (ref) UnregisterEventHotKey(ref);
    }
    [gHotKeyRefs removeAllObjects];
    [gBindingsByHotKeyID removeAllObjects];
}

static OSStatus HotKeyPressed(EventHandlerCallRef call, EventRef event, void *context) {
    (void)call; (void)context;
    EventHotKeyID hotKeyID = {0};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hotKeyID), NULL, &hotKeyID) != noErr) return noErr;

    SJBinding *binding = gBindingsByHotKeyID[@(hotKeyID.id)];
    if (!binding) return noErr;

    NSError *error = nil;
    if (!JumpToDesktopNumber(binding.desktopNumber, &error)) {
        // Desktops get removed while the daemon runs, so a binding pointing past
        // the end is normal, not fatal. Report and carry on.
        LogLine(@"%@ -> Desktop %lu: %@", binding.spec, (unsigned long)binding.desktopNumber,
                error.localizedDescription);
    }
    return noErr;
}

static BOOL RegisterBindings(NSError **error) {
    NSArray<SJBinding *> *bindings = LoadBindings(error);
    if (!bindings) return NO;

    UnregisterAllHotKeys();
    NSUInteger registered = 0;
    for (NSUInteger i = 0; i < bindings.count; i++) {
        SJBinding *binding = bindings[i];
        EventHotKeyID hotKeyID = {.signature = 'SJMP', .id = (UInt32)(i + 1)};
        EventHotKeyRef ref = NULL;
        OSStatus status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID,
                                              GetApplicationEventTarget(), 0, &ref);
        if (status != noErr) {
            // -9878 is eventHotKeyExistsErr: something else already owns the
            // combination. macOS's own "switch to Desktop N" shortcuts are the
            // usual culprit — they are on by default for Ctrl+1..N.
            LogLine(@"could not bind %@ (status %d)%@", binding.spec, (int)status,
                    status == -9878 ? @" — another app or a macOS shortcut already owns it;"
                                       " free it in System Settings > Keyboard > Keyboard Shortcuts"
                                    : @"");
            continue;
        }
        [gHotKeyRefs addObject:[NSValue valueWithBytes:&ref objCType:@encode(EventHotKeyRef)]];
        gBindingsByHotKeyID[@(hotKeyID.id)] = binding;
        registered++;
    }

    if (registered == 0) {
        if (error) *error = [NSError errorWithDomain:kProgramName code:18 userInfo:@{
            NSLocalizedDescriptionKey: @"None of the configured bindings could be registered."}];
        return NO;
    }
    LogLine(@"%lu of %lu binding%@ active", (unsigned long)registered,
            (unsigned long)bindings.count, bindings.count == 1 ? @"" : @"s");
    return YES;
}

static int RunDaemon(void) {
    gHotKeyRefs = [NSMutableArray array];
    gBindingsByHotKeyID = [NSMutableDictionary dictionary];

    // .accessory: a real app (so Carbon has an application event target and the
    // run loop pumps hotkey events) but with no Dock icon or menu bar.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    EventTypeSpec eventType = {.eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed};
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), &HotKeyPressed,
                                          1, &eventType, NULL, &gHotKeyHandler);
    if (status != noErr) {
        LogLine(@"could not install the hotkey handler (status %d)", (int)status);
        return 1;
    }

    NSError *error = nil;
    if (!LoadSkyLight(&error)) {
        LogLine(@"%@", error.localizedDescription);
        return 1;
    }
    if (!RegisterBindings(&error)) {
        LogLine(@"%@", error.localizedDescription);
        return 1;
    }

    // SIGHUP re-reads the config. Handled on a dispatch source, not in a signal
    // handler, so the reload can allocate and log safely.
    signal(SIGHUP, SIG_IGN);
    dispatch_source_t hup = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(hup, ^{
        LogLine(@"reloading %@", ConfigPath());
        NSError *reloadError = nil;
        if (!RegisterBindings(&reloadError)) {
            LogLine(@"reload failed, previous bindings are gone: %@", reloadError.localizedDescription);
        }
    });
    dispatch_resume(hup);

    LogLine(@"ready");
    [NSApp run];
    return 0;
}

// MARK: - CLI

static int CommandList(void) {
    NSError *error = nil;
    NSArray<SJDesktop *> *desktops = ReadDesktops(&error);
    if (!desktops) {
        LogLine(@"%@", error.localizedDescription);
        return 1;
    }
    BOOL multipleDisplays = NO;
    for (SJDesktop *desktop in desktops) {
        if (![desktop.displayIdentifier isEqualToString:desktops.firstObject.displayIdentifier]) {
            multipleDisplays = YES;
            break;
        }
    }
    for (SJDesktop *desktop in desktops) {
        printf("%s%lu  space id %llu", desktop.active ? "* " : "  ",
               (unsigned long)desktop.number, (unsigned long long)desktop.spaceID);
        if (multipleDisplays) printf("  display %s", desktop.displayIdentifier.UTF8String);
        printf("\n");
    }
    return 0;
}

static int CommandGo(NSString *argument) {
    NSUInteger number = 0;
    if (!ParseDesktopKey(argument, &number)) {
        LogLine(@"\"%@\" is not a Desktop number.", argument);
        return 2;
    }
    NSError *error = nil;
    if (!JumpToDesktopNumber(number, &error)) {
        LogLine(@"%@", error.localizedDescription);
        return 1;
    }
    return 0;
}

static int CommandInit(void) {
    NSString *path = ConfigPath();
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        LogLine(@"%@ already exists; leaving it alone.", path);
        return 1;
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![DefaultConfigJSON() writeToFile:path atomically:YES
                                 encoding:NSUTF8StringEncoding error:&error]) {
        LogLine(@"could not write %@: %@", path, error.localizedDescription);
        return 1;
    }
    printf("wrote %s\n", path.UTF8String);
    return 0;
}

static int CommandCheck(void) {
    NSError *error = nil;
    NSArray<SJBinding *> *bindings = LoadBindings(&error);
    if (!bindings) {
        LogLine(@"%@", error.localizedDescription);
        return 1;
    }
    NSArray<SJDesktop *> *desktops = ReadDesktops(NULL);
    printf("config %s\n", ConfigPath().UTF8String);
    for (SJBinding *binding in bindings) {
        BOOL exists = desktops && binding.desktopNumber <= desktops.count;
        printf("  %-18s -> Desktop %lu%s\n", binding.spec.UTF8String,
               (unsigned long)binding.desktopNumber,
               exists ? "" : "   (no such Desktop right now)");
    }
    if (LoadSkyLight(&error) &&
        ResolveOperationClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                              "initWithDisplayIdentifier:spaceID:")) {
        printf("switching backend: available\n");
    } else {
        printf("switching backend: UNAVAILABLE on this macOS build\n");
        return 1;
    }
    return 0;
}

static void PrintUsage(void) {
    printf("%s %s — jump straight to a macOS Desktop\n\n"
           "usage:\n"
           "  %s daemon        run the hotkey daemon (SIGHUP reloads the config)\n"
           "  %s go N          jump to Desktop N once\n"
           "  %s list          list Desktops; * marks the current one\n"
           "  %s check         validate the config and the switching backend\n"
           "  %s init          write a starter config\n"
           "  %s version\n\n"
           "config: %s\n",
           kProgramName.UTF8String, kVersion.UTF8String, kProgramName.UTF8String,
           kProgramName.UTF8String, kProgramName.UTF8String, kProgramName.UTF8String,
           kProgramName.UTF8String, kProgramName.UTF8String, ConfigPath().UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *command = argc > 1 ? @(argv[1]) : @"";

        if ([command isEqualToString:@"daemon"]) return RunDaemon();
        if ([command isEqualToString:@"list"]) return CommandList();
        if ([command isEqualToString:@"check"]) return CommandCheck();
        if ([command isEqualToString:@"init"]) return CommandInit();
        if ([command isEqualToString:@"go"]) {
            if (argc < 3) { LogLine(@"`go` needs a Desktop number."); return 2; }
            return CommandGo(@(argv[2]));
        }
        if ([command isEqualToString:@"version"] || [command isEqualToString:@"--version"]) {
            printf("%s %s\n", kProgramName.UTF8String, kVersion.UTF8String);
            return 0;
        }
        PrintUsage();
        return command.length == 0 ? 0 : 2;
    }
}
