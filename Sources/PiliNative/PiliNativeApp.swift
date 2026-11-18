import CFirebaseTelemetry
import SwiftUI

@main struct PiliNativeApp: App {
  init() {
    _ = MediaNetwork.shared
  }
  @AppStorage(TypefaceChoice.key) private var faceData = Data()
  @State private var restoredFaceData: Data?
  @UIApplicationDelegateAdaptor(DownloadLifecycle.self) private var appDelegate
  @StateObject private var accounts = AccountContext()
  @StateObject private var indicators = UnreadIndicators()
  @AppStorage(VipExperience.autoKey) private var autoVipExperience = true
  @AppStorage(HighRefreshRate.key) private var force120 = false
  @AppStorage("badge.dynamicMode") private var dynBadge = 2
  @AppStorage("badge.messageMode") private var msgBadge = 2
  @AppStorage("badge.messageMask") private var mask = UnreadTotals.allMask
  @AppStorage("inbox.hideLikes") private var hideLikeNotices = false
  private var visibleMask: Int { UnreadTotals.visibleMask(mask,hideLikes:hideLikeNotices) }
  @AppStorage("badge.periodic") private var periodic = true
  @AppStorage("badge.minutes") private var minutes = 5
  @State private var badgeRevision = 0
  private let sleepTimer = PlaybackSleepTimer.shared
  @Environment(\.scenePhase) private var phase
  @AppStorage(NavigationLayout.key) private var layoutData = Data()
  @State private var active = NavigationLayout.current().launch
  @State private var incoming: IncomingRoute?
  @State private var homeRevision = 0
  private func returnHome(_ layout: NavigationLayout) {
    incoming = nil
    active = layout.tabs.contains(.home) ? .home : layout.launch
    homeRevision &+= 1
  }
  @AppStorage("appearance") private var appearance = "system"
  private func badge(_ tab: MainTab) -> Text? {
    let m = tab == .mine
    if !m && tab != .dynamics { return nil }
    return UnreadTotals.label(
      indicators.count(for: accounts.state.active, messages: m), mode: m ? msgBadge : dynBadge
    ).map { Text(verbatim: $0) }
  }
  var body: some Scene {
    WindowGroup {
      // DIAGNOSTIC ROOT: bare FeedView only, to bisect the iOS 18 launch loop.
      FeedView()
        .environmentObject(accounts).environmentObject(indicators)
    }
    // iPadOS menu bar (and the ⌘ shortcut overlay): one item per column, in the user's order.
    .commands {
      CommandMenu("前往") {
        let tabs = NavigationLayout.read(layoutData).tabs
        ForEach(Array(tabs.prefix(9).enumerated()), id: \.element) { index, tab in
          Button(tab.title) { active = tab }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
        if tabs.contains(.search) {
          Divider()
          Button("搜索") { active = .search }.keyboardShortcut("f", modifiers: .command)
        }
      }
    }
  }
}
