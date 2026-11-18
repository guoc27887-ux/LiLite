import PiliWire
import SwiftUI

struct CreatorOpus: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var collections: [DynamicGateway.Collection] = []
  @State private var useWeb = false
  struct Kind: Decodable, Hashable { let meta: String, text: String }
  struct Opus: Decodable, Identifiable {
    struct Cover: Decodable { let url: String?, width: Int?, height: Int? }
    struct Stat: Decodable { let like: String? }
    let opus_id: String, content: String?, cover: Cover?, stat: Stat?
    var id: String { opus_id }
  }
  struct Response: Decodable { let items: [Opus]?, offset: String?, has_more: Bool? }
  struct Space: Decodable {
    struct Tab: Decodable {
      let param: String?, items: [Child]?
      struct Child: Decodable { let param: String?, filter: [Kind]? }
    }
    let tab2: [Tab]?
  }
  @State private var filters = [Kind(meta: "all", text: "全部图文")]
  @State private var selected = "all"
  @State private var rows: [Opus] = []
  @State private var page = 1
  @State private var offset = ""
  @State private var more = true
  @State private var busy = false
  @State private var issue: String?
  @State private var generation = UUID()
  private struct Scope: Equatable { let mid: Int64, owner: String?, filter: String }
  private var scope: Scope { Scope(mid: mid, owner: accounts.state.active, filter: selected) }
  @State private var contentScope: Scope?
  @State private var loadedScope: Scope?
  var body: some View {
    ScrollView {
      if !collections.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("文集").font(.headline).padding(.horizontal, 16)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(collections) { c in
                NavigationLink {
                  ArticleCollection(id: c.id)
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Rectangle().fill(.quaternary).frame(width: 150, height: 94)
                      .overlay {
                        SiteThumbnail(url: httpsURL(c.cover)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                      }
                      .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
                    Text(c.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if !c.subtitle.isEmpty {
                      Text(c.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                  }.frame(width: 150, alignment: .leading)
                }.buttonStyle(.plain)
              }
            }.padding(.horizontal, 16)
          }.scrollClipDisabled()
        }.padding(.top, 8)
      }
      CatalogGrid {
        ForEach(rows) { r in
          NavigationLink {
            DynamicDetail(id: r.id)
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              if let u = r.cover?.url.flatMap(httpsURL) {
                Rectangle().fill(.quaternary).aspectRatio(4 / 3, contentMode: .fit)
                  .overlay { SiteThumbnail(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                  .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
              }
              Text(r.content ?? "图文").font(.subheadline).lineLimit(3)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
              if let n = r.stat?.like, !n.isEmpty {
                Label(n, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
              }
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }.padding(16)
      if busy {
        PageLoading()
      } else if let issue {
        PageFailure(message: issue) { Task { await load(reset: page == 1) } }
      } else if rows.isEmpty {
        ContentUnavailableView("暂无图文", systemImage: "doc.richtext")
      }
      if more && !busy && issue == nil && !rows.isEmpty {
        Button("加载更多") { Task { await load(reset: false) } }
      }
    }
    .reportsScrollCollapse()
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      if filters.count > 1 {
        ChipBar(
          items: filters.map(\.meta), selection: $selected,
          title: { meta in filters.first { $0.meta == meta }?.text ?? meta }
        ).padding(.vertical, 6)
      }
    }
    .navigationTitle("图文投稿").task(id: scope) { if loadedScope != scope { await load(reset: true) } }
      .piliRefreshable { await load(reset: true) }
      .task(id: mid) {
        if let space = try? await BiliAPI.shared.read(
          "/x/v2/space", CreatorSpaceRequest.fields(mid),
          host: "app.bilibili.com", as: Space.self),
          let list = space.tab2?.first(where: { $0.param == "contribute" })?.items?.first(where: {
            $0.param == "opus"
          })?.filter
        {
          var keys = Set<String>()
          let values = ([Kind(meta: "all", text: "全部图文")] + list).filter {
            !$0.meta.isEmpty && keys.insert($0.meta).inserted
          }
          if !Task.isCancelled { filters = values }
        }
      }
  }
  @MainActor private func load(reset: Bool) async {
    if !reset && (busy || !more) { return }
    let id = UUID()
    let requested = scope
    generation = id
    let nextPage = reset ? 1 : page
    let previous = reset ? "" : offset
    if contentScope != requested {
      loadedScope = nil
      rows = []
      collections = []
      page = 1
      offset = ""
      more = true
      useWeb = false
    }
    contentScope = requested
    busy = true
    issue = nil
    defer { if generation == id { busy = false } }
    do {
      let a = BiliAPI.shared
      if reset || !useWeb {
        do {
          let flow = try await a.socialService(for: requested.owner).space(
            requested.mid, filter: requested.filter, cursor: previous.isEmpty ? nil : previous)
          try Task.checkCancellation()
          guard generation == id, scope == requested else { return }
          if reset { collections = flow.collections }
          var seen = reset ? Set<String>() : Set(rows.map(\.id))
          let fresh = flow.rows.filter { seen.insert($0.id).inserted }.map {
            Opus(
              opus_id: $0.id, content: $0.text,
              cover: $0.cover.isEmpty ? nil : .init(url: $0.cover, width: nil, height: nil),
              stat: $0.like.isEmpty ? nil : .init(like: $0.like))
          }
          rows = reset ? fresh : rows + fresh
          useWeb = false
          loadedScope = requested
          offset = flow.next ?? ""
          more = flow.next != nil
          page = nextPage + 1
          return
        } catch {
          try Task.checkCancellation()
          guard generation == id, scope == requested else { return }
          if !reset { throw error }
        }
      }
      let q = try await a.sign([
        "host_mid": String(requested.mid), "page": String(nextPage), "offset": previous, "type": requested.filter,
        "web_location": "333.1387",
      ])
      let r = try await a.read("/x/polymer/web-dynamic/v1/opus/feed/space", q,
        expectedAccount: requested.owner ?? "", as: Response.self)
      try Task.checkCancellation()
      guard generation == id, scope == requested else { return }
      var seen = reset ? Set<String>() : Set(rows.map(\.id))
      let fresh = (r.items ?? []).filter { seen.insert($0.id).inserted }
      rows = reset ? fresh : rows + fresh
      if reset { collections = [] }
      useWeb = true
      loadedScope = requested
      offset = r.offset ?? ""
      page = nextPage + 1
      more = r.has_more == true && !offset.isEmpty && offset != previous
    } catch { if generation == id && !Task.isCancelled { issue = error.localizedDescription } }
  }
}
