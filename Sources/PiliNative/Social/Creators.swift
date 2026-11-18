import SwiftUI

struct Creator: Decodable, Identifiable {
  let mid: Int64
  let uname: String?
  let face: String?
  let sign: String?
  var mtime: Int64? = nil
  var id: Int64 { mid }
}
struct FollowGroup: Decodable, Identifiable {
  let tagid: Int
  let name: String?
  let count: Int?
  var tip: String? = nil
  var id: Int { tagid }
}
extension BiliAPI {
  func connections(uid: String, fans: Bool, page: Int, term: String, order: Int = 0,expectedAccount:String?=nil) async throws
    -> Page<Creator>
  {
    struct List: Decodable {
      let list: [Creator]?
      let total: Int?
    }
    let search = !fans && !term.isEmpty
    var query = ["vmid": uid, "pn": String(page), "ps": "20", "order": "desc"]
    if search {
      query["name"] = term
    } else if !fans {
      query["order_type"] = order == 1 ? "attention" : ""
    }
    let r = try await read(
      search
        ? "/x/relation/followings/search" : fans ? "/x/relation/fans" : "/x/relation/followings",
      query,expectedAccount:expectedAccount,as: List.self)
    return Page(items: r.list ?? [], next: page * 20 < (r.total ?? 0) ? "\(page+1)" : nil)
  }
  func uploads(uid: Int64, page: Int, keyword: String) async throws -> Page<Video> {
    struct Result: Decodable {
      struct List: Decodable {
        struct Item: Decodable {
          let bvid: String, title: String, pic: String
          let author: String?
        }
        let vlist: [Item]?
      }
      struct Count: Decodable { let count: Int? }
      let list: List?
      let page: Count?
    }
    let r = try await read(
      "/x/space/wbi/arc/search",
      try await sign([
        "mid": "\(uid)", "pn": "\(page)", "ps": "25", "keyword": keyword, "order": "pubdate",
      ]), as: Result.self)
    return Page(
      items: (r.list?.vlist ?? []).map {
        .preview(id: $0.bvid, title: $0.title, cover: $0.pic, author: $0.author)
      }, next: page * 25 < (r.page?.count ?? 0) ? "\(page+1)" : nil)
  }
}
struct CreatorLinks: View {
  let uid: String
  /// Only the group and blacklist rows (the profile lists following and fans itself).
  var extrasOnly = false
  var body: some View {
    if !extrasOnly {
      NavigationLink { DeferredPage { RelationsList(uid: uid, fans: false) } } label: {
        SettingsRowLabel(title: "我的关注", symbol: "person.2.fill", color: .indigo)
      }
      NavigationLink { DeferredPage { RelationsList(uid: uid, fans: true) } } label: {
        SettingsRowLabel(title: "我的粉丝", symbol: "heart.fill", color: .pink)
      }
    }
    NavigationLink { DeferredPage { FollowGroupsView() } } label: {
      SettingsRowLabel(title: "关注分组", symbol: "folder.fill", color: .cyan)
    }
    NavigationLink { DeferredPage { BlacklistView(uid: uid) } } label: {
      SettingsRowLabel(title: "黑名单", symbol: "hand.raised.fill", color: .gray)
    }
  }
}
private struct FollowSortMenu: View {
  @Binding var order: Int
  var body: some View {
    Menu {
      Picker("关注排序", selection: $order) {
        Text("最近关注").tag(0)
        Text("最常访问").tag(1)
      }
    } label: {
      Label("关注排序", systemImage: "arrow.up.arrow.down")
    }
  }
}
struct RelationsList: View {
  let uid: String, fans: Bool
  @AppStorage("follow.sort") private var order = 0
  @EnvironmentObject private var accounts: AccountContext
  @State private var remoteName: String?
  @State private var removing: Creator?
  @State private var revision = 0
  @State private var busy = false
  @State private var issue: String?
  @State private var draft = ""
  @State private var query = ""
  private var creatorsList: some View {
    PageList(empty: fans ? "暂无粉丝" : "暂无关注") { p in
      try await BiliAPI.shared.connections(
        uid: uid, fans: fans, page: Int(p ?? "1") ?? 1, term: query, order: order, expectedAccount: accounts.state.active ?? "")
    } row: { person in
      HStack {
        CreatorLink(person: person)
        if !fans && uid == accounts.state.active { CreatorQuickRelation(mid: person.mid, knownFollowing: true) }
      }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if fans && uid == accounts.state.active {
          Button("移除粉丝", role: .destructive) { removing = person }.disabled(busy)
        }
      }.contextMenu {
        if fans && uid == accounts.state.active {
          Button("移除粉丝", role: .destructive) { removing = person }.disabled(busy)
        }
      }
    }
  }
  var body: some View {
    let list = creatorsList
    .id("\(query):\(revision):\(fans || !query.isEmpty ? 0 : order):\(accounts.state.active ?? "")")
    .navigationTitle((remoteName.map { $0 + "的" } ?? "") + (fans ? "粉丝" : "关注"))
    .task(id: uid + ":" + (accounts.state.active ?? "")) {
      let actor = accounts.state.active
      remoteName = nil
      guard actor != uid else { return }
      let name = try? await BiliAPI.shared.creatorCardName(uid, owner: actor)
      if !Task.isCancelled, accounts.state.active == actor { remoteName = name }
    }
    .toolbar {
      if !fans && query.isEmpty { FollowSortMenu(order: $order) }
      if !fans, uid == accounts.state.active {
        NavigationLink("分组") { DeferredPage { FollowGroupsView() } }
        NavigationLink("黑名单") { DeferredPage { BlacklistView(uid: uid) } }
      }
    }
    .confirmationDialog(
      "移除这位粉丝？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { p in
      Button("移除 " + (p.uname ?? String(p.mid)), role: .destructive) { Task { await remove(p) } }
    }.alert("未能移除", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
    .onChange(of: accounts.state.active) { _, _ in removing = nil }
    if fans {
      list
    } else {
      list.searchable(text: $draft, prompt: "搜索关注").onSubmit(of: .search) { query = draft }
        .onChange(of: draft) { _, s in if s.isEmpty { query = "" } }
    }
  }
  @MainActor private func remove(_ p: Creator) async {
    guard !busy, fans, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/modify", ["fid": String(p.mid), "act": "7", "re_src": "11"],
        expectedAccount: uid)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
struct CreatorLink: View {
  let person: Creator
  var body: some View {
    PlainRowLink {
      CreatorSpace(mid: person.mid, name: person.uname ?? "用户空间")
    } label: {
      HStack(spacing: 12) {
        SiteThumbnail(url: httpsURL(person.face ?? "")) {
          $0.resizable().scaledToFill()
        } placeholder: {
          Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
        }.frame(width: 44, height: 44).clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(person.uname ?? "\(person.mid)").font(.body.weight(.medium)).lineLimit(1)
          if let s = person.sign, !s.isEmpty {
            Text(s).piliFont(.caption).lineLimit(1).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 2).contentShape(Rectangle())
    }.piliTapFeedback()
  }
}
private struct FollowGroupsView: View {
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active { ScopedFollowGroups(owner: uid).id(uid) }
    else { ContentUnavailableView("请先登录", systemImage: "person.crop.circle") }
  }
}
private struct ScopedFollowGroups: View {
  let owner: String
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("follow.sort") private var order = 0
  @State private var revision = 0
  @State private var removing: FollowGroup?
  @State private var editing: FollowGroup?
  @State private var naming = false
  @State private var busy = false
  @State private var name = ""
  @State private var issue: String?
  var body: some View {
    PageList(empty: "没有分组") { _ in
      Page(items: try await BiliAPI.shared.read("/x/relation/tags", [:], expectedAccount: owner, as: [FollowGroup].self), next: nil)
    } row: { g in
      PlainRowLink { members(g) } label: {
        VStack(alignment: .leading) {
          Text((g.name ?? "分组") + "（" + String(g.count ?? 0) + "）")
          if let tip = g.tip, !tip.isEmpty { Text(tip).font(.caption).foregroundStyle(.secondary) }
        }
      }.swipeActions(allowsFullSwipe: false) { groupActions(g) }.contextMenu { groupActions(g) }
    }.id(revision).navigationTitle("关注分组").disabled(busy)
      .toolbar {
        NavigationLink("排序") { CloudOrder(uid: nil, expectedGroupOwner: owner) { revision += 1 } }
        Button("新建分组", systemImage: "plus") { editing = nil; name = ""; naming = true }
      }
      .confirmationDialog("删除这个关注分组？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { g in
        Button("删除", role: .destructive) { Task { await perform(.remove(g.id)) } }
      } message: { _ in Text("分组中的用户仍会保留在关注列表") }
      .alert(editing == nil ? "新建分组" : "修改分组", isPresented: $naming) {
        TextField("名称", text: $name).onChange(of: name) { _, value in if value.count > 16 { name = String(value.prefix(16)) } }
        Button("取消", role: .cancel) {}
        Button("保存") {
          let edit = editing.map { FollowGroupCommand.Edit.rename($0.id, name) } ?? .add(name)
          Task { await perform(edit) }
        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .alert("分组", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("好") {} } message: { Text(issue ?? "") }
  }
  @ViewBuilder private func groupActions(_ g: FollowGroup) -> some View {
    if FollowGroupCommand.custom(g.id) {
      Button("删除", role: .destructive) { removing = g }
      Button("改名") { editing = g; name = g.name ?? ""; naming = true }
    }
  }
  private func members(_ group: FollowGroup) -> some View {
    PageList(empty: "分组中没有关注", autoMore: true) { cursor in
      let n = Int(cursor ?? "1") ?? 1
      let rows = try await BiliAPI.shared.read("/x/relation/tag",
        ["mid": owner, "tagid": String(group.id), "pn": String(n), "ps": "20", "order_type": order == 1 ? "attention" : ""],
        expectedAccount: owner, as: [Creator].self)
      return Page(items: rows, next: !rows.isEmpty && (group.count.map { n * 20 < $0 } ?? (rows.count == 20)) ? String(n + 1) : nil)
    } row: { person in HStack {
      CreatorLink(person: person)
      CreatorQuickRelation(mid: person.mid, knownFollowing: true)
    } }.id(order).navigationTitle(group.name ?? "分组").toolbar { FollowSortMenu(order: $order) }
  }
  @MainActor private func perform(_ action: FollowGroupCommand.Edit) async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    do {
      let cmd = try FollowGroupCommand(action, owner: owner)
      try await cmd.apply(active: accounts.state.active) { path, fields, account in
        try await BiliAPI.shared.submit(path, fields, expectedAccount: account)
      }
      guard accounts.state.active == owner else { return }
      name = ""; revision += 1
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}
