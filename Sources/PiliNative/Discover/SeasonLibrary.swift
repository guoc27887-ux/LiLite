import SwiftUI

struct SeasonCalendar: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var type = 0
  private var owner: String { accounts.state.active ?? "" }
  var body: some View {
    VStack(spacing: 0) {
      PageList(empty: "暂无更新") { _ in
        let days: [SeasonSchedule.Day]
        if type == 0 {
          async let anime = try? BiliAPI.shared.seasonUpdates(1, owner: owner)
          async let domestic = try? BiliAPI.shared.seasonUpdates(4, owner: owner)
          let (a, b) = await (anime, domestic)
          try Task.checkCancellation()
          guard a != nil || b != nil else { throw ServiceError("未能载入更新日历") }
          days = SeasonSchedule.merge([a, b].compactMap { $0 })
        } else {
          days = try await BiliAPI.shared.seasonUpdates(type, owner: owner)
        }
        return Page(items: days, next: nil)
      } row: { d in
        Section(d.date + (d.is_today == 1 ? " · 今天" : "")) {
          if d.episodes?.isEmpty != false { Text("暂无更新").foregroundStyle(.secondary) }
          ForEach(d.episodes ?? []) { e in
            PlainRowLink {
              if let id=e.playableEpisodeID {
                EpisodeLink(id: id)
              } else {
                SeasonView(
                  season: .init(
                    season_id: e.season_id, title: e.title, cover: e.cover, index_show: e.pub_index)
                )
              }
            } label: {
              PosterRow(
                cover: httpsURL(e.cover), title: e.title,
                badge: e.follow == 1 ? "已追" : nil,
                lines: [e.pub_time.map { $0 + " 更新" } ?? ""],
                accent: e.delay == 1 ? e.delay_reason ?? "延期" : e.pub_index, width: 60)
            }.seasonCover(e.cover)
          }
        }
      }.id("\(type):\(owner)")
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      ChipBar(items: [0, 1, 4], selection: $type, title: { ["全部", "番剧", "", "", "国创"][$0] })
        .padding(.vertical, 6)
    }
    .navigationTitle("更新日历")
  }
}
struct FollowedSeasons: View {
  private let fixedType: Bool
  @EnvironmentObject private var accounts: AccountContext
  private var mine: Bool { accounts.state.active == uid }
  let uid: String
  struct ListResult: Decodable { let list: [Season]?, total: Int? }
  @State private var type: Int
  init(uid: String, initialType: Int = 1, fixedType: Bool = false) {
    self.fixedType = fixedType
    self.uid = uid
    _type = State(initialValue: initialType)
  }
  @State private var status = 2
  @State private var loaded = Set<Int64>()
  @State private var selected = Set<Int64>()
  @State private var selecting = false
  @State private var remove: Season?
  @State private var revision = 0
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    VStack(spacing: 0) {
      PageList(empty: "暂无作品") { cursor in
        let p = Int(cursor ?? "1") ?? 1
        var q = ["vmid": uid, "type": "\(type)", "pn": "\(p)", "ps": "15"]
        if status > 0 { q["follow_status"] = "\(status)" }
        let r = try await BiliAPI.shared.read(
          "/x/space/bangumi/follow/list", q, expectedAccount: accounts.state.active ?? "",
          as: ListResult.self)
        try Task.checkCancellation()
        if cursor == nil { loaded = [] }
        loaded.formUnion((r.list ?? []).map(\.id))
        return Page(items: r.list ?? [], next: p * 15 < (r.total ?? 0) ? "\(p+1)" : nil)
      } row: { s in
        if selecting && mine {
          Button {
            if !selected.insert(s.id).inserted { selected.remove(s.id) }
          } label: {
            HStack(spacing: 10) {
              Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(s.id) ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
              poster(s)
            }
          }.buttonStyle(.plain)
        } else {
          PlainRowLink {
            SeasonView(season: s)
          } label: {
            poster(s)
          }
          .contextMenu {
            if mine {
              Button("选择") {
                selected = [s.id]
                selecting = true
              }
              ForEach(destinations, id: \.self) { dest in
                Button("移到" + statusText(dest)) { Task { await move([s.id], to: dest) } }
              }
              Button("取消追番追剧", role: .destructive) { remove = s }
            }
          }.swipeActions { if mine { Button("取消追番追剧", role: .destructive) { remove = s } } }
        }
      }.id("\(uid):\(accounts.state.active ?? ""):\(type):\(status):\(revision)")
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      VStack(spacing: 2) {
        if !fixedType {
          ChipBar(items: [1, 2], selection: $type, title: { $0 == 1 ? "追番" : "追剧" })
        }
        ChipBar(items: [0, 1, 2, 3], selection: $status, title: { ["全部", "想看", "在看", "看过"][$0] })
      }.padding(.vertical, 6)
    }
    .navigationTitle(fixedType ? (type == 1 ? "追番" : "追剧") : "追番追剧").disabled(busy)
      .onChange(of: type) { _, _ in reset() }.onChange(of: status) { _, _ in reset() }
      .onChange(of: accounts.state.active) { _, _ in reset() }
      .toolbar {
        if mine {
          if selecting {
            Menu("已选 \(selected.count)") {
              Button("全选已加载作品") { selected = loaded }
              Button("取消全选") { selected = [] }
              ForEach(destinations, id: \.self) { dest in
                Button("移到" + statusText(dest)) { Task { await move(selected, to: dest) } }
                  .disabled(
                    selected.isEmpty)
              }
            }
          }
          Button(selecting ? "完成" : "选择") {
            selecting.toggle()
            selected = []
          }
        }
      }
      .confirmationDialog(
        "取消追番追剧？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
        presenting: remove
      ) { season in
        Button("取消追番追剧", role: .destructive) { Task { await move([season.id], to: 0) } }
      }
      .alert("追番追剧", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  private var destinations: [Int] { [1, 2, 3].filter { $0 != status } }
  private func poster(_ s: Season) -> some View {
    PosterRow(
      cover: httpsURL(s.cover), title: s.title, badge: s.badge,
      lines: [s.order, s.is_finish == 0 ? s.renewal_time : nil, s.index_show].compactMap { $0 },
      accent: s.progress)
  }
  private func statusText(_ n: Int) -> String { ["", "想看", "在看", "看过"][n] }
  private func reset() {
    selected = []
    loaded = []
    selecting = false
    revision += 1
  }
  private func move(_ ids: Set<Int64>, to target: Int) async {
    guard mine, !busy, !ids.isEmpty, ids.isSubset(of: loaded), (0...3).contains(target),
      target != 0 || ids.count == 1
    else { return }
    busy = true
    defer { busy = false }
    var fields = ["season_id": ids.sorted().map(String.init).joined(separator: ",")]
    if target > 0 { fields["status"] = String(target) }
    do {
      try await BiliAPI.shared.submit(
        target == 0 ? "/pgc/web/follow/del" : "/pgc/web/follow/status/update", fields,
        expectedAccount: uid)
      reset()
    } catch { issue = error.localizedDescription }
  }
}
struct SeasonFollow: View {
  let id: Int64
  struct Status: Decodable { let follow: Int?, follow_status: Int? }
  @EnvironmentObject var accounts: AccountContext
  @State private var status: Status?
  @State private var issue: String?
  @State private var busy = false
  var body: some View {
    if let owner = accounts.state.active {
      Section {
        if let s = status {
          if s.follow == 1 {
            Picker(
              "观看状态",
              selection: Binding(
                get: { s.follow_status ?? 2 }, set: { v in Task { await set(v, owner: owner) } })
            ) {
              Text("想看").tag(1)
              Text("在看").tag(2)
              Text("看过").tag(3)
            }
            Button("取消追番追剧", role: .destructive) { Task { await set(0, owner: owner) } }
          } else {
            Button("追番追剧") { Task { await set(-1, owner: owner) } }
          }
        } else if issue == nil {
          PageLoading()
        }
        if let issue {
          PageFailure(message: issue) { Task { await load(owner) } }
        }
      }.disabled(busy).task(id: "\(id):\(owner)") {
        status = nil
        issue = nil
        await load(owner)
      }
    }
  }
  private func load(_ owner: String) async {
    do {
      let next = try await BiliAPI.shared.read(
        "/pgc/view/web/season/user/status", ["season_id": "\(id)"], expectedAccount: owner,
        as: Status.self)
      guard !Task.isCancelled, accounts.state.active == owner else { return }
      status = next
      issue = nil
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
  private func set(_ target: Int, owner: String) async {
    guard !busy, accounts.state.active == owner else { return }
    busy = true
    defer { busy = false }
    var f = ["season_id": "\(id)"]
    if target > 0 { f["status"] = "\(target)" }
    do {
      try await BiliAPI.shared.submit(
        "/pgc/web/follow/" + (target < 0 ? "add" : target == 0 ? "del" : "status/update"), f,
        expectedAccount: owner)
      await load(owner)
    } catch {
      if !Task.isCancelled && accounts.state.active == owner { issue = error.localizedDescription }
    }
  }
}
