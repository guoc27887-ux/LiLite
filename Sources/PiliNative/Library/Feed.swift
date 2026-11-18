import SwiftUI

enum Shelf: String, CaseIterable {
  case recommended = "推荐"
  case popular = "热门"
}
@MainActor
final class FeedModel: ObservableObject {
  @Published var videos: [Video] = [] { didSet { contentRevision &+= 1 } }
  private var contentRevision = 0
  @Published var error: String?
  @Published var busy = false
  @Published var finished = false
  @Published var retainedStart: String?
  @Published var autoCursor:Int?
  private(set) var loaded = false
  private var page = 0, token = UUID()
  private struct Request { let shelf:Shelf, reset:Bool, page:Int }
  private var failed:Request?
  func load(_ shelf: Shelf, reset: Bool) async {
    guard !Task.isCancelled else { return }
    if !reset && (busy || finished) { return }
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
    busy = true
    error = nil
    failed = nil
    defer { if token == t { busy = false } }
    do {
      let batch =
        try await
        (shelf == .recommended
        ? BiliAPI.shared.recommendations(next, mobile: mobile) : BiliAPI.shared.popular(next))
      guard token == t, !Task.isCancelled else { return }
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
      if reset { retainedStart = result.1 }
      videos = result.0
      page = next
      autoCursor = result.2 && batch.next != nil ? next + 1 : nil
      finished = batch.next == nil
      loaded = true
    } catch { if token == t && !Task.isCancelled { failed=request;self.error=error.localizedDescription } }
  }
}
struct FeedView: View {
  @Environment(\.usesSystemSearchTab) private var systemSearch
  @EnvironmentObject private var indicators: UnreadIndicators
  @AppStorage("badge.messageMode") private var messageMode = 2
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("search.defaultWord") private var useHint = false
  @State private var hint = ""
  @State private var hintScope: String?
  @State private var hintRead: Date?
  @Environment(\.scenePhase) private var hintPhase
  @Environment(\.scrollHomeChannelToTop) private var channelToTop
  @Environment(\.openPersonalPage) private var openProfile
  /// The avatar comes from the shared profile cache, so returning to this tab never shows the
  /// placeholder again before the same picture.
  @ObservedObject private var profiles = ProfileStore.shared
  private var avatar: URL? {
    accounts.state.active.flatMap { profiles.profiles[$0]?.face }.flatMap(httpsURL)
  }
  @State private var search = false
  @AppStorage(RecommendationRules.key) private var rules = Data()
  @AppStorage("feed.mobile") private var mobile = true
  @AppStorage(NavigationLayout.key) private var layoutData = Data()
  @State private var shelf = NavigationRules.firstChannel(NavigationLayout.current().channels)
  @State private var pageProgress: CGFloat = 0
  @State private var chipFrames: [HomeChannel: CGRect] = [:]
  var body: some View {
    PiliNavigationStack {
      let channels = NavigationLayout.read(layoutData).channels
      Color.clear  // DIAG2: deck removed
        // The original client's header: one row (search, messages, menu, avatar) that scrolls
        // away with the feed, and the channel chips under it, which always stay.
        .piliSafeAreaBar(edge: .top, spacing: 0) {
          VStack(spacing: 0) {
            headerRow.padding(.top, 2).padding(.bottom, 8).piliHomeSearchVisibility()
            if channels.count > 1 { channelBar(channels).padding(.bottom, 6) }
          }
        }
        .toolbar(.hidden, for: .navigationBar)
      .task(id: accounts.state.active) {
        if let uid = accounts.state.active { await profiles.refresh(uid) }
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
        SearchView(
          initialHint: hint, embedded: true,
          placement: .navigationBarDrawer(displayMode: .always))
      }
      .piliTabRoot(.home)
      .navigationTitle("发现")
      .toolbarTitleDisplayMode(.inline)
      .toolbar(removing: .title)
      .navigationDestination(for: Video.self) { DetailView(initial: $0) }
    }
  }
  private func deck(_ channels: [HomeChannel]) -> some View {
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    let shelfID = "\(mobile):\(rules.hashValue):\(owner)"
    return RetainedDeck(choices: channels, selection: $shelf, progress: $pageProgress) { channel in
      switch channel {
      case .recommended: VideoShelf(shelf: .recommended).id(shelfID)
      case .popular: VideoShelf(shelf: .popular).id(shelfID)
      case .rank: Rankings(embedded: true)
      case .live: LiveDirectory(area: nil, child: nil, embedded: true)
      case .bangumi: PGCHome(cinema: false)
      case .cinema: PGCHome(cinema: true)
      }
    }.id("\(accounts.state.active ?? ""):\(owner)")
      .onChange(of: channels) { _, new in
        if !new.contains(shelf) { shelf = NavigationRules.firstChannel(new) }
      }
  }
  private var unreadMessages: Text? {
    UnreadTotals.label(indicators.count(for: accounts.state.active, messages: true), mode: messageMode)
      .map { Text(verbatim: $0) }
  }
  private var headerRow: some View {
    HStack(spacing: 10) {
      if !systemSearch || useHint { searchEntry } else { Spacer(minLength: 0) }
      // The original header: search, the message bell (signed in only), then the avatar.
      // Settings, rankings, live, the season index and "open link" live where the original
      // puts them (我的 page, home channels, the PGC "索引" header, the search page).
      if accounts.state.active != nil {
        NavigationLink {
          Inbox()
        } label: {
          Image(systemName: "bell").font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Circle())
            .overlay(alignment: .topTrailing) {
              if let unreadMessages {
                unreadMessages.font(.system(size: 10, weight: .bold)).monospacedDigit()
                  .foregroundStyle(.white).padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                  .background(.red, in: Capsule()).offset(x: -2, y: 2)
              }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .piliGlass(in: Circle(), interactive: true)
        .accessibilityLabel("消息中心")
      }
      if let openProfile { profileButton(openProfile) }
    }
    .padding(.horizontal, 16)
  }
  private func profileButton(_ open: @escaping @MainActor () -> Void) -> some View {
    let incognito = accounts.state.active != nil && accounts.state.owner(.role(.heartbeat)) == nil
    return Button(action: open) {
      SiteThumbnail(url: avatar) { $0.resizable().scaledToFill() } placeholder: {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
      }
      .frame(width: 38, height: 38).clipShape(Circle())
      .overlay(alignment: .bottomTrailing) {
        if incognito {
          Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .semibold))
            .padding(3).background(.regularMaterial, in: Circle()).offset(x: 3, y: 3)
        }
      }
    }.buttonStyle(.plain)
      .accessibilityLabel(accounts.state.active == nil ? "登录或查看我的" : "我的")
  }
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
  /// One capsule interpolated between the two chips the pager sits between.
  @ViewBuilder private func channelIndicator(_ channels: [HomeChannel]) -> some View {
    let p = min(max(0, pageProgress), CGFloat(max(0, channels.count - 1)))
    let i = Int(p.rounded(.down))
    let f = p - CGFloat(i)
    if channels.indices.contains(i), let a = chipFrames[channels[i]] {
      let b = channels.indices.contains(i + 1) ? chipFrames[channels[i + 1]] ?? a : a
      let x = a.minX + (b.minX - a.minX) * f
      let w = a.width + (b.width - a.width) * f
      Capsule().fill(Color(uiColor: .tertiarySystemFill))
        .frame(width: w, height: a.height)
        .offset(x: x, y: a.minY)
        .allowsHitTesting(false)
    }
  }
  private func channelBar(_ channels: [HomeChannel]) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          // The highlighted label follows the pager's nearest page, not the settled selection.
          let near = channels.indices.contains(Int(pageProgress.rounded())) ? channels[Int(pageProgress.rounded())] : shelf
          ForEach(channels) { c in
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("channels")) } action: {
                  chipFrames[c] = $0
                }
            }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : []).id(c)
          }
        }
        .background(alignment: .topLeading) { channelIndicator(channels) }
        .coordinateSpace(.named("channels"))
        .padding(.horizontal, 16)
      }.scrollClipDisabled()
        .onChange(of: shelf, initial: true) { _, c in
          withAnimation(.snappy) { proxy.scrollTo(c, anchor: .center) }
        }
    }
  }
}
private struct VideoShelf: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  struct Feedback {
    let video: Video, group: String, reason: Video.FeedReason, uid: String, index: Int
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.activeCatalogPage) private var channelActive
  @Environment(\.preparedCatalogPage) private var channelPrepared
  @State private var feedback: Feedback?
  @State private var sending = false
  @State private var notice: String?
  let shelf: Shelf
  @StateObject private var model = FeedModel()
  @State private var manualLoad: Task<Void, Never>?
  @AppStorage("feed.retainedTip") private var tip = true
  @Namespace private var hero
  @AppStorage("feed.hotEntrances") private var hotEntrances = false
  var body: some View {
    ScrollViewReader { proxy in shelfScroll(proxy) }
  }
  private func shelfScroll(_ proxy:ScrollViewProxy)->some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        Color.clear.frame(height:1).id("discover.feed.top")
        if shelf == .popular && hotEntrances {
          HStack {
            ForEach(Rankings.Mode.allCases, id: \.self) { mode in
              NavigationLink {
                Rankings(initial: mode)
              } label: {
                Text(mode.rawValue).frame(maxWidth: .infinity)
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
        if tip, let id = model.retainedStart,
          let cut = model.videos.firstIndex(where: { $0.id == id })
        {
          if cut > 0 { cards(Array(model.videos[..<cut])) }
          Button {
            withAnimation {proxy.scrollTo("discover.feed.top",anchor:.top)}
            startLoad(reset: true)
          } label: {
            Label("以下是上次推荐，点此刷新",systemImage:"arrow.up.circle").piliFont(.caption)
          }
          cards(Array(model.videos[cut...]))
        } else {
          cards(model.videos)
        }
        if let error = model.error {
          VStack(spacing: 12) {
            Text(error).piliFont(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试") { startLoad(retry: true) }.piliButtonStyle(.glass)
          }.frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if model.busy {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, model.videos.isEmpty ? 120 : 16)
        } else if !model.finished {
          Button("加载更多") { startLoad() }
            .piliButtonStyle(.glass).frame(maxWidth: .infinity)
          if channelActive,let cursor=model.autoCursor {
            Color.clear.frame(height:1).id("discover.feed.next.\(cursor)").onAppear {
              if cursor == model.autoCursor { startLoad() }
            }
          }
        } else if model.videos.isEmpty {
          ContentUnavailableView("暂无视频", systemImage: "play.rectangle")
        }
      }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
        .animation(.easeOut(duration: 0.25), value: model.videos.isEmpty)
        .animation(.easeOut(duration: 0.2), value: model.busy)
    }.environment(\.discoveryCardRemoval,{ change in
      model.videos.removeAll{v in v.bvid==change.archive || (change.creator != nil && v.owner?.mid==change.creator)}
    }).piliRefreshable { await model.load(shelf, reset: true) }
      .task(id:channelPrepared) { if channelPrepared && !model.loaded { await model.load(shelf, reset: true) } }
      .onChange(of: channelActive) { _, visible in
        if !visible { manualLoad?.cancel(); manualLoad = nil }
      }
      .onDisappear { manualLoad?.cancel(); manualLoad = nil }
  }
  @MainActor private func startLoad(reset: Bool = false, retry: Bool = false) {
    guard reset || !model.busy else { return }
    manualLoad?.cancel()
    manualLoad = Task {
      if retry { await model.retry(shelf) }
      else { await model.load(shelf, reset: reset) }
    }
  }
  @ViewBuilder private func cards(_ videos: [Video]) -> some View {
    if shelf == .recommended, sizeClass != .regular, let first = videos.first,
      first.id == model.videos.first?.id {
      VStack(alignment: .leading, spacing: 24) {
        archiveCard(first, featured: true)
        CatalogGrid(home: true) {
          ForEach(Array(videos.dropFirst())) { archiveCard($0, featured: false) }
        }
      }
    } else {
      CatalogGrid(home: shelf == .recommended) {
        ForEach(videos) { archiveCard($0, featured: false) }
      }
    }
  }
  private func archiveCard(_ v: Video, featured: Bool) -> some View {
        NavigationLink {
          if let link = v.recommendLink.flatMap(SharedLink.parse) {
            LinkDestination(item: link)
          } else {
            DetailView(initial: v).heroDestination(v.id, in: hero)
          }
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
              .matchedTransitionSource(id: v.id, in: hero)
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
        }.buttonStyle(.plain).archiveCover(v) {
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
        }.disabled(sending)
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
        CardPreferenceMutation.restore(item.video,at:item.index,to:&model.videos)
        feedback = nil
      } else {
        model.videos.removeAll { $0.id == item.video.id }
        feedback = item
      }
    } catch { notice = error.localizedDescription }
  }
}
