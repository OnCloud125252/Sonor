import SwiftUI

/// Shows the words above the HUD capsule.
///
/// While the user speaks it shows the live preview, with a dim tail for the words that the
/// next pass can still change. After that it shows the transcript with the assistant edit on
/// top: red strike-through for the words the assistant dropped, green for the words it added.
struct TranscriptPanelView: View {
    @ObservedObject var store: TranscriptStore
    let colorScheme: ColorScheme
    var width: CGFloat = 320

    /// Height of one line of text at this font and line spacing.
    private static let lineHeight: CGFloat = 17
    /// Room for four lines. Longer text scrolls instead of pushing the overlay up the screen.
    private static let maximumLines: CGFloat = 4
    private static let verticalPadding: CGFloat = 11

    private static var maximumTextHeight: CGFloat {
        lineHeight * maximumLines
    }

    private var baseColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var addedColor: Color {
        colorScheme == .dark ? Color(red: 0.45, green: 0.92, blue: 0.55) : Color(red: 0.06, green: 0.55, blue: 0.20)
    }

    private var removedColor: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 0.48, blue: 0.45) : Color(red: 0.72, green: 0.12, blue: 0.10)
    }

    /// Marks the state without taking a whole column of width, which an icon did.
    private var accentColor: Color {
        switch store.stage {
        case .listening:
            return colorScheme == .dark ? Color(red: 0.42, green: 0.68, blue: 1.0) : Color(red: 0.10, green: 0.42, blue: 0.90)
        case .edited:
            return store.hasEdit
                ? (colorScheme == .dark ? Color(red: 0.72, green: 0.58, blue: 1.0) : Color(red: 0.42, green: 0.26, blue: 0.85))
                : baseColor.opacity(0.30)
        case .hidden:
            return .clear
        }
    }

    var body: some View {
        if store.hasContent {
            panel
                .transition(.asymmetric(
                    insertion: .offset(y: 12).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accentColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            scrollingText
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: width, alignment: .leading)
        // The control line below is 40 points tall with a pill edge, so its radius is 20. The
        // card has to match it, or the overlay looks like two unrelated windows.
        .glass(cornerRadius: HUDMetrics.cornerRadius, colorScheme: colorScheme)
    }

    /// Short text sits in the card as it is. Long text scrolls inside four lines.
    ///
    /// `ViewThatFits` picks the first child that fits the room it is offered, so the card grows
    /// with the text up to four lines and stops there. Measuring the text by hand needed state
    /// that was empty on the first draw, and the card then opened with nothing in it.
    private var scrollingText: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                styledText
                ScrollView(.vertical, showsIndicators: false) {
                    styledText
                        .id(Self.topAnchor)
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
            }
            .frame(maxHeight: Self.maximumTextHeight)
            .onChange(of: store.liveMovingText) {
                // The newest words sit at the end, so the card follows them down.
                guard store.stage == .listening else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: store.stage) {
                // A finished edit reads from the start, so the card goes back to the top.
                guard store.stage == .edited else { return }
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
    }

    private var styledText: some View {
        text
            .font(.system(size: 12, weight: .medium))
            .lineSpacing(2.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let topAnchor = "transcript.top"
    private static let bottomAnchor = "transcript.bottom"

    private var text: Text {
        if store.stage == .listening {
            // The dim tail marks the words that the next pass can still change.
            return Text(store.liveSettledText).foregroundStyle(baseColor.opacity(0.8))
                + Text(store.liveMovingText).foregroundStyle(baseColor.opacity(0.38))
        }
        return store.segments.reduce(Text("").foregroundStyle(baseColor)) { result, segment in
            let spacer = (segment.id > 0 && segment.leadingSpace) ? Text(" ") : Text("")
            return result + spacer + styled(segment)
        }
    }

    private func styled(_ segment: TextDiffSegment) -> Text {
        switch segment.kind {
        case .kept:
            return Text(segment.text).foregroundStyle(baseColor.opacity(0.8))
        case .added:
            return Text(segment.text).foregroundStyle(addedColor)
        case .removed:
            return Text(segment.text).foregroundStyle(removedColor).strikethrough(true, color: removedColor)
        }
    }
}
