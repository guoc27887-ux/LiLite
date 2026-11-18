import SwiftUI

struct PageList<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
  let empty: String
  var focus: Item.ID? = nil
  var grid = false
  var gridItemWidth: Double? = nil
  var autoMore = true
  var discoveryArchive:((Item)->Video?)?=nil
  var dynamicCards = false
  var embeddedComments = false
  var active = true
  @Environment(\.activeCatalogPage) private var channelActive
  @Environment(\.preparedCatalogPage) private var channelPrepared
  var scrollToTopRequest = 0
  var prefetchFirstPage = false
  var heading: AnyView? = nil
  var controls: AnyView? = nil
  var refreshed: (() async -> Void)? = nil
  @AppStorage("social.waterfall") private var waterfall: Bool?
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage("grid.cardWidth") private var cardWidth = 240.0
  @Environment(\.libraryScrollToTop) private var libraryTop
  @Environment(\.dynamicTypeSize) private var textSize
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @State private var refreshHeader = 0
  let fetch: (String?) async throws -> Page<Item>
  @ViewBuilder let row: (Item) -> Row
  @State private var items: [Item] = []
  @State private var itemRevision = 0
  @State private var next: String?
  @State private var busy = false
  @State private var loaded = false
  @State private var message: String?
  @State private var continuation:URL?
  @State private var stamp = UUID()
  @State private var boundary = PageBoundary()
  @State private var autoPage = false
  @State private var space = UUID()
  @State private var viewport = CGSize.zero
  @State private var manualLoad: Task<Void, Never>?
  var body: some View {
    ScrollViewReader { proxy in
      Group {
        if dynamicCards {
          feedLayout
        } else if grid {
          ScrollView {
            VStack {
              if let heading { heading.id(refreshHeader) }
              if let controls { controls.id("pili.page.controls") }
              CatalogGrid(itemWidth: gridItemWidth) { ForEach(items) { item in row(item).id(item.id) } }
              footer
            }.padding()
          }.reportsScrollCollapse()
        } else if embeddedComments {
          // This page already lives inside a player. A second, self-sizing collection view
          // repeatedly asks UIKit text rows for their height while its parent settles.
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              if let heading { heading.id(refreshHeader) }
              if let controls { controls.id("pili.page.controls") }
              ForEach(items) { item in
                VStack(alignment: .leading, spacing: 0) {
                  row(item).padding(.leading, 14).padding(.trailing, 12)
                  Divider().padding(.leading, 58)
                }.id(item.id)
              }
              footer
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.environment(\.inListRows, true).reportsScrollCollapse()
        } else {
          List {
            if let heading { heading.id(refreshHeader) }
            if let controls { controls.id("pili.page.controls") }
            ForEach(items) { row($0) }
            footer
          }.listStyle(.plain).environment(\.inListRows, true).reportsScrollCollapse()
        }
      }.coordinateSpace(name: space)
      .background { GeometryReader { frame in
        Color.clear.onChange(of: frame.size, initial: true) { _, size in viewport = size }
      } }
      .environment(\.discoveryCardRemoval,discoveryArchive.map{ extract in { change in
        itemRevision &+= 1
        items.removeAll{ row in guard let video=extract(row) else{return false};return video.bvid==change.archive || (change.creator != nil && video.owner?.mid==change.creator) }
      }})
      .piliRefreshable {
        refreshHeader &+= 1
        async let header: Void = refreshed?() ?? ()
        await load(reset: true)
        await header
      }
      .task(id: channelPrepared && (active || prefetchFirstPage)) { if channelPrepared && (active || prefetchFirstPage) && !loaded { await load(reset: true) } }
      .onChange(of: channelActive && active) { _, visible in
        if !visible { manualLoad?.cancel(); manualLoad = nil }
      }
      .onDisappear { manualLoad?.cancel(); manualLoad = nil }
      .onChange(of: libraryTop) { _, _ in
        if let first = items.first { withAnimation { proxy.scrollTo(first.id, anchor: .top) } }
      }
      .onChange(of: scrollToTopRequest) { _, _ in
        if let first = items.first { withAnimation { proxy.scrollTo(first.id, anchor: .top) } }
      }
      .onChange(of: loaded) { _, didLoad in
        // The original reveals the located reply a quarter down the list once it is laid out
        // (jumpToItem in a post-frame callback). Rows are lazy, so retry after layout settles.
        if didLoad, let focus, items.contains(where: { $0.id == focus }) {
          Task { @MainActor in
            for wait in [30, 150, 400] {
              try? await Task.sleep(for: .milliseconds(wait))
              proxy.scrollTo(focus, anchor: UnitPoint(x: 0.5, y: 0.25))
            }
          }
        }
      }
    }
  }
  private var feedLayout: some View {
    GeometryReader { frame in
      let full = max(1, frame.size.width - 32)
      let columns =
        (waterfall ?? horizontal)
        ? FeedColumnPlan.columns(
          width: full, cardWidth: cardWidth, largeText: textSize.isAccessibilitySize || voiceOver)
        : 1
      let limit = max(150, min(500, cardWidth)) * 2
      ScrollView {
        LazyVStack(alignment: .center, spacing: 4) {
          if let heading { heading.id(refreshHeader) }
          if let controls { controls.id("pili.page.controls") }
          if columns > 1 {
            FeedWaterfall(
              items: items, available: full, viewport: frame.size.height, columns: columns, row: row
            )
          } else {
            ForEach(items) { item in
              row(item).frame(maxWidth: min(full, limit), alignment: .leading).id(item.id)
            }
          }
          footer
          if channelActive, active, autoPage, let next, message == nil {
            pageEdge(next)
          }
        }.padding(.horizontal, 16).padding(.vertical, 6)
          .frame(maxWidth: .infinity)
      }.reportsScrollCollapse()
    }
  }
  @ViewBuilder private var footer: some View {
    Group {
      if let message {
        VStack(spacing: 10) {
          Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
          if let continuation { NavigationLink("在哔哩哔哩网站继续"){SitePage(url:continuation,role:.recommend)} }
          Button("重试") { startLoad(reset: boundary.failedRefresh) }.piliButtonStyle(.glass)
        }.frame(maxWidth: .infinity).padding(.vertical, items.isEmpty ? 80 : 16)
      } else if busy {
        // First load sits in the middle of the page; later pages show a small footer spinner.
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, items.isEmpty ? 120 : 14)
      } else if loaded && items.isEmpty {
        ContentUnavailableView(empty, systemImage: "tray").padding(.top, 40)
      } else if loaded && next == nil {
        Text("没有更多了").font(.footnote).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      }
    }
    .transition(.opacity)
    .listRowSeparator(.hidden).listRowBackground(Color.clear)
    if !busy && next != nil && message == nil {
      let automatic = channelActive && autoMore && !dynamicCards && active && autoPage
      if !automatic {
        Button("加载更多") { startLoad(reset: false) }
          .piliButtonStyle(.glass).frame(maxWidth: .infinity)
          .listRowSeparator(.hidden).listRowBackground(Color.clear)
      } else if let cursor = next {
        pageEdge(cursor).listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
    }
  }
  private func pageEdge(_ cursor: String) -> some View {
    GeometryReader { frame in
      let y = frame.frame(in: .named(space)).minY
      let visible = PageBoundary.nearFooter(y: y, height: viewport.height)
      let ready = visible && !busy && channelActive && active && next == cursor && message == nil
      Color.clear.onChange(of: ready, initial: true) { _, reached in
        if reached { startLoad(reset: false) }
      }
    }.frame(height: 1).id("pili.page.next."+cursor).accessibilityHidden(true)
  }
  @MainActor private func startLoad(reset: Bool) {
    guard reset || !busy else { return }
    manualLoad?.cancel()
    manualLoad = Task { await load(reset: reset) }
  }
  @MainActor private func load(reset: Bool) async {
    guard !Task.isCancelled else { return }
    if !reset && (busy || next == nil) { return }
    let cursor = reset ? nil : next
    let id = UUID()
    stamp = id
    busy = true
    message = nil;continuation=nil
    defer { if stamp == id { busy = false } }
    do {
      let page = try await fetch(cursor)
      try Task.checkCancellation()
      guard stamp == id else { return }
      let previous = reset ? [] : items
      let revision = itemRevision
      let merging = Task.detached(priority: .userInitiated) {
        var seen = Set(previous.map(\.id))
        let added = page.items.filter { !Task.isCancelled && seen.insert($0.id).inserted }
        return (previous + added, !added.isEmpty)
      }
      let merged = await withTaskCancellationHandler { await merging.value } onCancel: { merging.cancel() }
      try Task.checkCancellation()
      guard stamp == id, itemRevision == revision else { return }
      let first = items.isEmpty
      // Fade the first page in; later pages append without animating every inserted row.
      var transaction = Transaction(animation: first ? .easeOut(duration: 0.25) : nil)
      transaction.disablesAnimations = !first
      withTransaction(transaction) {
        items = merged.0
        itemRevision &+= 1
        next = boundary.next(page.next, after: cursor, reset: reset)
        autoPage = (dynamicCards || autoMore) && merged.1
        loaded = true
      }
    } catch { if stamp == id && !Task.isCancelled { boundary.failed(refresh: reset); message = error.localizedDescription;continuation = (error as? ServiceError)?.continuation } }
  }
}
struct VideoLink: View {
  let video: Video
  /// Chart position, shown as a badge on the cover.
  var rank: Int? = nil
  /// Inside one creator's space every row has the same author; show the date in its place.
  var hidesOwner = false
  @Namespace private var hero
  var body: some View {
    PlainRowLink {
      DetailView(initial: video).heroDestination(video.id, in: hero)
    } label: {
      MediaRow(
        cover: video.cover, title: video.title, badge: rank.map { "TOP \($0)" },
        duration: video.duration.map { clockText(Double($0)) },
        subtitle: hidesOwner ? MediaStats.published(video.pubdate) : video.owner?.name,
        detail: MediaStats.line(
          views: video.stat?.view, danmaku: video.stat?.danmaku,
          extra: hidesOwner ? [] : [MediaStats.published(video.pubdate)]),
        hero: (video.id, hero))
    }.archiveCover(video)
  }
}
