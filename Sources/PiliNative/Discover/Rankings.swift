import SwiftUI

struct CuratedEdition: Decodable {
  struct Info: Decodable { let name: String?, label: String?, media_id: Int64? }
  let list: [Video]?, config: Info?, reminder: String?, media_id: Int64?
}
extension BiliAPI {
  func curatedEdition(_ number: Int?, page: Int, owner: String) async throws -> CuratedEdition {
    if let number {
      return try await read(
        "/x/web-interface/popular/series/one",
        try await sign(["number": String(number), "web_location": "333.934"]),
        expectedAccount: owner, as: CuratedEdition.self)
    }
    return try await read(
      "/x/web-interface/popular/precious",
      try await sign(["page": String(page), "page_size": "100", "web_location": "333.934"]),
      expectedAccount: owner, as: CuratedEdition.self)
  }
}
struct Rankings: View {
  enum Mode: String, CaseIterable {
    case rank = "排行榜"
    case weekly = "每周必看"
    case precious = "入站必刷"
  }
  @State private var mode: Mode
  @Namespace private var zoneSpace
  var embedded = false
  init(initial: Mode = .rank, embedded: Bool = false) {
    _mode = State(initialValue: initial); self.embedded = embedded
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var chart = DiscoveryRanking.all[0]
  @State private var weeks = [Week]()
  @State private var week = 0
  @State private var error: String?
  @State private var attempt = 0
  @State private var notice: String?
  @State private var editionTitle: String?
  @State private var editionLabel:String?
  @State private var start: PlaylistStart?
  @State private var listeningMediaID:Int64?
  @State private var positions = [String: Int]()
  @State private var ranks = [String: Int]()
  struct Week: Decodable, Identifiable {
    let number: Int, subject: String?, name: String?
    var id: Int { number }
  }
  struct Weeks: Decodable { let list: [Week]? }
  struct RankedSeason: Decodable, Identifiable {
    struct Episode: Decodable { let id: Int64?, index_show: String?, url: String? }
    struct Stats: Decodable { let view: Int64?, follow: Int64?, danmaku: Int64? }
    let season_id: Int64, title: String, cover: String?, url: String?, new_ep: Episode?, rank: Int?,
      stat: Stats?
    var id: Int64 { season_id }
    var target: SharedLink { url.flatMap { SharedLink.parse($0) } ?? .season(season_id) }
  }
  private var owner: String { accounts.state.owner(.role(.recommend)) ?? "" }
  var body: some View {
    // Read here so new chart positions re-render this view (rows are built in child bodies).
    let rankTable = ranks
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ChipBar(items: Mode.allCases, selection: $mode, title: \.rawValue)
        if mode == .weekly, !weeks.isEmpty {
          Menu {
            Picker("周次", selection: $week) {
              ForEach(weeks) { w in Text(w.name ?? w.subject ?? "第 \(w.number) 期").tag(w.number) }
            }
          } label: {
            HStack(spacing: 3) {
              Text(weeks.first { $0.number == week }.map { "第 \($0.number) 期" } ?? "期数")
              Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline).padding(.horizontal, 12).frame(height: 34)
            .piliGlass(in: Capsule(), interactive: true)
          }
          .buttonStyle(.plain).padding(.trailing, 16)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
      }
      .padding(.vertical, 6)
      .animation(.snappy(duration: 0.25), value: mode)
      Group {
        if mode == .rank {
          HStack(spacing: 0) {
            zoneRail
            RetainedDeck(choices: DiscoveryRanking.all, selection: $chart, swipe: false) { choice in
              chartBody(choice, ranks: rankTable)
            }.id(owner)
          }
        } else {
          VStack(spacing: 0) {
            if mode == .weekly {
              if let label = editionLabel, !label.isEmpty {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                  .padding(.bottom, 4)
              }
              if let error {
                VStack(spacing: 10) {
                  Text(error).font(.footnote).foregroundStyle(.secondary)
                  Button("重试") { attempt += 1 }.piliButtonStyle(.glass)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
              }
            }
            if mode != .weekly || week > 0 {
              editionBody.id("\(mode):\(week):\(owner)")
            } else if error == nil {
              ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
      .transition(.opacity)
      .animation(.easeOut(duration: 0.2), value: mode)
    }.piliCatalogTitle(mode == .weekly ? editionTitle ?? mode.rawValue : mode.rawValue, embedded: embedded)
      .task(id: "\(mode):\(attempt):\(owner)") {
        guard mode == .weekly else { return }
        do {
          let data = try await BiliAPI.shared.read(
            "/x/web-interface/popular/series/list",
            try await BiliAPI.shared.sign(["web_location": "333.934"]), expectedAccount: owner,
            as: Weeks.self)
          try Task.checkCancellation()
          weeks = data.list ?? []
          if !weeks.contains(where: { $0.number == week }) { week = weeks.first?.number ?? 0 }
          error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
      .onChange(of: week) { _, _ in
        editionTitle = nil
        editionLabel=nil
        notice = nil
      }
      .piliFullScreenCover(item: $start) { begin in
        LibraryPlaylist(
          kind: .curated(mode == .weekly ? week : nil), uid: owner, query: "", order: .mtime,
          viewed: 0, ascending: false, start: begin, allowChanges: false)
          .environment(\.listenOrigin,listeningMediaID.map{.media($0,kind:4)})
      }
  }
  /// Vertical zone list down the leading edge, like the original client's ranking page.
  private var zoneRail: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 2) {
          ForEach(DiscoveryRanking.all) { z in
            let current = z == chart
            Button {
              TouchFeedback.light()
              withAnimation(.snappy(duration: 0.22)) { chart = z }
            } label: {
              Text(z.title)
                .font(.subheadline.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background {
                  if current {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                      .fill(Color.accentColor.opacity(0.12))
                      .matchedGeometryEffect(id: "zone", in: zoneSpace)
                  }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).id(z)
            .accessibilityAddTraits(current ? .isSelected : [])
          }
        }.padding(.horizontal, 6).padding(.vertical, 6)
      }
      .scrollIndicators(.hidden)
      .frame(width: 76)
      .onChange(of: chart) { _, v in withAnimation(.snappy) { proxy.scrollTo(v, anchor: .center) } }
    }
    .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
  }
  @ViewBuilder private func chartBody(_ chart:DiscoveryRanking, ranks: [String: Int]) -> some View {
    switch chart {
    case .video(let rid, _):
      PageList(empty: "暂无上榜视频",discoveryArchive:{(v:Video) in v}) { _ in
        struct Result: Decodable { let list: [Video]? }
        let r = try await BiliAPI.shared.read(
          "/x/web-interface/ranking/v2",
          try await BiliAPI.shared.sign(["rid": String(rid), "type": "all"]),
          expectedAccount: owner, as: Result.self)
        let filtering = Task.detached(priority: .userInitiated) {
          let filter = RecommendationFilter()
          let rows = r.list ?? []
          var order = [String: Int]()
          for (i, v) in rows.enumerated() { order["\(rid):\(v.id)"] = i + 1 }
          return (rows.filter { !Task.isCancelled && filter.allows($0, from: .hotOrRank) }, order)
        }
        let result = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
        try Task.checkCancellation()
        self.ranks.merge(result.1) { $1 }
        return Page(items: result.0, next: nil)
      } row: {
        VideoLink(video: $0, rank: ranks["\(rid):\($0.id)"])
      }
    case .season(let type, _):
      PageList(empty: "暂无上榜作品") { _ in
        struct Result: Decodable { let list: [RankedSeason]? }
        let r = try await BiliAPI.shared.read(
          type == 1 ? "/pgc/web/rank/list" : "/pgc/season/rank/web/list",
          try await BiliAPI.shared.sign(["day": "3", "season_type": String(type)]),
          expectedAccount: owner, as: Result.self)
        return Page(items: r.list ?? [], next: nil)
      } row: { s in
        PlainRowLink {
          LinkDestination(item: s.target)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            if let n = s.rank {
              Text(String(n)).font(.title3.weight(.bold)).monospacedDigit()
                .foregroundStyle(n <= 3 ? Color.accentColor : Color.secondary).frame(width: 28)
                .padding(.top, 2)
            }
            SiteThumbnail(url: s.cover.flatMap(httpsURL)) {
              $0.resizable().scaledToFill()
            } placeholder: {
              Color.clear
            }
            .frame(width: 72, height: 96).background(.quaternary).clipped()
            .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
              Text(s.title).font(.subheadline.weight(.medium)).lineLimit(2)
              if let update = s.new_ep?.index_show { Text(update).font(.caption).foregroundStyle(.secondary) }
              Spacer(minLength: 0)
              let stats = [
                s.stat?.view.map { "\($0.formatted(.number.notation(.compactName)))播放" },
                s.stat?.follow.map { "\($0.formatted(.number.notation(.compactName)))追看" },
              ]
              Text(stats.compactMap { $0 }.joined(separator: " · ")).font(.caption)
                .foregroundStyle(.secondary).monospacedDigit()
            }.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
          }.padding(.vertical, 4).contentShape(Rectangle())
        }.contextMenu {
          if let u = s.cover.flatMap(httpsURL) {
            ContextLink("查看封面", systemImage: "photo") { NativeGallery([.init(u)]) }
          }
        }
      }.contextPushHost()
    }
  }
  private var editionBody: some View {
    let num = mode == .weekly ? week : nil
    return PageList(
      empty: "暂无上榜视频", autoMore:true,
      heading: mode == .weekly && notice?.isEmpty == false
        ? AnyView(Text(notice!).font(.footnote).foregroundStyle(.secondary)) : nil
    ) { c in
      let page = Int(c ?? "1") ?? 1
      let r = try await BiliAPI.shared.curatedEdition(num, page: page, owner: owner)
      try Task.checkCancellation()
      if c == nil {
        positions = [:]
        listeningMediaID=r.config?.media_id ?? r.media_id
        if num != nil {
          editionTitle = r.config?.name
          editionLabel=r.config?.label
          notice = r.reminder
        }
      }
      let rows = r.list ?? []
      for v in rows { positions[v.id] = page }
      return Page(items: rows, next: num == nil && !rows.isEmpty ? String(page + 1) : nil)
    } row: { v in
      Button {
        start = PlaylistStart(rowID: v.id, page: positions[v.id] ?? 1)
      } label: {
        MediaRow(
          cover: v.cover, title: v.title,
          duration: v.duration.map { clockText(Double($0)) },
          subtitle: v.owner?.name,
          detail: MediaStats.line(views: v.stat?.view, danmaku: v.stat?.danmaku))
      }.buttonStyle(.plain).archiveCover(v)
    }
  }
}
