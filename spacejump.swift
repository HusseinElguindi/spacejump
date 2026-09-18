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

import AppKit
import Carbon
import Darwin
import Foundation

let programName = "spacejump"
let version = "0.1.0"

// MARK: - Errors

struct SpacejumpError: Error, CustomStringConvertible {
    let code: Int
    let message: String
    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
    var description: String { message }
}

func log(_ message: String) {
    fputs("\(programName): \(message)\n", stderr)
}

// MARK: - Private SkyLight

typealias ConnectionID = Int32

// objc_msgSend is unavailable to Swift by name, so it is looked up once and
// cast to the exact C signature each call site needs.
@MainActor
private let objcMsgSend: UnsafeMutableRawPointer = {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "objc_msgSend") else {
        fatalError("objc_msgSend could not be resolved")
    }
    return symbol
}()

private typealias AllocFn = @convention(c) (UnsafeMutableRawPointer, Selector) -> Unmanaged<AnyObject>?
private typealias InitWithObjectFn = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject)
    -> Unmanaged<AnyObject>?
private typealias InitWithObjectAndUInt64Fn = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject, UInt64)
    -> Unmanaged<AnyObject>?
private typealias PerformFn = @convention(c) (AnyObject, Selector) -> Void

@MainActor
enum SkyLight {
    private static var connection: ConnectionID = 0
    private static var copyManagedDisplaySpaces: (@convention(c) (ConnectionID) -> Unmanaged<CFArray>?)?
    static let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    static func load() throws {
        if copyManagedDisplaySpaces != nil { return }

        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            throw SpacejumpError(1, "SkyLight.framework could not be loaded.")
        }
        guard let mainConnectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let copySpacesSymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") else {
            throw SpacejumpError(2, "SkyLight is missing the space symbols this build expects.")
        }
        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: (@convention(c) () -> ConnectionID).self)
        connection = mainConnection()
        copyManagedDisplaySpaces = unsafeBitCast(
            copySpacesSymbol, to: (@convention(c) (ConnectionID) -> Unmanaged<CFArray>?).self)
    }

    static func managedDisplaySpaces() -> [[String: Any]]? {
        guard let copy = copyManagedDisplaySpaces, let raw = copy(connection) else { return nil }
        return raw.takeRetainedValue() as? [[String: Any]]
    }

    // Every bridge operation is: alloc, init with its own selector, then
    // -performWithWMBridgeDelegate. Resolve defensively — these are private
    // classes and a macOS update may rename or reshape them; we want a clear
    // diagnostic, not an unrecognised-selector crash.
    static func resolveOperationClass(_ name: String, initSelector: String) -> NSObject.Type? {
        guard let cls = NSClassFromString(name) as? NSObject.Type else { return nil }
        guard cls.instancesRespond(to: NSSelectorFromString(initSelector)) else { return nil }
        guard cls.instancesRespond(to: performSelector) else { return nil }
        return cls
    }

    // +alloc returns +1; the init that consumes it returns +1. Neither hop is
    // visible to ARC, so ownership is handed back with takeRetainedValue.
    private static func alloc(_ cls: NSObject.Type) -> UnsafeMutableRawPointer? {
        let send = unsafeBitCast(objcMsgSend, to: AllocFn.self)
        let receiver = Unmanaged.passUnretained(cls as AnyObject).toOpaque()
        return send(receiver, NSSelectorFromString("alloc"))?.toOpaque()
    }

    static func makeOperation(_ cls: NSObject.Type, initSelector: String, spaces: [NSNumber]) -> AnyObject? {
        guard let instance = alloc(cls) else { return nil }
        let send = unsafeBitCast(objcMsgSend, to: InitWithObjectFn.self)
        return send(instance, NSSelectorFromString(initSelector), spaces as NSArray)?.takeRetainedValue()
    }

    static func makeOperation(_ cls: NSObject.Type, initSelector: String,
                              displayIdentifier: String, spaceID: UInt64) -> AnyObject? {
        guard let instance = alloc(cls) else { return nil }
        let send = unsafeBitCast(objcMsgSend, to: InitWithObjectAndUInt64Fn.self)
        return send(instance, NSSelectorFromString(initSelector), displayIdentifier as NSString, spaceID)?
            .takeRetainedValue()
    }

    static func perform(_ operation: AnyObject) {
        let send = unsafeBitCast(objcMsgSend, to: PerformFn.self)
        send(operation, performSelector)
    }
}

// MARK: - Desktop enumeration

// One ordinary Desktop. `number` is the 1-based position used by the keybinds,
// counted across displays in the order SkyLight reports them, which is the same
// left-to-right order Mission Control shows.
struct Desktop {
    let spaceID: UInt64
    let displayIdentifier: String
    let number: Int
    let active: Bool
}

// Reads the managed-space census. Only type 0 (ordinary Desktop) entries are
// numbered: fullscreen and tiled Spaces appear in this list too, but they are
// not what "Desktop 3" means to anyone, and activating one is out of contract.
@MainActor
func readDesktops() throws -> [Desktop] {
    try SkyLight.load()

    guard let displays = SkyLight.managedDisplaySpaces(), !displays.isEmpty else {
        throw SpacejumpError(3, "The managed-space list was empty or not in the expected shape.")
    }

    var desktops: [Desktop] = []
    for display in displays {
        guard let identifier = display["Display Identifier"] as? String,
              let members = display["Spaces"] as? [[String: Any]] else { continue }

        let currentID = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0

        for member in members {
            guard let spaceID = member["id64"] as? UInt64, let type = member["type"] as? Int else { continue }
            if type != 0 { continue }  // skip fullscreen / tiled
            if spaceID == 0 { continue }
            desktops.append(Desktop(spaceID: spaceID, displayIdentifier: identifier,
                                    number: desktops.count + 1, active: spaceID == currentID))
        }
    }

    if desktops.isEmpty {
        throw SpacejumpError(4, "No ordinary Desktops were found.")
    }
    return desktops
}

// MARK: - Activation

// How long to wait for an activation to be observed before calling it failed.
let activationTimeout: CFTimeInterval = 2.0

// Setting the current Space on its own updates the census but leaves the old
// Desktop's windows composited on screen. The working order is: show the target,
// hide its siblings on that display, then set current.
@MainActor
func activate(_ target: Desktop, among all: [Desktop]) throws {
    try SkyLight.load()

    guard let showClass = SkyLight.resolveOperationClass("SLSBridgedShowSpacesOperation",
                                                         initSelector: "initWithSpaces:"),
          let hideClass = SkyLight.resolveOperationClass("SLSBridgedHideSpacesOperation",
                                                         initSelector: "initWithSpaces:"),
          let currentClass = SkyLight.resolveOperationClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                                            initSelector: "initWithDisplayIdentifier:spaceID:")
    else {
        throw SpacejumpError(5, "The SkyLight bridge operations are unavailable or their ABI changed "
                                + "on this macOS build. spacejump cannot switch Desktops here.")
    }

    let siblings = all
        .filter { $0.spaceID != target.spaceID && $0.displayIdentifier == target.displayIdentifier }
        .map { NSNumber(value: $0.spaceID) }

    guard let show = SkyLight.makeOperation(showClass, initSelector: "initWithSpaces:",
                                            spaces: [NSNumber(value: target.spaceID)]),
          let hide = SkyLight.makeOperation(hideClass, initSelector: "initWithSpaces:", spaces: siblings),
          let setCurrent = SkyLight.makeOperation(currentClass, initSelector: "initWithDisplayIdentifier:spaceID:",
                                                  displayIdentifier: target.displayIdentifier,
                                                  spaceID: target.spaceID)
    else {
        throw SpacejumpError(6, "Could not construct the activation operations.")
    }

    SkyLight.perform(show)
    SkyLight.perform(hide)
    SkyLight.perform(setCurrent)

    // The bridge operations are asynchronous: -performWithWMBridgeDelegate
    // returns void and the work lands later. Poll the census until the target
    // reads as active, pumping the run loop each round so the operations get
    // serviced -- a short-lived CLI process would otherwise exit before the
    // switch happened, and report success for a switch that never occurred.
    let deadline = CFAbsoluteTimeGetCurrent() + activationTimeout
    repeat {
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
        if let now = try? readDesktops(),
           now.contains(where: { $0.spaceID == target.spaceID && $0.active }) {
            return
        }
    } while CFAbsoluteTimeGetCurrent() < deadline

    throw SpacejumpError(19, String(format: "Desktop %d did not become active within %.1fs.",
                                    target.number, activationTimeout))
}

// Jump to a 1-based Desktop number. Re-reads the census every time: Desktops are
// added, removed and reordered behind our back, so a cached map goes stale.
@MainActor
func jump(toDesktop number: Int) throws {
    let desktops = try readDesktops()

    guard number >= 1, number <= desktops.count else {
        throw SpacejumpError(7, "Desktop \(number) does not exist (there "
                                + "\(desktops.count == 1 ? "is" : "are") \(desktops.count)).")
    }

    let target = desktops[number - 1]
    if target.active { return }  // already there; nothing to do
    try activate(target, among: desktops)
}

// MARK: - Key names

// Carbon virtual key codes are positional, not character-based: kVK_ANSI_1 is
// "the key where 1 sits on an ANSI board". Names below follow what a user would
// type in the config, not the Carbon spelling.
let keyCodeTable: [String: UInt32] = {
    let raw: [String: Int] = [
        "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
        "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "0": kVK_ANSI_0,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "escape": kVK_Escape,
        "grave": kVK_ANSI_Grave, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1, "keypad2": kVK_ANSI_Keypad2,
        "keypad3": kVK_ANSI_Keypad3, "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7, "keypad8": kVK_ANSI_Keypad8,
        "keypad9": kVK_ANSI_Keypad9,
    ]
    return raw.mapValues { UInt32($0) }
}()

struct KeyCombination {
    let keyCode: UInt32
    let modifiers: UInt32
}

// "ctrl+shift+3" -> keyCode + Carbon modifier mask. Order is free; the key is
// whichever token is not a modifier, and there must be exactly one.
func parseCombination(_ spec: String) throws -> KeyCombination {
    var modifiers: UInt32 = 0
    var keyToken: String?

    for rawToken in spec.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { continue }

        switch token {
        case "cmd", "command": modifiers |= UInt32(cmdKey)
        case "opt", "option", "alt": modifiers |= UInt32(optionKey)
        case "ctrl", "control": modifiers |= UInt32(controlKey)
        case "shift": modifiers |= UInt32(shiftKey)
        default:
            if keyToken != nil {
                throw SpacejumpError(8, "\"\(spec)\" names more than one non-modifier key.")
            }
            keyToken = token
        }
    }

    guard let keyToken else {
        throw SpacejumpError(9, "\"\(spec)\" has no key, only modifiers.")
    }
    guard let keyCode = keyCodeTable[keyToken] else {
        throw SpacejumpError(10, "\"\(keyToken)\" is not a key name spacejump knows.")
    }
    // A bare key with no modifiers would swallow that key system-wide.
    if modifiers == 0 {
        throw SpacejumpError(11, "\"\(spec)\" has no modifier; that would capture the key everywhere.")
    }
    return KeyCombination(keyCode: keyCode, modifiers: modifiers)
}

// MARK: - Configuration

struct Binding {
    let desktopNumber: Int
    let combination: KeyCombination
    let spec: String
}

func configPath() -> String {
    var base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
    if base.isEmpty { base = (NSHomeDirectory() as NSString).appendingPathComponent(".config") }
    return ((base as NSString).appendingPathComponent(programName) as NSString)
        .appendingPathComponent("config.json")
}

// ctrl+opt+N rather than ctrl+N: macOS ships "Switch to Desktop N" on ctrl+N
// and, when those are enabled, they already own the combination, so
// RegisterEventHotKey would fail and nothing would work out of the box.
let defaultConfigJSON = """
{
  "bindings": {
    "space1": "ctrl+opt+1",
    "space2": "ctrl+opt+2",
    "space3": "ctrl+opt+3",
    "space4": "ctrl+opt+4",
    "space5": "ctrl+opt+5"
  }
}

"""

// Accepts "space3" or plain "3" as the binding name.
func parseDesktopKey(_ key: String) -> Int? {
    var digits = Substring(key.lowercased())
    if digits.hasPrefix("space") { digits = digits.dropFirst(5) }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    guard let value = Int(digits), value >= 1 else { return nil }
    return value
}

func loadBindings() throws -> [Binding] {
    let path = configPath()
    guard let data = FileManager.default.contents(atPath: path) else {
        throw SpacejumpError(12, "No config at \(path). Run `\(programName) init` to write a starting one.")
    }

    let root: Any
    do {
        root = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw SpacejumpError(13, "\(path) is not a JSON object: \(error.localizedDescription).")
    }
    guard let object = root as? [String: Any] else {
        throw SpacejumpError(13, "\(path) is not a JSON object.")
    }
    guard let bindings = object["bindings"] as? [String: Any] else {
        throw SpacejumpError(14, "The config needs a \"bindings\" object.")
    }

    var parsed: [Binding] = []
    // Sorted so that reporting and hotkey ids are stable between runs.
    for key in bindings.keys.sorted() {
        guard let number = parseDesktopKey(key) else {
            throw SpacejumpError(15, "\"\(key)\" is not a Desktop name; use \"space3\" or \"3\".")
        }
        guard let spec = bindings[key] as? String else {
            throw SpacejumpError(16, "The binding for \"\(key)\" must be a string like \"ctrl+3\".")
        }
        parsed.append(Binding(desktopNumber: number, combination: try parseCombination(spec), spec: spec))
    }

    if parsed.isEmpty {
        throw SpacejumpError(17, "No bindings are configured.")
    }
    return parsed
}

// MARK: - Daemon

@MainActor
enum Daemon {
    private static var hotKeyRefs: [EventHotKeyRef] = []
    private static var bindingsByHotKeyID: [UInt32: Binding] = [:]
    private static var hotKeyHandler: EventHandlerRef?
    private static var hupSource: DispatchSourceSignal?

    private static let signature: OSType = {
        var value: OSType = 0
        for byte in "SJMP".utf8 { value = value << 8 | OSType(byte) }
        return value
    }()

    private static func unregisterAllHotKeys() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        bindingsByHotKeyID.removeAll()
    }

    private static let hotKeyPressed: EventHandlerUPP = { _, event, _ in
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr else { return noErr }

        // Carbon delivers application-target events on the main thread.
        MainActor.assumeIsolated {
            guard let binding = bindingsByHotKeyID[hotKeyID.id] else { return }
            do {
                try jump(toDesktop: binding.desktopNumber)
            } catch {
                // Desktops get removed while the daemon runs, so a binding pointing
                // past the end is normal, not fatal. Report and carry on.
                log("\(binding.spec) -> Desktop \(binding.desktopNumber): \(error)")
            }
        }
        return noErr
    }

    private static func registerBindings() throws {
        let bindings = try loadBindings()

        unregisterAllHotKeys()
        var registered = 0
        for (index, binding) in bindings.enumerated() {
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.combination.keyCode, binding.combination.modifiers,
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                // -9878 is eventHotKeyExistsErr: something else already owns the
                // combination. macOS's own "switch to Desktop N" shortcuts are the
                // usual culprit — they are on by default for Ctrl+1..N.
                let hint = status == eventHotKeyExistsErr
                    ? " — another app or a macOS shortcut already owns it;"
                      + " free it in System Settings > Keyboard > Keyboard Shortcuts"
                    : ""
                log("could not bind \(binding.spec) (status \(status))\(hint)")
                continue
            }
            hotKeyRefs.append(ref)
            bindingsByHotKeyID[hotKeyID.id] = binding
            registered += 1
        }

        if registered == 0 {
            throw SpacejumpError(18, "None of the configured bindings could be registered.")
        }
        log("\(registered) of \(bindings.count) binding\(bindings.count == 1 ? "" : "s") active")
    }

    static func run() -> Int32 {
        // .accessory: a real app (so Carbon has an application event target and
        // the run loop pumps hotkey events) but with no Dock icon or menu bar.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, nil,
                                         &hotKeyHandler)
        if status != noErr {
            log("could not install the hotkey handler (status \(status))")
            return 1
        }

        do {
            try SkyLight.load()
            try registerBindings()
        } catch {
            log("\(error)")
            return 1
        }

        // SIGHUP re-reads the config. Handled on a dispatch source, not in a
        // signal handler, so the reload can allocate and log safely.
        signal(SIGHUP, SIG_IGN)
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler {
            log("reloading \(configPath())")
            do {
                try registerBindings()
            } catch {
                log("reload failed, previous bindings are gone: \(error)")
            }
        }
        hup.resume()
        hupSource = hup

        log("ready")
        app.run()
        return 0
    }
}

// MARK: - CLI

@MainActor
func commandList() -> Int32 {
    let desktops: [Desktop]
    do {
        desktops = try readDesktops()
    } catch {
        log("\(error)")
        return 1
    }
    let multipleDisplays = desktops.contains { $0.displayIdentifier != desktops[0].displayIdentifier }
    for desktop in desktops {
        var line = "\(desktop.active ? "* " : "  ")\(desktop.number)  space id \(desktop.spaceID)"
        if multipleDisplays { line += "  display \(desktop.displayIdentifier)" }
        print(line)
    }
    return 0
}

@MainActor
func commandGo(_ argument: String) -> Int32 {
    guard let number = parseDesktopKey(argument) else {
        log("\"\(argument)\" is not a Desktop number.")
        return 2
    }
    do {
        try jump(toDesktop: number)
    } catch {
        log("\(error)")
        return 1
    }
    return 0
}

func commandInit() -> Int32 {
    let path = configPath()
    if FileManager.default.fileExists(atPath: path) {
        log("\(path) already exists; leaving it alone.")
        return 1
    }
    do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try defaultConfigJSON.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        log("could not write \(path): \(error.localizedDescription)")
        return 1
    }
    print("wrote \(path)")
    return 0
}

@MainActor
func commandCheck() -> Int32 {
    let bindings: [Binding]
    do {
        bindings = try loadBindings()
    } catch {
        log("\(error)")
        return 1
    }
    let desktops = try? readDesktops()
    print("config \(configPath())")
    for binding in bindings {
        let exists = desktops.map { binding.desktopNumber <= $0.count } ?? false
        let spec = binding.spec.padding(toLength: max(18, binding.spec.count), withPad: " ", startingAt: 0)
        print("  \(spec) -> Desktop \(binding.desktopNumber)\(exists ? "" : "   (no such Desktop right now)")")
    }
    if (try? SkyLight.load()) != nil,
       SkyLight.resolveOperationClass("SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                      initSelector: "initWithDisplayIdentifier:spaceID:") != nil {
        print("switching backend: available")
        return 0
    }
    print("switching backend: UNAVAILABLE on this macOS build")
    return 1
}

func printUsage() {
    print("""
    \(programName) \(version) — jump straight to a macOS Desktop

    usage:
      \(programName) daemon        run the hotkey daemon (SIGHUP reloads the config)
      \(programName) go N          jump to Desktop N once
      \(programName) list          list Desktops; * marks the current one
      \(programName) check         validate the config and the switching backend
      \(programName) init          write a starter config
      \(programName) version

    config: \(configPath())
    """)
}

@main
struct Spacejump {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        let command = arguments.count > 1 ? arguments[1] : ""

        switch command {
        case "daemon": exit(Daemon.run())
        case "list": exit(commandList())
        case "check": exit(commandCheck())
        case "init": exit(commandInit())
        case "go":
            guard arguments.count > 2 else {
                log("`go` needs a Desktop number.")
                exit(2)
            }
            exit(commandGo(arguments[2]))
        case "version", "--version":
            print("\(programName) \(version)")
            exit(0)
        default:
            printUsage()
            exit(command.isEmpty ? 0 : 2)
        }
    }
}
