import SwiftUI

struct LibraryHistoryItem: Identifiable {
  let record: MineHistoryPage.Row, display: ProfileShelfItem
  var id: String { display.id }
}
extension BiliAPI {
  func fullHistory(_ uid: String, category: String, term: String, cursor: String?) async throws -> (
    Page<LibraryHistoryItem>, [MineHistoryPage.Tab]?
  ) {
    let p = max(1, Int(cursor ?? "") ?? 1)
    let reply: MineHistoryPage
    if term.isEmpty {
      let position = cursor?.split(separator: ":").map(String.init) ?? []
      reply = try await read(
        "/x/web-interface/history/cursor",
        [
          "type": category, "ps": "20",
          "max": position.first ?? "0", "view_at": position.last ?? "0",
        ], expectedAccount: uid, as: MineHistoryPage.self)
    } else {
      reply = try await read(
        "/x/web-interface/history/search", ["business": "all", "pn": String(p), "keyword": term],
        expectedAccount: uid, as: MineHistoryPage.self)
    }
    let rows = reply.list ?? []
    let items = rows.compactMap { row in
      row.entry.map { LibraryHistoryItem(record: row, display: $0) }
    }
    let next: String?
    if rows.isEmpty {
      next = nil
    } else if !term.isEmpty {
      next = String(p + 1)
    } else if let last = rows.last, let oid = last.history?.oid, let stamp = last.view_at, stamp > 0
    {
      next = "\(oid):\(stamp)"
    } else if let point = reply.cursor, let oid = point.max, let stamp = point.view_at, stamp > 0 {
      next = "\(oid):\(stamp)"
    } else {
      next = nil
    }
    return (.init(items: items, next: next == cursor ? nil : next), reply.tab)
  }
}

struct ProfileFullHistory: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var category = "all"
  @State private var tabs: [MineHistoryPage.Tab] = []
  @State private var search = ""
  @State private var term = ""
  @State private var revision = 0
  @State private var loaded: [String: LibraryHistoryItem] = [:]
  @State private var selecting = false
  @State private var selected = Set<String>()
  @State private var deletion: [String]?
  @State private var busy = false
  @State private var issue: String?
  @State private var confirmClear = false
  @State private var confirmPause: Bool?
  @State private var paused: Bool?
  @State private var visit: Int64?
  var body: some View {
    PageList(empty: "暂无观看记录") {
      cursor in
      let scope = identity
      let (page, choices) = try await BiliAPI.shared.fullHistory(
        uid, category: category, term: term, cursor: cursor)
      try Task.checkCancellation()
      guard scope == identity else { throw CancellationError() }
      if cursor == nil {
        loaded = [:]
        if term.isEmpty, category == "all", let choices {
          var seen: Set<String> = ["all"]
          tabs = choices.filter {
            !$0.name.isEmpty && !$0.type.isEmpty && seen.insert($0.type).inserted
          }
        }
      }
      for item in page.items { if let key = item.record.deleteKey { loaded[key] = item } }
      selected.formIntersection(Set(loaded.keys))
      return page
    } row: { item in
      row(item)
    }
    .id(identity).navigationTitle("观看历史")
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      if term.isEmpty && !tabs.isEmpty { categories.padding(.vertical, 6) }
    }
    .navigationDestination(item: $visit) { mid in
      CreatorSpace(mid: mid, name: loaded.values.first { $0.record.author_mid == mid }?.record.author_name ?? "用户空间")
    }
    .searchable(text: $search, prompt: "搜索全部观看记录").onSubmit(of: .search) { setTerm(search) }
    .onChange(of: search) { _, text in if text.isEmpty { setTerm("") } }
    .task(id: uid) { await readPause() }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if selecting {
          Menu("已选 \(selected.count)") {
            Button("全选已加载记录") { selected = Set(loaded.keys) }
            Button("取消全选") { selected = [] }
            Button("删除所选记录", role: .destructive) { deletion = selected.sorted() }.disabled(
              selected.isEmpty)
          }
          Button("完成") {
            selecting = false
            selected = []
          }
        } else {
          Menu {
            Button("选择记录") { selecting = true }
            Button("删除已看完的记录", role: .destructive) {
              let finished = loaded.compactMap { key, item in item.record.progress == -1 ? key : nil
              }
              if finished.isEmpty { issue = "当前列表没有已看完的记录" } else { deletion = finished.sorted() }
            }
            if let paused {
              Button(paused ? "恢复观看记录" : "暂停观看记录") { confirmPause = !paused }
            } else {
              Button("读取历史记录状态") { Task { await readPause() } }
            }
            Button("清空全部历史", role: .destructive) { confirmClear = true }
            NavigationLink("观看历史设置") { HistorySettings(uid: uid) }
          } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("观看记录选项")
          }
        }
      }
    }.disabled(busy)
    .confirmationDialog(
      "删除所选的 \(deletion?.count ?? 0) 条观看记录？",
      isPresented: Binding(
        get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion
    ) { keys in
      Button("删除", role: .destructive) { Task { await remove(keys) } }
    }
    .confirmationDialog("清空此账号的全部观看记录？", isPresented: $confirmClear) {
      Button("清空全部", role: .destructive) {
        Task {
          await mutate {
            try await BiliAPI.shared.submit(
              "/x/v2/history/clear", ["jsonp": "jsonp"], expectedAccount: uid)
            reset()
          }
        }
      }
    }
    .confirmationDialog(
      confirmPause == true ? "暂停记录观看历史？" : "恢复记录观看历史？",
      isPresented: Binding(
        get: { confirmPause != nil }, set: { if !$0 { confirmPause = nil } }),
      presenting: confirmPause
    ) { next in
      Button(next ? "暂停" : "恢复") {
        Task {
          await mutate {
            try await BiliAPI.shared.submit(
              "/x/v2/history/shadow/set", ["switch": next ? "true" : "false", "jsonp": "jsonp"],
              expectedAccount: uid)
            paused = next
          }
        }
      }
    }
    .alert("观看历史", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  private var identity: String { uid + ":" + category + ":" + term + ":" + String(revision) }
  private var categories: some View {
    ChipBar(
      items: ["all"] + tabs.map(\.type),
      selection: Binding(get: { category }, set: { next in
        guard next != category else { return }
        category = next
        reset()
      }),
      title: { type in type == "all" ? "全部" : tabs.first { $0.type == type }?.name ?? type })
  }
  private func setTerm(_ text: String) {
    let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if term != next {
      term = next
      reset()
    }
  }
  private func reset() {
    selected = []
    selecting = false
    loaded = [:]
    revision += 1
  }
  private func readPause() async {
    do {
      let value = try await BiliAPI.shared.read(
        "/x/v2/history/shadow", ["jsonp": "jsonp"], expectedAccount: uid, as: Bool.self)
      try Task.checkCancellation()
      paused = value
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @ViewBuilder private func row(_ item: LibraryHistoryItem) -> some View {
    let rec = item.record
    if selecting {
      Button {
        if let key = rec.deleteKey { if !selected.insert(key).inserted { selected.remove(key) } }
      } label: {
        HStack {
          Image(
            systemName: rec.deleteKey.map(selected.contains) == true
              ? "checkmark.circle.fill" : "circle")
            .font(.title3).foregroundStyle(rec.deleteKey.map(selected.contains) == true ? Color.accentColor : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
          historyLabel(item)
        }
      }.disabled(rec.deleteKey == nil)
    } else {
      Group {
        if case .link(let link) = item.display.target {
          PlainRowLink { LinkDestination(item: link) } label: { historyLabel(item) }
        } else if case .courseHistory(let id, let ep, let aid, let seconds) = item.display.target {
          PlainRowLink {
            HistoryCourseLink(id: id, byEpisode: ep, aid: aid, seconds: seconds)
          } label: { historyLabel(item) }
        } else {
          historyLabel(item).foregroundStyle(.secondary)
        }
      }
      .contextMenu {
        if let mid = rec.author_mid, mid > 0 {
          Button("访问 " + (rec.author_name ?? "UP 主"), systemImage: "person.crop.circle") { visit = mid }
        }
        if let bvid = rec.laterBVID, let main = accounts.state.active {
          Button("加入稍后再看", systemImage: "clock") {
            Task {
              await mutate {
                try await BiliAPI.shared.submit(
                  "/x/v2/history/toview/add", ["bvid": bvid], expectedAccount: main)
                AppToast.show("已加入稍后再看")
              }
            }
          }
        }
        if let key = rec.deleteKey {
          Button("多选", systemImage: "checkmark.circle") {
            selected = [key]
            selecting = true
          }
          Button("删除记录", systemImage: "trash", role: .destructive) { deletion = [key] }
        }
      }
      .swipeActions {
        if let key = rec.deleteKey {
          Button("删除", systemImage: "trash", role: .destructive) { deletion = [key] }
        }
      }
    }
  }
  private func historyLabel(_ item: LibraryHistoryItem) -> some View {
    let record = item.record
    let row = item.display
    let progress =
      record.progress == -1
      ? "已看完"
      : record.duration.flatMap { duration in
        duration > 0
          ? clockText(Double(max(0, record.progress ?? 0))) + " / " + clockText(Double(duration)) : nil
      } ?? ""
    let date = MediaStats.published(record.view_at)
    return MediaRow(
      cover: row.cover, title: row.title,
      badge: record.is_fav == 1 ? "已收藏" : record.badge,
      duration: record.duration.flatMap { $0 > 0 ? clockText(Double($0)) : nil },
      progress: record.progress == -1 ? 1 : row.progress,
      subtitle: row.caption,
      detail: [progress, date ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
  }
  private func remove(_ keys: [String]) async {
    let safe = keys.filter { loaded[$0]?.record.deleteKey == $0 }
    guard !safe.isEmpty else { return }
    await mutate {
      try await BiliAPI.shared.submit(
        "/x/v2/history/delete", ["kid": safe.joined(separator: ","), "jsonp": "jsonp"],
        expectedAccount: uid)
      reset()
    }
  }
  private func mutate(_ action: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do { try await action() } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
