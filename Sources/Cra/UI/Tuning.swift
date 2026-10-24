import AppKit
import Observation

/// Rendering constants calibrated against Arc. They can be changed at run time
/// for calibration with `cra://debug?lift=0.15&liftInactive=0.93&alpha=1&toolbar=0.4&material=21`.
@MainActor @Observable
final class CraTuning {
    static let shared = CraTuning()

    /// White layer over the behind-window blur (active / inactive window).
    var liftActive: Double = 0.0
    var liftInactive: Double = 0.75
    /// Multiplier on the theme's gradient opacity (vibrant themes only).
    var gradientAlphaScale: Double = 1
    /// Black overlay that makes the toolbar band out of the space background.
    var toolbarAlpha: Double = 0.40
    var material: NSVisualEffectView.Material = .hudWindow
    var forceActiveBlur = false
    var darkBlur = true

    func apply(_ q: [String: String]) {
        if let v = q["lift"].flatMap(Double.init) { liftActive = v }
        if let v = q["liftInactive"].flatMap(Double.init) { liftInactive = v }
        if let v = q["alpha"].flatMap(Double.init) { gradientAlphaScale = v }
        if let v = q["toolbar"].flatMap(Double.init) { toolbarAlpha = v }
        if let v = q["material"].flatMap(Int.init), let m = NSVisualEffectView.Material(rawValue: v) { material = m }
        if let v = q["state"] { forceActiveBlur = v == "active" }
        if let v = q["appearance"] { darkBlur = v != "light" }
    }
}
