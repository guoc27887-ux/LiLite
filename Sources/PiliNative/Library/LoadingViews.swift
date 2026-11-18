import SwiftUI

/// Whole-page loading placeholder: centred, and it only fades in after a short delay so fast
/// loads never flash a spinner. Safe inside a `List` (no separator, clear background).
struct PageLoading: View {
  var label: String? = nil
  @State private var shown = false
  var body: some View {
    VStack(spacing: 12) {
      ProgressView().controlSize(.regular)
      if let label { Text(label).font(.footnote).foregroundStyle(.secondary) }
    }
    .frame(maxWidth: .infinity, minHeight: 220)
    .opacity(shown ? 1 : 0)
    .task {
      try? await Task.sleep(for: .milliseconds(160))
      withAnimation(.easeOut(duration: 0.25)) { shown = true }
    }
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityLabel(label ?? "正在载入")
  }
}

/// Spinner for media surfaces: invisible for the first moments, so a fast load goes straight
/// from black to the picture and only a slow one ever shows a loading state.
struct DelayedSpinner: View {
  var delay: Duration = .milliseconds(600)
  var tint: Color = .white
  @State private var shown = false
  var body: some View {
    ProgressView().tint(tint).controlSize(.regular)
      .opacity(shown ? 1 : 0)
      .task {
        try? await Task.sleep(for: delay)
        withAnimation(.easeOut(duration: 0.2)) { shown = true }
      }
      .allowsHitTesting(false).accessibilityLabel("正在载入")
  }
}

/// Whole-page failure with a retry button, matching `PageLoading`'s placement.
struct PageFailure: View {
  let message: String
  var retry: (() -> Void)? = nil
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
      Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let retry { Button("重试", action: retry).piliButtonStyle(.glass) }
    }
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity, minHeight: 220)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .transition(.opacity)
  }
}
