import SwiftUI

struct SavedReadings: View {
  enum Shelf: String, CaseIterable {
    case articles = "图文"
    case topics = "话题"
    case drafts = "未发布笔记"
    case published = "公开笔记"
  }
  struct Entry: Identifiable {
    let id: String, title: String, detail: String, cover: URL?, link: URL?
    var archive: Int64? = nil
  }
  let uid: String
  private let hub: FavoriteHub.Tab?
  @State private var shelf: Shelf
  init(uid: String, initialShelf: Shelf = .articles, hub: FavoriteHub.Tab? = nil) {
    self.hub = hub
    self.uid = uid
    _shelf = State(initialValue: initialShelf)
  }
  @State private var version = 0
  @State private var selecting = false
  @State private var selected = Set<String>()
  @State private var toRemove = Set<String>()
  @State private var loaded = Set<String>()
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    VStack(spacing: 0) {
      PageList(empty: "暂无内容") { c in
        let reply = try await load(page: Int(c ?? "1") ?? 1)
        try Task.checkCancellation()
        if c == nil { loaded = [] }
        loaded.formUnion(reply.items.map(\.id))
        return reply
      } row: { e in
        if selecting {
          Button {
            if !selected.insert(e.id).inserted { selected.remove(e.id) }
          } label: {
            HStack(spacing: 10) {
              Image(systemName: selected.contains(e.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(e.id) ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
              label(e)
            }
          }.buttonStyle(.plain)
        } else {
          PlainRowLink {
            destination(e)
          } label: {
            label(e)
          }.swipeActions {
            Button(shelf == .drafts || shelf == .published ? "删除" : "取消收藏", role: .destructive) {
              toRemove = [e.id]
            }
          }
        }
      }.id("\(shelf):\(version)")
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      if hub == nil || hub == .note {
        ChipBar(
          items: hub == .note ? [.drafts, .published] : Shelf.allCases, selection: $shelf,
          title: \.rawValue
        ).padding(.vertical, 6).disabled(selecting)
      }
    }
    .navigationTitle("图文、话题和笔记")
      .onChange(of: shelf) { _, _ in
        selecting = false
        selected = []
        toRemove = []
        loaded = []
      }
      .modifier(SelectionCancelBack(active: selecting) { selected = []; selecting = false })
      .toolbar {
        if selecting {
          Button(selected.isSuperset(of: loaded) ? "取消全选" : "全选") {
            selected = selected.isSuperset(of: loaded) ? [] : loaded
          }
          Button("删除（\(selected.count)）", role: .destructive) { toRemove = selected }.disabled(
            selected.isEmpty)
        }
        if shelf == .drafts && !selecting {
          NavigationLink { NotebookLocalShelf(owner: uid) } label: {
            Image(systemName: "internaldrive").accessibilityLabel("本机草稿")
          }
        }
        if shelf == .drafts || shelf == .published {
          Button(selecting ? "完成" : "管理") {
            selecting.toggle()
            selected = []
          }
        }
      }.disabled(busy)
      .confirmationDialog(
        shelf == .drafts || shelf == .published ? "删除所选笔记？" : "取消收藏？",
        isPresented: Binding(get: { !toRemove.isEmpty }, set: { if !$0 { toRemove = [] } }),
        presenting: Array(toRemove)
      ) { ids in
        Button("确认", role: .destructive) { Task { await remove(ids) } }
      }.alert("收藏", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  /// Original-client article item: title and meta on the left, the cover on the right; topics
  /// lead with a "#" badge.
  @ViewBuilder private func label(_ e: Entry) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if shelf == .topics {
        Image(systemName: "number").font(.headline).foregroundStyle(.tint)
          .frame(width: 40, height: 40)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(e.title).font(.subheadline.weight(.medium)).lineLimit(shelf == .topics ? 1 : 3)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        if !e.detail.isEmpty {
          Text(e.detail).lineLimit(2).font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, minHeight: e.cover == nil ? nil : 72, alignment: .topLeading)
      if let cover = e.cover {
        Rectangle().fill(.quaternary).frame(width: 112, height: 72)
          .overlay {
            SiteThumbnail(url: cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
          }
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
      }
    }
    .padding(.vertical, 4).contentShape(Rectangle())
  }
  @ViewBuilder private func destination(_ e: Entry) -> some View {
    switch shelf {
    case .topics: if let id = Int64(e.id) { TopicFeed(topic: .init(id: id, name: e.title)) }
    case .articles: ArticleReader(opus: e.id)
    case .published: if let id = Int64(e.id) { ArticleReader(note: id) }
    case .drafts:
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(e.title).piliFont(.headline)
          Text(e.detail).textSelection(.enabled)
          if let oid = e.archive, let note = Int64(e.id) {
            NavigationLink("编辑笔记") {
              NativeNotebook(oid: oid, owner: uid, suppliedTitle: e.title, requested: note)
            }
          }
          if let u = e.link { NavigationLink("打开原笔记") { SitePage(url: u) } }
        }.padding()
      }.navigationTitle("笔记")
    }
  }
  private func load(page: Int) async throws -> Page<Entry> {
    let api = BiliAPI.shared
    guard let user = try await AccountJar.shared.current(), user.id == uid else {
      throw ServiceError("账号已切换")
    }
    let data: [String: Any]
    let items: [Entry]
    let next: Bool
    func identifier(_ v: Any?) -> String? {
      if let s = v as? String, let n = Int64(s), n > 0 { return s }
      if let n = v as? NSNumber, n.int64Value > 0 { return n.stringValue }
      return nil
    }
    switch shelf {
    case .articles:
      data = try await api.dynamicData(
        "/x/polymer/web-dynamic/v1/opus/feed/fav", ["page": String(page), "page_size": "20"],
        expectedAccount: uid)
      items = (data["items"] as? [[String: Any]] ?? []).compactMap { i in
        guard let id = identifier(i["opus_id"]) else { return nil }
        return Entry(
          id: id, title: i["content"] as? String ?? "图文",
          detail: [
            (i["author"] as? [String: Any])?["name"] as? String,
            ((i["stat"] as? [String: Any])?["like"] as? NSNumber).map { "\($0) 赞" },
            i["pub_time"] as? String,
          ].compactMap { $0 }.joined(separator: " · "),
          cover: ((i["cover"] as? [String: Any])?["url"] as? String).flatMap(httpsURL), link: nil)
      }
      next = data["has_more"] as? Bool ?? false
    case .topics:
      data = try await api.dynamicData(
        "/x/topic/web/fav/list",
        ["page_size": "24", "page_num": String(page), "web_location": "333.1387"],
        expectedAccount: uid)
      let bag = data["topic_list"] as? [String: Any]
      let raw = bag?["topic_items"] as? [[String: Any]] ?? []
      items = raw.compactMap { i in
        guard let id = identifier(i["id"]), let name = i["name"] as? String else { return nil }
        let counts = [
          (i["view"] as? NSNumber).map {
            "\($0.int64Value.formatted(.number.notation(.compactName))) 浏览"
          },
          (i["discuss"] as? NSNumber).map {
            "\($0.int64Value.formatted(.number.notation(.compactName))) 讨论"
          },
        ]
        return Entry(
          id: id, title: name, detail: counts.compactMap { $0 }.joined(separator: " · "),
          cover: nil, link: nil)
      }
      next =
        ((bag?["page_info"] as? [String: Any])?["total"] as? Int).map { page * 24 < $0 }
        ?? (raw.count == 24)
    case .drafts, .published:
      let pub = shelf == .published
      var q = ["pn": String(page), "ps": "10"]
      q["csrf"] = user.csrf
      data = try await api.dynamicData(
        pub ? "/x/note/publish/list/user" : "/x/note/list", q, expectedAccount: uid)
      let raw = data["list"] as? [[String: Any]] ?? []
      items = raw.compactMap { i in
        guard let id = identifier(i[pub ? "cvid" : "note_id"]) else { return nil }
        return Entry(
          id: id, title: i["title"] as? String ?? "笔记",
          detail: [i["summary"] as? String, i["message"] as? String].compactMap { $0 }.joined(
            separator: "\n"),
          cover: ((i["arc"] as? [String: Any])?["pic"] as? String).flatMap(httpsURL),
          link: (i["web_url"] as? String).flatMap(httpsURL), archive: NotebookArchiveLink.archive(i)
        )
      }
      next = raw.count == 10
    }
    guard try await AccountJar.shared.current()?.id == uid else { throw ServiceError("账号已切换") }
    return Page(items: items, next: next ? String(page + 1) : nil)
  }
  @MainActor private func remove(_ ids: [String]) async {
    guard !busy, !ids.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      switch shelf {
      case .topics:
        try await api.submit("/x/topic/fav/sub/cancel", ["topic_id": ids[0]], expectedAccount: uid)
      case .articles:
        _ = try await api.dynPost(
          "/x/community/cosmo/interface/simple_action",
          ["entity": ["object_id_str": ids[0], "type": ["biz": 2]], "action": 4],
          expectedAccount: uid)
      case .published, .drafts:
        let pub = shelf == .published
        try await api.submit(
          pub ? "/x/note/publish/del" : "/x/note/del",
          [pub ? "cvids" : "note_ids": ids.joined(separator: ",")], expectedAccount: uid)
      }
      selected = []
      toRemove = []
      selecting = false
      version += 1
    } catch { issue = error.localizedDescription }
  }
}
struct ArchiveNotes: View {
  let aid: Int64
  var interactive = false
  var model: PlayerModel? = nil, cid: Int64? = nil, videoTitle: String? = nil
  @State private var count: Int?
  @EnvironmentObject private var accounts: AccountContext
  @State private var editing = false
  @State private var revision = 0
  struct Result: Decodable {
    struct Metadata: Decodable { let total: Int? }
    struct Row: Decodable, Identifiable {
      struct Author: Decodable {
        let name: String?, mid: Int64?, face: String?, level: Int?, is_senior_member: Int?
      }
      let cvid: Int64, summary: String?, pubtime: String?, author: Author?
      var id: Int64 { cvid }
    }
    let page: Metadata?, list: [Row]?
  }
  var body: some View {
    PageList(empty: "暂无公开笔记") { cursor in
      let page = Int(cursor ?? "1") ?? 1
      var q = ["oid": String(aid), "oid_type": "0", "pn": String(page), "ps": "10"]
      let uid = accounts.state.active
      let identity = try await AccountJar.shared.current()
      guard identity?.id == uid else { throw ServiceError("账号已切换") }
      q["csrf"] = identity?.csrf
      let r = try await BiliAPI.shared.read(
        "/x/note/publish/list/archive", q, expectedAccount: uid ?? "", as: Result.self)
      try Task.checkCancellation()
      guard accounts.state.active == uid else { throw ServiceError("账号已切换") }
      count = r.page?.total
      let entries = r.list ?? []
      return Page(
        items: entries,
        next: (r.page?.total.map { page * 10 < $0 } ?? (entries.count == 10))
          ? String(page + 1) : nil)
    } row: { row in
      VStack(alignment: .leading, spacing: 6) {
        if let a = row.author, let mid = a.mid, mid > 0 {
          PlainRowLink {
            CreatorSpace(mid: mid, name: a.name ?? "用户空间")
          } label: {
            HStack {
              if let u = a.face.flatMap(GalleryPicture.source) {
                SiteThumbnail(url: u) {
                  $0.resizable().scaledToFill()
                } placeholder: {
                  Color.clear
                }.frame(width: 30, height: 30).clipShape(Circle())
              }
              Text(a.name ?? "用户空间")
              if let level = a.level { UserLevelBadge(level: level, height: 10, hardcore: a.is_senior_member == 1) }
              if a.is_senior_member == 1 { Text("硬核会员").font(.caption2) }
            }
          }.buttonStyle(.borderless)
        }
        PlainRowLink {
          ArticleReader(note: row.cvid)
        } label: {
          VStack(alignment: .leading) {
            Text(row.summary ?? "查看笔记")
            if let time = row.pubtime { Text(time).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
    }.id(revision).modifier(ReplyEdgeDismiss()).navigationTitle(count.map { "视频笔记（\($0)）" } ?? "视频笔记").toolbar {
      if accounts.state.active != nil { Button("记笔记") { editing = true } }
    }.piliSheet(isPresented: $editing, onDismiss: { revision += 1 }) {
      PiliNavigationStack {
        if let owner = accounts.state.active {
          NativeNotebook(
            oid: aid, owner: owner, suppliedTitle: videoTitle, interactive: interactive,
            model: model, cid: cid
          )
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { editing = false } }
          }
        }
      }
    }.onChange(of: accounts.state.active) { _, _ in
      editing = false
      revision += 1
    }
  }
}
