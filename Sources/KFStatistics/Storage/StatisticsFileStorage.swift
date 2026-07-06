// ──────────────────────────────────────────────
//  StatisticsFileStorage
//
//  A pure-Swift file-based storage with
//  length-prefixed frame format for append-only
//  event logging. Uses atomic writes for durability.
//  No external dependencies.
// ──────────────────────────────────────────────

import Foundation

final actor StatisticsFileStorage: StatisticsStorage {

    private let fileManager: FileManager
    private let baseURL: URL

    private(set) var estimatedByteCount: UInt64 = 0

    init(directory: URL? = nil) {
        let fileManager = FileManager.default
        let base: URL
        if let dir = directory {
            base = dir
        } else if let caches = fileManager.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first {
            base = caches.appendingPathComponent("com.eventstracker", isDirectory: true)
        } else {
            base = fileManager.temporaryDirectory.appendingPathComponent("com.eventstracker", isDirectory: true)
        }

        self.fileManager = fileManager
        self.baseURL = base
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // ────────────────────────────────────────────
    //  MARK: - Public API
    // ────────────────────────────────────────────

    /// Append a length-prefixed frame to the WAL.
    /// Frame format: [4-byte LE UInt32 length][payload bytes]
    func append(_ data: Data, forKey key: String) async throws {
        let url = fileURL(forKey: key)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.seekToEnd()
        var length = UInt32(data.count).littleEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try handle.write(contentsOf: data)

        estimatedByteCount += UInt64(4 + data.count)
    }

    /// Read all frames, strip length prefixes, return each frame's payload as a separate element.
    func popAll(forKey key: String) async throws -> [Data] {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        let raw = try Data(contentsOf: url)
        guard !raw.isEmpty else { return [] }

        var batches: [Data] = []
        var cursor = 0
        while cursor + 4 <= raw.count {
            let b0 = UInt32(raw[cursor])
            let b1 = UInt32(raw[cursor + 1]) << 8
            let b2 = UInt32(raw[cursor + 2]) << 16
            let b3 = UInt32(raw[cursor + 3]) << 24
            let frameLen = Int(b0 | b1 | b2 | b3)
            cursor += 4
            // Reject unreasonable frame lengths (corrupted file)
            guard frameLen > 0, cursor + frameLen <= raw.count else { break }
            batches.append(Data(raw[cursor..<cursor + frameLen]))
            cursor += frameLen
        }

        // Truncate
        let sz = UInt64(raw.count)
        try Data().write(to: url, options: .atomic)
        estimatedByteCount -= min(estimatedByteCount, sz)
        return batches
    }

    func flush() async throws {
        // Atomic writes are immediately durable — no fsync needed.
    }

    func clear() async throws {
        estimatedByteCount = 0
        let contents = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(forKey key: String) -> URL {
        baseURL.appendingPathComponent("\(key).evtlog")
    }
}
