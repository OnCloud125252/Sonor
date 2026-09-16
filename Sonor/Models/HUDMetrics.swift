import Foundation
import CoreGraphics

/// Fixed sizes of the overlay.
///
/// Every line of the overlay is exactly `contentWidth` wide, so both edges line up.
public enum HUDMetrics {
    /// Width of the text card and of the control line below it.
    public static let contentWidth: CGFloat = 460
    /// Width of the panel window. The extra room is the margin around the content.
    public static let windowWidth: CGFloat = 500
    /// Height of the control line.
    public static let controlHeight: CGFloat = 40
    /// Gap between two items on the control line.
    public static let controlGap: CGFloat = 8
    /// Width of one round control.
    public static let roundControlWidth: CGFloat = 40
    /// Width of the assistant picker on the control line.
    public static let assistantWidth: CGFloat = 130
    /// Corner radius shared by the card and the control line.
    public static let cornerRadius: CGFloat = 20
}
