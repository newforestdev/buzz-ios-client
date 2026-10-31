import AVFoundation
import BuzzKit
import UIKit

/// Configuration and cancellation stay on the main actor; AVFoundation performs the
/// asynchronous extraction internally and returns exactly one result for the one time.
@MainActor
private final class MessageVideoFrameGenerator {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 720)
    }

    func frame() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))]
            ) { _, image, _, result, error in
                if result == .succeeded, let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? MessageVideoStore.Failure.invalidResponse)
                }
            }
        }
    }

    func cancel() { generator.cancelAllCGImageGeneration() }
}

@MainActor
enum MessageVideoPreview {
    private static var generating = 0
    private nonisolated static let cache = RemoteImageCache(countLimit: 64, totalCostLimit: 16 * 1024 * 1024)
    private static var pending: [String: (id: UUID, task: Task<UIImage?, Never>)] = [:]

    nonisolated static func cachedImage(source: MessageVideoStore.Source) -> UIImage? {
        cache.image(forKey: source.key)
    }

    static func storedImage(source: MessageVideoStore.Source) async -> UIImage? {
        if let image = cachedImage(source: source) { return image }
        guard let data = await MediaDiskCache.shared.data(for: "\(source.key)-poster"),
              let image = UIImage(data: data) else { return nil }
        guard !Task.isCancelled else { return nil }
        cache.insert(image, forKey: source.key)
        return image
    }

    static func releaseMemory() { cache.removeAll() }

    static func cancelPending() {
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
    }

    static func image(
        source: MessageVideoStore.Source, authorization: (any MediaReadAuthorizing)?, downloaded: Bool = false
    ) async -> UIImage? {
        if let image = await storedImage(source: source) { return image }
        guard !Task.isCancelled else { return nil }
        if let entry = pending[source.key] {
            let image = await entry.task.value
            if image != nil || !downloaded || Task.isCancelled { return image }
            if pending[source.key]?.id == entry.id { pending[source.key] = nil }
        }
        let identifier = UUID()
        // Deliberately owned here, not by the row's visibility task: a quick scroll
        // must not discard a frame that is about to finish and could be saved for reuse.
        // Backgrounding/sign-out can still cancel it, and extraction has a deadline.
        let task = Task { await generate(source: source, authorization: authorization, downloaded: downloaded) }
        pending[source.key] = (identifier, task)
        let image = await task.value
        if pending[source.key]?.id == identifier { pending[source.key] = nil }
        return image
    }

    private static func generate(
        source: MessageVideoStore.Source, authorization: (any MediaReadAuthorizing)?, downloaded: Bool
    ) async -> UIImage? {
        do {
            while generating >= 2 { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            generating += 1
            defer { generating -= 1 }
            let localFile = downloaded ? try await MessageVideoStore.shared.cachedPreviewFile(for: source) : nil
            defer { if let localFile { try? FileManager.default.removeItem(at: localFile) } }
            let resource = localFile == nil ? MessageVideoResource(
                source: source, authorization: authorization,
                byteBudget: (downloaded ? 16 : 4) * 1024 * 1024
            ) : nil
            let asset = localFile.map { AVURLAsset(url: $0) } ?? resource!.asset
            let generator = MessageVideoFrameGenerator(asset: asset)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                generator.cancel()
                resource?.close()
            }
            defer {
                deadline.cancel()
                generator.cancel()
                resource?.close()
            }
            let frame = try await withTaskCancellationHandler {
                try await generator.frame()
            } onCancel: {
                Task { @MainActor in generator.cancel() }
            }
            try Task.checkCancellation()
            let image = UIImage(cgImage: frame)
            if let data = image.jpegData(compressionQuality: 0.8) {
                await MediaDiskCache.shared.insert(data, for: "\(source.key)-poster")
            }
            guard !Task.isCancelled else { return nil }
            cache.insert(image, forKey: source.key)
            return image
        } catch {
            return nil
        }
    }
}
