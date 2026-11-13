import Foundation

/// One-time moves from the app's former name (Nombres) and former bundle id (local.lexikos):
/// data folder and preferences.
enum Migration {
    static func run(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], defaults: UserDefaults = Runtime.current.defaults) throws {
        let fm = FileManager.default
        let support = support.resolvingSymlinksInPath()
        let old = support.appendingPathComponent("Nombres"), new = support.appendingPathComponent("Lexikos")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            let staging = support.appendingPathComponent("Lexikos-migration-staging")
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.copyItem(at: old, to: staging)
            guard let enumerator = fm.enumerator(atPath: old.path) else { throw CocoaError(.fileReadUnknown) }
            for case let relative as String in enumerator {
                let source = old.appendingPathComponent(relative)
                if try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    guard try Data(contentsOf: source) == Data(contentsOf: staging.appendingPathComponent(relative)) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            }
            try fm.moveItem(at: staging, to: new)
        }

        adoptDefaults(from: "local.nombres", flag: "migratedFromNombres", defaults: defaults)
        adoptDefaults(from: "local.lexikos", flag: "migratedFromLocalId", defaults: defaults)
    }

    /// Copies an old preferences domain into the current one, without overwriting and skipping AppKit's own keys.
    private static func adoptDefaults(from domain: String, flag: String, defaults d: UserDefaults) {
        guard !d.bool(forKey: flag) else { return }
        for (k, v) in d.persistentDomain(forName: domain) ?? [:]
        where !k.hasPrefix("NS") && d.object(forKey: k) == nil { d.set(v, forKey: k) }
        d.set(true, forKey: flag)
    }
}
