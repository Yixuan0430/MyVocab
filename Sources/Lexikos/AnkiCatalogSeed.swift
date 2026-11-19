import Foundation

struct AnkiCatalogSeed: Sendable {
    let fetchedAt: Date
    private let rawPayloads: [String: Data]

    static let bundled: AnkiCatalogSeed? = loadBundled()

    func decks(for query: String) -> [AnkiWebDeckSummary]? {
        guard let payload = rawPayloads[query] else { return nil }
        return try? AnkiWebClient.decodeListDecks(payload)
    }

    var availableLanguages: [String] { Array(rawPayloads.keys).sorted() }

    static func parse(_ compressed: Data) -> AnkiCatalogSeed? {
        guard let raw = try? ZstdDecompress.decompressData(compressed) else { return nil }
        let bytes = [UInt8](raw)
        guard bytes.count >= 14, bytes[0] == 0x4D, bytes[1] == 0x59, bytes[2] == 0x56, bytes[3] == 0x43 else {
            return nil
        }
        var offset = 4
        func readUInt16() -> UInt16? {
            guard bytes.count - offset >= 2 else { return nil }
            let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return v
        }
        func readUInt32() -> UInt32? {
            guard bytes.count - offset >= 4 else { return nil }
            var v: UInt32 = 0
            for idx in 0..<4 { v |= UInt32(bytes[offset + idx]) << (idx * 8) }
            offset += 4
            return v
        }
        func readInt64() -> Int64? {
            guard bytes.count - offset >= 8 else { return nil }
            var v: UInt64 = 0
            for idx in 0..<8 { v |= UInt64(bytes[offset + idx]) << (idx * 8) }
            offset += 8
            return Int64(bitPattern: v)
        }
        guard let epoch = readInt64(), let count = readUInt16() else { return nil }
        var payloads: [String: Data] = [:]
        payloads.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let keyLen = readUInt16(), let valLen = readUInt32() else { return nil }
            let kLen = Int(keyLen)
            let vLen = Int(valLen)
            guard bytes.count - offset >= kLen + vLen else { return nil }
            let key = String(bytes: bytes[offset..<(offset + kLen)], encoding: .utf8) ?? ""
            offset += kLen
            let val = Data(bytes[offset..<(offset + vLen)])
            offset += vLen
            if !key.isEmpty { payloads[key] = val }
        }
        return AnkiCatalogSeed(fetchedAt: Date(timeIntervalSince1970: TimeInterval(epoch)), rawPayloads: payloads)
    }

    private static func loadBundled() -> AnkiCatalogSeed? {
        guard let url = resourceURL(), let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private static func resourceURL() -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AnkiCatalogSeed", withExtension: "bin.zst") { return url }
        #endif
        return Bundle.main.url(forResource: "AnkiCatalogSeed", withExtension: "bin.zst")
    }
}

enum ProtoWire {
    enum Value { case varint(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    struct Field { let number: Int; let value: Value }

    static func fields(in data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard i < bytes.count else { throw AnkiWebError.badResponse }
                let byte = bytes[i]
                i += 1
                guard shift < 63 || byte <= 1 else { throw AnkiWebError.badResponse }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
            }
            throw AnkiWebError.badResponse
        }
        while i < bytes.count {
            let key = try readVarint()
            let number = Int(key >> 3)
            guard number > 0 else { throw AnkiWebError.badResponse }
            switch key & 7 {
            case 0:
                out.append(Field(number: number, value: .varint(try readVarint())))
            case 1:
                guard bytes.count - i >= 8 else { throw AnkiWebError.badResponse }
                let raw = bytes[i..<i + 8].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
                i += 8
                out.append(Field(number: number, value: .fixed64(raw)))
            case 2:
                guard let len = Int(exactly: try readVarint()), len >= 0, len <= bytes.count - i else {
                    throw AnkiWebError.badResponse
                }
                out.append(Field(number: number, value: .bytes(Data(bytes[i..<i + len]))))
                i += len
            case 5:
                guard bytes.count - i >= 4 else { throw AnkiWebError.badResponse }
                let raw = bytes[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
                i += 4
                out.append(Field(number: number, value: .fixed32(raw)))
            default:
                throw AnkiWebError.badResponse
            }
        }
        return out
    }
}
