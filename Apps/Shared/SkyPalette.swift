import UIKit

/// Sun/mixed/shade colours as a function of how much direct beam is getting through.
enum SkyPalette {
    static let clearSun = UIColor(red: 1.00, green: 0.78, blue: 0.20, alpha: 0.95)
    static let clearMixed = UIColor(red: 0.98, green: 0.91, blue: 0.72, alpha: 0.90)
    static let clearShade = UIColor(red: 0.36, green: 0.45, blue: 0.56, alpha: 0.85)
    /// The flat light of an overcast day: one slate for everything. Dark enough to stay
    /// visible over Apple's light-grey streets (a paler grey made the sidewalks vanish).
    static let flat = UIColor(red: 0.42, green: 0.47, blue: 0.56, alpha: 0.90)

    /// Any colour faded toward the flat overcast light by how much beam is missing.
    static func fade(_ color: UIColor, beam: Double) -> UIColor {
        lerp(flat, color, CGFloat(min(1, max(0, beam))))
    }

    static func colors(beam: Double) -> (sun: UIColor, mixed: UIColor, shade: UIColor) {
        let t = CGFloat(min(1, max(0, beam)))
        return (lerp(flat, clearSun, t), lerp(flat, clearMixed, t), lerp(flat, clearShade, t))
    }

    /// A block's fill for its sunny share: shade → mixed → sun, then faded by the beam.
    /// Translucent, so streets stay readable under the density view.
    static func cell(fraction: Double, beam: Double, alpha: CGFloat = 0.42) -> UIColor {
        let f = CGFloat(min(1, max(0, fraction)))
        let base = f < 0.5 ? lerp(clearShade, clearMixed, f * 2) : lerp(clearMixed, clearSun, (f - 0.5) * 2)
        return fade(base, beam: beam).withAlphaComponent(alpha)
    }

    static func lerp(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: aa + (ba - aa) * t)
    }
}
