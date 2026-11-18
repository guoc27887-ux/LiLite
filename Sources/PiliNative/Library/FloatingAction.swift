import SwiftUI

/// Round glass action pinned to the bottom trailing corner (the original's FloatingActionButton).
struct FloatingAction: ViewModifier {
  let title: String
  let symbol: String
  var disabled = false
  let action: () -> Void
  func body(content: Content) -> some View {
    content.overlay(alignment: .bottomTrailing) {
      Button(action: action) {
        Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 56, height: 56)
      }
      .piliButtonStyle(.glassProminent).buttonBorderShape(.circle)
      .disabled(disabled)
      .accessibilityLabel(title)
      .padding(.trailing, 20).padding(.bottom, 16)
    }
  }
}
extension View {
  func floatingAction(_ title: String, systemImage: String, disabled: Bool = false,
    action: @escaping () -> Void) -> some View {
    modifier(FloatingAction(title: title, symbol: systemImage, disabled: disabled, action: action))
  }
  /// Pins a tab or chip bar under the navigation bar on a glass-friendly background.
  func pinnedHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      header().padding(.vertical, 6).frame(maxWidth: .infinity).background(.bar)
    }
  }
}
