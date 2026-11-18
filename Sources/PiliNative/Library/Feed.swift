import SwiftUI

enum Shelf: String, CaseIterable {
  case recommended = "推荐"
  case popular = "热门"
}
/// Observed property by property: the feed redraws when its videos change, and only the footer
/// when a page starts or stops loading (as an ObservableObject every flag re-rendered the feed).
@MainActor @Observable
final class FeedModel {
  private(set) var videos: [Video] = []
  @ObservationIgnored private var positions: [String: Int] = [:]
  @ObservationIgnored private var contentRevision = 0
  var error: String?
  var busy = false
  var finished = false
  @ObservationIgnored private var retainedStart: String?
  private(set) var retainedIndex: Int?
  var autoCursor:Int?
  @ObservationIgnored private(set) var loaded = false
  @ObservationIgnored private var page = 0
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private var emptyRun = 0
  private struct Request { let shelf:Shelf, reset:Bool, page:Int }
  @ObservationIgnored private var failed:Request?
  /// A next page that came back while the list was moving, put in once it stops (or once the
  /// reader is about to run out). Putting a page in costs 80–150 ms on an iPad's five columns,
  /// one hitch per page right in the middle of a fling.
  @ObservationIgnored private var held: (() -> Void)?
  @ObservationIgnored var moving = false { didSet { if !moving { releaseHeld() } } }
  @ObservationIgnored var nearBottom = false { didSet { if nearBottom { releaseHeld() } } }
  private func releaseHeld() {
    guard let apply = held else { return }
    held = nil
    apply()
  }
  private func setVideos(_ value: [Video]) {
    positions.removeAll(keepingCapacity: true)
    for (index, video) in value.enumerated() { positions[video.id] = index }
    videos = value
    contentRevision &+= 1
    let index = retainedStart.flatMap { positions[$0] }
    if retainedIndex != index { retainedIndex = index }
  }
  func covers(after video: Video) -> ArraySlice<Video> {
    guard let index = positions[video.id] else { return [] }
    return videos[(index + 1)..<min(videos.count, index + 7)]
  }
  func remove(where match: (Video) -> Bool) {
    let kept = videos.filter { !match($0) }
    if kept.count != videos.count { setVideos(kept) }
  }
  func restore(_ video: Video, at index: Int) {
    var list = videos
    CardPreferenceMutation.restore(video, at: index, to: &list)
    setVideos(list)
  }
  func load(_ shelf: Shelf, reset: Bool) async {
    guard !Task.isCancelled else { return }
    if !reset && (busy || finished || held != nil) { return }
    await fetch(Request(shelf:shelf,reset:reset,page:reset ? 1:page+1))
  }
  func retry(_ shelf:Shelf) async {
    guard !busy, !Task.isCancelled else{return}
    if let failed,failed.shelf==shelf {await fetch(failed)}
    else {await load(shelf,reset:videos.isEmpty)}
  }
  private func fetch(_ request:Request) async {
    let shelf=request.shelf,reset=request.reset,next=request.page
    let mobile = UserDefaults.standard.object(forKey: "feed.mobile") as? Bool ?? true
    let filterSource:RecommendationFilter.Source = shelf == .popular ? .hotOrRank
      : mobile ? .mobileFeed:.feed
    let t = UUID()
    token = t
    held = nil
    busy = true
    error = nil
    failed = nil
    defer { if token == t { busy = false } }
    do {
      func request(_ number: Int) async throws -> (items: [Video], next: String?) {
        let b = try await (shelf == .recommended
          ? BiliAPI.shared.recommendations(number, mobile: mobile, screen: MobileFeed.screenEdges())
          : BiliAPI.shared.popular(number))
        return (b.items, b.next)
      }
      let batch = try await request(next)
      guard token == t, !Task.isCancelled else { return }
      let last = next
      let previous = videos
      let revision = contentRevision
      let keepPrevious = reset && shelf == .recommended
        && (UserDefaults.standard.object(forKey: "feed.keepPrevious") as? Bool ?? true)
      let filtering = Task.detached(priority: .userInitiated) {
        var seen = Set(reset ? [] : previous.map(\.id))
        let policy = RecommendationFilter()
        let fresh = batch.items.filter {
          !Task.isCancelled && policy.allows($0, from: filterSource) && seen.insert($0.id).inserted
        }
        let old = keepPrevious ? previous.prefix(previous.count > 200 ? 50 : previous.count).filter {
          !Task.isCancelled && seen.insert($0.id).inserted && policy.allows($0, from: filterSource)
        } : []
        return ((reset ? [] : previous) + fresh + old, old.first?.id, !fresh.isEmpty)
      }
      let result = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
      guard token == t, revision == contentRevision, !Task.isCancelled else { return }
      let apply = { [self] in
        guard token == t, revision == contentRevision else { return }
        if reset { retainedStart = result.1; emptyRun = 0 }
        setVideos(result.0)
        page = last
        // The original keeps loading recommendations as the list scrolls even when a page is
        // filtered away; stop auto-loading only after a few empty pages in a row.
        emptyRun = result.2 ? 0 : emptyRun + 1
        let keepGoing = shelf == .recommended ? emptyRun < 3 : result.2
        autoCursor = keepGoing && batch.next != nil ? last + 1 : nil
        finished = batch.next == nil
        loaded = true
      }
      if !reset, moving, !nearBottom { held = apply } else { apply() }
    } catch { if token == t && !Task.isCancelled { failed=request;self.error=error.localizedDescription } }
  }
}
/// The home page. Anything that changes often (the avatar, unread counts, the bar's environment)
/// lives in small child views, and the channel pages sit behind an equatable `HomeDeck`: a
/// re-render of this view used to rebuild every visible card, several times a frame while the
/// tab bar animated.
struct FeedView: View {
  @Environment(\.usesSystemSearchTab) private var systemSearch
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("search.defaultWord") private var useHint = false
  @State private var hint = ""
  @State private var hintScope: String?
  @State private var hintRead: Date?
  @Environment(\.scenePhase) private var hintPhase
  @State private var search = false
  @AppStorage(RecommendationRules.key) private var rules = Data()
  @AppStorage("feed.mobile") private var mobile = true
  @AppStorage(NavigationLayout.key) private var layoutData = Data()
  @State private var shelf = NavigationRules.firstChannel(NavigationLayout.current().channels)
  @State private var channelMotion = PagerIndicatorMotion()
  @State private var windowInsets = FeedHeaderInsets()
  @Environment(\.collapseHomeSearch) private var collapseSearch
  @Environment(\.interfaceScaled) private var interfaceScaled
  @State private var reserved = FeedHeaderInsets()
  @State private var pendingReserved: FeedHeaderInsets?
  @State private var searchHeight: CGFloat = 54
  @State private var headerHeight: CGFloat = 0
  var body: some View {
    PiliNavigationStack {
      let channels = NavigationLayout.read(layoutData).channels
      GeometryReader { safe in
        // A wide large window has room for the channels and the search row side by side, so the
        // header is one row there and nothing needs to collapse while scrolling.
        let oneRow = channels.count > 1 && WindowCanvas.shared.large && safe.size.width >= 700
        // An iPhone Duo standing partly open like a book: the avatar and channels on the left
        // page, search and messages on the right, one row as on a large screen.
        let hinge = reserved.fold
        let travel = collapseSearch && !oneRow && hinge == nil ? searchHeight : 0
        // The page runs under the status bar so the glass covers it too. Depending on the tab
        // container the bar is either this reader's safe area or measured by the probe.
        let top = max(windowInsets.top, safe.safeAreaInsets.top)
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            if let hinge {
              HStack(spacing: 0) {
                HStack(spacing: 10) {
                  avatarItem
                  if channels.count > 1 {
                    HomeChannelBar(channels: channels, shelf: $shelf, motion: channelMotion, inset: 6, centered: false)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      // Channels running on past the half fade out short of the hinge.
                      .mask {
                        HStack(spacing: 0) {
                          Rectangle()
                          LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                        }.padding(.vertical, -12)
                      }
                  } else {
                    Spacer(minLength: 0)
                  }
                }
                .padding(.leading, 16).padding(.trailing, 12)
                .frame(width: max(0, hinge.lowerBound), alignment: .leading)
                HStack(spacing: 10) { searchItem; bellItem }
                  .padding(.leading, hinge.upperBound - hinge.lowerBound + 16).padding(.trailing, 16)
                  .frame(maxWidth: .infinity)
              }.padding(.top, 2).padding(.bottom, 8)
            } else if oneRow {
              HStack(spacing: 10) {
                avatarItem
                HomeChannelBar(channels: channels, shelf: $shelf, motion: channelMotion, inset: 6, centered: false)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .mask { Rectangle().padding(.vertical, -12) }
                HStack(spacing: 10) { searchItem; bellItem }
                  .frame(width: min(360, max(260, safe.size.width * 0.32)))
              }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
            } else {
              headerRow.padding(.top, 2).padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { searchHeight = $0 }
                .homeSearchControls()
              if channels.count > 1 {
                HomeChannelBar(channels: channels, shelf: $shelf, motion: channelMotion).padding(.bottom, 6)
              }
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, reserved.leading).padding(.trailing, reserved.trailing)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
          // As Coolapk does: the header, status bar included, is frosted glass the feed scrolls
          // under, instead of a band the feed stops at.
          .padding(.top, top)
          .background { FeedHeaderShade() }
          .zIndex(1)
          // Lay out the full exposed page once. The header and page then translate together.
          GeometryReader { viewport in
            deck(channels, viewport: viewport.size, under: headerHeight + top)
              .environment(\.homeFeedBottomClearance, travel + safe.safeAreaInsets.bottom)
          }
          .padding(.top, -(headerHeight + top))
          .padding(.bottom, -travel)
        }
        .homeSearchMotion(travel: travel)
        .clipped()
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .padding(.top, reserved.top)
        .onGeometryChange(for: FeedHeaderInsets.self) { _ in
          // iOS 27.1 reservedRegions API is not in the iOS 26 SDK; folds report no insets.
          FeedHeaderInsets()
        } action: { reserved = $0 }
        .padding(.leading, windowInsets.leading).padding(.trailing, windowInsets.trailing)
        .background {
          FeedWindowSafeArea { windowInsets = $0 }.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      // Official cards sit on the grouped background so their own surface reads as a card. It is
      // drawn behind the whole home page and never inside a pager page, where a colour reaching
      // into the safe area would feed the header inset and the page size into each other.
      .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
      .toolbar(.hidden, for: .navigationBar)
      .task(id: accounts.state.active) {
        if let uid = accounts.state.active { await ProfileStore.shared.refresh(uid) }
      }
      .task(id: "\(useHint):\(hintPhase == .active):\(accounts.state.owner(.role(.recommend)) ?? "")") {
        let uid = accounts.state.owner(.role(.recommend)) ?? ""
        guard useHint else { hint = ""; hintRead = nil; hintScope = nil; return }
        guard hintPhase == .active else { return }
        if hintScope != uid { hint = ""; hintRead = nil; hintScope = uid }
        guard hintRead.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else {return}
        if let s = try? await BiliAPI.shared.defaultSearchWord(owner:uid), !Task.isCancelled {
          hint = s; hintRead = Date()
        }
      }
      // The original client opens search as a page with the field on top, not a sheet.
      .navigationDestination(isPresented: $search) {
        SearchView(initialHint: hint)
      }
      .piliTabRoot(.home)
      .navigationTitle("首页")
      .toolbarTitleDisplayMode(.inline)
      .piliRemovingToolbarTitle()
      .navigationDestination(for: Video.self) { DetailView(initial: $0) }
    }
  }
  /// Each channel page runs under the frosted header: its top `under` points are safe area, so
  /// lists start below the header and scroll on beneath it, and anything fixed sits below it.
  private func deck(_ channels: [HomeChannel], viewport: CGSize, under: CGFloat) -> some View {
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    // The app feed is personal only with the account's access key: reload once it is authorised.
    let token = accounts.state.accounts.first { $0.id == owner }?.mobileToken?.isEmpty == false
    return HomeDeck(
      channels: channels, selected: shelf, shelf: $shelf, motion: channelMotion, viewport: viewport,
      under: under, shelfID: "\(mobile):\(rules.hashValue):\(owner):\(token)")
      .equatable()
      .id("\(accounts.state.active ?? ""):\(owner)")
      .onChange(of: channels) { _, new in
        if !new.contains(shelf) { shelf = NavigationRules.firstChannel(new) }
      }
  }
  /// The official app's header: the avatar, search, then the message bell (signed in only).
  /// Settings, rankings, live, the season index and "open link" live where the original puts
  /// them (我的 page, home channels, the PGC "索引" header, the search page).
  private var headerRow: some View {
    HStack(spacing: 10) {
      avatarItem
      searchItem
      bellItem
    }
    .padding(.horizontal, 16)
  }
  private var avatarItem: some View { HomeAvatarItem() }
  @ViewBuilder private var searchItem: some View {
    if !systemSearch || useHint { searchEntry } else { Spacer(minLength: 0) }
  }
  private var bellItem: some View { HomeBellItem() }
  private var searchEntry: some View {
    Button {
      search = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
        Text(useHint && !hint.isEmpty ? hint : "搜索").lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 44)
      .contentShape(Capsule())
      .piliGlass(in: Capsule(), interactive: true)
    }.buttonStyle(.plain).accessibilityLabel("搜索")
  }
}

/// The channel pages. Equatable on what they show, so the page above re-rendering (its header,
/// the tab bar's environment) does not rebuild the feeds and their cards.
private struct HomeDeck: View, Equatable {
  let channels: [HomeChannel]
  /// The selection when this value was made: the binding alone would compare equal to itself.
  let selected: HomeChannel
  @Binding var shelf: HomeChannel
  let motion: PagerIndicatorMotion
  let viewport: CGSize, under: CGFloat
  let shelfID: String
  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.channels == b.channels && a.selected == b.selected && a.motion === b.motion
      && a.viewport == b.viewport && a.under == b.under && a.shelfID == b.shelfID
  }
  var body: some View {
    RetainedDeck(choices: channels, selection: $shelf, viewport: viewport, onProgress: motion.update) { channel in
      Group {
        switch channel {
        case .recommended: VideoShelf(shelf: .recommended).equatable().id(shelfID)
        case .popular:
          // The original's 排行榜 entrance switches to the ranking channel when the home page has it.
          VideoShelf(shelf: .popular, openRank: channels.contains(.rank) ? { shelf = .rank } : nil)
            .equatable().id(shelfID)
        case .rank: Rankings(embedded: true)
        case .live: LiveDirectory(area: nil, child: nil, embedded: true)
        case .bangumi: PGCHome(cinema: false)
        case .cinema: PGCHome(cinema: true)
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: under).allowsHitTesting(false) }
      // The header is the glass here. iOS 26's own top edge effect sits above the whole page at
      // the status bar and would hide the header and the feed under an opaque strip.
      .piliScrollEdgeEffectHidden(true, for: .top)
    }
  }
}

/// The header's avatar: follows the shared profile cache by itself, so a profile refresh only
/// redraws this button.
private struct HomeAvatarItem: View {
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.openPersonalPage) private var openProfile
  /// The avatar comes from the shared profile cache, so returning to this tab never shows the
  /// placeholder again before the same picture.
  @ObservedObject private var profiles = ProfileStore.shared
  var body: some View {
    if let openProfile {
      let avatar = accounts.state.active.flatMap { profiles.profiles[$0]?.face }.flatMap(httpsURL)
      let incognito = accounts.state.active != nil && accounts.state.owner(.role(.heartbeat)) == nil
      Button(action: openProfile) {
        SiteThumbnail(url: avatar) { $0.resizable().scaledToFill() } placeholder: {
          Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36).clipShape(Circle())
        // Set in a glass ring the size of the bell beside the search, as Coolapk does.
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .piliGlass(in: Circle(), interactive: true)
        .overlay(alignment: .bottomTrailing) {
          if incognito {
            Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .semibold))
              .padding(3).background(.regularMaterial, in: Circle()).offset(x: 1, y: 1)
          }
        }
      }.buttonStyle(.plain)
        .accessibilityLabel(accounts.state.active == nil ? "登录或查看我的" : "我的")
    }
  }
}

/// The message bell with its unread count, redrawn alone when the count changes.
private struct HomeBellItem: View {
  @EnvironmentObject private var accounts: AccountContext
  @EnvironmentObject private var indicators: UnreadIndicators
  @AppStorage("badge.messageMode") private var messageMode = 2
  var body: some View {
    if accounts.state.active != nil {
      let unread = UnreadTotals.label(indicators.count(for: accounts.state.active, messages: true), mode: messageMode)
      NavigationLink {
        Inbox()
      } label: {
        Image(systemName: "bell").font(.system(size: 17, weight: .medium))
          .frame(width: 44, height: 44).contentShape(Circle())
          .overlay(alignment: .topTrailing) {
            if let unread {
              Text(verbatim: unread).font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(.red, in: Capsule()).offset(x: -2, y: 2)
            }
          }
      }
      .buttonStyle(.plain).foregroundStyle(.primary)
      .piliGlass(in: Circle(), interactive: true)
      .accessibilityLabel("消息中心")
    }
  }
}

/// The home header's frosted glass, as Coolapk's: the feed shows blurred beneath it, lightly
/// tinted so the search and the channels stay legible, with a hairline at its foot.
private struct FeedHeaderShade: View {
  var body: some View {
    Rectangle().fill(.ultraThinMaterial)
      .overlay { Color(uiColor: .systemGroupedBackground).opacity(0.4) }
      .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
      .allowsHitTesting(false)
  }
}

private struct HomeChannelBar: View {
  let channels: [HomeChannel]
  @Binding var shelf: HomeChannel
  let motion: PagerIndicatorMotion
  var inset: CGFloat = 16
  /// Centred when the chips are narrower than the bar, as in the official app; they scroll as
  /// before once they overflow it.
  var centered = true
  @Environment(\.scrollHomeChannelToTop) private var channelToTop
  @State private var chipWidths: [HomeChannel: CGFloat] = [:]
  @State private var barWidth: CGFloat = 0
  private let spacing: CGFloat = 4

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: spacing) {
          // The highlighted label follows the pager's nearest page, not the settled selection.
          let near = channels.indices.contains(motion.nearestIndex) ? channels[motion.nearestIndex] : shelf
          ForEach(Array(channels.enumerated()), id: \.element) { index, c in
            let current = shelf == c
            Button {
              TouchFeedback.light()
              if current { channelToTop() } else { shelf = c }
            } label: {
              Text(c.rawValue)
                .font(.subheadline.weight(near == c ? .semibold : .regular))
                .foregroundStyle(near == c ? Color.primary : Color.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidths[c] = $0 }
            .background(alignment: .leading) {
              HomeChannelHighlight(index: index, lastIndex: channels.count - 1, motion: motion,
                nextWidth: channels.indices.contains(index + 1) ? chipWidths[channels[index + 1]] : nil,
                spacing: spacing)
            }
            .accessibilityAddTraits(current ? .isSelected : []).id(c)
          }
        }
        .padding(.horizontal, inset)
        .frame(minWidth: centered ? barWidth : 0)
      }.scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .onChange(of: shelf, initial: true) { _, c in
          withAnimation(.snappy) { proxy.scrollTo(c, anchor: .center) }
        }
    }
  }
}
/// Keep the capsule in its chip's coordinates when the entire header is settling vertically.
private struct HomeChannelHighlight: View {
  let index: Int, lastIndex: Int
  let motion: PagerIndicatorMotion
  let nextWidth: CGFloat?
  let spacing: CGFloat

  var body: some View {
    let progress = min(max(0, motion.progress), CGFloat(lastIndex))
    if Int(progress) == index {
      GeometryReader { chip in
        let step = progress - CGFloat(index)
        let width = chip.size.width
        Capsule().fill(Color(uiColor: .tertiarySystemFill))
          .frame(width: width + ((nextWidth ?? width) - width) * step, height: chip.size.height)
          .padding(.leading, (width + spacing) * step)
          .frame(width: width, alignment: .leading)
      }
      .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

/// The tab container can extend a navigation root under the status bar. Measure just the
/// uncovered part in the feed's own coordinates, including the user's interface scale.
private struct FeedWindowSafeArea: UIViewRepresentable {
  let change: (FeedHeaderInsets) -> Void

  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) {
    view.change = change
    view.measureAfterLayout()
  }

  final class Probe: UIView {
    var change: ((FeedHeaderInsets) -> Void)?
    private var scheduled = false
    private var last: FeedHeaderInsets?
    private weak var observedTransition: UIViewControllerTransitionCoordinator?

    private func deferDuringNavigation() -> Bool {
      var responder = next
      while let current = responder {
        if let controller = current as? UIViewController,
          let transition = controller.navigationController?.transitionCoordinator {
          if transition === observedTransition { return true }
          observedTransition = transition
          // The navigation transition temporarily translates or scales the feed. Converting
          // the window's safe rect at that point would resize every row under the finger.
          if transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            self?.observedTransition = nil
            self?.measureAfterLayout()
          }) { return true }
          observedTransition = nil
          return false
        }
        responder = current.next
      }
      return false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); measureAfterLayout() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measureAfterLayout() }
    override func layoutSubviews() { super.layoutSubviews(); measureAfterLayout() }

    func measureAfterLayout() {
      guard !scheduled, window != nil else { return }
      scheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scheduled = false
        guard let window = self.window, self.bounds.height > 0, !self.deferDuringNavigation() else { return }
        let safe = self.convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
        let overlap = FeedHeaderInsets.window(bounds: self.bounds, safe: safe,
          rightToLeft: self.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        if self.last != overlap {
          self.last = overlap
          self.change?(overlap)
        }
      }
    }
  }
}

private struct HomeFeedBottomClearance: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
  var homeFeedBottomClearance: CGFloat {
    get { self[HomeFeedBottomClearance.self] }
    set { self[HomeFeedBottomClearance.self] = newValue }
  }
}
private struct FeedHeaderPlacement: ViewModifier {
  @State private var insets = FeedHeaderInsets()
  func body(content: Content) -> some View {
    content
      .padding(.top, insets.top)
      .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
      .frame(maxWidth: .infinity)
      .onGeometryChange(for: FeedHeaderInsets.self) { _ in
        // iOS 27.1 reservedRegions API is not in the iOS 26 SDK; folds report no insets.
        FeedHeaderInsets()
      } action: { insets = $0 }
  }
}

/// The app feed (`x/v2/feed/index`) is only personal with the recommendation account's access
/// key. A signed-in account without one (web, cookie or imported sign-in) gets the guest feed,
/// unlike the official app, so say so once and offer 移动端授权.
private struct MobileFeedAuthorizationTip: View {
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("feed.mobile") private var mobile = true
  @AppStorage("feed.authorizationTip") private var show = true
  var body: some View {
    if show, mobile, let uid = accounts.state.owner(.role(.recommend)),
      accounts.state.accounts.first(where: { $0.id == uid })?.mobileToken?.isEmpty != false
    {
      HStack(spacing: 10) {
        Image(systemName: "iphone.badge.exclamationmark").foregroundStyle(.orange)
        NavigationLink { DeferredPage { MobileAuthorization(uid: uid) } } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("推荐账号未完成移动端授权").piliFont(.subheadline, weight: .semibold)
            Text("App 推荐暂为游客内容，授权后与官方客户端一致").piliFont(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Button { show = false } label: {
          Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("不再提示")
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .background(Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: HomeCardStyle.radius, style: .continuous))
    }
  }
}

/// The feed's loading / retry footer: the only part that follows `busy`. Reaching it loads the
/// next page by itself, as the original's endless feed does; the button only stays for a feed
/// that stopped after several pages came back empty.
private struct ShelfFooter: View {
  let model: FeedModel
  let start: (_ retry: Bool) -> Void
  /// Asks for the next page if the end of the list is (still) on screen.
  let more: () -> Void
  @Environment(\.activeCatalogPage) private var active
  var body: some View {
    if let error = model.error {
      VStack(spacing: 12) {
        Text(error).piliFont(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("重试") { start(true) }.piliGlassButton()
      }.frame(maxWidth: .infinity).padding(.vertical, 24)
    } else if model.busy {
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, model.videos.isEmpty ? 120 : 16)
    } else if !model.finished && model.autoCursor != nil {
      // A page too short to fill the screen asks again once it lands (its count changes).
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
        .task(id: "\(model.videos.count):\(active)") { if active { more() } }
    } else if !model.finished {
      Button("加载更多") { start(false) }.piliGlassButton().frame(maxWidth: .infinity)
    } else if model.videos.isEmpty {
      ContentUnavailableView("暂无视频", systemImage: "play.rectangle")
    }
  }
}

/// Loads the channel when it is prepared and tracks whether it is on screen, reading the
/// channel environment here so its changes (every tab switch) do not re-render the feed.
private struct ShelfActivation: ViewModifier {
  let model: FeedModel, paging: FeedScrollPaging, shelf: Shelf
  @Environment(\.activeCatalogPage) private var active
  @Environment(\.preparedCatalogPage) private var prepared
  func body(content: Content) -> some View {
    content
      .task(id: prepared) { if prepared && !model.loaded { await model.load(shelf, reset: true) } }
      .onChange(of: active, initial: true) { _, visible in
        paging.active = visible
        if !visible { paging.endDrag(); paging.cancelLoad() }
      }
  }
}

/// Room below the last row for the tab bar, applied here so its changes (the bar minimising)
/// only move the padding.
private struct HomeFeedBottomPadding: ViewModifier {
  let extra: CGFloat
  @Environment(\.homeFeedBottomClearance) private var clearance
  func body(content: Content) -> some View { content.padding(.bottom, extra + clearance) }
}

/// One card of a shelf, drawn again only when its video (or the shelf's busy state) changes.
/// Every next page of the feed re-rendered every card on screen, their menus included, since
/// their closures never compare equal: 80–150 ms on an iPad's five columns, where a page (seven
/// videos, under two rows) arrives about once a second of scrolling.
private struct ShelfCell<Card: View>: View, Equatable {
  let video: Video
  let busy: Bool
  @ViewBuilder let card: () -> Card
  nonisolated static func == (a: Self, b: Self) -> Bool { a.video == b.video && a.busy == b.busy }
  var body: some View { card() }
}

private struct VideoShelf: View, Equatable {
  /// The 排行榜 closure is rebuilt by every parent render; only whether it exists matters here.
  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.shelf == b.shelf && (a.openRank == nil) == (b.openRank == nil)
  }
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.displayScale) private var displayScale
  @Environment(\.imageDisplay) private var imageDisplay
  @AppStorage("grid.recommendWidth") private var recommendedWidth = 240.0
  @AppStorage("grid.cardWidth") private var cardWidth = 240.0
  struct Feedback {
    let video: Video, group: String, reason: Video.FeedReason, uid: String, index: Int
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var feedback: Feedback?
  @State private var sending = false
  @State private var notice: String?
  let shelf: Shelf
  var openRank: (() -> Void)? = nil
  @State private var model = FeedModel()
  /// Unobserved: whether this channel is the one on screen, the running page load and the drag
  /// that may request one. Tab switches and loads used to re-render the whole feed through them.
  @State private var paging = FeedScrollPaging()
  @AppStorage("feed.retainedTip") private var tip = true
  @AppStorage("feed.hotEntrances") private var hotEntrances = false
  @AppStorage(HomeCardStyle.featuredKey) private var featuredFirst = false
  var body: some View {
    ScrollViewReader { proxy in shelfScroll(proxy) }
  }
  private func shelfScroll(_ proxy:ScrollViewProxy)->some View {
    let videos = model.videos
    let boundary = tip ? model.retainedIndex : nil
    let split = boundary.flatMap { $0 > 0 ? $0 : nil }
    let firstSection = videos[..<(split ?? videos.endIndex)]
    // The large first card is optional (设置 › 推荐过滤 › 首个推荐使用大卡片); by default every
    // recommendation is an official double-column card.
    let featured = featuredFirst && shelf == .recommended && sizeClass != .regular ? firstSection.first : nil
    return ScrollView {
      CatalogGrid(home: shelf == .recommended, gap: HomeCardStyle.gap, rowSpacing: CGFloat(HomeCardStyle.gap)) {
        Section {
          ForEach(firstSection.dropFirst(featured == nil ? 0 : 1)) { v in
            ShelfCell(video: v, busy: sending) { gridCard(v) }.equatable()
          }
        } header: {
          VStack(alignment: .leading, spacing: 12) {
            shelfHeader
            if boundary == 0 { refreshPrevious(proxy) }
            if let featured { archiveCard(featured, featured: true).padding(.bottom, 8) }
          }.frame(maxWidth: .infinity, alignment: .leading).id("discover.feed.top")
        } footer: {
          if split == nil { ShelfFooter(model: model, start: { startLoad(retry: $0) }, more: loadMore) }
        }
        if let split {
          Section {
            ForEach(videos[split...]) { v in
              ShelfCell(video: v, busy: sending) { gridCard(v) }.equatable()
            }
          } header: {
            refreshPrevious(proxy)
          } footer: {
            ShelfFooter(model: model, start: { startLoad(retry: $0) }, more: loadMore)
          }
        }
      }.padding(.horizontal, HomeCardStyle.gap).padding(.top, 4).modifier(HomeFeedBottomPadding(extra: 16))
      // The first page fades in over the spinner (later pages just append).
      .animation(.easeOut(duration: 0.25), value: videos.isEmpty)
    }
    .environment(\.homeFeedBottomClearance, 0)
    .piliOnScrollGeometryChange(for: Bool.self) { nearEnd($0) } action: { _, near in
      autoPage(nearEnd: near)
    }
    .piliOnScrollGeometryChange(for: Bool.self) { g in
      FeedScrollPaging.reachedEnd(visible: g.visibleRect, contentHeight: g.contentSize.height)
    } action: { _, end in
      paging.atEnd = end
      model.nearBottom = end
      if end { loadMore() }
    }
    .piliOnScrollPhaseChange { _, phase, geometry in
      model.moving = phase == .interacting || phase == .decelerating
      switch phase {
      case .interacting:
        paging.beginDrag()
        autoPage(nearEnd: nearEnd(geometry))
      case .decelerating: break
      default: paging.endDrag()
      }
    }
    .environment(\.discoveryCardRemoval,{ [model] change in
      model.remove { v in v.bvid==change.archive || (change.creator != nil && v.owner?.mid==change.creator) }
    }).piliRefreshable {
      paging.endDrag()
      await model.load(shelf, reset: true)
    }
    .modifier(ShelfActivation(model: model, paging: paging, shelf: shelf))
    .onDisappear { paging.endDrag(); paging.cancelLoad() }
  }

  private func nearEnd(_ geometry: PiliScrollGeometry) -> Bool {
    FeedScrollPaging.nearEnd(visible: geometry.visibleRect, contentHeight: geometry.contentSize.height)
  }

  /// The footer is reached: load on, as long as the end stays in reach (a short page asks again).
  private func loadMore() {
    guard paging.active, paging.atEnd, !model.busy, model.error == nil, model.autoCursor != nil,
      !model.finished else { return }
    startLoad()
  }

  private func autoPage(nearEnd: Bool) {
    guard paging.active, !model.busy, model.error == nil, model.autoCursor != nil,
      paging.takePage(nearEnd: nearEnd) else { return }
    startLoad()
  }

  @ViewBuilder private var shelfHeader: some View {
    if shelf == .recommended { MobileFeedAuthorizationTip() }
    if shelf == .popular && hotEntrances {
      HStack {
        ForEach(Rankings.Mode.allCases, id: \.self) { mode in
          if mode == .rank, let openRank {
            Button(action: openRank) { Text(mode.rawValue).frame(maxWidth: .infinity) }
          } else {
            NavigationLink {
              Rankings(initial: mode)
            } label: {
              Text(mode.rawValue).frame(maxWidth: .infinity)
            }
          }
        }
      }.buttonStyle(.bordered)
    }
    if let feedback {
      HStack {
        Text(feedback.reason.toast ?? "已反馈").font(.footnote)
        Spacer()
        Button("撤销") { Task { await send(feedback, undo: true) } }
      }.disabled(sending)
    }
    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
  }

  private func refreshPrevious(_ proxy: ScrollViewProxy) -> some View {
    Button {
      withAnimation { proxy.scrollTo("discover.feed.top", anchor: .top) }
      startLoad(reset: true)
    } label: {
      Label("以下是上次推荐，点此刷新", systemImage: "arrow.up.circle").piliFont(.caption)
    }
  }

  @MainActor private func startLoad(reset: Bool = false, retry: Bool = false) {
    guard reset || !model.busy else { return }
    let model = model, shelf = shelf
    paging.startLoad {
      if retry { await model.retry(shelf) }
      else { await model.load(shelf, reset: reset) }
    }
  }
  /// The official client's double-column card on the grouped background.
  private func gridCard(_ v: Video) -> some View {
    cardLink(v)
    .buttonStyle(PressPrefetchStyle { if v.recommendLink == nil { ArchiveDetailPrefetch.shared.warm(v.bvid) } })
    .onAppear { prefetchCovers(after: v) }
    .overlay(alignment: .bottomTrailing) { moreMenu(v) }
    .archiveCover(v) { feedbackMenus(v) }
    .disabled(sending)
  }
  /// A video opens by value, through the stack's `navigationDestination(for: Video.self)`: a link
  /// carrying its own destination per card was the heaviest part of a card to make, and an
  /// iPad's grid makes five at a time as a row scrolls in (80–110 ms frames mid-fling).
  @ViewBuilder private func cardLink(_ v: Video) -> some View {
    if v.recommendLink == nil, zoomStyle(for: v) == .custom {
      NavigationLink(value: v) { HomeVideoCard(video: v).modifier(CardZoomSource()) }
    } else {
      LazyLink(zoomStyle: zoomStyle(for: v)) { destination(v) } label: { HomeVideoCard(video: v) }
    }
  }
  private func zoomStyle(for video: Video) -> CardZoomStyle? {
    let opensVideo = video.recommendationOpensVideo ?? video.recommendLink.flatMap(SharedLink.parse)?.opensVideoDetail ?? true
    return opensVideo ? .custom : nil
  }
  @ViewBuilder private func destination(_ v: Video) -> some View {
    if let link = v.recommendLink.flatMap(SharedLink.parse) {
      LinkDestination(item: link)
    } else {
      DetailView(initial: v)
    }
  }
  /// The official card's trailing "⋮": 稍后再看 and the feed's own feedback reasons.
  @ViewBuilder private func moreMenu(_ v: Video) -> some View {
    let aid = v.aid ?? ArchiveNumber.av(v.bvid)
    let viewer = accounts.state.active
    if (viewer != nil && aid != nil) || hasFeedback(v) {
      Menu {
        if let viewer, let aid {
          Button("添加到稍后再看", systemImage: "clock") { addLater(aid, owner: viewer) }
        }
        feedbackMenus(v)
      } label: {
        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
          .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
          .frame(width: 30, height: 30).contentShape(Rectangle())
      }
      .tint(Color(uiColor: .secondaryLabel))
      .padding(.trailing, 2).padding(.bottom, 2)
      .accessibilityLabel("更多操作")
    }
  }
  private func hasFeedback(_ v: Video) -> Bool {
    accounts.state.owner(.role(.recommend)) != nil
      && (v.recommendMenu ?? []).contains {
        ["dislike", "feedback"].contains($0.type) && !($0.reasons ?? []).isEmpty
      }
  }
  @ViewBuilder private func feedbackMenus(_ v: Video) -> some View {
    if let uid = accounts.state.owner(.role(.recommend)) {
      ForEach(Array((v.recommendMenu ?? []).enumerated()), id: \.offset) { _, group in
        if ["dislike", "feedback"].contains(group.type), let reasons = group.reasons,
          !reasons.isEmpty
        {
          Menu(group.type == "dislike" ? "不感兴趣" : "反馈") {
            ForEach(reasons) { r in
              Button(r.name) {
                Task {
                  await send(
                    .init(
                      video: v, group: group.type, reason: r, uid: uid,
                      index: model.videos.firstIndex(where: { $0.id == v.id }) ?? 0),
                    undo: false)
                }
              }
            }
          }
        }
      }
    }
  }
  private func addLater(_ aid: Int64, owner: String) {
    Task { @MainActor in
      do {
        try await BiliAPI.shared.submit(
          "/x/v2/history/toview/add", ["aid": String(aid)], expectedAccount: owner)
        AppToast.show("已加入稍后再看")
      } catch { notice = error.localizedDescription }
    }
  }
  /// The optional large first card.
  private func archiveCard(_ v: Video, featured: Bool) -> some View {
        LazyLink(zoomStyle: zoomStyle(for: v)) {
          destination(v)
        } label: {
          VStack(alignment: .leading, spacing: featured ? 10 : 8) {
            Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
              .overlay {
                SiteThumbnail(url: v.cover) { img in
                  img.resizable().scaledToFill()
                } placeholder: {
                  Color.clear
                }
              }
              .overlay(alignment: .bottomTrailing) {
                if let d = v.duration {
                  Text(clockText(Double(d))).font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(featured ? 12 : 8)
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: featured ? NativeGlass.panelRadius : NativeGlass.cardRadius, style: .continuous))
              .cardZoomCover(radius: featured ? NativeGlass.panelRadius : NativeGlass.cardRadius)
            VStack(alignment: .leading, spacing: 4) {
              Text(v.title).piliFont(featured ? .title3 : .subheadline, weight: .semibold)
                .lineLimit(2).multilineTextAlignment(.leading)
              if let reason = v.recommendationReason, !reason.isEmpty {
                Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.tint)
              }
              HStack(spacing: 4) {
                if let name = v.owner?.name { Text(name).lineLimit(1) }
                if v.owner?.name != nil, v.stat?.view != nil { Text("·") }
                if let views = v.stat?.view {
                  Text(views.formatted(.number.notation(.compactName)) + "次观看").fixedSize()
                }
              }.piliFont(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, featured ? 4 : 2)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(PressPrefetchStyle { if v.recommendLink == nil { ArchiveDetailPrefetch.shared.warm(v.bvid) } })
        .archiveCover(v) { feedbackMenus(v) }.disabled(sending)
  }
  /// Decodes the covers of the next rows while this one scrolls in, at the size the cards draw.
  private func prefetchCovers(after v: Video) {
    let ahead = model.covers(after: v)
    guard !ahead.isEmpty else { return }
    let gap = HomeCardStyle.gap
    let window = Double(WindowCanvas.shared.size.width)
    let desired = min(500, max(150, shelf == .recommended ? recommendedWidth : cardWidth))
    let columns = Double(max(1, InterfacePresentation.columns(
      width: window - 2 * gap, gap: gap, desired: desired, accessible: false)))
    let width = (window - 2 * gap - gap * (columns - 1)) / columns
    let pixels = ArtworkCacheRules.pixels(
      width: width, height: width / Double(HomeCardStyle.coverAspect), scale: Double(displayScale))
    let quality = (imageDisplay ?? .stored).quality
    let pictures = ahead.map(\.pic)
    Task(priority: .utility) {
      await ArtworkPrefetch.shared.prefetch(pictures, pixels: pixels, quality: quality)
    }
  }
  @MainActor private func send(_ item: Feedback, undo: Bool) async {
    guard !sending, accounts.state.owner(.role(.recommend)) == item.uid else { return }
    sending = true
    notice = nil
    defer { sending = false }
    do {
      try await BiliAPI.shared.feedFeedback(
        item.video, group: item.group, reason: item.reason.id, undo: undo, uid: item.uid)
      guard accounts.state.owner(.role(.recommend)) == item.uid else { return }
      if undo {
        model.restore(item.video, at: item.index)
        feedback = nil
      } else {
        model.remove { $0.id == item.video.id }
        feedback = item
      }
    } catch { notice = error.localizedDescription }
  }
}
