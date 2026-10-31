import AVFoundation
import BuzzKit
import UniformTypeIdentifiers

/// Supplies authenticated, seekable ranges using AVFoundation's public resource loader.
@MainActor
final class MessageVideoResource: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let source: MessageVideoStore.Source
    private let authorization: (any MediaReadAuthorizing)?
    private let byteBudget: Int64?
    private var suppliedBytes: Int64 = 0
    private var requestedChunks: Set<Int64> = []
    private var pending: [ObjectIdentifier: (request: AVAssetResourceLoadingRequest, task: Task<Void, Never>)] = [:]

    init(source: MessageVideoStore.Source, authorization: (any MediaReadAuthorizing)?, byteBudget: Int64? = nil) {
        self.source = source
        self.authorization = authorization
        self.byteBudget = byteBudget
        var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
        components.scheme = "steelbeach-video"
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    func resourceLoader(
        _: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(request)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.pending[key] = nil }
            do {
                try await self.supply(request)
                guard !Task.isCancelled, !request.isCancelled else { return }
                request.finishLoading()
            } catch {
                guard !Task.isCancelled, !request.isCancelled else { return }
                request.finishLoading(with: error)
            }
        }
        pending[key] = (request, task)
        return true
    }

    func resourceLoader(_: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeValue(forKey: ObjectIdentifier(request))?.task.cancel()
    }

    func close() {
        let work = Array(pending.values)
        pending.removeAll()
        for entry in work {
            entry.task.cancel()
            if !entry.request.isCancelled, !entry.request.isFinished {
                entry.request.finishLoading(with: URLError(.cancelled))
            }
        }
        asset.cancelLoading()
    }

    private func supply(_ request: AVAssetResourceLoadingRequest) async throws {
        let dataRequest = request.dataRequest
        var offset = max(dataRequest?.currentOffset ?? 0, dataRequest?.requestedOffset ?? 0)
        var end: Int64?
        if let dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(
                Int64(dataRequest.requestedLength)
            )
            guard !overflow else { throw MessageVideoStore.Failure.invalidResponse }
            end = requestedEnd
        }
        repeat {
            try Task.checkCancellation()
            let chunkOffset = offset / MessageVideoStore.chunkSize * MessageVideoStore.chunkSize
            if !requestedChunks.contains(chunkOffset) {
                if let byteBudget, suppliedBytes + MessageVideoStore.chunkSize > byteBudget {
                    throw MessageVideoStore.Failure.previewBudget
                }
                requestedChunks.insert(chunkOffset)
                suppliedBytes += MessageVideoStore.chunkSize
            }
            let part = try await MessageVideoStore.shared.chunk(for: source, at: offset, authorization: authorization)
            try Task.checkCancellation()
            guard !request.isCancelled else { return }
            try setInformation(request.contentInformationRequest, chunk: part)
            guard let dataRequest else { return }
            let upper = min(part.offset + Int64(part.data.count), end ?? part.total)
            guard offset < upper else { return }
            let lowerIndex = Int(offset - part.offset)
            let upperIndex = Int(upper - part.offset)
            dataRequest.respond(with: part.data.subdata(in: lowerIndex ..< upperIndex))
            offset = upper
            if offset >= min(end ?? part.total, part.total) { return }
        } while true
    }

    private func setInformation(
        _ info: AVAssetResourceLoadingContentInformationRequest?, chunk: MessageVideoStore.Chunk
    ) throws {
        guard let info else { return }
        let candidates = [source.mimeType.flatMap { UTType(mimeType: $0) },
                          UTType(mimeType: chunk.mimeType), UTType(filenameExtension: source.url.pathExtension)]
        let type = candidates.compactMap { $0 }.first { $0.conforms(to: .movie) } ?? .mpeg4Movie
        if let allowed = info.allowedContentTypes, !allowed.isEmpty {
            guard allowed.contains(type.identifier) else { throw MessageVideoStore.Failure.invalidResponse }
        }
        info.contentType = type.identifier
        info.contentLength = chunk.total
        info.isByteRangeAccessSupported = true
    }
}
