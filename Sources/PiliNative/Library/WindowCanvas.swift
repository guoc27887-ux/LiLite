import SwiftUI
import UIKit

/// The current window, not the device. iPad Split View, Stage Manager and the iPhone Duo's
/// folded (≈466×678 pt) and unfolded (≈626×890 pt) screens all change it while the app runs, and
/// the Duo always reports the phone idiom, so layout defaults follow this instead of the idiom.
///
/// `large` mirrors the original client's `isTablet` (shortest side ≥ 600). It is stored apart from
/// `size` so views that only ask "is this a large screen" re-render when that answer flips, not on
/// every pixel of a window resize.
@MainActor @Observable final class WindowCanvas {
  static let shared = WindowCanvas()
  private(set) var size: CGSize
  private(set) var large: Bool
  private init() {
    let initial = WindowCanvas.keyWindowSize ?? CGSize(width: 390, height: 844)
    size = initial
    large = WindowCanvas.isLarge(initial)
  }
  static func isLarge(_ size: CGSize) -> Bool { min(size.width, size.height) >= 600 }
  func update(_ next: CGSize) {
    guard next.width > 0, next.height > 0, next.width.isFinite, next.height.isFinite else { return }
    if next != size { size = next }
    let l = Self.isLarge(next)
    if l != large { large = l }
  }
  private static var keyWindowSize: CGSize? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.bounds.size
  }
}

/// Layout of a player page, after the original client's video page:
/// - `stacked`: player on top, tabs under it (phones, folded Duo, narrow iPad windows);
/// - `side`: landscape, player and intro on the left, comments and episodes on the right;
/// - `square`: nearly square large windows (unfolded Duo held sideways in Split View, 13" iPad
///   portrait): player across the top, intro / comments / episodes as columns below.
enum PlayerPageLayout: Equatable {
  /// `tabletop`: an iPhone Duo stood partly folded with the hinge across the screen — the
  /// picture above the fold, tabs below it, nothing laid across the division.
  case stacked, side, square, tabletop
  /// The original's thresholds: landscape once width / height ≥ 1.2; "almost square" when a
  /// full-width 16:9 player would still leave 60% of the height.
  static func resolve(width: CGFloat, height: CGFloat, horizontal: Bool) -> Self {
    guard width > 0, height > 0 else { return .stacked }
    if width / height >= 1.2, width >= 540 { return horizontal ? .side : .stacked }
    guard horizontal, width >= 600 else { return .stacked }
    return width / (16.0 / 9) >= 0.4 * height ? .square : .stacked
  }
  /// Player width in the side layout (the original's `_childWhenDisabledLandscapeInner`).
  static func sideWidth(width: CGFloat, height: CGFloat) -> CGFloat {
    var w = min(0.7, max(0.5, height / width * 1.08)) * width
    if width >= 560 { w = width - min(425, max(280, width - w)) }
    return w
  }
}

/// The device fold, as the system reports it: an active `.division` reserved region (iPhone Duo,
/// iOS 27.1). Inactive while the device lies flat, so layouts only change in a folded posture.
enum DeviceFold {
  static func division(in proxy: GeometryProxy) -> CGRect? {
    // iOS 27.1 reservedRegions API is not in the iOS 26 SDK; folds report nil.
    return nil
  }
}

private struct WindowCanvasProbe: ViewModifier {
  func body(content: Content) -> some View {
    content.background {
      Color.clear.ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { WindowCanvas.shared.update($0) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

extension View {
  /// Attach once at the window root.
  func tracksWindowCanvas() -> some View { modifier(WindowCanvasProbe()) }
}
