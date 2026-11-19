import Foundation
import libzstd

enum ZstdDecompress {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func isZstd(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(magic)
    }

    static func decompress(_ source: URL, to destination: URL, maxBytes: Int = 256 * 1024 * 1024) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        guard let firstChunk = try reader.read(upToCount: 65536), !firstChunk.isEmpty else {
            throw ImportError.unreadable
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        if !isZstd(firstChunk) {
            try copyRaw(firstChunk: firstChunk, reader: reader, writer: writer, maxBytes: maxBytes)
            return
        }

        guard let stream = ZSTD_createDStream() else { throw ImportError.unreadable }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw ImportError.unreadable }

        let outCapacity = max(65536, ZSTD_DStreamOutSize())
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)
        var totalWritten = 0
        var lastResult: Int = 1
        var currentChunk: Data? = firstChunk

        while let chunk = currentChunk, !chunk.isEmpty {
            try chunk.withUnsafeBytes { rawIn in
                guard let inBase = rawIn.baseAddress else { return }
                var inBuf = ZSTD_inBuffer(src: inBase, size: rawIn.count, pos: 0)
                while inBuf.pos < inBuf.size {
                    let produced = try outBuffer.withUnsafeMutableBytes { rawOut -> Int in
                        guard let outBase = rawOut.baseAddress else { throw ImportError.unreadable }
                        var outBuf = ZSTD_outBuffer(dst: outBase, size: outCapacity, pos: 0)
                        let code = ZSTD_decompressStream(stream, &outBuf, &inBuf)
                        guard ZSTD_isError(code) == 0 else { throw ImportError.unreadable }
                        lastResult = code
                        return outBuf.pos
                    }
                    if produced > 0 {
                        totalWritten += produced
                        guard totalWritten <= maxBytes else { throw ImportError.unreadable }
                        try writer.write(contentsOf: outBuffer.prefix(produced))
                    }
                }
            }
            currentChunk = try reader.read(upToCount: 65536)
        }
        guard lastResult == 0, totalWritten > 0 else { throw ImportError.unreadable }
    }

    static func decompressData(_ data: Data, maxBytes: Int = 16 * 1024 * 1024) throws -> Data {
        guard !data.isEmpty else { throw ImportError.unreadable }
        if !isZstd(data) {
            guard data.count <= maxBytes else { throw ImportError.unreadable }
            return data
        }
        guard let stream = ZSTD_createDStream() else { throw ImportError.unreadable }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw ImportError.unreadable }

        let outCapacity = max(65536, ZSTD_DStreamOutSize())
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)
        var output = Data()
        var lastResult: Int = 1
        try data.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.baseAddress else { throw ImportError.unreadable }
            var inBuf = ZSTD_inBuffer(src: inBase, size: rawIn.count, pos: 0)
            while inBuf.pos < inBuf.size {
                let produced = try outBuffer.withUnsafeMutableBytes { rawOut -> Int in
                    guard let outBase = rawOut.baseAddress else { throw ImportError.unreadable }
                    var outBuf = ZSTD_outBuffer(dst: outBase, size: outCapacity, pos: 0)
                    let code = ZSTD_decompressStream(stream, &outBuf, &inBuf)
                    guard ZSTD_isError(code) == 0 else { throw ImportError.unreadable }
                    lastResult = code
                    return outBuf.pos
                }
                if produced > 0 {
                    guard output.count + produced <= maxBytes else { throw ImportError.unreadable }
                    output.append(contentsOf: outBuffer.prefix(produced))
                }
            }
        }
        guard lastResult == 0, !output.isEmpty else { throw ImportError.unreadable }
        return output
    }

    static func compress(_ data: Data) throws -> Data {
        let bound = ZSTD_compressBound(data.count)
        guard ZSTD_isError(bound) == 0 else { throw ImportError.unreadable }
        var output = Data(count: bound)
        let written: Int = output.withUnsafeMutableBytes { rawOut in
            data.withUnsafeBytes { rawIn in
                guard let dst = rawOut.baseAddress, let src = rawIn.baseAddress else { return 0 }
                return ZSTD_compress(dst, bound, src, data.count, 3)
            }
        }
        guard ZSTD_isError(written) == 0, written > 0 else { throw ImportError.unreadable }
        output.count = written
        return output
    }

    private static func copyRaw(firstChunk: Data, reader: FileHandle, writer: FileHandle, maxBytes: Int) throws {
        var total = firstChunk.count
        guard total <= maxBytes else { throw ImportError.unreadable }
        try writer.write(contentsOf: firstChunk)
        while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
            total += chunk.count
            guard total <= maxBytes else { throw ImportError.unreadable }
            try writer.write(contentsOf: chunk)
        }
    }
}
