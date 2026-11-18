import SwiftUI

enum NativeGlass {
  /// The deployment target is iOS 26, so Liquid Glass is always available.
  static let available = true
  /// Corner radius for content cards (thumbnails, panels) in the iOS 26+ design language.
  static let cardRadius: CGFloat = 18
  /// Corner radius for large grouped surfaces such as sheets' inner panels.
  static let panelRadius: CGFloat = 26
  /// Corner radius for small thumbnails and chips.
  static let thumbRadius: CGFloat = 10
}

/// Use the system optical material on the controls layer, keeping media and reading surfaces plain.
private struct NativeGlassSurface<S: Shape>: ViewModifier {
  let shape: S
  let interactive: Bool
  let tint: Color?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ViewBuilder func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(.background, in: shape)
    } else if #available(iOS 26, *) {
      content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    } else {
      // iOS 18 fallback for this fork: plain system material instead of Liquid Glass.
      content.background(.regularMaterial, in: shape)
    }
  }
}

extension View {
  func piliGlass<S: Shape>(
    in shape: S, interactive: Bool = false, tint: Color? = nil,
    fallback: AnyShapeStyle = AnyShapeStyle(.regularMaterial)
  ) -> some View {
    modifier(NativeGlassSurface(shape: shape, interactive: interactive, tint: tint))
  }
}

struct PiliGlassGroup<Content: View>: View {
  var spacing: CGFloat = 8
  @ViewBuilder var content: () -> Content
  @ViewBuilder var body: some View {
    if #available(iOS 26, *) {
      GlassEffectContainer(spacing: spacing, content: content)
    } else {
      content()
    }
  }
}

/// Standard navigation/toolbars already adopt Liquid Glass. Do not replace their system material.
struct NativeNavigationBackground: ViewModifier {
  let black: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if black {
      content.toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    } else {
      content
    }
  }
}
