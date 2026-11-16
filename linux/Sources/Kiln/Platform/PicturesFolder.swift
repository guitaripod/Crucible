import Foundation

/// The desktop's Pictures folder (`XDG_PICTURES_DIR` in `user-dirs.dirs`, else `~/Pictures`), where saved images go
/// under names that never replace an earlier file.
public enum PicturesFolder {
    public static var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        if let text = try? String(contentsOf: config.appendingPathComponent("user-dirs.dirs"), encoding: .utf8),
           let path = picturesPath(in: text, home: home.path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("Pictures", isDirectory: true)
    }

    /// The Pictures entry of a `user-dirs.dirs` file, with `$HOME` expanded; nil when it has none or names the home itself.
    public static func picturesPath(in text: String, home: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("XDG_PICTURES_DIR="), let equals = trimmed.firstIndex(of: "=") else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            value = value.replacingOccurrences(of: "$HOME", with: home)
            guard value.hasPrefix("/"), URL(fileURLWithPath: value).standardized.path != URL(fileURLWithPath: home).standardized.path else { return nil }
            return value
        }
        return nil
    }

    /// Writes `data` as `name`.png in the folder, creating it, with " 2", " 3" and on added when the name is taken.
    public static func write(_ data: Data, named name: String, in folder: URL = url) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-")
        var candidate = folder.appendingPathComponent("\(base).png")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).png")
            number += 1
        }
        try data.write(to: candidate, options: .withoutOverwriting)
        return candidate
    }

    /// `url`'s path with the home folder shown as `~`.
    public static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
