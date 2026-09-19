import AppKit
import SwiftUI

extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA` (sRGB).
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    /// Perceived brightness 0…1.
    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

enum NoteAppearance {
    static let presets: [(name: String, hex: String)] = [
        ("Yellow", "#F5D76E"), ("Orange", "#F8B878"), ("Pink", "#F4A6C0"), ("Purple", "#C3A6F0"),
        ("Blue", "#9CC9F5"), ("Green", "#A8E0A0"), ("Gray", "#D5D8DC"),
    ]

    static func background(hex: String?) -> NSColor? { NSColor(hex: hex) }

    /// Explicit text color if set; otherwise black/white chosen for contrast with a custom
    /// background, or the system color when the note uses the default background.
    static func text(textHex: String?, backgroundHex: String?) -> NSColor {
        if let c = NSColor(hex: textHex) { return c }
        if let bg = NSColor(hex: backgroundHex) { return bg.luminance > 0.55 ? NSColor(white: 0.1, alpha: 1) : .white }
        return .textColor
    }
}
