import SwiftUI
import AppKit

/// The system light/dark setting lives in the global domain under `AppleInterfaceStyle`.
/// Views that force their own NSAppearance cannot read it from the SwiftUI environment.
enum SystemAppearance {
    static func prefersDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
}


struct ActiveVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    var cornerRadius: CGFloat = 0
    var colorScheme: ColorScheme

    // Rebuilding an NSAppearance on every update allocated one object per glass surface per
    // frame. There are only two possible values, so they are created once.
    private static let darkAppearance = NSAppearance(named: .darkAqua)
    private static let lightAppearance = NSAppearance(named: .aqua)

    private var targetAppearance: NSAppearance? {
        colorScheme == .dark ? Self.darkAppearance : Self.lightAppearance
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.appearance = targetAppearance
        return view
    }

    // Assigning `material` marks the blur dirty even when the value did not change, so each
    // assignment is guarded. The HUD redraws 20 times a second while recording.
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
        if nsView.layer?.cornerRadius != cornerRadius { nsView.layer?.cornerRadius = cornerRadius }
        let appearance = targetAppearance
        if nsView.appearance !== appearance { nsView.appearance = appearance }
    }
}

struct SafeGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var isInteractive: Bool = false
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("hudAppearance") var hudAppearance = "glass"
    
    func body(content: Content) -> some View {
        let isSolid = hudAppearance == "solid"
        if isSolid {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1)
                )
        } else {
            if #available(macOS 26.0, *) {
            if isInteractive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            let isDark = colorScheme == .dark
            content
                .background(
                    ActiveVisualEffectView(
                        material: isDark ? .hudWindow : .headerView,
                        blendingMode: .behindWindow,
                        state: .active,
                        cornerRadius: cornerRadius,
                        colorScheme: colorScheme
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(isDark ? Color.black.opacity(0.1) : Color.white.opacity(0.2))
                    )
                )
            }
        }
    }
}

extension View {
    func safeGlassEffect(cornerRadius: CGFloat, isInteractive: Bool = false) -> some View {
        self.modifier(SafeGlassModifier(cornerRadius: cornerRadius, isInteractive: isInteractive))
    }
}

extension NSWindow {
    /// Reading the private `cornerRadius` key built a throwaway NSWindow from a lazy static,
    /// which can run off the main thread, and an unknown key raises an uncatchable
    /// Objective-C exception. The system value is 10 points.
    static let standardCornerRadius: CGFloat = 10.0
}
