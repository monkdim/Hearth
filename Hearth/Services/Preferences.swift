import Foundation
import Observation

/// App-wide user preferences. Persisted to UserDefaults so they survive launches.
@MainActor
@Observable
final class Preferences {
    private static let maxTokensKey = "hearth.maxResponseTokens"
    private static let temperatureKey = "hearth.temperature"
    private static let positionModeKey = "hearth.positionMode"
    private static let lastPanelOriginKey = "hearth.lastPanelOrigin"

    enum PositionMode: String, CaseIterable, Identifiable {
        case centered
        case rememberLast

        var id: String { rawValue }
        var label: String {
            switch self {
            case .centered: "Center of active screen"
            case .rememberLast: "Remember last position"
            }
        }
    }

    /// Maximum number of tokens the model is allowed to generate in a single response.
    /// Practical ceiling — most replies finish well below this.
    var maxResponseTokens: Int {
        didSet {
            UserDefaults.standard.set(maxResponseTokens, forKey: Self.maxTokensKey)
        }
    }

    /// Sampling temperature. 0 = deterministic, 1 = creative.
    var temperature: Double {
        didSet {
            UserDefaults.standard.set(temperature, forKey: Self.temperatureKey)
        }
    }

    /// Where the launcher panel appears on ⌥Space.
    var positionMode: PositionMode {
        didSet {
            UserDefaults.standard.set(positionMode.rawValue, forKey: Self.positionModeKey)
        }
    }

    /// Cached panel origin when `positionMode == .rememberLast`.
    var lastPanelOrigin: CGPoint? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.lastPanelOriginKey),
                  let point = try? JSONDecoder().decode(CGPointWrapper.self, from: data) else {
                return nil
            }
            return CGPoint(x: point.x, y: point.y)
        }
        set {
            if let newValue {
                let wrapper = CGPointWrapper(x: newValue.x, y: newValue.y)
                if let data = try? JSONEncoder().encode(wrapper) {
                    UserDefaults.standard.set(data, forKey: Self.lastPanelOriginKey)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastPanelOriginKey)
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.maxTokensKey)
        self.maxResponseTokens = stored > 0 ? stored : Self.defaultMaxTokens

        let storedTemp = UserDefaults.standard.object(forKey: Self.temperatureKey) as? Double
        self.temperature = storedTemp ?? 0.6

        let storedPos = UserDefaults.standard.string(forKey: Self.positionModeKey)
        self.positionMode = storedPos.flatMap { PositionMode(rawValue: $0) } ?? .centered
    }

    /// Discrete length presets for the response-length picker.
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case short    = 1024
        case medium   = 4096
        case long     = 8192
        case extended = 16384
        case max      = 32768

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .short:    "Short"
            case .medium:   "Medium"
            case .long:     "Long"
            case .extended: "Extended"
            case .max:      "Maximum"
            }
        }

        var subtitle: String {
            switch self {
            case .short:    "1K tokens · quick answers"
            case .medium:   "4K tokens · most chats"
            case .long:     "8K tokens · long code"
            case .extended: "16K tokens · big jobs"
            case .max:      "32K tokens · model ceiling"
            }
        }
    }

    static let defaultMaxTokens = LengthPreset.long.rawValue

    /// Snaps an arbitrary value to the closest preset for the picker UI.
    static func nearestPreset(to value: Int) -> LengthPreset {
        LengthPreset.allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .long
    }
}

/// CGPoint isn't Codable on its own; use a small wrapper.
private struct CGPointWrapper: Codable {
    let x: CGFloat
    let y: CGFloat
}
