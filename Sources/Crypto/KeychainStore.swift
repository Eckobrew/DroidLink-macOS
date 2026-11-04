import Foundation

public enum KeychainStore {
    private static let directoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DroidLink/security", isDirectory: true)
        let legacyDir = appSupport.appendingPathComponent("DroidDock/security", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) && FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return dir
    }()

    private static func fileURL(for key: String) -> URL {
        let sanitized = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return directoryURL.appendingPathComponent("\(sanitized).dat")
    }

    public static func save(key: String, data: Data) {
        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[KeychainStore] Failed to save key \(key): \(error)")
        }
    }

    public static func load(key: String) -> Data? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func delete(key: String) {
        let url = fileURL(for: key)
        try? FileManager.default.removeItem(at: url)
    }
}
