import SwiftUI

struct CreatorFavorites: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  private struct Row: Decodable, Identifiable {
    let id: Int64, title: String?, cover: String?, media_count: Int?, type: Int?, state: Int?
    var key: String { "\(type ?? 0):\(id)" }
  }
  private struct Payload: Decodable { let count: Int?, list: [Row]?, has_more: Bool? }
  private struct GroupData: Decodable { let name: String?, mediaListResponse: Payload? }
  @State private var revision = 0
  @State private var names: [String] = ["创建的收藏夹", "收藏和订阅"]
  @State private var values: [[Row]] = [[], []]
  @State private var counts = [0, 0]
  @State private var next = [0, 0]
  @State private var expanded = [true, true]
  @State private var loading = [false, false]
  @State private var groupErrors: [String?] = [nil, nil]
  @State private var issue: String?
  @State private var ready = false
  @State private var refreshing = false
  @State private var stamp = UUID()
  private struct Scope: Equatable { let mid: Int64, owner: String }
  @State private var contentScope: Scope?
  var body: some View {
    List {
      if ready {
        if let issue {
          HStack { Text(issue).font(.caption); Button("重试") { revision += 1 } }
        }
        ForEach(0..<2, id: \.self) { i in
          Section {
            if expanded[i] {
              if values[i].isEmpty { Text("暂无内容").font(.subheadline).foregroundStyle(.secondary) }
              ForEach(values[i], id: \.key) { row in
                if row.state == 1 {
                  Label(row.title ?? "已失效", systemImage: "nosign").foregroundStyle(.secondary)
                } else {
                  PlainRowLink {
                    CreatorFolderContents(
                      id: row.id, title: row.title ?? names[i], collection: row.type == 21)
                  } label: {
                    MediaRow(
                      cover: row.cover.flatMap(httpsURL), title: row.title ?? "收藏夹",
                      badge: row.type == 21 ? "合集" : nil,
                      subtitle: "\(row.media_count ?? 0) 个内容", thumbWidth: 120)
                  }
                }
              }
              if let error = groupErrors[i] {
                Text(error).font(.caption).foregroundStyle(.secondary)
              }
              if loading[i] {
                ProgressView().frame(maxWidth: .infinity)
              } else if next[i] > 0 {
                Button(groupErrors[i] == nil ? "加载更多" : "重试") { Task { await more(i) } }
                  .piliButtonStyle(.glass).frame(maxWidth: .infinity)
              }
            }
          } header: {
            Button {
              withAnimation(.snappy(duration: 0.25)) { expanded[i].toggle() }
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(names[i]).font(.headline).foregroundStyle(.primary)
                Text("\(counts[i])").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary).rotationEffect(.degrees(expanded[i] ? 0 : -90))
              }.contentShape(Rectangle())
            }.buttonStyle(.plain).textCase(nil)
          }
        }
      } else if let issue {
        PageFailure(message: issue) { revision += 1 }
      } else {
        PageLoading()
      }
    }.listStyle(.plain).environment(\.inListRows, true).reportsScrollCollapse()
      .task(id: "\(mid):\(accounts.state.active ?? ""):\(revision)") {
        if !ready || contentScope != Scope(mid: mid, owner: accounts.state.active ?? "") || issue != nil {
          await initial()
        }
      }
      .piliRefreshable { await initial() }
  }
  @MainActor private func initial() async {
    let token = UUID()
    let uid = accounts.state.active ?? ""
    stamp = token
    refreshing = true
    defer { if stamp == token { refreshing = false } }
    let scope = Scope(mid: mid, owner: uid)
    if contentScope != scope {
      ready = false
      values = [[], []]
      counts = [0, 0]
      next = [0, 0]
      expanded = [true, true]
    }
    contentScope = scope
    loading = [false, false]
    issue = nil
    groupErrors = [nil, nil]
    do {
      let data = try await BiliAPI.shared.read(
        "/x/v3/fav/folder/space", ["up_mid": String(mid), "mobi_app": "iphone", "platform": "ios"],
        expectedAccount: uid, as: [GroupData].self)
      try Task.checkCancellation()
      guard stamp == token, uid == (accounts.state.active ?? "") else { return }
      for i in 0..<2 {
        let section = data.indices.contains(i) ? data[i] : nil
        names[i] = section?.name ?? (i == 0 ? "创建的收藏夹" : "收藏和订阅")
        let raw = section?.mediaListResponse?.list ?? []
        var seen = Set<String>()
        values[i] = raw.filter { $0.id > 0 && seen.insert($0.key).inserted }
        counts[i] = section?.mediaListResponse?.count ?? raw.count
        next[i] = raw.count < counts[i] ? 2 : 0
      }
      ready = true
    } catch { if !Task.isCancelled && stamp == token { issue = error.localizedDescription } }
  }
  @MainActor private func more(_ index: Int) async {
    let pg = next[index]
    let token = stamp
    let uid = accounts.state.active ?? ""
    guard !refreshing, !loading[index], pg > 0 else { return }
    groupErrors[index] = nil
    loading[index] = true
    defer { if token == stamp { loading[index] = false } }
    do {
      var q = ["pn": String(pg), "ps": "20", "up_mid": String(mid)]
      if index == 1 { q["platform"] = "web" }
      let page = try await BiliAPI.shared.read(
        index == 0 ? "/x/v3/fav/folder/created/list" : "/x/v3/fav/folder/collected/list", q,
        expectedAccount: uid, as: Payload.self)
      try Task.checkCancellation()
      guard stamp == token, uid == (accounts.state.active ?? "") else { return }
      var seen = Set(values[index].map(\.key))
      let raw = page.list ?? []
      let added = raw.filter { $0.id > 0 && seen.insert($0.key).inserted }
      values[index].append(contentsOf: added)
      if let n = page.count { counts[index] = n }
      next[index] = !raw.isEmpty && (page.has_more ?? (pg * 20 < counts[index])) ? pg + 1 : 0
    } catch {
      if token == stamp && !Task.isCancelled { groupErrors[index] = error.localizedDescription }
    }
  }
}

struct CreatorFolderContents: View {
  let id: Int64, title: String, collection: Bool
  var body: some View {
    if collection { SubscriptionCollection(item: .init(id:id,type:21,title:title)) }
    else { FavoriteFolderScreen(id:id) }
  }
}
