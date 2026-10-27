// keys-up: releases every modifier, in case a test left one held down.
import CoreGraphics
let src = CGEventSource(stateID: .hidSystemState)
for k: CGKeyCode in [55, 54, 59, 62, 56, 60, 58, 61, 63] { let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)!; e.flags = []; e.post(tap: .cghidEventTap) }
let f = CGEvent(source: src)!; f.type = .flagsChanged; f.flags = []; f.post(tap: .cghidEventTap)
