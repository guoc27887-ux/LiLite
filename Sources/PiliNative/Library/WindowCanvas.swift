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
  /// The fold's division in window coordinates while the device stands partly folded (see
  /// `DeviceFold`). Read by UIKit code (一镜到底's landing), so no view observes it.
  @ObservationIgnored private(set) var fold: CGRect?
  func updateFold(_ next: CGRect?) { if next != fold { fold = next } }
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
        // The whole window, safe areas included: on an iPhone Duo the status area moves between
        // the side and the top as pages change, and measuring inside it made the open Duo
        // (951×669) read as a 951×553 phone on the video page, which then fell back to the
        // phone's stacked layout.
        .onGeometryChange(for: CGSize.self) { g in
          let inset = g.safeAreaInsets
          return CGSize(width: g.size.width + inset.leading + inset.trailing,
            height: g.size.height + inset.top + inset.bottom)
        } action: { WindowCanvas.shared.update($0) }
        .onGeometryChange(for: CGRect?.self) { DeviceFold.division(in: $0) } action: {
          WindowCanvas.shared.updateFold($0)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

extension View {
  /// Attach once at the window root.
  func tracksWindowCanvas() -> some View { modifier(WindowCanvasProbe()) }
}
