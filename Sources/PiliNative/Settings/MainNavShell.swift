import SwiftUI
import Observation

private struct ShellContextKey: EnvironmentKey { static let defaultValue: NavigationChrome? = nil }
private struct ProfileShortcutKey:EnvironmentKey {static let defaultValue:(@MainActor ()->Void)?=nil}
private struct ShellTabKey: EnvironmentKey { static let defaultValue: MainTab? = nil }
private struct HomeSearchCollapseKey: EnvironmentKey { static let defaultValue = false }
private struct SystemSearchTabKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var usesSystemSearchTab: Bool {
    get { self[SystemSearchTabKey.self] }
    set { self[SystemSearchTabKey.self] = newValue }
  }
  fileprivate var navChrome: NavigationChrome? {
    get { self[ShellContextKey.self] }
    set { self[ShellContextKey.self] = newValue }
  }
  var openPersonalPage:(@MainActor ()->Void)? {get {self[ProfileShortcutKey.self]} set{self[ProfileShortcutKey.self]=newValue}}
  var scrollHomeChannelToTop: @MainActor () -> Void {
    let chrome = navChrome
    return { if chrome?.active == .home { chrome?.top(allowRefresh: false) } }
  }
  fileprivate var owningTab: MainTab? {
    get { self[ShellTabKey.self] }
    set { self[ShellTabKey.self] = newValue }
  }
  fileprivate var collapseHomeSearch: Bool {
    get { self[HomeSearchCollapseKey.self] }
    set { self[HomeSearchCollapseKey.self] = newValue }
  }
}
@MainActor @Observable private final class NavigationChrome {
  private(set) var visible: [MainTab: Bool] = [:]
  private(set) var fraction = 1.0
  @ObservationIgnored private var owners: [MainTab: UUID] = [:]
  @ObservationIgnored var listen = false
  @ObservationIgnored var reduce = false
  @ObservationIgnored var mode = NavigationHideMode.sync
  @ObservationIgnored var active = MainTab.home
  @ObservationIgnored private var mounted: [MainTab: WeakView] = [:]
  @ObservationIgnored private var touched: [MainTab: WeakView] = [:]
  @ObservationIgnored var reselect = RootTabReselect()
  private final class WeakView {
    weak var value: UIView?
    init(_ view: UIView) { value = view }
  }
  func mount(_ view: UIView, for tab: MainTab) { mounted[tab] = WeakView(view) }
  func show(_ t: MainTab, _ token: UUID) {
    owners[t] = token
    if visible[t] != true { visible[t] = true }
    if active == t { reset() }
  }
  func leave(_ t: MainTab, _ token: UUID) {
    guard owners[t] == token else { return }
    visible[t] = false
  }
  func reset() { if fraction != 1 { fraction = 1 } }
  @ObservationIgnored private var travel: CGFloat = 0
  /// The header follows the finger at a calm rate after a small dead zone (so small
  /// corrections never twitch it), animates any large jump, and settles with a spring when the
  /// finger lifts, so even a fast flick reads as a slide rather than a cut.
  func drag(_ t: MainTab, delta: CGFloat, top: Bool, scroll: UIScrollView) {
    guard t == active, visible[t] == true else { return }
    touched[t] = WeakView(scroll)
    guard listen, delta.isFinite else { return }
    if top {
      travel = 0
      settle(1)
      return
    }
    if delta != 0, (delta > 0) != (travel > 0) { travel = 0 }
    travel += delta
    guard abs(travel) > 14 else { return }
    if mode == .instant || reduce {
      settle(travel > 0 ? 0 : 1)
      return
    }
    let v = max(0, min(1, fraction - Double(delta) / 96))
    guard v != fraction else { return }
    if abs(v - fraction) > 0.18 {
      withAnimation(.smooth(duration: 0.22)) { fraction = v }
    } else {
      fraction = v
    }
  }
  func release(_ t: MainTab, velocity: CGFloat) {
    guard t == active, visible[t] == true, listen else { return }
    travel = 0
    guard fraction > 0, fraction < 1 else { return }
    let target: Double = velocity > 260 ? 0 : velocity < -260 ? 1 : (fraction < 0.5 ? 0 : 1)
    settle(target)
  }
  private func settle(_ value: Double) {
    guard fraction != value else { return }
    withAnimation(reduce ? nil : .smooth(duration: 0.3)) { fraction = value }
  }
  func top(allowRefresh: Bool = true) {
    guard visible[active] == true, let root = mounted[active]?.value, root.window != nil else {
      return
    }
    let scroll =
      (touched[active]?.value as? UIScrollView).flatMap {
        NavScrollAttachment.visible($0,in:root) ? $0:nil
      }
      ?? NavScrollAttachment.primaryScroll(in: root)
    guard let s = scroll else { return }
    let leadingY = -s.adjustedContentInset.top
    if allowRefresh, reselect.shouldRefresh(active, atTop:s.contentOffset.y <= leadingY+1, now:ProcessInfo.processInfo.systemUptime) {
      if !NativePullRefresh.repeatTab(on:s), let ui=s.refreshControl, !ui.isRefreshing { ui.sendActions(for:.valueChanged) }
    }
    s.setContentOffset(CGPoint(x: s.contentOffset.x, y: leadingY), animated: !reduce)
    reset()
  }
}

private struct TabRootMarker: ViewModifier {
  let tab: MainTab
  @Environment(\.navChrome) private var chrome
  @Environment(\.owningTab) private var owner
  @State private var token = UUID()
  func body(content: Content) -> some View {
    content.background {
      if let chrome, owner == tab {
        NavScrollAttachment(mounted: { chrome.mount($0, for: tab) }, change: { delta, top, scroll in
          chrome.drag(tab, delta: delta, top: top, scroll: scroll)
        }, ended: { velocity in chrome.release(tab, velocity: velocity) })
        .allowsHitTesting(false)
      }
    }.onAppear { if owner == tab { chrome?.show(tab, token) } }
      .onDisappear { if owner == tab { chrome?.leave(tab, token) } }
  }
}
extension View {
  func piliTabRoot(_ tab: MainTab) -> some View { modifier(TabRootMarker(tab: tab)) }
  func piliHomeSearchVisibility() -> some View { modifier(HomeSearchVisibility()) }
}
private struct HomeSearchVisibility: ViewModifier {
  @Environment(\.navChrome) private var chrome
  @Environment(\.collapseHomeSearch) private var enabled
  func body(content: Content) -> some View {
    if let chrome {
      NavigationStrip(chrome: chrome, enabled: enabled, alignment: .bottom) { content }
    } else { content }
  }
}
private struct NavigationStrip<Content: View>: View {
  let chrome: NavigationChrome, enabled: Bool, alignment: Alignment
  @ViewBuilder let content: () -> Content
  var body: some View {
    // Scroll progress is observed only by the strip, never by the tab/page hierarchy.
    CollapsingStrip(fraction: enabled ? chrome.fraction : 1, alignment: alignment, content: content)
  }
}
private struct CollapsingStrip<Content: View>: View {
  let fraction: CGFloat, alignment: Alignment
  @ViewBuilder let content: () -> Content
  @State private var measured: CGFloat = 52
  var body: some View {
    content().fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { h in
        if h > 0 { measured = h }
      }
      .frame(height: max(0, measured * fraction), alignment: alignment).clipped()
      .allowsHitTesting(fraction > 0.65).accessibilityHidden(fraction < 0.65)
  }
}

/// One style for every device and pose, as Apple asks (no idiom checks for layout): a tab bar
/// in compact width — the search-role tab in its own Liquid Glass button at the trailing edge —
/// and a tab bar that can become a sidebar in regular width (iPad, the unfolded iPhone Duo).
/// Folding or resizing the window changes only the size class, never this view's identity.
private struct AdaptiveTabStyle: ViewModifier {
  func body(content: Content) -> some View { content.tabViewStyle(.sidebarAdaptable) }
}
struct MainNavShell: View {
  let layout: NavigationLayout, badge: (MainTab) -> Text?
  @Binding var active: MainTab
  @State private var chrome = NavigationChrome()
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityReduceMotion) private var reduce
  enum Shortcut: Int, Identifiable {
    case search, profile
    var id: Self { self }
  }
  @State private var shortcut: Shortcut?
  /// Content tabs in the user's order; search always uses the system search tab role.
  private var contentTabs: [MainTab] { layout.tabs.filter { $0 != .search } }
  var body: some View {
    let collapseSearch = layout.collapseTop && !voiceOver
    TabView(selection: $active) {
      ForEach(contentTabs) { tab in
        Tab(tab.title, systemImage: tab.icon, value: tab) {
          root(tab, collapseSearch: collapseSearch)
        }.badge(badge(tab))
      }
      if layout.tabs.contains(.search) {
        Tab(MainTab.search.title, systemImage: MainTab.search.icon, value: MainTab.search, role: .search) {
          root(.search, collapseSearch: false)
        }
      }
    }
    .modifier(AdaptiveTabStyle())
    .piliTabBarMinimizeOnScroll(layout.collapseBottom && !voiceOver)
    .environment(\.navChrome, chrome)
    .environment(\.usesSystemSearchTab, layout.tabs.contains(.search))
    .environment(\.openPersonalPage, {
      if layout.tabs.contains(.mine) { select(.mine) } else { shortcut = .profile }
    })
    .onChange(of: active, initial: true) { _, value in
      chrome.reselect = RootTabReselect()
      chrome.active = value
      chrome.reset()
    }
    .onChange(of: "\(layout.collapseTop):\(voiceOver):\(reduce)", initial: true) { _, _ in
      chrome.listen = !voiceOver && layout.collapseTop
      chrome.mode = .sync
      chrome.reduce = reduce
      chrome.reset()
    }
    .background {
      // ⌘1… and ⌘F live in the app's 前往 menu; without a search column ⌘F opens search here.
      if !layout.tabs.contains(.search) {
        Button("搜索") { shortcut = .search }.keyboardShortcut("f", modifiers: .command)
          .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
      }
      if !layout.directBack, let first = layout.tabs.first, first != active {
        Button("返回首个栏目") { select(first) }.keyboardShortcut(.escape, modifiers: [])
          .frame(width: 0, height: 0).clipped().accessibilityHidden(true)
      }
    }
    .piliSheet(item: $shortcut) { shortcut in
      Group {
        switch shortcut {
        case .search: SearchView()
        case .profile: ProfileView()
        }
      }.environment(\.navChrome, nil).environment(\.owningTab, nil)
        .presentationDragIndicator(.visible)
    }
  }
  private func root(_ tab: MainTab, collapseSearch: Bool) -> some View {
    tab.screen
      .environment(\.activeCatalogPage, active == tab)
      .environment(\.preparedCatalogPage, active == tab)
      .environment(\.owningTab, tab)
      .environment(\.collapseHomeSearch, tab == .home && collapseSearch)
      .background {
        NativeTabReselect(tab: tab) { selected in
          if chrome.active == selected { chrome.top() }
        }.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
      }
  }
  private func select(_ t: MainTab) {
    TouchFeedback.light()
    guard t != active else {
      chrome.top()
      chrome.reset()
      return
    }
    active = t
  }
}
