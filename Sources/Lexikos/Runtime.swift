import Foundation

/// Storage/service identity deliberately remains Lexikos across the brand change.
struct Runtime {
    let root: URL
    let readOnly: Bool
    let isolated: Bool
    let migrationEnabled: Bool
    let syncEnabled: Bool
    let defaults: UserDefaults
    let temporaryDefaultsDomain: String?
    private static let cleanupRegistry = TemporaryDefaultsRegistry()
    static let current = Runtime()

    func cleanup() {
        guard let domain = temporaryDefaultsDomain else { return }
        Self.removeTemporaryDomain(domain, defaults: defaults)
    }

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key) else { return nil }
            precondition(i + 1 < arguments.count && !arguments[i + 1].hasPrefix("--"), "参数缺少值：" + key)
            return arguments[i + 1]
        }
        readOnly = arguments.contains("--learning-report") || arguments.contains("--dump")
        let path = value("--data-dir") ?? environment["MYVOCAB_DATA_DIR"] ?? environment["LEXIKOS_DATA"]
        let testing = environment["XCTestConfigurationFilePath"] != nil || arguments.first?.contains(".xctest") == true
        isolated = path != nil || arguments.contains("--snapshot") || testing
        root = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? (isolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("myvocab-isolated-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lexikos"))
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lexikos").resolvingSymlinksInPath().path
        let selected = root.resolvingSymlinksInPath().path
        precondition(!isolated || readOnly || (selected != live && !selected.hasPrefix(live + "/")), "隔离运行不能使用正式数据目录")
        migrationEnabled = !isolated && !arguments.contains("--no-migration") && !arguments.contains("--learning-report")
        syncEnabled = !isolated && !arguments.contains("--no-sync") && !arguments.contains("--learning-report")
        if let name = value("--defaults-domain") {
            precondition(name != Bundle.main.bundleIdentifier, "不能用自身 Bundle ID 作为偏好 suite")
            defaults = UserDefaults(suiteName: name)!
            temporaryDefaultsDomain = nil // Explicit domains belong to the caller.
        } else if isolated {
            // Absolute suite paths keep CFPreferences' asynchronous empty-file writes
            // out of the user's Library/Preferences, even after process exit.
            let name = FileManager.default.temporaryDirectory
                .appendingPathComponent("com.yixuanwu.myvocab.isolated." + UUID().uuidString).path
            defaults = UserDefaults(suiteName: name)!
            temporaryDefaultsDomain = name
            Self.cleanupRegistry.register(name, defaults: defaults)
        } else {
            defaults = .standard
            temporaryDefaultsDomain = nil
        }
    }
}

/// exit() bypasses Swift destructors, so CLI and normal app termination use atexit.
private final class TemporaryDefaultsRegistry {
    private let lock = NSLock()
    private var domains: [(String, UserDefaults)] = []
    init() { atexit { Runtime.cleanupAtExit() } }
    func register(_ name: String, defaults: UserDefaults) {
        lock.lock(); defer { lock.unlock() }
        domains.append((name, defaults))
    }
    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        for (name, defaults) in domains {
            Runtime.removeTemporaryDomain(name, defaults: defaults)
        }
        domains.removeAll()
    }
}

extension Runtime {
    fileprivate static func removeTemporaryDomain(_ name: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        // CFPreferences can retain an empty plist after removing the domain.
        let file = URL(fileURLWithPath: name + ".plist")
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { fputs("临时偏好清理失败：\(error)\n", stderr) }
    }
    fileprivate static func cleanupAtExit() { cleanupRegistry.cleanup() }
}
