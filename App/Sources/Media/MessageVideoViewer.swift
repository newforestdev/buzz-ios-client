import AVKit
import BuzzKit
import Observation
import SwiftUI

/// The same player survives expanding inline playback to full screen and back.
@MainActor
@Observable
final class MessageVideoPlayback {
    private static weak var active: MessageVideoPlayback?
    private(set) var player: AVPlayer?
    private(set) var failure: String?
    private var resource: MessageVideoResource?
    private var statusObservation: NSKeyValueObservation?
    private var ownsAudioSession = false

    func play(source: MessageVideoStore.Source, authorization: (any MediaReadAuthorizing)?) {
        Self.active?.close()
        Self.active = self
        failure = nil
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            ownsAudioSession = true
            let resource = MessageVideoResource(source: source, authorization: authorization)
            self.resource = resource
            let item = AVPlayerItem(asset: resource.asset)
            item.preferredForwardBufferDuration = 5
            let video = AVPlayer(playerItem: item)
            player = video
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === item else { return }
                    self.playbackFailed()
                }
            }
            video.play()
        } catch {
            playbackFailed()
        }
    }

    func pause() { player?.pause() }
    static func pauseActive() { active?.pause() }
    static func closeActive() { active?.close() }

    func playbackFailed() {
        close()
        failure = "Couldn't play this video. Check your connection and try again. Its format may not be supported."
    }

    func close() {
        failure = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        resource?.close()
        resource = nil
        if Self.active === self { Self.active = nil }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}

struct MessageVideoViewer: View {
    let media: MessageMedia
    let playback: MessageVideoPlayback
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if let player = playback.player {
                    VideoPlayer(player: player)
                        .accessibilityLabel(MessageMediaDescription.label(for: media, state: .loaded))
                } else {
                    ContentUnavailableView {
                        Label("Couldn't play video", systemImage: "video.slash")
                    } description: {
                        Text(playback.failure ?? "Tap Try again to load this video.")
                    } actions: {
                        Button("Try again", action: retry).buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 56)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.hiveSymbol(.body, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.hivePress(.control, in: .circle))
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close video")
            .padding(12)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
    }
}
