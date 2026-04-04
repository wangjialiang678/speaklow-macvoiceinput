import Foundation

struct EnvLoader {
    static func loadDashScopeAPIKey() -> String? {
        // Priority: .env 文件优先于环境变量，避免继承 shell 中的错误 key
        // 1. ~/.config/speaklow/.env
        // 2. Executable's parent directory .env
        // 3. Environment variable DASHSCOPE_API_KEY (fallback)
        if let key = loadKeyFromConfigFiles() {
            return key
        }

        if let value = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        return nil
    }

    /// 仅从 .env 配置文件加载 key，不检查环境变量。用于 bridge 子进程环境构建，
    /// 避免继承 shell 中的错误 key。
    static func loadKeyFromConfigFiles() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = homeDir + "/.config/speaklow/.env"
        if let key = loadKey("DASHSCOPE_API_KEY", fromEnvFile: configPath) {
            return key
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingPath = executableURL.deletingLastPathComponent().path + "/.env"
            if let key = loadKey("DASHSCOPE_API_KEY", fromEnvFile: siblingPath) {
                return key
            }
        }

        return nil
    }

    private static func loadKey(_ key: String, fromEnvFile path: String) -> String? {
        let dict = loadEnvFile(at: path)
        if let value = dict[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    static func loadEnvFile(at path: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            // Split on first '='
            guard let eqRange = trimmed.range(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes if present
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
