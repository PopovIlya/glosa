import Foundation

/// Reads keys from the process environment, then from the first `.env` found.
/// Keys never live in code.
public struct Env: Sendable {
    public let values: [String: String]

    public init(values: [String: String]) { self.values = values }

    public subscript(key: String) -> String? {
        guard let v = values[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    public static func load() -> Env {
        var merged: [String: String] = [:]
        if let url = candidateFiles().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            merged = parse(text)
        }
        // The real environment wins over the file.
        for (k, v) in ProcessInfo.processInfo.environment { merged[k] = v }
        return Env(values: merged)
    }

    /// Working directory, then every parent of the app bundle (so `build/Glosa.app` finds the repo's `.env`),
    /// then `~/.config/glosa/.env`.
    static func candidateFiles() -> [URL] {
        var urls = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")]
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            urls.append(dir.appendingPathComponent(".env"))
            dir = dir.deletingLastPathComponent()
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/glosa/.env"))
        return urls
    }

    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
