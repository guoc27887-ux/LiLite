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
  /// Wider than tall; stored apart for the same reason as `large`.
  private(set) var landscape: Bool
  private init() {
    let initial = WindowCanvas.keyWindowSize ?? CGSize(width: 390, height: 844)
    size = initial
    large = WindowCanvas.isLarge(initial)
    landscape = initial.width > initial.height
  }
  static func isLarge(_ size: CGSize) -> Bool { PlayerPageLayout.isLargeWindow(size) }
  func update(_ next: CGSize) {
    guard next.width > 0, next.height > 0, next.width.isFinite, next.height.isFinite else { return }
    if next != size { size = next }
    let l = Self.isLarge(next)
    if l != large { large = l }
    let wide = next.width > next.height
    if wide != landscape { landscape = wide }
  }
  private static var keyWindowSize: CGSize? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.bounds.size
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
