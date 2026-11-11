import Compression
import Foundation

/// A small ZIP reader (for EPUBs) and STORE-only writer (for backups), so the
/// app needs no third-party packages. Supports stored and deflated entries.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    let data: Data
    private(set) var entries: [String: Entry] = [:]

    enum ZipError: LocalizedError {
        case notZip, unsupported(String), corrupt(String)
        var errorDescription: String? {
            switch self {
            case .notZip: return "The file isn't a valid EPUB (it isn't a ZIP archive)."
            case .unsupported(let n): return "Unsupported compression in \(n)."
            case .corrupt(let n): return "Damaged entry \(n) in the file."
            }
        }
    }

    init(data: Data) throws {
        self.data = data
        // End of central directory: last 22+ bytes, signature 0x06054b50.
        let count = data.count
        guard count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = count - 22
        let lowest = max(0, count - 22 - 65_535)
        while i >= lowest {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let total = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<total {
            guard p + 46 <= count, u32(p) == 0x0201_4B50 else { break }
            let method = u16(p + 10)
            let csize = Int(u32(p + 20))
            let size = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            let offset = Int(u32(p + 42))
            let nameData = data.subdata(in: data.startIndex + p + 46 ..< data.startIndex + p + 46 + nameLen)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: size, localHeaderOffset: offset)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    private func u16(_ o: Int) -> UInt16 {
        UInt16(data[data.startIndex + o]) | UInt16(data[data.startIndex + o + 1]) << 8
    }

    private func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }

    /// Looks a path up as given, percent-decoded, or case-insensitively.
    func entry(_ path: String) -> Entry? {
        if let e = entries[path] { return e }
        if let d = path.removingPercentEncoding, let e = entries[d] { return e }
        let lower = path.lowercased()
        return entries.first { $0.key.lowercased() == lower }?.value
    }

    func read(_ path: String) throws -> Data? {
        guard let e = entry(path) else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, u32(h) == 0x0403_4B50 else { throw ZipError.corrupt(e.name) }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt(e.name) }
        let raw = data.subdata(in: data.startIndex + start ..< data.startIndex + start + e.compressedSize)
        switch e.method {
        case 0: return raw
        case 8: return try inflate(raw, size: e.size, name: e.name)
        default: throw ZipError.unsupported(e.name)
        }
    }

    func string(_ path: String) throws -> String? {
        guard let d = try read(path) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB is headerless deflate).
    private func inflate(_ input: Data, size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          inp.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt(name) }
        return output
    }
}

/// Writes an uncompressed ZIP (EPUBs and images are already compressed).
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    mutating func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(body.count)
        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x0800); local.le16(0)
        local.le16(0); local.le16(0x21) // time/date
        local.le32(crc); local.le32(UInt32(content.count)); local.le32(UInt32(content.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        body.append(local); body.append(nameData); body.append(content)

        var c = Data()
        c.le32(0x0201_4B50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(0)
        c.le16(0); c.le16(0x21)
        c.le32(crc); c.le32(UInt32(content.count)); c.le32(UInt32(content.count))
        c.le16(UInt16(nameData.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0); c.le32(0)
        c.le32(offset)
        central.append(c); central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        return out
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
