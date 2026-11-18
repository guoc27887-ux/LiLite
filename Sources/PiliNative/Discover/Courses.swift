import SwiftUI

struct CoursesView: View {
  let mid: String
  var favorites = false
  @State private var remove: Response.Item?
  @State private var revision = 0
  @State private var error: String?
  struct Response: Decodable {
    struct Item: Decodable, Identifiable {
      let season_id: Int64, title: String?, status: String?, cover: String?, marks: [String]?,
        ctime: String?
      var id: Int64 { season_id }
    }
    struct Cursor: Decodable { let next: Bool? }
    let items: [Item]?, page: Cursor?
  }
  var body: some View {
    PageList(empty: "暂无课程") { c in
      let p = Int(c ?? "1") ?? 1
      let r = try await BiliAPI.shared.read(
        favorites ? "/pugv/app/web/favorite/page" : "/pugv/app/web/season/page",
        ["mid": mid, "pn": "\(p)", "ps": favorites ? "20" : "30", "web_location": "333.1387"],
        expectedAccount: favorites ? mid : nil, as: Response.self)
      return Page(items: r.items ?? [], next: r.page?.next == true ? "\(p+1)" : nil)
    } row: { i in
      PlainRowLink {
        CourseDetail(id: i.id)
      } label: {
        MediaRow(
          cover: i.cover.flatMap(httpsURL), title: i.title ?? "课程",
          badge: i.marks?.first,
          subtitle: i.status,
          detail: favorites
            ? i.ctime.flatMap(Int64.init).flatMap(MediaStats.published).map { "收藏于 " + $0 }
            : (i.marks?.dropFirst().joined(separator: " · ")))
      }
      .seasonCover(i.cover ?? "")
      .swipeActions { if favorites { Button("取消收藏", role: .destructive) { remove = i } } }
    }.id(revision).navigationTitle(favorites ? "收藏的课程" : "课堂")
      .confirmationDialog(
        "取消收藏该课程？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
        presenting: remove
      ) { course in
        Button("取消收藏", role: .destructive) {
          Task {
            do {
              try await BiliAPI.shared.submit(
                "/pugv/app/web/favorite/del", ["season_id": String(course.season_id)],
                expectedAccount: mid)
              revision += 1
            } catch { self.error = error.localizedDescription }
          }
        }
      }.alert("收藏的课程", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }))
    {
      Button("好") {}
    } message: {
      Text(error ?? "")
    }
  }
}
struct CourseDetail: View {
  typealias Course = CourseCatalog
  let id: Int64
  var byEpisode = false
  @EnvironmentObject private var accounts: AccountContext
  private var main: String { accounts.state.active ?? "" }
  private var viewer: String { accounts.state.owner(.role(.video)) ?? "" }
  private var history: String { accounts.state.owner(.role(.heartbeat)) ?? "" }
  @State private var course: Course?
  @State private var favored: Bool?
  @State private var lastEpisode: Int64?
  @State private var studyTimes = [Int64: Double]()
  @State private var studied = Set<Int64>()
  @State private var displayedMain: String?
  @State private var busy = false
  @State private var revision = 0
  @State private var error: String?
  var body: some View {
    ScrollView {
      if let c = course {
        LazyVStack(alignment: .leading, spacing: 20) {
          hero(c)
          info(c)
          actions(c)
          if let team = c.cooperators, !team.isEmpty { teamRail(team) }
          ForEach(c.groups) { group in lessonSection(group, c) }
          if c.lessons.isEmpty {
            Text("暂无课时").font(.subheadline).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity).padding(.vertical, 24)
          }
          if c.partial,
            let url = URL(string: "https://www.bilibili.com/cheese/play/ss" + String(c.season_id))
          {
            NavigationLink { SitePage(url: url) } label: {
              Label("查看官方课程目录", systemImage: "safari").font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
            }.piliButtonStyle(.glass)
          }
          introduction(c)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 32)
        .transition(.opacity)
      } else if let error {
        PageFailure(message: error) { revision += 1 }
      } else {
        PageLoading()
      }
    }
    .animation(.easeOut(duration: 0.25), value: course == nil)
    .navigationTitle(course?.title ?? "课程")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let c = course, let url = URL(string: "https://www.bilibili.com/cheese/play/ss\(c.season_id)") {
        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
      }
    }
    .task(id: "\(id):\(byEpisode):\(viewer):\(main):\(history):\(revision)") { await load() }
  }
  private func resume(_ c: Course) -> SeasonInfo.Episode? {
    guard let e = c.preferred(episode: byEpisode ? id : lastEpisode, aid: nil, useSaved: false),
      e.canRequestPlayback else { return nil }
    return e
  }
  @ViewBuilder private func hero(_ c: Course) -> some View {
    let cover = Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
      .overlay {
        SiteThumbnail(url: c.cover.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
          Color.clear
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: NativeGlass.panelRadius, style: .continuous))
    if let e = resume(c) {
      NavigationLink { player(e, c) } label: {
        cover.overlay {
          Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
        }
      }.buttonStyle(.plain).accessibilityLabel("播放：" + e.label)
    } else {
      cover
    }
  }
  private func info(_ c: Course) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(c.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
      if let subtitle = c.subtitle, !subtitle.isEmpty {
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
      }
      let notes = [
        c.release_info,
        c.user_status?.is_expired == true ? "课程已到期" : c.expiry_info_content.map { "有效期 " + $0 },
        c.stop_sell == true ? "已停止发售" : nil,
      ].compactMap { $0 }.filter { !$0.isEmpty }
      if !notes.isEmpty {
        Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
      }
      if let t = c.up_info, let n = t.mid, n > 0 {
        NavigationLink { CreatorSpace(mid: n, name: t.uname ?? "讲师") } label: {
          HStack(spacing: 10) {
            SiteThumbnail(url: t.avatar.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
              Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
            }
            .frame(width: 34, height: 34).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
              Text(t.uname ?? "讲师").font(.subheadline.weight(.medium))
              Text("讲师").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.top, 8)
      }
    }
  }
  @ViewBuilder private func actions(_ c: Course) -> some View {
    HStack(spacing: 10) {
      if let e = resume(c) {
        NavigationLink { player(e, c) } label: {
          HStack(spacing: 6) {
            Image(systemName: "play.fill")
            Text(lastEpisode == nil ? "开始学习" : "继续学习").lineLimit(1)
          }.frame(maxWidth: .infinity)
        }.piliButtonStyle(.glassProminent)
      }
      if !main.isEmpty, displayedMain == main, let f = favored {
        Button {
          let owner = main
          TouchFeedback.light()
          Task { await toggle(c, previous: f, owner: owner) }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: f ? "star.fill" : "star").contentTransition(.symbolEffect(.replace))
            Text(f ? "已收藏" : "收藏")
          }.frame(maxWidth: resume(c) == nil ? .infinity : nil)
        }
        .piliButtonStyle(.glass).tint(f ? .orange : nil).disabled(busy)
      }
    }
    .font(.subheadline.weight(.semibold))
  }
  private func teamRail(_ team: [Course.Teacher]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("课程团队").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(Array(team.enumerated()), id: \.offset) { _, t in
            if let n = t.mid, n > 0 {
              NavigationLink { CreatorSpace(mid: n, name: t.nick_name ?? "讲师") } label: {
                VStack(spacing: 4) {
                  SiteThumbnail(url: t.avatar.flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
                  }
                  .frame(width: 48, height: 48).clipShape(Circle())
                  Text(t.nick_name ?? "讲师").font(.caption).lineLimit(1)
                  if let role = t.role, !role.isEmpty {
                    Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                }.frame(width: 72)
              }.buttonStyle(.plain)
            }
          }
        }
      }.scrollClipDisabled()
    }
  }
  private func lessonSection(_ group: Course.LessonGroup, _ c: Course) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(group.title).font(.headline)
        Text("\(group.episodes.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        Spacer()
        if group.episodes.filter(\.allowCacheEntry).count > 1 {
          NavigationLink {
            SeasonBatchCache(episodes: group.episodes, course: true, title: group.title)
          } label: {
            Label("缓存", systemImage: "arrow.down.circle").font(.subheadline)
          }.buttonStyle(.plain).foregroundStyle(.tint)
        }
      }
      ForEach(group.episodes) { e in
        if e.canRequestPlayback {
          NavigationLink { player(e, c) } label: { lessonLabel(e) }.buttonStyle(.plain)
        } else if e.isLiveCourse || (c.drm_switch ?? 0) > 0,
          let url = URL(string: "https://www.bilibili.com/cheese/play/ep" + String(e.id))
        {
          NavigationLink { SitePage(url: url) } label: { lessonLabel(e) }.buttonStyle(.plain)
        } else {
          lessonLabel(e).opacity(0.55)
        }
      }
    }
  }
  @ViewBuilder private func introduction(_ c: Course) -> some View {
    let text = (c.brief?.content ?? "").replacingOccurrences(
      of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive]
    ).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let photos = (c.brief?.img ?? []).compactMap { $0.url.flatMap(httpsURL) }.map { GalleryPicture($0) }
    if !text.isEmpty || !photos.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(c.brief?.title ?? "课程介绍").font(.headline)
        if !text.isEmpty {
          Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
        ForEach(photos.indices, id: \.self) { i in
          GalleryLink(photos, index: i) {
            RemoteArtwork(url: photos[i].url) { phase in
              if let image = phase.image {
                image.resizable().scaledToFit()
              } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
          }
        }
      }
    }
  }
  private func lessonLabel(_ e: SeasonInfo.Episode) -> some View {
    let length = e.duration.flatMap { $0 > 0 ? Double($0) : nil }
    let studiedTime = studyTimes[e.id] ?? 0
    let note = [
      e.isLiveCourse ? "直播课"
        : (e.accessReason ?? ((e.barred || (e.cid <= 0 && !e.canResolveCID)) ? "暂不可播放" : nil)),
      e.play.map { Int64($0).formatted(.number.notation(.compactName)) + "次播放" },
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    let study = studiedTime > 0 ? "学至 " + clockText(studiedTime) : studied.contains(e.id) ? "已学习" : nil
    return MediaRow(
      cover: e.cover.flatMap(httpsURL), title: e.label,
      badge: e.preview ? "试看" : e.badge,
      duration: length.map { clockText($0) },
      progress: length.map { studied.contains(e.id) && studiedTime == 0 ? 1 : studiedTime / $0 },
      subtitle: note, detail: study, thumbWidth: 128)
  }
  private func player(_ e: SeasonInfo.Episode, _ c: Course) -> some View {
    EpisodePlayer(
      episode: e, course: true, initialSeconds: PlaybackMemory.enabled ? studyTimes[e.id] : nil,
      sequence: (c.groups.first { $0.episodes.contains(where: { $0.id == e.id }) }?.episodes
        ?? c.lessons), seasonTitle: c.title,
      seasonID: c.season_id)
  }
  @MainActor private func load() async {
    let m = main
    let v = viewer
    let h = history
    course = nil
    displayedMain = nil
    error = nil
    favored = nil
    lastEpisode = nil
    studyTimes = [:]
    studied = []
    do {
      let c = try await BiliAPI.shared.courseCatalog(id, byEpisode: byEpisode, videoOwner: v)
      try Task.checkCancellation()
      course = c
      let tracker: Course?
      if h == v {
        tracker = c
      } else {
        tracker = try? await BiliAPI.shared.read(
          "/pugv/view/web/season", ["season_id": String(c.season_id)], expectedAccount: h,
          as: Course.self)
        try Task.checkCancellation()
      }
      if let tracker {
        lastEpisode = tracker.user_status?.progress?.last_ep_id
        for item in tracker.lessons {
          if item.studied == true { studied.insert(item.id) }
          if let value = tracker.continueSeconds(for: item) { studyTimes[item.id] = value }
        }
      }
      guard !m.isEmpty else { return }
      let value: Int?
      if m == v {
        value = c.user_status?.favored
      } else {
        value = try await BiliAPI.shared.courseFavoriteState(c.season_id, owner: m)
      }
      try Task.checkCancellation()
      guard main == m else { return }
      if let value, [0, 1].contains(value) {
        favored = value == 1
        displayedMain = m
      }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
  @MainActor private func toggle(_ c: Course, previous: Bool, owner: String) async {
    guard !busy, !owner.isEmpty, main == owner, displayedMain == owner else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/pugv/app/web/favorite/" + (previous ? "del" : "add"), ["season_id": String(c.season_id)],
        expectedAccount: owner)
      if main == owner { favored = !previous }
    } catch { if main == owner { self.error = error.localizedDescription } }
  }
}
extension BiliAPI {
  func courseCatalog(_ id: Int64, byEpisode: Bool, videoOwner: String) async throws -> CourseCatalog
  {
    guard id > 0 else { throw ServiceError("课程编号无效") }
    struct Envelope: Decodable { let code: Int, message: String?, data: CourseCatalog? }
    func query(_ path: String) async throws -> CourseCatalog {
      let raw = try await fetch(
        path, [byEpisode ? "ep_id" : "season_id": String(id)], host: "api.bilibili.com",
        expectedAccount: videoOwner, cacheVideoIdentity: true)
      let r = try JSONDecoder().decode(Envelope.self, from: raw)
      guard r.code == 0, let c = r.data, c.season_id > 0, byEpisode || c.season_id == id else {
        throw ServiceError(r.message ?? "课程暂不可用")
      }
      return c
    }
    let basic = try await query("/pugv/view/web/season")
    var complete = try await query("/pugv/view/web/season/v2")
    guard complete.season_id == basic.season_id else { throw ServiceError("课程目录不匹配") }
    if complete.sections == nil && complete.episodes == nil { throw ServiceError("未能读取课程目录") }
    if complete.sections != nil { complete.episodes = basic.episodes }
    return complete
  }
  // When main and playback accounts differ, never use the playback account's favorite state for a main-account mutation.
  func courseFavoriteState(_ id: Int64, owner: String) async throws -> Int? {
    guard id > 0, !owner.isEmpty,
      let url = URL(string: "https://api.bilibili.com/pugv/view/web/season?season_id=" + String(id))
    else { throw URLError(.badURL) }
    return try await ConnectionRetry.current().perform(readOnly: true) { _ in
      guard let account = try await AccountJar.shared.current(.role(.main)), account.id == owner
      else { throw ServiceError("账号已切换") }
      var req = URLRequest(url: url)
      req.httpShouldHandleCookies = false
      req.setValue(account.header, forHTTPHeaderField: "Cookie")
      req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
      let (data, raw) = try await self.webResponse(req, identity: account)
      struct Status: Decodable {
        struct Value: Decodable { let user_status: SeasonInfo.User? }
        let code: Int, data: Value?
      }
      guard (raw as? HTTPURLResponse)?.statusCode == 200,
        let r = try? JSONDecoder().decode(Status.self, from: data), r.code == 0
      else { throw ServiceError("未能读取课程收藏状态") }
      return r.data?.user_status?.favored
    }
  }
}
extension BiliAPI {
  func courseFormats(
    _ e: SeasonInfo.Episode, language: String? = nil, expectedAccount: String? = nil
  ) async throws -> DashFormats {
    try await playEpisodeService(
      e, course: true, language: language, expectedAccount: expectedAccount
    ).0

  }
}
