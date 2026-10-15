import Foundation

enum RugSize: String, CaseIterable {
    case small, medium, large

    var coverage: Float {
        switch self {
        case .small: return 0.55
        case .medium: return 0.70
        case .large: return 0.84
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// UserDefaults-backed preferences. Environment variables override a few of them for debugging.
enum Settings {
    static let didChange = Notification.Name("BlanketSettingsDidChange")
    private static let defaults = UserDefaults.standard
    private static let env = ProcessInfo.processInfo.environment

    static var rugStyle: RugStyle {
        get {
            if let s = env["BLANKET_STYLE"], let style = RugStyle(rawValue: s.lowercased()) { return style }
            return RugStyle(rawValue: defaults.string(forKey: "rugStyle") ?? "") ?? .tabriz
        }
        set { defaults.set(newValue.rawValue, forKey: "rugStyle"); changed() }
    }

    static var customImagePath: String? {
        get {
            if let p = env["BLANKET_IMAGE"] { return p.isEmpty ? nil : p }
            return defaults.string(forKey: "customImagePath")
        }
        set { defaults.set(newValue, forKey: "customImagePath"); changed() }
    }

    static var rugSize: RugSize {
        get { RugSize(rawValue: defaults.string(forKey: "rugSize") ?? "") ?? .large }
        set { defaults.set(newValue.rawValue, forKey: "rugSize"); changed() }
    }

    static var rugHidden: Bool {
        get { defaults.bool(forKey: "rugHidden") }
        set { defaults.set(newValue, forKey: "rugHidden") }
    }

    static var flatCamera: Bool {
        env["BLANKET_FLAT_CAMERA"] != nil || defaults.bool(forKey: "flatCamera")
    }

    /// What the rug should be made from right now.
    static var rugSource: RugSource {
        if let path = customImagePath { return .image(URL(fileURLWithPath: path)) }
        return .style(rugStyle)
    }

    private static func changed() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
