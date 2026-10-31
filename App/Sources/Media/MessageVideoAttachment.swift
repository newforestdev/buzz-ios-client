import AVKit
import BuzzKit
import SwiftUI
import UIKit

/// A fixed reservation: poster, inline player and errors replace pixels, never row height.
struct MessageVideoAttachment: View {
    let media: MessageMedia
    var onTap: (() -> Void)?
    var loader: RemoteImageLoader = .messageMedia
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.messageTap) private var messageTap
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var poster: RemoteImageResolved?
    @State private var generatedPoster: UIImage?
    @State private var generatedKey: String?
    @State private var visible = false
    @State private var isViewing = false
    @State private var playback = MessageVideoPlayback()
    @Namespace private var zoom

    private var source: MessageVideoStore.Source? {
        guard let url = URL(string: media.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, let community = environment.sessionCommunityID,
              let identity = environment.selfPubkeyHex else { return nil }
        return MessageVideoStore.Source(url: url, scope: "\(community)|\(identity)", mimeType: media.mimeType)
    }

    private var posterRequest: RemoteImageRequest {
        RemoteImageRequest(url: media.posterURL.flatMap(URL.init(string:)),
                           pixelSize: MessageMediaLayout.inlinePixelSize(displayScale: displayScale))
    }

    private struct Work: Equatable {
        let source: MessageVideoStore.Source?
        let visible: Bool
        let poster: RemoteImageRequest
    }

    private var work: Work {
        Work(source: source, visible: visible && scenePhase == .active, poster: posterRequest)
    }

    var body: some View {
        MessageMediaReservation(aspectRatio: media.aspectRatio, kind: .video) {
            ZStack {
                if let player = playback.player, !isViewing {
                    VideoPlayer(player: player)
                        .simultaneousGesture(TapGesture().onEnded { onTap?() })
                        .overlay(alignment: .topTrailing) {
                            Button {
                                onTap?()
                                isViewing = true
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.6), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand video")
                            .padding(4)
                        }
                } else {
                    preview
                }
            }
        }
        .clipShape(MessageMediaFrame.shape)
        .overlay { MessageMediaFrame.shape.strokeBorder(MessageMediaFrame.border, lineWidth: 1) }
        .matchedTransitionSource(id: media.id, in: zoom)
        .accessibilityAction(named: "Play video", play)
        .accessibilityAction(named: "Expand video") {
            if playback.player == nil { play() }
            isViewing = true
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        .task(id: work) {
            guard work.visible, let source = work.source else { return }
            await loadPoster(source: source)
        }
        .task(id: work) {
            guard work.visible, let source = work.source else { return }
            // Let a quick scroll past cancel before initiating a large download.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let complete = await MessageVideoStore.shared.prefetch(
                source, authorization: environment.mediaReadAuthorizer
            )
            // A first attempt may have exhausted its small streaming budget. Once
            // prefetch completes, try again against the already-cached video bytes.
            guard complete, !Task.isCancelled, fallbackPoster == nil,
                  poster?.request != posterRequest else { return }
            await loadPoster(source: source, downloaded: true)
        }
        .onChange(of: visible) { _, shown in
            if !shown, !isViewing { playback.close() }
        }
        .onChange(of: source) { _, _ in playback.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item === playback.player?.currentItem else { return }
            playback.playbackFailed()
        }
        .onDisappear {
            if !isViewing { playback.close() }
        }
        .fullScreenCover(isPresented: $isViewing, onDismiss: { playback.pause() }, content: {
            MessageVideoViewer(media: media, playback: playback, retry: play)
                .navigationTransition(.zoom(sourceID: media.id, in: zoom))
        })
    }

    private var preview: some View {
        Button(action: play) {
            Color.black.overlay {
                if let image = RemoteImageDisplay.drawn(
                    resolved: poster, request: posterRequest,
                    cached: { loader.cachedImage(for: $0, pixelSize: $1) }
                ) ?? fallbackPoster {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .overlay {
                Image(systemName: playback.failure == nil ? "play.fill" : "arrow.clockwise")
                    .font(.hiveSymbol(fixedSize: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.6), in: .circle)
            }
            .overlay(alignment: .bottomLeading) {
                Text(playback.failure == nil ? "Video" : "Couldn't play · Tap to retry")
                    .font(.hive(.caption, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(8)
            }
            .clipped()
        }
        .buttonStyle(.hivePress(.control, in: MessageMediaFrame.shape))
        .accessibilityLabel(MessageMediaDescription.label(for: media, state: .loaded))
        .accessibilityHint(playback.failure ?? "Plays the video inline")
    }

    private func loadPoster(source: MessageVideoStore.Source, downloaded: Bool = false) async {
        // Check a previously generated poster before retrying an absent/broken remote
        // poster URL. A remote timeout must not delay displaying our saved fallback.
        if let image = await MessageVideoPreview.storedImage(source: source) {
            guard !Task.isCancelled else { return }
            generatedPoster = image
            generatedKey = source.key
            return
        }
        let request = posterRequest
        if let url = request.url, let image = await loader.image(for: url, pixelSize: request.pixelSize) {
            guard !Task.isCancelled else { return }
            poster = RemoteImageResolved(request: request, image: image)
            return
        }
        guard !Task.isCancelled else { return }
        let image = await MessageVideoPreview.image(
            source: source, authorization: environment.mediaReadAuthorizer, downloaded: downloaded
        )
        guard !Task.isCancelled, let image else { return }
        generatedPoster = image
        generatedKey = source.key
    }

    private var fallbackPoster: UIImage? {
        guard let source else { return nil }
        return (generatedKey == source.key ? generatedPoster : nil)
            ?? MessageVideoPreview.cachedImage(source: source)
    }

    private func play() {
        onTap?()
        messageTap.run(single: {
            guard let source else { return }
            if let player = playback.player {
                player.play()
            } else {
                playback.play(source: source, authorization: environment.mediaReadAuthorizer)
            }
        }, double: nil)
    }
}
