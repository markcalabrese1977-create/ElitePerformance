import SwiftUI

/// Bottom room for the floating tab bar (iOS 26) on the three tab screens that scroll (Today, History, Analytics), so the last row and
/// Today's Start Session button can always be scrolled fully clear of the bar: on the smallest screen (iPhone SE, 375 x 667), at the
/// largest Dynamic Type sizes, with or without the backup banner.
///
/// The system already treats the bar as the bottom safe area of a List / ScrollView: the end of Today, History and Analytics stops
/// above the bar with no help (measured on the SE: ~20 pt gap). `contentMargins` is measured from the TOP of the bar, so a margin the
/// size of the bar would leave a bar-sized empty band above it (tried at 70 pt: a 70 pt gap). This is therefore only breathing room.
enum FloatingTabBarClearance {
    /// Gap between the last row and the top of the bar, in points.
    static let bottom: CGFloat = 16
}

extension View {
    func clearsFloatingTabBar() -> some View {
        contentMargins(.bottom, FloatingTabBarClearance.bottom, for: .scrollContent)
    }
}
