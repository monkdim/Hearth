import Foundation
import Observation

/// Settings for the local OpenAI-compatible HTTP server Hearth exposes so
/// other tools (OpenClaw, scripts, IDE extensions) can use Hearth's active
/// MLX model as if it were a hosted LLM.
///
/// Everything is local-only — the listener binds to 127.0.0.1, never the
/// public interface. The bearer token is friction against random localhost
/// processes hitting the endpoint, not a security boundary against a hostile
/// local user.
@MainActor
@Observable
final class APIServerStore {
    private static let enabledKey = "hearth.apiServer.enabled"
    private static let portKey    = "hearth.apiServer.port"
    private static let tokenKey   = "hearth.apiServer.token"

    /// Default port. Picked next to Ollama's 11434 so the muscle memory
    /// transfers — but different enough to not collide if Ollama is also
    /// running on this machine.
    static let defaultPort: Int = 11435

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }
    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Self.portKey)
        }
    }
    var token: String {
        didSet {
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let savedPort = defaults.integer(forKey: Self.portKey)
        self.port = savedPort > 0 ? savedPort : Self.defaultPort
        if let existing = defaults.string(forKey: Self.tokenKey), !existing.isEmpty {
            self.token = existing
        } else {
            let fresh = Self.makeToken()
            defaults.set(fresh, forKey: Self.tokenKey)
            self.token = fresh
        }
    }

    func regenerateToken() {
        token = Self.makeToken()
    }

    /// 32 bytes of randomness, base64-url-encoded. Nothing fancy.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
