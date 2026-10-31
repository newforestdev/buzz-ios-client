import BuzzKit
import Foundation

/// Authenticated ranges are shared by preview generation, prefetch and playback.
/// Only a small chunk is held in memory; the common image/video disk cache owns bytes.
actor MessageVideoStore {
    static let shared = MessageVideoStore()
    static let chunkSize: Int64 = 512 * 1024

    struct Source: Hashable, Sendable {
        let url: URL
        let scope: String
        let mimeType: String?

        var key: String { MediaDiskCache.key("video|\(scope)|\(url.absoluteString)") }
    }

    struct Chunk: Codable, Sendable {
        let data: Data
        let offset: Int64
        let total: Int64
        let mimeType: String
    }

    enum Failure: Error { case invalidResponse, rangeUnsupported, previewBudget }

    private var inFlight: [String: (id: UUID, task: Task<Chunk, Error>)] = [:]
    private var prefetching: Set<String> = []

    func chunk(
        for source: Source, at offset: Int64, authorization: (any MediaReadAuthorizing)?
    ) async throws -> Chunk {
        try Task.checkCancellation()
        let start = max(0, offset / Self.chunkSize * Self.chunkSize)
        let key = "\(source.key)-\(start)"
        if let stored = await MediaDiskCache.shared.data(for: key),
           let chunk = try? PropertyListDecoder().decode(Chunk.self, from: stored),
           chunk.offset == start, chunk.total > start,
           chunk.data.count == Int(min(Self.chunkSize, chunk.total - start)) {
            return chunk
        }
        if let existing = inFlight[key] { return try await existing.task.value }
        let identifier = UUID()
        let task = Task { try await Self.fetch(source, start: start, authorization: authorization) }
        inFlight[key] = (identifier, task)
        defer { if inFlight[key]?.id == identifier { inFlight[key] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        if let encoded = try? PropertyListEncoder().encode(result) {
            await MediaDiskCache.shared.insert(encoded, for: key)
        }
        return result
    }

    /// Runs behind the visible row, stopping when its task is cancelled or the app
    /// backgrounds. Two videos at most prefetch at once; playback can request any range.
    @discardableResult
    func prefetch(_ source: Source, authorization: (any MediaReadAuthorizing)?) async -> Bool {
        do {
            guard !prefetching.contains(source.key) else { return false }
            while prefetching.count >= 2 { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
            guard prefetching.insert(source.key).inserted else { return false }
            defer { prefetching.remove(source.key) }
            var offset: Int64 = 0
            repeat {
                try Task.checkCancellation()
                let part = try await chunk(for: source, at: offset, authorization: authorization)
                offset = part.offset + Int64(part.data.count)
                if offset >= part.total { break }
            } while true
            return true
        } catch {
            // Prefetch failure is silent; a tap retries the required range with fresh auth.
            return false
        }
    }

    func cancelPending() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
    }

    /// A small, fully cached clip can also be decoded through AVFoundation's local
    /// file path. No network fallback here, and no unbounded second copy of a movie.
    func cachedPreviewFile(for source: Source) async throws -> URL? {
        guard let first = await cachedChunk(source, start: 0), first.total <= 128 * 1024 * 1024 else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("steelbeach-preview-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        do {
            defer { try? handle.close() }
            var part = first
            while true {
                try Task.checkCancellation()
                try handle.write(contentsOf: part.data)
                let next = part.offset + Int64(part.data.count)
                if next == first.total { return file }
                guard let following = await cachedChunk(source, start: next), following.total == first.total else {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                part = following
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func cachedChunk(_ source: Source, start: Int64) async -> Chunk? {
        guard let bytes = await MediaDiskCache.shared.data(for: "\(source.key)-\(start)"),
              let part = try? PropertyListDecoder().decode(Chunk.self, from: bytes),
              part.offset == start, part.total > start,
              part.data.count == Int(min(Self.chunkSize, part.total - start)) else { return nil }
        return part
    }

    private nonisolated static func fetch(
        _ source: Source, start: Int64, authorization: (any MediaReadAuthorizing)?
    ) async throws -> Chunk {
        guard ["http", "https"].contains(source.url.scheme?.lowercased() ?? ""), source.url.host != nil else {
            throw Failure.invalidResponse
        }
        var request = URLRequest(url: source.url)
        request.setValue("bytes=\(start)-\(start + chunkSize - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let header = await authorization?.authorization(for: source.url) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return try await MessageVideoNetwork.shared.fetch(request, start: start)
    }
}
