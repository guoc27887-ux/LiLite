import SwiftUI

struct MatchDetailView: View {
  let id: Int64
  struct Payload: Decodable {
    struct Contest: Decodable {
      struct Club: Decodable {
        let title: String?, logo: String?, logoFull: String?
        var imageURL: URL? {
          if let full = logoFull.flatMap(httpsURL) { return full }
          guard let logo, !logo.isEmpty else { return nil }
          if let url = httpsURL(logo) { return url }
          return logo.hasPrefix("/") ? httpsURL("https://i1.hdslb.com" + logo) : nil
        }
      }
      let contest_status: Int?
      let game_stage: String?, stime: Int64?, home_score: Int?, away_score: Int?, live_room: Int64?,
        season: Club?, home_team: Club?, away_team: Club?, playback: String?
    }
    let contest: Contest?
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var data: Payload.Contest?
  @State private var issue: String?
  @State private var retry = 0
  @State private var resourceKey = ""
  var body: some View {
    Group {
      if let d = data {
        Discussion(oid: id, type: 27, embeddedTitle: "赛事详情", readingHeader: AnyView(matchHeader(d)),
          readingControls: AnyView(Text("赛事讨论").font(.headline)))
      } else if let issue {
        ContentUnavailableView { Label("比赛未能加载", systemImage: "sportscourt") }
          description: { Text(issue) } actions: { Button("重试") { retry += 1 } }
      } else { ProgressView() }
    }.navigationTitle("赛事详情").toolbar {
      if data != nil { Button("刷新比赛", systemImage: "arrow.clockwise") { retry += 1 } }
    }.task(id: "\(id):\(retry):\(accounts.state.active ?? "")") { await load() }
  }
  private func matchHeader(_ d: Payload.Contest) -> some View {
    VStack(spacing: 14) {
      VStack(spacing: 3) {
        Text(d.season?.title ?? "赛事").font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
        if let stage = d.game_stage, !stage.isEmpty {
          Text(stage).font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack(alignment: .center) {
        club(d.home_team, fallback: "主队")
        VStack(spacing: 6) {
          Text(d.contest_status == 1 ? "VS" : "\(d.home_score ?? 0) : \(d.away_score ?? 0)")
            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
          if let status = d.contest_status, let text = [1:"未开始", 2:"进行中", 3:"已结束"][status] {
            Text(text).font(.caption.weight(.semibold))
              .foregroundStyle(status == 2 ? Color.white : Color.secondary)
              .padding(.horizontal, 8).padding(.vertical, 2)
              .background(status == 2 ? Color.pink : Color(uiColor: .tertiarySystemFill), in: Capsule())
          }
        }
        .frame(minWidth: 100)
        club(d.away_team, fallback: "客队")
      }
      if let date = d.stime {
        Text(Date(timeIntervalSince1970: Double(date)), format: .dateTime.year().month().day().hour().minute())
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      HStack(spacing: 10) {
        if let room = d.live_room, room > 0 {
          NavigationLink { LivePlayer(id: room, title: d.season?.title ?? "比赛直播") } label: {
            Label(d.contest_status == 2 ? "观看直播" : "直播间", systemImage: "dot.radiowaves.left.and.right")
          }
          .piliButtonStyle(.glassProminent)
        }
        if d.contest_status != 2, let p = d.playback, !p.isEmpty {
          if let r = SharedLink.parse(p) {
            NavigationLink { LinkDestination(item: r) } label: { Label("观看回放", systemImage: "play.rectangle") }
              .piliButtonStyle(.glass)
          } else if let url = httpsURL(p) {
            Link(destination: url) { Label("观看回放", systemImage: "play.rectangle") }.piliButtonStyle(.glass)
          }
        }
      }
      .font(.subheadline.weight(.medium)).buttonBorderShape(.capsule)
    }
    .padding(16).frame(maxWidth: .infinity)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
    .padding(.vertical, 8)
  }
  private func club(_ record: Payload.Contest.Club?, fallback: String) -> some View {
    VStack(spacing: 6) {
      SiteThumbnail(url: record?.imageURL) { $0.resizable().scaledToFit() } placeholder: {
        Image(systemName: "shield.lefthalf.filled").resizable().scaledToFit().foregroundStyle(.quaternary)
      }
      .frame(width: 52, height: 52).accessibilityHidden(true)
      Text(record?.title ?? fallback).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity)
  }
  @MainActor private func load() async {
    let owner = accounts.state.active
    let key = "\(id):\(owner ?? "")"
    if resourceKey != key { resourceKey = key; data = nil }
    issue = nil
    do {
      let r = try await BiliAPI.shared.read("/x/esports/match/info", ["cid":String(id), "platform":"2"],
        expectedAccount: owner ?? "", as: Payload.self)
      try Task.checkCancellation()
      guard let v = r.contest else { throw ServiceError("未找到比赛") }
      if owner == accounts.state.active { data = v }
    } catch {
      if !Task.isCancelled && owner == accounts.state.active { data = nil; issue = error.localizedDescription }
    }
  }
}
