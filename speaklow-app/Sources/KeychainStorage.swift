import Foundation
import Security

enum AppSettingsStorage {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.speaklow.app"

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SpeakLow"
        let dir = appSupport.appendingPathComponent(appName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var settingsFileURL: URL {
        storageDirectory.appendingPathComponent(".settings")
    }

    // MARK: - Public API

    static func load(account: String) -> String? {
        let dict = loadSettings()
        return dict[account]
    }

    static func save(_ value: String, account: String) {
        var dict = loadSettings()
        dict[account] = value
        writeSettings(dict)
    }

    static func delete(account: String) {
        var dict = loadSettings()
        dict.removeValue(forKey: account)
        writeSettings(dict)
    }

    // MARK: - File I/O

    private static func loadSettings() -> [String: String] {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeSettings(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let url = settingsFileURL
        try? data.write(to: url, options: [.atomic])
        // Restrict to owner-only read/write (0600)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
