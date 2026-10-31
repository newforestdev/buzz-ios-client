import CryptoKit
import Foundation

/// Shared byte budget for image originals, thumbnails and video ranges. Caches is
/// excluded from device backups and may also be reclaimed by iOS under storage pressure.
actor MediaDiskCache {
    static let shared = MediaDiskCache()
    static let byteLimit: Int64 = 5_000_000_000

    private struct Entry {
        let size: Int64
        var accessed: Date
    }

    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SteelbeachMedia", isDirectory: true)
    private var entries: [String: Entry] = [:]
    private var total: Int64 = 0
    private var indexed = false

    nonisolated static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func data(for key: String) -> Data? {
        prepare()
        let file = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file) else {
            if let missing = entries.removeValue(forKey: key) { total -= missing.size }
            return nil
        }
        let now = Date()
        // A range may be read repeatedly during playback; avoid a filesystem write per read.
        if now.timeIntervalSince(entries[key]?.accessed ?? .distantPast) > 30 {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            entries[key]?.accessed = now
        }
        return data
    }

    func insert(_ data: Data, for key: String) {
        prepare()
        guard Int64(data.count) <= Self.byteLimit else { return }
        // Leave space for the OS and other app data instead of filling a nearly full device.
        let available = (try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage ?? Self.byteLimit
        trim(to: min(Self.byteLimit - Int64(data.count), total + available - 256_000_000 - Int64(data.count)))
        guard available >= Int64(data.count) + 32_000_000 else { return }
        let file = directory.appendingPathComponent(key)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            total -= entries[key]?.size ?? 0
            entries[key] = Entry(size: Int64(data.count), accessed: Date())
            total += Int64(data.count)
            trim(to: Self.byteLimit)
        } catch {
            // A cache write is optional: keep showing/playing the fetched bytes.
        }
    }

    private func prepare() {
        guard !indexed else { return }
        indexed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for file in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? [] {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            entries[file.lastPathComponent] = Entry(
                size: size, accessed: values.contentModificationDate ?? .distantPast
            )
            total += size
        }
        trim(to: Self.byteLimit)
    }

    private func trim(to limit: Int64) {
        guard total > max(0, limit) else { return }
        for (key, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard total > max(0, limit) else { break }
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(key))
                entries[key] = nil
                total -= entry.size
            } catch {
                // Retry eviction on a later insertion if iOS temporarily protects a file.
            }
        }
    }
}
