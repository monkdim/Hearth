import Foundation
import os

/// One-time data migration from the previous "Ember" identity to "Hearth".
/// Moves the entire Application Support directory (including downloaded
/// models — multi-GB) and copies UserDefaults so the user doesn't lose state.
enum Migration {
    private static let logger = Logger(subsystem: "com.colbydimaggio.hearth", category: "Migration")
    private static let markerKey = "hearth.migratedFromEmber"

    static func runIfNeeded() {
        migrateApplicationSupport()
        migrateUserDefaults()
    }

    private static func migrateApplicationSupport() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let oldDir = appSupport.appending(path: "Ember", directoryHint: .isDirectory)
        let newDir = appSupport.appending(path: "Hearth", directoryHint: .isDirectory)

        guard fm.fileExists(atPath: oldDir.path) else { return }
        guard !fm.fileExists(atPath: newDir.path) else { return }

        do {
            try fm.moveItem(at: oldDir, to: newDir)
            logger.info("Moved Ember Application Support → Hearth")
        } catch {
            logger.error("Application Support move failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func migrateUserDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        defer { defaults.set(true, forKey: markerKey) }

        // Read the Ember-era preferences file directly. The new app is running
        // under a different bundle id, so the system loaded a fresh defaults
        // domain — we have to grab the old plist out-of-band.
        let oldPlistPath = NSHomeDirectory() + "/Library/Preferences/com.colbydimaggio.ember.plist"
        guard let dict = NSDictionary(contentsOfFile: oldPlistPath) as? [String: Any] else { return }

        for (key, value) in dict {
            // Only port the ember-namespaced keys; system-injected keys aren't ours.
            guard key.hasPrefix("ember.") else { continue }
            let newKey = "hearth." + String(key.dropFirst("ember.".count))
            // Don't clobber a value the user has already set under Hearth.
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
        logger.info("Copied Ember UserDefaults → Hearth")
    }
}
