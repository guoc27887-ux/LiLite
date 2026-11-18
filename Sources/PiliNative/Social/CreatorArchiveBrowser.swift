import SwiftUI

struct CreatorArchiveBrowser: View {
  typealias Source = CreatorArchiveSource
  typealias Tag = CreatorArchiveTag
  @EnvironmentObject private var accounts: AccountContext
  @State private var playlist: PlaylistStart?
  @State private var hint: CreatorQueueHint?
  @State private var webHint: CreatorQueueHint?
  @State private var webKey = ""
  @State private var hintKey = ""
  @State private var tagError: String?
  @State private var moreAvailable = false
  @State private var loadingTags = false
  @State private var browser: CreatorPlaybackCursor?
  private var effectiveHint: CreatorQueueHint? {
    let mobile = hintKey == scope.storageKey ? hint : nil
    return webKey == scope.storageKey ? webHint ?? mobile : mobile
  }
  @State private var hasLocal = false
  @State private var listen = false
  let source: Source, title: String
  /// Off inside a creator's space, which has its own search in the toolbar.
  var searchable = true
  @State private var order = "pubdate"
  @State private var reverse = false
  @State private var tag: Tag?
  @State private var options: [Tag] = []
  @State private var page = 1
  @State private var total: Int?
  @State private var rows: [Video] = []
  @State private var search = ""
  @State private var term = ""
  @State private var jump = false
  @State private var pageText = ""
  @State private var busy = false
  @State private var error: String?
  @State private var epoch = UUID()
  @State private var contentKey: String?
  @State private var loadedKey: String?
  private var numberedByCursor: Bool { source.uploads && !scope.filtered }
  private var maxPage: Int? {
    let size = numberedByCursor ? 20 : 30
    return total.map { max(1, ($0 + size - 1) / size) }
  }
  private var scope: CreatorArchiveScope {
    .init(
      source: source, title: title, order: order, reverse: reverse, tid: tag?.tid ?? 0,
      special: tag?.special_type, term: term, owners: .init(accounts.state))
  }
  private var userMode: Bool { source.uploads }
  private var key: String { "\(page):\(scope.storageKey)" }
  private var orderName: String {
    userMode ? (order == "click" ? "最多播放" : order == "stow" ? "最多收藏" : "最新发布")
      : (reverse ? "正序" : "倒序")
  }
  @ViewBuilder private var sortMenu: some View {
    Menu {
      if userMode {
        Picker("排序", selection: $order) {
          Text("最新发布").tag("pubdate")
          Text("最多播放").tag("click")
          Text("最多收藏").tag("stow")
        }
        Section("投稿分类") {
          if options.isEmpty {
            Button("载入投稿分类") { Task { await loadTags() } }.disabled(loadingTags)
          }
          Button {
            tag = nil
            page = 1
          } label: {
            if tag == nil { Label("全部类型", systemImage: "checkmark") } else { Text("全部类型") }
          }
          ForEach(options) { t in
            Button {
              tag = t
              page = 1
            } label: {
              if tag?.id == t.id { Label(t.name ?? "分类", systemImage: "checkmark") } else { Text(t.name ?? "分类") }
            }
          }
        }
      } else {
        Picker("顺序", selection: $reverse) {
          Text("倒序").tag(false)
          Text("正序").tag(true)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.semibold))
        Text(tag?.name.map { orderName + " · " + $0 } ?? orderName).lineLimit(1)
      }
      .font(.subheadline).foregroundStyle(.secondary).contentShape(Rectangle())
    }
  }
  var body: some View {
    List {
      HStack(spacing: 8) {
        if !rows.isEmpty || hasLocal || numberedByCursor {
          Button {
            playlist = PlaylistStart()
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "play.fill")
              Text("播放全部")
            }.font(.subheadline.weight(.semibold))
          }.piliButtonStyle(.glassProminent)
          if hasLocal || scope.mayResume(effectiveHint) {
            Button {
              playlist = PlaylistStart(resume: true)
            } label: {
              Text("继续").font(.subheadline.weight(.medium))
            }.piliButtonStyle(.glass)
          }
          if !rows.isEmpty {
            Button { listen = true } label: {
              Image(systemName: "headphones").font(.subheadline.weight(.medium))
            }.piliButtonStyle(.glass).accessibilityLabel("收听全部")
          }
        }
        Spacer(minLength: 0)
        sortMenu
      }
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
      ForEach(rows) { v in
        VideoLink(video: v, hidesOwner: true).contextMenu {
          Button("从这里连续播放") { playlist = PlaylistStart(rowID: v.bvid, page: page) }
        }
      }
      if busy {
        PageLoading()
      } else if let error {
        PageFailure(message: error) { Task { await load() } }
      } else if rows.isEmpty {
        ContentUnavailableView("暂无视频", systemImage: "play.rectangle")
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain).environment(\.inListRows, true).reportsScrollCollapse()
    .navigationDestination(isPresented: $listen) {
      if let first = rows.first {
        CreatorDirectoryListen(video: first, scope: scope, hint: effectiveHint)
      }
    }
    .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
    .piliRefreshable { await load() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if page > 1 || (maxPage.map { $0 > 1 } ?? moreAvailable) {
        HStack(spacing: 4) {
          Button { page -= 1 } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 40)
          }.disabled(page <= 1).accessibilityLabel("上一页")
          Button {
            pageText = String(page)
            jump = true
          } label: {
            Text(maxPage.map { "\(page) / \($0)" } ?? "第 \(page) 页")
              .font(.subheadline.monospacedDigit()).frame(minWidth: 72)
          }
          Button { page += 1 } label: {
            Image(systemName: "chevron.right").frame(width: 44, height: 40)
          }.disabled(maxPage.map { page >= $0 } ?? !moreAvailable).accessibilityLabel("下一页")
        }
        .buttonStyle(.plain).padding(.horizontal, 6)
        .piliGlass(in: Capsule(), interactive: true)
        .padding(.bottom, 8)
        .disabled(busy)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .navigationTitle(title).task(id: key) { if loadedKey != key { await load() } }.onChange(of: order) { _, _ in page = 1 }
      .onChange(of: reverse) { _, _ in page = 1 }
      .task(id: scope) {
        let s = scope
        hint = nil
        hintKey = s.storageKey
        hasLocal = LibraryPlaylist.hasCreatorMark(s)
        guard !s.source.uploads || (!s.owners.history.isEmpty && s.owners.history == s.owners.main)
        else { return }
        let h = try? await CreatorArchiveCatalog.hint(s)
        if !Task.isCancelled, s == scope { hint = h }
      }
      .onChange(of: CreatorQueueOwners(accounts.state)) { _, _ in
        playlist = nil
        options = []
        tag = nil
        page = 1
      }
      .piliFullScreenCover(
        item: $playlist, onDismiss: { hasLocal = LibraryPlaylist.hasCreatorMark(scope) }
      ) { start in
        LibraryPlaylist(
          kind: .creator(scope, effectiveHint), uid: scope.owners.main, query: "", order: .mtime,
          viewed: 0,
          ascending: false, start: start, allowChanges: false)
      }
      .modifier(
        ArchiveSearch(
          active: userMode && searchable, text: $search,
          submit: {
            term = search
            page = 1
          })
      )
      .alert(
        "投稿分类", isPresented: Binding(get: { tagError != nil }, set: { if !$0 { tagError = nil } })
      ) {
        Button("重试") { Task { await loadTags() } }
        Button("关闭", role: .cancel) {}
      } message: {
        Text(tagError ?? "")
      }
      .alert("跳到页码", isPresented: $jump) {
        TextField("页码", text: $pageText).keyboardType(.numberPad)
        Button("前往") {
          if let n = Int(pageText), n > 0, pageText.count <= 8, maxPage.map({ n <= $0 }) ?? true {
            page = n
          } else {
            error = "页码不在范围内"
          }
        }
        Button("取消", role: .cancel) {}
      }
  }
  @MainActor private func loadTags() async {
    guard !loadingTags, source.uploads else { return }
    let s = scope
    loadingTags = true
    defer { loadingTags = false }
    do {
      let r = try await CreatorArchiveCatalog.page(s, 1)
      guard !Task.isCancelled, s == scope else { return }
      options = r.tags
      if let h = r.hint {
        webHint = h
        webKey = s.storageKey
      }
      if options.isEmpty { tagError = "暂时没有投稿分类" }
    } catch { if !Task.isCancelled, s == scope { self.tagError = error.localizedDescription } }
  }
  @MainActor private func load() async {
    let id = UUID()
    epoch = id
    busy = true
    error = nil
    let requestedKey = key
    if contentKey != requestedKey { loadedKey = nil; rows = []; total = nil; moreAvailable = false }
    contentKey = requestedKey
    defer { if epoch == id { busy = false } }
    let requested = scope
    do {
      if numberedByCursor {
        let c: CreatorPlaybackCursor
        if let browser, case .creator(let previous) = browser.scope, previous == requested {
          c = browser
        } else {
          c = CreatorPlaybackCursor(
            requested, type: 1, desc: true, sort: requested.sortField, reportable: false)
          browser = c
        }
        let r = try await c.browsing(page)
        guard !Task.isCancelled, epoch == id, requestedKey == key else { return }
        total = c.total
        moreAvailable = r.later
        rows = r.videos
        loadedKey = requestedKey
        return
      }
      let r = try await CreatorArchiveCatalog.page(requested, page)
      try Task.checkCancellation()
      guard epoch == id, requestedKey == key else { return }
      if userMode, tag == nil { options = r.tags }
      if let h = r.hint {
        webHint = h
        webKey = requested.storageKey
      }
      total = r.total
      moreAvailable = r.more
      rows = r.videos
      loadedKey = requestedKey
    } catch { if !Task.isCancelled && epoch == id { self.error = error.localizedDescription } }
  }
}
private struct ArchiveSearch: ViewModifier {
  let active: Bool
  @Binding var text: String
  let submit: () -> Void
  func body(content: Content) -> some View {
    if active {
      content.searchable(text: $text, prompt: "搜索投稿").onSubmit(of: .search, submit).onChange(
        of: text
      ) { _, s in if s.isEmpty { submit() } }
    } else {
      content
    }
  }
}

private struct CreatorDirectoryListen: View {
  let video: Video, scope: CreatorArchiveScope, hint: CreatorQueueHint?
  @EnvironmentObject private var accounts: AccountContext
  @State private var type: Int?
  @State private var issue: String?
  @State private var attempt = 0
  var body: some View {
    Group {
      if let n = scope.source.uploads ? 1 : (type ?? hint?.type) {
        ArchiveListenEntry(video: video, origin: .media(scope.source.business, kind: Int64(n)))
      } else if let issue {
        VStack(spacing: 12) {
          PageFailure(message: issue) { attempt += 1 }
          if let aid = ArchiveNumber.av(video.bvid) {
            NavigationLink("只收听当前视频") { ArchiveListenEntry(video: video, origin: .archive(aid)) }
          }
        }
      } else {
        PageLoading()
      }
    }.task(id: attempt) {
      guard !scope.source.uploads, hint?.type == nil else { return }
      issue = nil
      do {
        let fresh = try await CreatorArchiveCatalog.hint(scope)
        guard !Task.isCancelled, CreatorQueueOwners(accounts.state) == scope.owners else { return }
        if let t = fresh?.type { type = t } else { issue = "未找到这个列表的收听入口" }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
