import BuzzKit
import SwiftUI

// The three things drawn in an attachment's reserved box when a picture is not.
//
// All three fill the box they are given rather than sizing to their content, because the
// box was reserved before anyone knew which of them it would be — see
// ``MessageMediaLayout``.

// MARK: - The frame

/// The fill and the outline every attachment sits in.
///
/// It exists as a shared shape rather than a modifier per state because a loading box, a
/// failed box and a letterboxed picture all have to be the *same* rectangle: the whole
/// point of reserving space is that nothing about the box changes when the bytes arrive,
/// and a border that appears with the picture is a change.
enum MessageMediaFrame {
    /// The surface behind an attachment. A tint of the secondary colour rather than a
    /// fixed grey, so it sits correctly in both appearances and behind a letterboxed
    /// picture in either.
    static let fill = Color.secondary.opacity(0.12)

    /// The hairline that separates a pale picture from the conversation behind it.
    static let border = Color.secondary.opacity(0.25)

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MessageMediaLayout.cornerRadius, style: .continuous)
    }
}

// MARK: - Loading

/// The box while the bytes are on their way.
///
/// Deliberately still: no spinner, no shimmer, no `ProgressView`. A conversation can hold
/// a dozen of these and each animation is a display-link the scroll has to share; the app
/// has already paid once for animating something that sits in a message list. The dimmed
/// glyph says "a picture goes here" without asking for a frame of its own, and the box is
/// the right size and shape either way, so nothing about the layout is waiting on the
/// answer.
struct MessageMediaLoadingView: View {
    var body: some View {
        Image(systemName: "photo")
            .font(.hiveSymbol(.title2))
            .foregroundStyle(.secondary.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - Failure

/// The box when there is no picture and there is not going to be one.
///
/// A URL that 404s, a host that is not reachable, or bytes no decoder can read all land
/// here, and they are not distinguished on screen: the reader's question is "what was
/// that?", not "which layer failed?". So the answer is the author's own `alt` where there
/// is one, and the fact that something was there where there is not — never an empty box,
/// which reads as a rendering bug rather than as a missing file.
///
/// It is a control, because "try again" is a real answer for the commonest cause. The
/// media host on this deployment is tailnet-only, so walking out of range fails every
/// attachment at once and walking back in fixes them; a retry that clears the loader's
/// negative cache is the difference between that recovering on a tap and recovering when
/// the entries age out.
struct MessageMediaFailureView: View {
    let media: MessageMedia

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.hiveSymbol(.title3))
                .foregroundStyle(.secondary)
            Text(MessageMediaDescription.placeholderText(for: media, state: .failed))
                .font(.hive(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
