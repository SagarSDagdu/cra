// key <code> [ctrl ...]: posts one plain key press. Send ⌘ shortcuts with
// `cliclick kd:cmd t:x ku:cmd` instead: a key-up carrying ⌘ leaves ⌘ latched.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let code = CGKeyCode(a[1])!
var flags: CGEventFlags = (123...126).contains(Int(code)) ? [.maskNumericPad, .maskSecondaryFn] : []
for m in a.dropFirst(2) { switch m { case "cmd": flags.insert(.maskCommand); case "ctrl": flags.insert(.maskControl); case "shift": flags.insert(.maskShift); case "opt": flags.insert(.maskAlternate); default: break } }
let src = CGEventSource(stateID: .privateState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(30000)
}
