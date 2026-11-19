import CloudKit
import Foundation
import os
#if os(macOS)
import Security
#endif

@MainActor final class Sync {
    static let container = "iCloud.com.yixuanwu.lexikos"
    private static let zone = CKRecordZone.ID(zoneName: "Lexikos")
    private static let log = Logger(subsystem: "com.yixuanwu.lexikos", category: "sync")

    private let decks: DeckStore
    private let progress: ProgressStore
    private var engine: CKSyncEngine?
    let environment: String
    let stateFile: URL
    let onServerFile: URL
    let recordTagsFile: URL
    private var onServer: Set<String>
    private var deckSystemFields: [String: Data] = [:]
    private var dirtyDecks: Set<UUID> = []
    private var retriedConflicts: Set<UUID> = []
    private var persistenceFailed = false
    private var delegate: Delegate?

    nonisolated static func cloudEnvironment() -> String {
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any],
           let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
           let env = entitlements["com.apple.developer.icloud-container-environment"] as? String {
            return env.lowercased() == "production" ? "production" : "development"
        }
        #endif
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    init(decks: DeckStore, progress: ProgressStore, enabled: Bool = Runtime.current.syncEnabled,
         environment: String = Sync.cloudEnvironment()) {
        self.decks = decks
        self.progress = progress
        self.environment = environment
        let suffix = environment == "production" ? "-production" : ""
        stateFile = decks.storageRoot.appendingPathComponent("sync-state\(suffix).json")
        onServerFile = decks.storageRoot.appendingPathComponent("sync-uploaded\(suffix).json")
        recordTagsFile = decks.storageRoot.appendingPathComponent("sync-record-tags\(suffix).json")
        onServer = []
        deckSystemFields = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: recordTagsFile))) ?? [:]
        guard enabled, decks.storageRoot.path == progress.storageRoot.path,
              decks.storageRoot.path == Runtime.current.root.path else { return }
        onServer = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: onServerFile))) ?? []
        let saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(contentsOf: stateFile))
        let delegate = Delegate(owner: self)
        engine = CKSyncEngine(.init(database: CKContainer(identifier: Self.container).privateCloudDatabase,
                                    stateSerialization: saved, delegate: delegate))
        self.delegate = delegate
        decks.onSave = { [weak self] deck in
            self?.handleLocalDeckSave(deck.id)
        }
        decks.onDelete = { [weak self] id in
            self?.dirtyDecks.remove(id)
            self?.retriedConflicts.remove(id)
            self?.enqueue(.saveRecord(Self.deletionID(id)))
            self?.enqueue(.deleteRecord(Self.id(deck: id)))
        }
        progress.onRecord = { [weak self] in self?.enqueue(.saveRecord(Self.id(event: $0.id))) }
        enqueueAll()
    }

    func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            Self.log.error("sync: \(error, privacy: .public)")
        }
    }

    private func handleLocalDeckSave(_ id: UUID) {
        dirtyDecks.insert(id)
        retriedConflicts.remove(id)
        let name = Self.id(deck: id).recordName
        if onServer.remove(name) != nil {
            persistOnServer()
        }
        enqueue(.saveRecord(Self.id(deck: id)))
    }

    private func enqueue(_ change: CKSyncEngine.PendingRecordZoneChange) {
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: [change])
    }

    private func enqueueAll() {
        guard let engine else { return }
        for deleted in decks.deletedIDs { enqueue(.deleteRecord(Self.id(deck: deleted))) }
        let ids = decks.decks.map { Self.id(deck: $0.id) }
            + progress.byID.keys.map { Self.id(event: $0) }
            + decks.deletedIDs.map { Self.deletionID($0) }
        let missing = ids.filter { !onServer.contains($0.recordName) }
        guard !missing.isEmpty else { return }
        if onServer.isEmpty { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zone))]) }
        engine.state.add(pendingRecordZoneChanges: missing.map { .saveRecord($0) })
    }

    private func markOnServer(_ names: [String]) {
        guard !names.isEmpty else { return }
        let updated = onServer.union(names)
        do {
            try JSONEncoder().encode(updated).write(to: onServerFile, options: .atomic)
            onServer = updated
        } catch {
            Self.log.error("sync uploaded: \(error)")
        }
    }

    private func persistOnServer() {
        do {
            try JSONEncoder().encode(onServer).write(to: onServerFile, options: .atomic)
        } catch {
            Self.log.error("sync uploaded: \(error)")
        }
    }

    private func storeSystemFields(_ records: [CKRecord]) {
        var changed = false
        for r in records where r.recordType == "Deck" {
            deckSystemFields[r.recordID.recordName] = Self.encodeSystemFields(r)
            changed = true
        }
        guard changed else { return }
        do {
            try JSONEncoder().encode(deckSystemFields).write(to: recordTagsFile, options: .atomic)
        } catch {
            Self.log.error("sync tags: \(error)")
        }
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func decodeDeckRecord(from data: Data, expectedID: CKRecord.ID) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver),
              record.recordType == "Deck",
              record.recordID == expectedID else { return nil }
        return record
    }

    private static func id(deck: UUID) -> CKRecord.ID { CKRecord.ID(recordName: "deck-\(deck.uuidString)", zoneID: zone) }
    private static func deletionID(_ deck: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "deleted-deck-" + deck.uuidString, zoneID: zone)
    }
    private static func id(event: UUID) -> CKRecord.ID { CKRecord.ID(recordName: "event-\(event.uuidString)", zoneID: zone) }

    func record(for id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        if name.hasPrefix("deleted-deck-"), let uuid = UUID(uuidString: String(name.dropFirst("deleted-deck-".count))),
           decks.deletedIDs.contains(uuid), let payload = try? JSONEncoder().encode(DeckDeletion(deletedDeck: uuid)) {
            let r = CKRecord(recordType: "Event", recordID: id)
            r["deck"] = uuid.uuidString
            r["payload"] = payload
            return r
        }
        if name.hasPrefix("deck-"), let uuid = UUID(uuidString: String(name.dropFirst(5))), let deck = decks.deck(uuid) {
            let r = deckSystemFields[name].flatMap { Self.decodeDeckRecord(from: $0, expectedID: id) }
                ?? CKRecord(recordType: "Deck", recordID: id)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
            guard (try? JSONEncoder().encode(deck.cards).write(to: file, options: .atomic)) != nil else { return nil }
            r["name"] = deck.name
            r["cards"] = CKAsset(fileURL: file)
            return r
        }
        if name.hasPrefix("event-"), let uuid = UUID(uuidString: String(name.dropFirst(6))), let e = progress.byID[uuid],
           let payload = try? JSONEncoder().encode(e) {
            let r = CKRecord(recordType: "Event", recordID: id)
            r["deck"] = e.deck.uuidString
            r["payload"] = payload
            return r
        }
        return nil
    }

    func apply(_ records: [CKRecord], deleted: [CKRecord.ID]) -> [String] {
        var applied: [String] = []
        var events: [ReviewEvent] = []
        var deckRecords: [CKRecord] = []
        var expectedApplied = 0
        let ordered = records.sorted {
            $0.recordID.recordName.hasPrefix("deleted-deck-") && !$1.recordID.recordName.hasPrefix("deleted-deck-")
        }
        for r in ordered {
            switch r.recordType {
            case "Deck":
                expectedApplied += 1
                guard let uuid = UUID(uuidString: String(r.recordID.recordName.dropFirst(5))),
                      let name = r["name"] as? String, let url = (r["cards"] as? CKAsset)?.fileURL,
                      let cards = try? JSONDecoder().decode([Card].self, from: Data(contentsOf: url)) else { continue }
                if decks.deletedIDs.contains(uuid) {
                    enqueue(.deleteRecord(Self.id(deck: uuid)))
                    applied.append(r.recordID.recordName)
                    continue
                }
                if decks.upsert(Deck(id: uuid, name: name, cards: cards)) {
                    deckRecords.append(r)
                    applied.append(r.recordID.recordName)
                }
            case "Event":
                expectedApplied += 1
                if let data = r["payload"] as? Data, let deletion = try? JSONDecoder().decode(DeckDeletion.self, from: data) {
                    if decks.remove(deletion.deletedDeck) { applied.append(r.recordID.recordName) }
                    continue
                }
                if let data = r["payload"] as? Data, let e = try? JSONDecoder().decode(ReviewEvent.self, from: data) {
                    events.append(e)
                }
            default:
                break
            }
        }
        if !deckRecords.isEmpty { storeSystemFields(deckRecords) }
        if !events.isEmpty { progress.merge(events) }
        applied += events.filter { progress.byID[$0.id] != nil }.map { "event-" + $0.id.uuidString }
        for id in deleted where id.recordName.hasPrefix("deck-") {
            if let uuid = UUID(uuidString: String(id.recordName.dropFirst(5))), !decks.remove(uuid) { persistenceFailed = true }
        }
        if persistenceFailed || applied.count < expectedApplied {
            persistenceFailed = true
            do {
                if FileManager.default.fileExists(atPath: stateFile.path) {
                    try FileManager.default.removeItem(at: stateFile)
                }
            } catch {
                Self.log.error("sync cursor: \(error)")
            }
        }
        return applied
    }

    private static func isTransient(_ code: CKError.Code) -> Bool {
        switch code {
        case .batchRequestFailed, .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private func clearLocalSyncState() {
        for file in [stateFile, onServerFile, recordTagsFile] where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { Self.log.error("sync reset: \(error)") }
        }
        onServer = []
        deckSystemFields = [:]
        dirtyDecks = []
        retriedConflicts = []
    }

    fileprivate func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let u):
            guard !persistenceFailed else { return }
            do { try JSONEncoder().encode(u.stateSerialization).write(to: stateFile, options: .atomic) }
            catch { Self.log.error("sync state: \(error)") }
        case .accountChange(let c):
            switch c.changeType {
            case .signIn:
                enqueueAll()
            case .switchAccounts, .signOut:
                clearLocalSyncState()
            @unknown default:
                break
            }
        case .fetchedRecordZoneChanges(let f):
            markOnServer(apply(f.modifications.map(\.record), deleted: f.deletions.map(\.recordID)))
        case .sentRecordZoneChanges(let s):
            storeSystemFields(s.savedRecords)
            for saved in s.savedRecords where saved.recordID.recordName.hasPrefix("deck-") {
                if let uuid = UUID(uuidString: String(saved.recordID.recordName.dropFirst(5))) {
                    dirtyDecks.remove(uuid)
                    retriedConflicts.remove(uuid)
                }
            }
            markOnServer(s.savedRecords.map(\.recordID.recordName))
            handleFailedSaves(s.failedRecordSaves)
            for (recordID, error) in s.failedRecordDeletes where Self.isTransient(error.code) {
                enqueue(.deleteRecord(recordID))
            }
        case .fetchedDatabaseChanges(let f):
            if f.deletions.contains(where: { $0.zoneID == Self.zone }) {
                onServer = []
                deckSystemFields = [:]
                for file in [onServerFile, recordTagsFile] where FileManager.default.fileExists(atPath: file.path) {
                    do { try FileManager.default.removeItem(at: file) }
                    catch { Self.log.error("sync zone reset: \(error)") }
                }
                enqueueAll()
            }
        default:
            break
        }
    }

    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave]) {
        for failure in failures {
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { continue }
                let name = failure.record.recordID.recordName
                if name.hasPrefix("deck-"), let uuid = UUID(uuidString: String(name.dropFirst(5))),
                   dirtyDecks.contains(uuid), !retriedConflicts.contains(uuid) {
                    storeSystemFields([server])
                    retriedConflicts.insert(uuid)
                    enqueue(.saveRecord(failure.record.recordID))
                } else {
                    markOnServer(apply([server], deleted: []))
                }
            case .zoneNotFound:
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zone))])
                enqueue(.saveRecord(failure.record.recordID))
            default:
                if Self.isTransient(failure.error.code) {
                    enqueue(.saveRecord(failure.record.recordID))
                } else {
                    Self.log.error("save \(failure.record.recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
                }
            }
        }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let engine else { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: Array(pending.prefix(300))) { id in
            await self.record(for: id)
        }
    }

    private final class Delegate: CKSyncEngineDelegate, @unchecked Sendable {
        weak var owner: Sync?
        init(owner: Sync) { self.owner = owner }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            await owner?.handle(event)
        }

        func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
            await owner?.nextBatch(context)
        }
    }
}

@MainActor final class SettingsSync {
    private static let keys = ["lang", "newPerDay", "groupSize", "autoSpeak", "startDeck"]
    private let cloud = NSUbiquitousKeyValueStore.default
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var isPulling = false

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pull() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.push() }
            })
        cloud.synchronize()
        pull()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let a as NSObject, let b as NSObject):
            return a.isEqual(b)
        default:
            return false
        }
    }

    private func pull() {
        isPulling = true
        defer { isPulling = false }
        let d = Runtime.current.defaults
        for k in Self.keys {
            if let v = cloud.object(forKey: k), !Self.valuesEqual(d.object(forKey: k), v) {
                d.set(v, forKey: k)
            }
        }
    }

    private func push() {
        guard !isPulling else { return }
        let d = Runtime.current.defaults
        for k in Self.keys {
            if let v = d.object(forKey: k), !Self.valuesEqual(cloud.object(forKey: k), v) {
                cloud.set(v, forKey: k)
            }
        }
    }
}
