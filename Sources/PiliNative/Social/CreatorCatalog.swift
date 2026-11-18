import SwiftUI

struct CreatorComics: View {
  let mid: Int64
  struct ListData: Decodable {
    struct Row: Decodable, Identifiable {
      let param: String, title: String?, cover: String?, styles: String?, label: String?
      var id: String { param }
    }
    let item: [Row]?, count: Int?
  }
  struct Selected: Identifiable {
    let url: URL
    var id: URL { url }
  }
  @State private var selected: Selected?
  var body: some View {
    PageList(empty: "暂无漫画") { cursor in
      let pg = Int(cursor ?? "1") ?? 1
      let r = try await BiliAPI.shared.read(
        "/x/v2/space/comic",
        [
          "vmid": String(mid), "platform": "ios", "mobi_app": "iphone", "pn": String(pg),
          "ps": "20", "qn": "32",
        ], host: "app.bilibili.com", as: ListData.self)
      let items = r.item ?? []
      return Page(
        items: items, next: (!items.isEmpty && pg * 20 < (r.count ?? 0)) ? String(pg + 1) : nil)
    } row: { r in
      Button {
        if let n = Int64(r.id), n > 0,
          let u = URL(string: "https://manga.bilibili.com/detail/mc\(n)")
        {
          selected = .init(url: u)
        }
      } label: {
        PosterRow(
          cover: r.cover.flatMap(httpsURL), title: r.title ?? "漫画",
          lines: [r.styles ?? ""], accent: r.label, width: 72)
      }.buttonStyle(.plain).seasonCover(r.cover ?? "")
    }.navigationTitle("漫画").piliSheet(item: $selected) { p in SitePage(url: p.url) }
  }
}
struct CreatorGuards: View {
  let mid: Int64
  var name: String? = nil, total: Int? = nil
  @EnvironmentObject private var accounts: AccountContext
  private struct Ranked: Identifiable { let rank: Int, member: Payload.Row; var id: Int64 { member.uid } }
  struct Payload: Decodable {
    struct Row: Decodable, Identifiable {
      let uid: Int64, username, face: String?, guard_level: Int?
      var id: Int64 { uid }
    }
    let guard_top_list: [Row]?, has_more: Int?
  }
  private func fetchGuardPage(cursor: String?) async throws -> Page<Ranked> {
    let page = Int(cursor ?? "1") ?? 1
    let r = try await BiliAPI.shared.read(
      "/xlive/app-ucenter/v1/guard/MainGuardCardAll",
      ["page": String(page), "page_size": "20", "ruid": String(mid)],
      host: "api.live.bilibili.com", expectedAccount: accounts.state.active ?? "", as: Payload.self)
    let rows = r.guard_top_list ?? []
    let items = rows.enumerated().map {
      Ranked(rank: (page - 1) * 20 + $0.offset + 1, member: $0.element)
    }
    return Page(items: items, next: r.has_more == 1 && !rows.isEmpty ? String(page + 1) : nil)
  }
  @ViewBuilder private func guardRow(_ entry: Ranked) -> some View {
    let r = entry.member
    PlainRowLink {
      CreatorSpace(mid: r.uid, name: r.username ?? "用户")
    } label: {
      RankedPersonRow(
        rank: entry.rank, avatar: r.face.flatMap(httpsURL), name: r.username ?? "用户",
        tag: r.guard_level.flatMap { [1: "总督", 2: "提督", 3: "舰长"][$0] },
        tagColor: r.guard_level == 1 ? .red : r.guard_level == 2 ? .purple : .blue)
    }
  }
  private var catalogList: some View {
    AnyView(PageList(empty: "暂无大航海成员", autoMore: true, fetch: fetchGuardPage, row: { entry in guardRow(entry) }))
  }
  private var catalogTitle: String {
    (name.map { $0 + "的" } ?? "") + "舰队" + (total.map { "（" + String($0) + "）" } ?? "")
  }
  var body: some View {
    catalogList.id(accounts.state.active).navigationTitle(catalogTitle)
  }
}
