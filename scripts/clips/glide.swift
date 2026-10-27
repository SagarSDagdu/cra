// glide <step> ...: hand-like pointer moves posted to the HID tap at 240 Hz.
//   m:x,y,ms   glide to x,y over ms (eased; drags if the button is down)
//   j:x,y      jump to x,y
//   d / u      button down / up at the current point
//   w:ms       wait
import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .hidSystemState)
var pos = CGEvent(source: nil)!.location
var down = false

func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.post(tap: .cghidEventTap)
}
func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
    let n = parts.count > 1 ? parts[1].split(separator: ",").map { Double($0)! } : []
    switch parts[0] {
    case "m":
        let from = pos, to = CGPoint(x: n[0], y: n[1])
        let steps = max(1, Int(n[2] / 1000 * 240))
        // A slight arc, like a wrist, perpendicular to the path.
        let dx = to.x - from.x, dy = to.y - from.y, len = max(1, hypot(dx, dy))
        let bow = min(18, len * 0.06)
        for i in 1...steps {
            let t = ease(Double(i) / Double(steps))
            let arc = sin(Double.pi * t) * bow
            pos = CGPoint(x: from.x + dx * t - dy / len * arc, y: from.y + dy * t + dx / len * arc)
            post(down ? .leftMouseDragged : .mouseMoved, pos)
            usleep(useconds_t(1_000_000 / 240))
        }
        pos = to
    case "j":
        pos = CGPoint(x: n[0], y: n[1]); post(down ? .leftMouseDragged : .mouseMoved, pos)
    case "d":
        down = true; post(.leftMouseDown, pos)
    case "u":
        down = false; post(.leftMouseUp, pos)
    case "w":
        usleep(useconds_t(n[0] * 1000))
    default:
        FileHandle.standardError.write("bad step \(arg)\n".data(using: .utf8)!); exit(1)
    }
}
