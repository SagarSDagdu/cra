// record <pid> <seconds> <out.mov> [x,y,w,h]: records only that app's windows (even when
// covered) at 120 fps. The rect is in global points; default: the app's largest window.
import AVFoundation
import Foundation
import ScreenCaptureKit

let a = CommandLine.arguments
let pid = pid_t(a[1])!
let seconds = Double(a[2])!
let out = URL(fileURLWithPath: a[3])
try? FileManager.default.removeItem(at: out)

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamOutput {
    func recordingOutputDidStartRecording(_ r: SCRecordingOutput) { FileHandle.standardError.write("started\n".data(using: .utf8)!) }
    func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) { print("failed", e); exit(1) }
    func stream(_ s: SCStream, didOutputSampleBuffer b: CMSampleBuffer, of t: SCStreamOutputType) {}
}

Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let app = content.applications.first(where: { $0.processID == pid }) else { print("no app"); exit(1) }
    var rect: CGRect
    if a.count > 4 {
        let n = a[4].split(separator: ",").map { Double($0)! }
        rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    } else {
        let wins = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { print("no window"); exit(1) }
        rect = w.frame
    }
    guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { print("no display"); exit(1) }
    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    let cfg = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    cfg.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    cfg.width = Int(rect.width * scale)
    cfg.height = Int(rect.height * scale)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    cfg.showsCursor = true
    cfg.backgroundColor = .white
    cfg.queueDepth = 8
    let d = Delegate()
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(d, type: .screen, sampleHandlerQueue: .global())
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = out
    rc.outputFileType = .mov
    rc.videoCodecType = .hevc
    let ro = SCRecordingOutput(configuration: rc, delegate: d)
    try stream.addRecordingOutput(ro)
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    try await stream.stopCapture()
    try await Task.sleep(nanoseconds: 300_000_000)
    print(out.path, "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", "scale", scale)
    exit(0)
}
RunLoop.main.run()
