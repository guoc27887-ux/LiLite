import SwiftUI

struct CreatorRelation: Decodable {
  let attribute: Int?, tag: [Int]?, special: Int?, mtime: Int64?
  var followed: Bool { attribute == 2 || attribute == 6 || attribute == 1 }
}
struct SharedFollowing: View {
  let mid: Int64, uid: String
  let alsoFollowsCreator: Bool
  @EnvironmentObject private var accounts: AccountContext
  @State private var remoteName: String?
  @State private var total: Int?
  private func fetchSharedPage(cursor: String?) async throws -> Page<Creator> {
    let fields = (cursor ?? "1:0").split(separator: ":")
    let page = Int(fields.first ?? "1") ?? 1
    let offset = Int(fields.last ?? "0") ?? 0
    struct Result: Decodable { let list: [Creator]?, total: Int? }
    guard let account = try await AccountJar.shared.current(), account.id == uid,
      let csrf = account.csrf
    else { throw ServiceError("请重新登录") }
    let r = try await BiliAPI.shared.read(
      alsoFollowsCreator
        ? "/x/relation/followings/followed_upper" : "/x/relation/same/followings",
      ["vmid": String(mid), "pn": String(page), "csrf": csrf, "web_location": "333.789"],
      expectedAccount: uid, as: Result.self)
    try Task.checkCancellation()
    total = r.total
    let rows = r.list ?? []
    let seen = offset + rows.count
    return Page(
      items: rows, next: !rows.isEmpty && seen < (r.total ?? 0) ? "\(page+1):\(seen)" : nil)
  }
  private var sharedList: some View {
    PageList(empty: "暂无用户", fetch: fetchSharedPage) { person in
      CreatorLink(person: person)
    }
  }
  var body: some View {
    VStack(alignment: .leading) {
      if let total {
        Text("共 \(total) 人").piliFont(.caption).foregroundStyle(.secondary).padding(.horizontal)
      }
      sharedList
    }.navigationTitle(alsoFollowsCreator ? "我关注的" + (total.map(String.init) ?? "") + "人也关注了" + (remoteName ?? "TA") : (remoteName.map { "我与" + $0 + "的" } ?? "") + "共同关注")
    .task(id: "\(mid):\(accounts.state.active ?? "")") {
      remoteName = nil
      guard accounts.state.active == uid else { return }
      let name = try? await BiliAPI.shared.creatorCardName(String(mid), owner: uid)
      if !Task.isCancelled, accounts.state.active == uid { remoteName = name }
    }
  }
}
struct CreatorGroupEditor: View {
  let mid: Int64, uid: String
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var naming = false
  @State private var name = ""
  @State private var groups: [FollowGroup] = []
  @State private var original = Set<Int>()
  @State private var selected = Set<Int>()
  @State private var loaded = false
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    Form {
      if let issue {
        Section {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          if !loaded { Button("重试") { Task { await load() } } }
        }
      }
      if loaded {
        Section {
          Button { selected = [] } label: {
            groupRow("默认分组", tip: nil, count: nil, on: selected.isEmpty)
          }
          ForEach(groups) { g in
            Button {
              if !selected.insert(g.tagid).inserted { selected.remove(g.tagid) }
            } label: {
              groupRow(g.name ?? "分组", tip: g.tip,
                count: g.count.map { max(0, $0 + (selected.contains(g.id) ? 1 : 0) - (original.contains(g.id) ? 1 : 0)) },
                on: selected.contains(g.id))
            }
          }
          Button { name = ""; naming = true } label: {
            Label("新建分组", systemImage: "plus.circle.fill")
          }
          .disabled(busy)
        } footer: {
          Text("可同时加入多个分组，不选择则放入默认分组")
        }
      }
    }
    .overlay { if !loaded && issue == nil { ProgressView() } }
    .navigationTitle("设置关注分组").navigationBarTitleDisplayMode(.inline).disabled(busy)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") { Task { await save() } }.piliButtonStyle(.glassProminent).disabled(!loaded || busy)
        }
      }
      .alert("新建分组", isPresented: $naming) {
        TextField("分组名称", text: $name)
        Button("取消", role: .cancel) {}
        Button("创建") { Task { await add() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 16)
      }
      .task(id: uid) { await load() }
  }
  private func groupRow(_ title: String, tip: String?, count: Int?, on: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: on ? "checkmark.square.fill" : "square")
        .font(.title3).foregroundStyle(on ? Color.accentColor : Color.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(.primary)
        if let tip, !tip.isEmpty { Text(tip).piliFont(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      if let count { Text(String(count)).monospacedDigit().foregroundStyle(.secondary) }
    }
    .contentShape(Rectangle())
    .accessibilityAddTraits(on ? .isSelected : [])
  }
  @MainActor private func load() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let api = BiliAPI.shared
      async let list = api.read(
        "/x/relation/tags", [:], expectedAccount: uid, as: [FollowGroup].self)
      async let current = api.read(
        "/x/relation", ["fid": String(mid)], expectedAccount: uid, as: CreatorRelation.self)
      let (rows, rel) = try await (list, current)
      try Task.checkCancellation()
      guard rel.followed else { throw ServiceError("请先关注这位用户") }
      groups = rows.filter { $0.tagid != 0 }
      original = Set((rel.tag ?? []).filter { $0 != 0 })
      selected = original
      loaded = true
      issue = nil
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @MainActor private func add() async {
    guard !busy, loaded, accounts.state.active == uid else { return }
    busy = true; defer { busy = false }
    do {
      let cmd = try FollowGroupCommand(.add(name), owner: uid)
      try cmd.check(active: accounts.state.active)
      struct Reply: Decodable { struct Item: Decodable { let tagid: Int }; let data: Item }
      let bytes = try await BiliAPI.shared.submitResponse(cmd.path, cmd.fields, expectedAccount: uid)
      let tag = try JSONDecoder().decode(Reply.self, from: bytes).data.tagid
      try cmd.check(active: accounts.state.active)
      guard tag > 0, FollowGroupCommand.custom(tag) else { throw ServiceError("分组编号无效") }
      if !groups.contains(where: { $0.id == tag }) {
        groups.append(.init(tagid: tag, name: cmd.fields["tag"], count: 0))
      }
      selected.insert(tag); issue = nil
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
  @MainActor private func save() async {
    guard !busy, loaded else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/tags/addUsers",
        [
          "fids": String(mid),
          "tagids": selected.isEmpty
            ? "0" : selected.sorted().map(String.init).joined(separator: ","),
        ], expectedAccount: uid)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
