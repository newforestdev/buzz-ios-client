import SwiftUI

/// The home tab's compact compose control, and the panel that grows out of it.
///
/// # Why this is not a `Menu`
///
/// It was one, for a day. A `Menu` supplies the open and close animation, the dismissal, the
/// material and the accessibility — and it supplies its *own look*, which is the whole of
/// what was wrong with it here. Two things cannot be reached from inside the control:
///
/// - **The press shape.** While a menu is open iOS draws a rounded-rect platter behind the
///   label to show where the menu came from. On a circular glass button that reads as a
///   square appearing under the finger, and the platter's shape is not settable —
///   `contentShape`, `buttonBorderShape` and clipping all leave it alone, because it is
///   drawn by the presentation rather than by the label.
/// - **The panel.** A menu's rows are Apple's rows. The owner's reference is a glass card
///   that *grows out of the button* carrying a subtitled row and a prominent action, which
///   no menu configuration produces.
///
/// So the control is this app's own: a ``PressFeedbackButtonStyle`` washing inside the
/// circle, which is the treatment every other control here uses and is clipped to the shape
/// by construction, and a panel that is a view like any other.
///
/// # What owning it costs, and how each cost is paid
///
/// - *Dismissal.* A full-screen scrim behind the panel, tapped anywhere — and the `+` turns
///   into an `✕` while the panel is out, so the way back is on screen rather than implied.
/// - *The animation.* One `GlassEffectContainer` holds both pieces, so the panel's glass and
///   the button's are sampled together and fuse as they meet instead of reading as two
///   separate lozenges; the panel's own transition is a scale anchored at
///   `.bottomTrailing`, which is what makes it appear to come out of the button rather than
///   fade in above it.
/// - *Accessibility.* The rows are plain buttons with their own labels; the scrim is a
///   button too, labelled, so a reader that cannot see the `✕` can still leave.
///
/// # The geometry
///
/// The root navigation row places this fixed-size control beside the tabs. The panel is
/// an overlay so opening it never changes the row's height or the button's position.
struct HomeComposeButton: View {
    /// Opens the new-direct-message sheet.
    let newMessage: () -> Void
    /// Opens the new-channel sheet.
    let newChannel: () -> Void

    /// Shared with the root so a tap outside the panel dismisses it.
    @Binding var isOpen: Bool

    var body: some View {
        GlassEffectContainer(spacing: Self.glassSpacing) {
            toggle
                .overlay(alignment: .bottomTrailing) {
                    if isOpen {
                        panel
                            .padding(.bottom, Self.diameter + Self.glassSpacing)
                    }
                }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        // The panel is a layer over the sidebar rather than a thing in it, so the whole
        // control is one accessibility container and the rows inside it stay reachable.
        .accessibilityElement(children: .contain)
    }

    // MARK: - The button

    private var toggle: some View {
        Button {
            HiveHaptics.play(.disclosureToggled)
            withAnimation(Self.motion) { isOpen.toggle() }
        } label: {
            Image(systemName: "plus")
                // Fixed rather than relative, for the reason the system's own tab-bar glyphs
                // are: this drawing sits inside a circle matched to a control UIKit draws,
                // and type that grew past it would render as a `+` clipped by its own glass.
                .font(.hiveSymbol(fixedSize: Self.glyphPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                // 45° is the whole of the `✕`: the glyph is symmetrical, so rotating it is
                // one animatable number where a symbol swap would be a cut.
                .rotationEffect(.degrees(isOpen ? 45 : 0))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.hivePress(.control, in: .circle))
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isOpen ? "Close" : "Create")
        .accessibilityHint(isOpen ? "" : "Starts a new message or a new channel")
    }

    // MARK: - The panel

    /// The card: the subtitled row, then the prominent action, as the reference has them.
    private var panel: some View {
        VStack(alignment: .leading, spacing: Self.panelSpacing) {
            row(
                title: "Channel",
                subtitle: "Organize teams and work",
                symbol: "number",
                action: newChannel
            )
            primaryAction
        }
        .padding(Self.panelPadding)
        .frame(width: Self.panelWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.panelRadius))
        // Anchored at the corner the button occupies, which is what reads as the card
        // growing out of it. A plain `.opacity` here is the version that looks like a
        // menu appearing above a button, and that is the thing this replaced.
        .transition(
            .scale(scale: 0.05, anchor: .bottomTrailing).combined(with: .opacity)
        )
    }

    private func row(
        title: String,
        subtitle: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            choose(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.hiveSymbol(.title3, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.rowGlyphBox, height: Self.rowGlyphBox)
                    // The reference's own treatment: the glyph in a soft square, which is
                    // what keeps a line drawing from floating loose beside two lines of text.
                    .background(.primary.opacity(0.08), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.hive(.headline, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.hive(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect(cornerRadius: Self.rowRadius))
        }
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: Self.rowRadius)))
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    /// The bottom capsule — the reference's Message pill, under the owner's own wording.
    private var primaryAction: some View {
        Button {
            choose(newMessage)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.hiveSymbol(.subheadline, weight: .semibold))
                Text("New Message")
                    .font(.hive(.headline, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Self.primaryHeight)
            .background(.primary.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.hivePress(.control, in: .capsule))
        .accessibilityLabel("New Message")
        .accessibilityHint("Message someone directly")
    }

    /// Puts the panel away, then does the thing. In that order: the sheet the action opens is
    /// presented over this screen, and a card still animating underneath a presenting sheet
    /// is a frame nobody asked for.
    private func choose(_ action: @escaping () -> Void) {
        withAnimation(Self.motion) { isOpen = false }
        action()
    }

    // MARK: - Metrics

    /// Smaller than the tab bar controls while remaining an easy touch target.
    static let diameter: CGFloat = 48
    /// How big the `+` is inside its glass.
    static let glyphPointSize: CGFloat = 18
    static let panelWidth: CGFloat = 320
    static let panelRadius: CGFloat = 28
    static let panelPadding: CGFloat = 12
    static let panelSpacing: CGFloat = 10
    static let rowRadius: CGFloat = 18
    static let rowGlyphBox: CGFloat = 44
    static let primaryHeight: CGFloat = 50
    /// The distance between the card and the button, and the container's sampling distance.
    /// One number for both: the spacing a `GlassEffectContainer` is given is the range over
    /// which it lets two shapes fuse, so a gap wider than it would never merge.
    static let glassSpacing: CGFloat = 12
    static let scrimOpacity: CGFloat = 0.22
    /// Retargetable, so a second tap while the card is still arriving turns it around rather
    /// than queueing behind it.
    static let motion: Animation = .snappy(duration: 0.3)
}

#Preview {
    ZStack {
        Color.hiveNight.ignoresSafeArea()
        HomeComposeButton(newMessage: {}, newChannel: {}, isOpen: .constant(false))
    }
}
