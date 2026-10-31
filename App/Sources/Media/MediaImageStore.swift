import BuzzKit
import Foundation

/// Original images and relay thumbnails share the video cache's disk budget.
actor MediaImageStore {
    static let shared = MediaImageStore()
    struct HTTPFailure: Error { let status: Int }
    private var inFlight: [String: (id: UUID, task: Task<Data, Error>)] = [:]
    private var prefetchCount = 0

    func data(
        for url: URL, scope: String, session: URLSession, authorization: (any MediaReadAuthorizing)?
    ) async throws -> Data {
        let key = MediaDiskCache.key("image|\(scope)|\(url.absoluteString)")
        if let data = await MediaDiskCache.shared.data(for: key) { return data }
        if let existing = inFlight[key] { return try await existing.task.value }
        let identifier = UUID()
        let task = Task { try await Self.fetch(url, session: session, authorization: authorization) }
        inFlight[key] = (identifier, task)
        defer { if inFlight[key]?.id == identifier { inFlight[key] = nil } }
        let data = try await task.value
        try Task.checkCancellation()
        if RemoteImageLoader.downsample(data, maxPixelSize: 1) != nil {
            await MediaDiskCache.shared.insert(data, for: key)
        }
        return data
    }

    func prefetch(
        _ url: URL, scope: String, session: URLSession, authorization: (any MediaReadAuthorizing)?
    ) async {
        do {
            while prefetchCount >= 2 { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
            prefetchCount += 1
            defer { prefetchCount -= 1 }
            _ = try await data(for: url, scope: scope, session: session, authorization: authorization)
        } catch {
            // Optional work. Opening the image will retry normally.
        }
    }

    func cancelPending() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
    }

    private nonisolated static func fetch(
        _ url: URL, session: URLSession, authorization: (any MediaReadAuthorizing)?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        if let header = await authorization?.authorization(for: url) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw HTTPFailure(status: http.statusCode)
        }
        return data
    }
}
