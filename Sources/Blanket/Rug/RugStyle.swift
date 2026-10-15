import CoreGraphics

/// Colour roles used by the rug painter.
struct RugPalette {
    let red: CGColor        // field
    let darkRed: CGColor    // field, darker abrash bands
    let navy: CGColor       // medallion body, spandrels
    let deepNavy: CGColor   // main border background
    let cream: CGColor      // outlines, rings, inner guard
    let gold: CGColor       // stars, rosettes
    let teal: CGColor       // sprig accent
    let ink: CGColor        // sprig outline

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// Built-in rug designs. Same drawing, different palettes and seeds; Nain is an allover design.
enum RugStyle: String, CaseIterable {
    case tabriz, heriz, kashan, nain

    var displayName: String {
        switch self {
        case .tabriz: return "Tabriz"
        case .heriz: return "Heriz"
        case .kashan: return "Kashan"
        case .nain: return "Nain"
        }
    }

    var seed: UInt64 {
        switch self {
        case .tabriz: return 7
        case .heriz: return 19
        case .kashan: return 31
        case .nain: return 43
        }
    }

    /// Allover designs have no central medallion, pendants or spandrels.
    var allover: Bool { self == .nain }

    var palette: RugPalette {
        typealias P = RugPalette
        switch self {
        case .tabriz:
            return P(red: P.rgb(0.56, 0.12, 0.14), darkRed: P.rgb(0.40, 0.07, 0.10),
                     navy: P.rgb(0.11, 0.15, 0.32), deepNavy: P.rgb(0.07, 0.09, 0.22),
                     cream: P.rgb(0.93, 0.87, 0.74), gold: P.rgb(0.82, 0.64, 0.28),
                     teal: P.rgb(0.24, 0.44, 0.42), ink: P.rgb(0.09, 0.07, 0.09))
        case .heriz:
            return P(red: P.rgb(0.70, 0.30, 0.17), darkRed: P.rgb(0.55, 0.20, 0.10),
                     navy: P.rgb(0.13, 0.18, 0.36), deepNavy: P.rgb(0.09, 0.11, 0.24),
                     cream: P.rgb(0.95, 0.91, 0.80), gold: P.rgb(0.86, 0.70, 0.36),
                     teal: P.rgb(0.30, 0.50, 0.46), ink: P.rgb(0.10, 0.08, 0.08))
        case .kashan:
            return P(red: P.rgb(0.91, 0.86, 0.74), darkRed: P.rgb(0.86, 0.80, 0.66),
                     navy: P.rgb(0.12, 0.15, 0.35), deepNavy: P.rgb(0.48, 0.10, 0.14),
                     cream: P.rgb(0.97, 0.94, 0.86), gold: P.rgb(0.80, 0.62, 0.30),
                     teal: P.rgb(0.25, 0.45, 0.42), ink: P.rgb(0.30, 0.10, 0.12))
        case .nain:
            return P(red: P.rgb(0.93, 0.90, 0.82), darkRed: P.rgb(0.89, 0.86, 0.78),
                     navy: P.rgb(0.52, 0.62, 0.76), deepNavy: P.rgb(0.38, 0.48, 0.63),
                     cream: P.rgb(0.98, 0.97, 0.93), gold: P.rgb(0.76, 0.68, 0.52),
                     teal: P.rgb(0.62, 0.70, 0.80), ink: P.rgb(0.35, 0.40, 0.48))
        }
    }
}
