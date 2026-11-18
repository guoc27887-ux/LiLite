import SwiftUI
import UIKit

// iOS 18 compatibility shims for this fork (deployment target lowered from 26 to 18).
// Each helper uses the real iOS 26 API when running on iOS 26+, and falls back to the
// closest iOS 18 equivalent otherwise. Upstream code should call these instead of the
// iOS 26-only APIs directly.

enum PiliButtonStyle {
  case glass
  case glassProminent
}

extension View {
  @ViewBuilder func piliButtonStyle(_ style: PiliButtonStyle) -> some View {
    if #available(iOS 26, *) {
      switch style {
      case .glass: buttonStyle(.glass)
      case .glassProminent: buttonStyle(.glassProminent)
      }
    } else {
      switch style {
      case .glass: buttonStyle(.bordered)
      case .glassProminent: buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder func piliSafeAreaBar<BarContent: View>(
    edge: VerticalEdge, spacing: CGFloat = 8, @ViewBuilder content: () -> BarContent
  ) -> some View {
    if #available(iOS 26, *) {
      safeAreaBar(edge: edge, spacing: spacing, content: content)
    } else {
      safeAreaInset(edge: edge, spacing: spacing, content: content)
    }
  }

  @ViewBuilder func piliTabBarMinimizeOnScroll(_ minimize: Bool) -> some View {
    if #available(iOS 26, *) {
      tabBarMinimizeBehavior(minimize ? .onScrollDown : .never)
    } else {
      self
    }
  }
}

extension UINavigationController {
  /// iOS 26 renamed `interactivePopGestureRecognizer` to
  /// `interactiveContentPopGestureRecognizer`; both drive the edge-swipe pop.
  var piliContentPopGesture: UIGestureRecognizer? {
    if #available(iOS 26, *) {
      return interactiveContentPopGestureRecognizer
    }
    return interactivePopGestureRecognizer
  }
}
