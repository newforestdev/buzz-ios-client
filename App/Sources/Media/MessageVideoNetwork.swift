import Foundation

/// One pooled URLSession delivers blocks of bytes, rather than iterating over a movie
/// byte by byte. The lock covers the task table and every mutable request state.
final class MessageVideoNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MessageVideoNetwork()

    private final class Request {
        let start: Int64
        let continuation: CheckedContinuation<MessageVideoStore.Chunk, Error>
        var data = Data()
        var total: Int64 = 0
        var length = 0
        var mimeType = "video/mp4"
        var failure: Error?

        init(start: Int64, continuation: CheckedContinuation<MessageVideoStore.Chunk, Error>) {
            self.start = start
            self.continuation = continuation
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func install(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let cancelled = cancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func fetch(_ request: URLRequest, start: Int64) async throws -> MessageVideoStore.Chunk {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                requests[task.taskIdentifier] = Request(start: start, continuation: continuation)
                lock.unlock()
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let request = requests[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            request.failure = (response as? HTTPURLResponse)?.statusCode == 200
                ? MessageVideoStore.Failure.rangeUnsupported : MessageVideoStore.Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        guard let header = http.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else {
            request.failure = MessageVideoStore.Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        let parts = header.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, let first = Int64(parts[0]), let last = Int64(parts[1]),
              let total = Int64(parts[2]), first == request.start, last >= first,
              last - first < MessageVideoStore.chunkSize, total > last,
              last == min(first + MessageVideoStore.chunkSize - 1, total - 1),
              http.mimeType != "text/html", http.mimeType != "application/json" else {
            request.failure = MessageVideoStore.Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        request.total = total
        request.length = Int(last - first + 1)
        request.mimeType = http.mimeType ?? "video/mp4"
        request.data.reserveCapacity(request.length)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let request = requests[dataTask.taskIdentifier] else { return }
        guard request.data.count + data.count <= request.length else {
            request.failure = MessageVideoStore.Failure.invalidResponse
            dataTask.cancel()
            return
        }
        request.data.append(data)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let request = requests.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let request else { return }
        if let failure = request.failure ?? error {
            request.continuation.resume(throwing: failure)
        } else if request.data.count != request.length || request.length == 0 {
            request.continuation.resume(throwing: MessageVideoStore.Failure.invalidResponse)
        } else {
            request.continuation.resume(returning: MessageVideoStore.Chunk(
                data: request.data, offset: request.start, total: request.total, mimeType: request.mimeType
            ))
        }
    }
}
