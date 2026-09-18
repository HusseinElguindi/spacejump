# spacejump

Jump straight to a macOS Desktop from the keyboard. No animation, no swipe
synthesis, no Accessibility permission, SIP stays on.

```sh
make
make install PREFIX=~/.local     # or PREFIX=/usr/local with sudo
spacejump init                   # write ~/.config/spacejump/config.json
spacejump check                  # validate config + switching backend
make load PREFIX=~/.local        # start the daemon via LaunchAgent
```

Then press <kbd>Ctrl</kbd>+<kbd>Opt</kbd>+<kbd>3</kbd>.

## Why not a synthetic swipe

Every "instant space switcher" works by forging the Dock-swipe gesture the
trackpad sends. That approach has three problems this tool avoids:

- **A swipe is relative.** "Go to Desktop 7" becomes "swipe N times and hope",
  with a prediction cache to guess where you landed. When a swipe is silently
  ignored the cache drifts and every later switch looks out of bounds. Direct
  jumps are all this tool does, so relative stepping is the wrong primitive.
- **It broke on macOS 27.** The Dock stopped reading the private `CGEvent`
  gesture fields; the payload now has to be smuggled in as a serialized IOHID
  blob under field 4205, whose layout is reverse-engineered and can change.
- **Instant swipes race the compositor.** Giving the gesture near-zero duration
  to kill the animation reintroduces a WindowServer surface-purge race — an
  unrendered menu bar, black wallpaper, broken screenshots.

`spacejump` instead drives the SkyLight WindowManager bridge operations
directly: show the target Space, hide its siblings on that display, set the
display's current Space. There is no gesture and no animation to suppress.

## Configuration

`~/.config/spacejump/config.json` (honours `XDG_CONFIG_HOME`):

```json
{
  "bindings": {
    "space1": "ctrl+opt+1",
    "space2": "ctrl+opt+2",
    "space3": "ctrl+opt+3"
  }
}
```

Names may be `"space3"` or just `"3"`. Desktops are numbered 1..N in Mission
Control order, counting only ordinary Desktops — fullscreen and tiled Spaces are
skipped. `spacejump list` prints the current numbering.

Modifiers: `cmd`/`command`, `opt`/`option`/`alt`, `ctrl`/`control`, `shift`.
Keys: digits, letters, `f1`–`f20`, arrows, `space`, `tab`, `return`, `escape`,
`grave`, `minus`, `equal`, `leftbracket`, `rightbracket`, `keypad0`–`keypad9`.
At least one modifier is required — a bare key would be captured system-wide.

`make reload` (or `pkill -HUP -x spacejump`) re-reads the config in place; the
daemon logs how many bindings came back.

### About Ctrl+N

The defaults use **Ctrl+Opt+N** because macOS ships its own "Switch to Desktop N"
on Ctrl+N. When those are enabled they already own the combination and
`RegisterEventHotKey` fails with `eventHotKeyExistsErr` — the daemon log names
the binding that lost. To use bare Ctrl+N, first turn the system ones off in
**System Settings → Keyboard → Keyboard Shortcuts → Mission Control**.

## Commands

| | |
|---|---|
| `spacejump daemon` | run the hotkey daemon (what the LaunchAgent starts) |
| `spacejump go N` | jump to Desktop N once |
| `spacejump list` | list Desktops; `*` marks the current one |
| `spacejump check` | validate config + backend availability |
| `spacejump init` | write a starter config |

`go` makes the tool usable as a backend for any other hotkey daemon (skhd,
Karabiner, Raycast) without running ours.

## Implementation notes

**The bridge operations are asynchronous.** `-performWithWMBridgeDelegate`
returns `void` and the work lands later. A short-lived CLI process will exit
before the switch happens and — if it does not check — report success for a
switch that never occurred. `spacejump` polls the Space census until the target
reads as active, pumping the run loop each round, and fails with a timeout
rather than lying. This was a real bug in the first working draft: `go 5`
returned exit 0 and did not move.

**`check` is necessary, not sufficient.** It confirms the private classes
resolve with the selectors this build expects. It does not prove a switch
lands — the failure above passed `check` cleanly. Use `go N` for that.

**Setting the current Space alone is not enough.** It updates the census while
the compositor keeps showing the old Desktop's windows. The order that works is
show target → hide siblings on that display → set current.

**Desktops are re-enumerated on every jump**, so adding or removing Desktops
never needs a reload, and a binding pointing past the end is reported rather
than fatal.

## Requirements and limits

- Apple Silicon, macOS 27. Verified end to end on **27.0, build 26A428**, SIP
  enabled: build, enumeration, switching, bounds handling, LaunchAgent, hotkeys
  and SIGHUP reload. Earlier macOS versions are untested — the bridge operations
  are private, and `spacejump check` reports if the ABI moved.
- No Accessibility permission: hotkeys use Carbon `RegisterEventHotKey` rather
  than an event tap.
- **Unverified:** multi-display layouts, fullscreen/tiled Spaces, and whether
  keyboard focus follows the switch. Single-display ordinary Desktops are the
  tested shape.

## Credits

The bridge-operation ABIs and the three-step activation order come from
[native-space-kit](https://github.com/Fjx-dylanZ/native-space-kit). The macOS 27
gesture breakage and the compositor race are documented in
[noswoosh](https://github.com/mmathys/noswoosh) issues #1 and #9.

MIT — see [LICENSE](LICENSE).
