import AVFoundation
import SwiftUI
import UIKit

struct DetailView: View {
  @Environment(\.libraryPlaybackPanel) private var libraryPanel
  @StateObject private var interactiveStory = InteractiveStory()
  @StateObject private var bulletInspector = BulletInspector()
  @AppStorage("dm.tap") private var tapBullet = true
  @AppStorage("detail.argue") private var showArgue = true
  @State private var wideViewport = false
  @State private var sideAuthor: Video.Owner?
  @State private var sidebarPart: (bvid: String, cid: Int64)?
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage("layout.member") private var memberPref: Bool?
  @AppStorage("detail.related") private var relatedShown = true
  private var useMemberPanel: Bool { wideViewport && (memberPref ?? horizontal) }
  private var creatorPanel: AnyView? {
    guard useMemberPanel, let author = sideAuthor, let id = author.mid else { return nil }
    return AnyView(
      PiliNavigationStack {
        CreatorVideoPanel(mid: id, name: author.name ?? "UP 主", current: (detail ?? following ?? initial).bvid) { next, part in
          sideAuthor = nil
          if next.bvid == (detail ?? following ?? initial).bvid {
            if let part, detail?.cid == part || detail?.pages?.contains(where: { $0.cid == part }) == true { cid = part }
          } else {
            sidebarPart = part.map { (next.bvid, $0) }
            following = next
          }
        }.toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("返回视频") { sideAuthor = nil } }
        }
      }.id(id))
  }
  @AppStorage("sponsor.enabled") private var sponsorEnabled = false
  @AppStorage(SponsorRules.key) private var blockRules = Data()
  let initial: Video
  var initialPage: Int? = nil, initialCID: Int64? = nil
  var initialSeconds: Double? = nil
  var libraryPoint: ArchiveStart? = nil
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.listenOrigin) private var listenOrigin
  @AppStorage("play.continuePart") private var continuePart = true
  @State private var startHint: ArchiveStart?
  @State private var detailOwner: String?
  var queueEnd: CloudAdvance? = nil
  var queueStep: CloudStep? = nil
  @State private var following: Video?
  @State private var descendingParts = false
  @State private var reversedSections = Set<Int64>()
  @AppStorage("play.reverseFirst") private var jumpOnReverse = true
  @State private var visited: [String] = []
  @State private var lastOpened: Int64?
  @AppStorage(InterfaceInteraction.preinitialize) private var early = false
  @AppStorage(VideoTransport.autoKey) private var autoplay = true
  @State private var manualTicket: PlaybackEntryID?
  @State private var prepared: PlaybackEntryID?
  private func ticket(_ video: Video, _ cid: Int64) -> PlaybackEntryID {
    .init(source: video.bvid, cid: cid, owner: accounts.state.owner(.role(.video)))
  }
  var resumeFullscreen = false
  @State private var offeredPart:ArchiveStart?
  @State private var offeredOn:Int64?
  @State private var detail: Video?
  @State private var cid: Int64?
  @State private var detailError: String?
  @State private var reload = 0
  @State private var retryPlayback = 0
  @State private var brightness: CGFloat?
  @AppStorage("play.subtitleSize") private var subtitleSize = 17.0
  @State private var danmakuList = false
  @State private var playbackOptions = false
  @State private var theater = false
  /// Mirrors `theater` without animation, so the cover appears and leaves instantly and only the
  /// system rotation moves.
  @State private var theaterShown = false
  /// Fullscreen fully covers the page: only then is the inline player detached.
  @State private var theaterCovering = false
  @State private var theaterCloseRequest = 0
  @AppStorage("detail.replies") private var showReplies = true
  @State private var panelOverride: Bool?
  @State private var listen = false
  @State private var listenHandoff: UUID?
  @State private var sponsorPanel = false
  @State private var introExpanded = false
  @State private var composeBullet = false
  @State private var bulletSettings = false
  @State private var bulletAt = 0.0
  @State private var bulletDraft = ""
  @State private var commentCount: Int64?
  private var showBullets: Bool {
    get { model.preferences.bullets }
    nonmutating set { model.preferences.bullets = newValue }
  }
  @StateObject private var model = PlayerModel()
  private func archivePlaylist(_ video: Video) -> AnyView? {
    guard (video.pages?.count ?? 0) > 1 || !(video.ugc_season?.sections ?? []).isEmpty else {
      return nil
    }
    return AnyView(
      List {
        if let pages = video.pages, pages.count > 1 {
          Section {
            ForEach(descendingParts ? Array(pages.reversed()) : pages) { part in
              Button {
                if cid != part.cid { cid = part.cid }
              } label: {
                HStack {
                  Text("P\(part.page) · \(part.part)")
                  Spacer()
                  if cid == part.cid {
                    Image(systemName: "speaker.wave.2.fill").accessibilityLabel("正在播放")
                  }
                }
              }
            }
          } header: {
            HStack {
              Text("分 P")
              Spacer()
              Button(descendingParts ? "顺序" : "倒序") {
                descendingParts.toggle()
                if jumpOnReverse { cid = (descendingParts ? pages.last : pages.first)?.cid ?? cid }
              }
            }
          }
        }
        ForEach(video.ugc_season?.sections ?? []) { section in
          Section {
            ForEach(section.ordered(reversedSections)) { entry in
              if let target = entry.playable(by: video.owner?.name) {
                Button {
                  if target.bvid != video.bvid { following = target }
                } label: {
                  HStack {
                    Text(target.title)
                    Spacer()
                    if target.bvid == video.bvid {
                      Image(systemName: "speaker.wave.2.fill").accessibilityLabel("正在播放")
                    }
                  }
                }
              }
            }
          } header: {
            HStack {
              Text(section.title ?? "合集")
              Spacer()
              if queueEnd == nil, (section.episodes?.count ?? 0) > 1 {
                Button(reversedSections.contains(section.id) ? "顺序" : "倒序") {
                  if reversedSections.contains(section.id) {
                    reversedSections.remove(section.id)
                  } else {
                    reversedSections.insert(section.id)
                  }
                  if jumpOnReverse,
                    let first = section.ordered(reversedSections).compactMap({
                      $0.playable(by: video.owner?.name)
                    }).first, first.bvid != video.bvid
                  {
                    following = first
                  }
                }
              }
            }
          }
        }
      }.listStyle(.plain))
  }
  private func keyboardStep(_ forward: Bool) {
    guard let detail, let cid else { return }
    let wrap = model.preferences.repeatMode == .cycle
    let original = (detail.pages ?? []).map(\.cid)
    let parts = descendingParts ? Array(original.reversed()) : original
    let entries = (detail.ugc_season?.sections ?? []).flatMap { $0.ordered(reversedSections) }
      .compactMap { $0.playable(by: detail.owner?.name) }
    if let to = manualNeighbor(
      cid, in: parts, forward: forward, wrap: wrap && entries.isEmpty && queueStep == nil)
    {
      startHint = ArchiveStart(cid: to, seconds: 0)
      self.cid = to
      return
    }
    if following == nil, let queueStep {
      Task { _ = await queueStep(forward, theater) }
      return
    }
    if let id = manualNeighbor(detail.bvid, in: entries.map(\.bvid), forward: forward, wrap: wrap) {
      following = entries.first { $0.bvid == id }
    }
  }
  @MainActor private func playArchive(
    _ video: Video, source: String, cid: Int64, start: Double?, playNow: Bool
  ) async {
    let multiple = (video.pages?.count ?? 0) > 1
    let partTitle = video.pages?.first(where: { $0.cid == cid })?.part
    let title = SystemMediaTitle(
      title: multiple ? (partTitle ?? video.title) : video.title, artist: video.owner?.name,
      cover: video.cover)
    let step: ((Bool) -> Void)?
    if queueStep != nil || multiple || video.ugc_season != nil {
      step = { forward in self.keyboardStep(forward) }
    } else {
      step = nil
    }
    await model.load(
      source, cid: cid, aid: video.aid, start: start, rememberPart: multiple, playNow: playNow,
      mediaTitle: title, step: step)
  }
  private func videoSurface(_ video: Video) -> some View {
    let decoration = ZStack(alignment: .bottom) {
      if showBullets && !theater {
        BulletOverlay(
          items: model.bullets, time: model.seconds, revision: model.revision,
          clock: model.engine, inspector: bulletInspector)
      }
    }
    let input = ZStack {
      // With autoplay the player stays black until the first frame, like the original client;
      // the cover only stands in when playback waits for a tap.
      if !autoplay && !model.hasPlayed && !model.playing && model.seconds < 0.25, let cover = video.cover {
        SiteThumbnail(url: cover) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }.allowsHitTesting(false).accessibilityHidden(true)
      }
      if model.ready {
        PlayerGestures(
          model: model, inspector: showBullets && tapBullet ? bulletInspector : nil,
          enterTheater: { theater = true })
      }
      if showBullets && tapBullet {
        PinnedBullet(
          inspector: bulletInspector, cid: cid, duration: model.duration, seek: model.seek)
      }
      if let error = model.error {
        VStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
          Text("视频加载失败").font(.headline)
          Text(error).font(.caption).foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center).lineLimit(3)
          Button { retryPlayback += 1 } label: {
            Label("重新播放", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold))
          }
          .piliButtonStyle(.glass).padding(.top, 4)
        }
        .foregroundStyle(.white).padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
      } else if !model.ready && detailError == nil {
        DelayedSpinner()
      }
      if model.ready && model.error == nil { PlayerBufferingIndicator(player: model.engine) }
      StoryFinish(model: model)
      if let offer=continueBadge(video){VStack{Spacer();HStack{offer;Spacer()}.padding(.leading,8)}.padding(.bottom,52)}
    }
    return Theater(
      player: model.engine, overlay: AnyView(decoration), interaction: AnyView(input),
      caption: AnyView(PlaybackCaption(model: model)),
      marks: AnyView(ViewportMarks(model: model)),timeline:model.timeline, detached: theaterCovering, toggle: model.toggle,
      seek: model.seek, expand: { theater = true }, upscale: model.upscale
    ).environment(\.styledSubtitles,model.captions)
    .environment(\.playerChrome, inlineChrome(video))
    .modifier(
      PlayerKeyboard(
        player:model.engine,toggle:{
          if model.ready{model.toggle()}else if let cid{manualTicket=ticket(video,cid);retryPlayback+=1}
        },fullscreen:{theater=true},bullets:{showBullets.toggle()},step:keyboardStep,foreground:!theater,
        model:model,item:.init(bvid:video.bvid,aid:video.aid ?? ArchiveNumber.av(video.bvid),episode:nil,copyright:video.copyright),cid:cid,creator:detail?.bvid==video.bvid && (video.staff ?? []).isEmpty ? video.owner?.mid:nil,bvid:video.bvid)
    )
  }
  /// Portrait player tools in the original client's places: header right = listen, cast,
  /// danmaku settings, picture in picture, more; bottom = previous/next after the time, then
  /// episodes, subtitles, speed, and quality when wide.
  private func inlineChrome(_ video: Video) -> PlayerChromeSlots {
    let steps =
      queueStep != nil || (video.pages?.count ?? 0) > 1 || !(video.ugc_season?.sections ?? []).isEmpty
    return PlayerChromeSlots(
      headerTrailing: AnyView(
        HStack(spacing: 0) {
          if let detail, let cid {
            Button {
              let time = model.seconds
              model.engine.pause()
              model.playing = false
              listenHandoff = ListenQueue.shared.handoff(ListenTrack(detail, cid: cid, origin: listenOrigin), at: time)
              listen = true
            } label: { PlayerGlyph(symbol: "headphones") }.accessibilityLabel("听视频")
          }
          PlayerCastButton(player: model.engine, subject: .archive(bvid: video.bvid, aid: video.aid,
            cid: cid, title: video.title, quality: model.quality))
          Button { bulletSettings = true } label: { PlayerGlyph(symbol: "text.bubble.badge.gearshape") }
            .accessibilityLabel("弹幕设置")
          PlayerPiPButton(player: model.engine)
          Button { playbackOptions = true } label: { PlayerGlyph(symbol: "ellipsis") }
            .accessibilityLabel("更多设置")
        }),
      bottomTrailing: AnyView(
        HStack(spacing: 0) {
          PlayerCaptionMenu(session: model.captions)
          PlayerSpeedMenu(model: model)
        }),
      bottomLeading: steps ? AnyView(PlayerStepButtons { keyboardStep($0) }) : nil,
      bottomEpisode: archivePlaylist(video).map { list in
        AnyView(PlayerEpisodeButton(list: list) { theater = true })
      },
      bottomWide: AnyView(PlayerQualityMenu(model: model)))
  }
  private func continueBadge(_ video:Video)->AnyView?{
    guard continuePart,cid==offeredOn,let mark=offeredPart,let part=video.pages?.first(where:{$0.cid==mark.cid}) else{return nil}
    return AnyView(Button{
      guard offeredOn==cid,offeredPart?.cid==mark.cid else{return}
      offeredPart=nil;startHint=mark;cid=mark.cid
    }label:{Label("继续看 P\(part.page)",systemImage:"play.fill").font(.caption.bold()).padding(7)
      .foregroundStyle(.white).background(.black.opacity(0.75),in:Capsule())}.buttonStyle(.plain))
  }
  private func videoInfo(_ video: Video) -> some View {
    let pickPart = $cid
    let refreshPart = $retryPlayback
    let hasDescription = !(video.desc ?? "").isEmpty || !(video.desc_v2 ?? []).isEmpty
    return LazyVStack(alignment: .leading, spacing: 18) {
      creatorRow(video)
      VStack(alignment: .leading, spacing: 10) {
        ArchiveMetadata(video:video,labels:sponsorEnabled ? Array(Set(model.sponsor.compactMap{
          $0.valid && $0.segment==[0,0] && model.sponsorRules.mode($0) != 4 ? $0.detail?.title:nil
        })).sorted():[], expanded: introExpanded, toggle: { introExpanded.toggle() })
        OnlineViewers(timeline:model.timeline,fallback:cid.map{.init(bvid:video.bvid,aid:video.aid,cid:$0)})
          .font(.footnote).foregroundStyle(.secondary)
        if showArgue, let text = video.argue_info?.argue_msg, !text.isEmpty {
          Label(text, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
        }
        if hasDescription && introExpanded {
          ArchiveDescription(video: video, wide: wideViewport, cid:cid, duration:model.duration > 0 ? model.duration : video.pages?.first(where:{$0.cid == cid})?.duration.map(Double.init), seek: { t in
            if model.ready && model.duration > 0 { model.seek(min(t, model.duration)) }
          }, expanded: true).id(video.bvid)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      EngagementBar(
        item: .init(bvid: video.bvid, aid: video.aid, episode: nil, copyright: video.copyright),
        counts: .init(like: video.stat?.like, coin: video.stat?.coin, favorite: video.stat?.favorite),
        extras: detail.flatMap { d in cid.map { c in AnyView(
          VideoActions(
            video: d, cid: c, model: model, seconds: { model.seconds },
            onBullet: { model.didPost($0, cid: c) }, openComments: { panelOverride = true }))
        } })
      // The original has no tool row under the intro: these live in the player's 更多 sheet.
      Color.clear.frame(height: 0)
        .piliSheet(isPresented: $playbackOptions) { ArchivePlaybackOptions(model: model, actions: moreActions) }
        .piliSheet(isPresented: $bulletSettings) {
          PiliNavigationStack {
            DanmakuStylePanel().toolbar { Button("完成") { bulletSettings = false } }
          }
          .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .piliSheet(isPresented: $danmakuList) {
          if let currentCID = cid {
            PiliNavigationStack {
              DanmakuList(cid:currentCID,aid:video.aid,duration:model.duration,current:model.seconds,
                seek:model.seek,snapshot:{bulletInspector.snapshot?() ?? []})
                .toolbar { Button("关闭") { danmakuList = false } }
            }
          }
        }
        .onChange(of: sponsorEnabled) { _, _ in Task { await model.reloadSponsors() } }
        .onChange(of: blockRules) { _, _ in Task { await model.reloadSponsors() } }
      if let error = model.bulletError, showBullets {
        HStack {
          Text(error).piliFont(.caption).foregroundStyle(.secondary)
          Button("重试") { model.retryBullets() }.piliButtonStyle(.glass).controlSize(.small)
        }
      }
      if let error = model.qualityError {
        Text(error).piliFont(.caption).foregroundStyle(.secondary)
      }
      if let pages = detail?.pages, pages.count > 1 {
        ArchivePartStrip(pages: pages, current: cid, descending: descendingParts) { picked in
          cid = picked
        } reorder: {
          descendingParts.toggle()
          if jumpOnReverse, let next = (descendingParts ? pages.last : pages.first), next.cid != cid {
            startHint = ArchiveStart(cid: next.cid, seconds: 0)
            cid = next.cid
          }
        }
      }
      if let detail, let cid {
        VideoExtras(
          video: detail, cid: cid, jump: { model.seek($0) },
          choose: {
            pickPart.wrappedValue = $0
            refreshPart.wrappedValue += 1
          }, model: model, story: interactiveStory, reversedSections: $reversedSections,
          canReverseCollection: queueEnd == nil, playCollection:{next,part in
            if next.bvid==video.bvid{if let part{pickPart.wrappedValue=part}}else{sidebarPart=part.map{(next.bvid,$0)};following=next}
          },
          showOwner: useMemberPanel ? { sideAuthor = video.owner } : nil)
      }
      if let error = detailError {
        VStack(spacing: 10) {
          Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("重新加载详情") { reload += 1 }.piliButtonStyle(.glass)
        }.frame(maxWidth: .infinity)
      }
      if detail != nil {
        IntroRelated {
          Divider()
          ArchiveRelatedList(bvid: video.bvid)
        }
      }
    }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 24)
      .animation(.easeOut(duration: 0.25), value: detail?.bvid)
      .animation(.snappy(duration: 0.3), value: introExpanded)
  }
  @ViewBuilder private func creatorRow(_ video: Video) -> some View {
    if let owner = video.owner?.name {
      let identity = HStack(spacing: 10) {
        ProfileAvatar(url: video.owner?.avatar, size: 38)
        Text(owner).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
      }
      HStack(spacing: 12) {
        if useMemberPanel, video.owner?.mid != nil {
          Button {
            TouchFeedback.light()
            sideAuthor = video.owner
          } label: { identity }.buttonStyle(.plain)
        } else if let mid = video.owner?.mid {
          NavigationLink {
            CreatorSpace(mid: mid, name: owner)
          } label: { identity }.buttonStyle(.plain).piliTapFeedback()
        } else {
          identity
        }
        Spacer(minLength: 8)
        if (video.staff ?? []).isEmpty, let mid = video.owner?.mid {
          CreatorQuickRelation(mid: mid).controlSize(.small)
        }
      }
    }
  }
  /// Secondary tools on one horizontally scrolling line of quiet chips.
  /// Hands the 更多 sheet the page's own panels (listen, danmaku list/settings, SponsorBlock).
  private var moreActions: ArchiveMoreActions {
    var a = ArchiveMoreActions(video: detail, cid: cid, story: interactiveStory)
    if let detail, let cid {
      a.listen = {
        let time = model.seconds
        model.engine.pause()
        model.playing = false
        listenHandoff = ListenQueue.shared.handoff(ListenTrack(detail, cid: cid, origin: listenOrigin), at: time)
        listen = true
      }
      a.enqueue = { ListenQueue.shared.add(ListenTrack(detail, cid: cid, origin: listenOrigin)) }
      a.danmakuList = { danmakuList = true }
    }
    a.danmakuSettings = { bulletSettings = true }
    if sponsorEnabled { a.sponsor = { sponsorPanel = true } }
    a.reload = { retryPlayback += 1 }
    return a
  }
  /// Tab bar accessory: send a bullet and toggle bullets, as in the original client.
  private var bulletAccessory: some View {
    HStack(spacing: 4) {
      Button {
        guard accounts.state.active != nil, cid != nil else { return }
        bulletAt = model.seconds
        withAnimation(.snappy(duration: 0.25)) { composeBullet = true }
      } label: {
        Text("发弹幕").font(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
      }.buttonStyle(.plain).disabled(accounts.state.active == nil || cid == nil)
      Button {
        TouchFeedback.light()
        showBullets.toggle()
      } label: {
        Image(systemName: showBullets ? "text.bubble.fill" : "text.bubble")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(showBullets ? Color.accentColor : Color.secondary)
          .frame(width: 36, height: 36).contentShape(Rectangle())
          .contentTransition(.symbolEffect(.replace))
      }.buttonStyle(.plain).accessibilityLabel(showBullets ? "关闭弹幕" : "开启弹幕")
    }
  }

  @ViewBuilder private func detailPanels(source: Video, video: Video, deferred: (() -> Void)?) -> some View {
PlaybackPanels(
  model: model, key: source.bvid, canDiscuss: showReplies, selection: $panelOverride,
  full: { theater = true }, startDeferred: deferred, playlist: JoinedPlaybackPanels.merge(libraryPanel, archivePlaylist(video), fullscreen: false), creator: creatorPanel,
  accessory: AnyView(bulletAccessory),
  commentCount: commentCount ?? (detail ?? video).stat?.reply.map(Int64.init),
  related: detail != nil && relatedShown ? AnyView(ArchiveRelatedList(bvid: video.bvid).id(video.bvid)) : nil
) {
  if let cid, prepared == ticket(video, cid) {
    videoSurface(video)
  } else {
    PlaybackCover(title: video.title, url: video.cover, enabled: cid != nil) {
      guard let cid, detailOwner == (accounts.state.active ?? "") else { return }
      manualTicket = ticket(video, cid)
      retryPlayback += 1
    }
  }
} info: {
  ScrollView {
    videoInfo(video).frame(maxWidth: .infinity, alignment: .leading)
  }.defaultScrollAnchor(.top).reportsScrollCollapse().id(source.bvid)
} replies: {
  if let aid = video.aid ?? ArchiveNumber.av(video.bvid) {
    Discussion(
      oid: aid, type: 1, owner: video.owner?.mid, intro: video.desc, embeddedTitle: "视频",
      readingCount: { n in commentCount = n }, mentionOwnerName: video.owner?.name
    ).environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model)).id(aid)
  } else {
    ContentUnavailableView("未找到评论区", systemImage: "text.bubble")
  }
}
  }

  var body: some View {
    let source = following ?? initial
    let video = detail ?? following ?? initial
    let firstPage = following == nil ? initialPage : 1
    let startSeconds = following == nil ? initialSeconds : 0
    let deferred: (() -> Void)? = cid.flatMap { target in
      let key = ticket(video, target)
      guard prepared != key, detailOwner == (accounts.state.active ?? "") else { return nil }
      return { manualTicket = key; retryPlayback += 1 }
    }
    return detailPanels(source: source, video: video, deferred: deferred)
      .onGeometryChange(for: Bool.self) {
      $0.size.width > $0.size.height && $0.size.width >= 540
    } action: {
      wideViewport = $0
      if !$0 { sideAuthor = nil }
    }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
      .linkedDiscussion(oid: detail?.aid ?? detail.flatMap { ArchiveNumber.av($0.bvid) }, type: 1, author: detail?.owner?.mid,
        playback: ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model),
        selectComments:{if showReplies {sideAuthor=nil;panelOverride=true}})
      .task(id: "\(reload)|\(accounts.state.active ?? "")|\(source.bvid)") {
        let uid = accounts.state.active
        let pickedPart = sidebarPart.flatMap { $0.bvid == source.bvid ? $0.cid : nil }
        sidebarPart = nil
        sideAuthor = nil
        detailError = nil
        offeredPart=nil;offeredOn=nil
        cid = nil
        detail = nil
        detailOwner = nil
        startHint = nil
        do {
          let v = try await BiliAPI.shared.detail(source.bvid)
          try Task.checkCancellation()
          let parts = v.pages ?? []
          let first = parts.first?.cid ?? v.cid
          let requestedCID = following == nil ? initialCID : pickedPart
          if let id = requestedCID, id != v.cid, !parts.contains(where: { $0.cid == id }) {
            throw ServiceError("视频没有这个分 P")
          }
          let explicitPage = requestedCID.flatMap { id in parts.first { $0.cid == id }?.page } ?? firstPage
          let mark =
            following == nil && requestedCID == nil && firstPage == nil && startSeconds == nil ? libraryPoint : nil
          let pageFromList = parts.first(where: { $0.cid == mark?.cid })?.page
          let pointFromList =
            (pageFromList != nil || (mark != nil && mark?.cid == v.cid)) ? mark : nil
          var remote: ServiceWatchPoint?
          if pointFromList==nil,startSeconds==nil,let uid,
             PlaybackMemory.enabled || (continuePart && parts.count>1),
             let readCID=requestedCID ?? explicitPage.flatMap({p in parts.first(where:{$0.page==p})?.cid}) ?? first{
            let api = BiliAPI.shared
            if let q = try? await api.sign(["bvid":v.bvid,"cid":String(readCID)]) {
              remote = try? await api.read(
                "/x/player/wbi/v2", q, expectedAccount: uid, as: ServiceWatchPoint.self)
            }
          }
          try Task.checkCancellation()
          guard accounts.state.active == uid else { return }
          detail = v
          detailOwner = uid ?? ""
          startHint = ArchiveStart.select(
            parts, fallback: v.cid,
            page: (following != nil && pickedPart == nil && descendingParts ? parts.last?.page : explicitPage)
              ?? pageFromList,
            from: startSeconds ?? pointFromList?.seconds,
            continuePart: false,
            local: LastArchivePart.recall(LastArchivePart.key(v.bvid, uid: uid)), remote: remote,
            saveTime: PlaybackMemory.enabled)
          cid=startHint?.cid
          if following==nil,requestedCID==nil,firstPage==nil,startSeconds==nil,pointFromList==nil{
            offeredOn=cid
            offeredPart=ArchiveStart.offer(parts,current:cid,enabled:continuePart,local:LastArchivePart.recall(LastArchivePart.key(v.bvid,uid:uid)),remote:remote,keepTime:PlaybackMemory.enabled)
          }
          if cid == nil { detailError = "没有可播放的分集" }
        } catch { if !Task.isCancelled { detailError = error.localizedDescription } }
      }
      .task(id:"\(source.bvid):\(offeredPart?.cid ?? 0):\(prepared?.cid ?? 0)"){
        guard offeredPart != nil,prepared != nil else{return}
        do{try await Task.sleep(for:.seconds(4))}catch{return};offeredPart=nil
      }
      .task(id: "\(source.bvid):\(detail?.bvid ?? ""):\(cid ?? 0):\(accounts.state.active ?? ""):\(interactiveStory.revision)") {
        guard let current = detail, current.bvid == source.bvid, let cid else {
          interactiveStory.clear(); model.clearStory(); return
        }
        let choice = $cid, restart = $retryPlayback
        await interactiveStory.open(.init(bvid: current.bvid, cid: cid, owner: accounts.state.active ?? ""),
          root: current.cid ?? current.pages?.first?.cid, interactive: current.rights?.is_stein_gate == 1, reader: .site, model: model) { target in
          choice.wrappedValue = target; restart.wrappedValue += 1
        }
      }
      .task(id: "\(source.bvid):\(cid ?? 0):\(retryPlayback):\(accounts.state.owner(.role(.video)) ?? "")") {
        let presentation = $theater
        let selection = $cid
        let nextArchive = $following
        let chain = $visited
        let hint = $startHint
        let outside = following == nil ? queueEnd : nil
        let partOrder = $descendingParts
        let sectionOrder = $reversedSections
        let activePart = cid
        model.queueEnd = { mode, valid in
          guard let cid = activePart, valid() else { return .end }
          let original = (video.pages ?? []).map(\.cid)
          let parts = partOrder.wrappedValue ? Array(original.reversed()) : original
          let entries = (video.ugc_season?.sections ?? []).flatMap {
            $0.ordered(sectionOrder.wrappedValue)
          }.compactMap { $0.playable(by: video.owner?.name) }
          if parts.count > 1,
            let to = mode.after(cid, in: parts, wrap: outside == nil && entries.isEmpty), to != cid
          {
            hint.wrappedValue = ArchiveStart(cid: to, seconds: 0)
            selection.wrappedValue = to
            return .advanced
          }
          if let outside {
            let result = await outside(presentation.wrappedValue, mode)
            if result == .restart, let first = parts.first, first != cid {
              hint.wrappedValue = ArchiveStart(cid: first, seconds: 0)
              selection.wrappedValue = first
              return .advanced
            }
            if result != .end { return result }
          } else if let id = mode.after(video.bvid, in: entries.map(\.bvid)),
            let dest = entries.first(where: { $0.bvid == id })
          {
            if dest.bvid == video.bvid { return .restart }
            nextArchive.wrappedValue = dest
            return .advanced
          }
          if mode == .cycle && outside == nil { return .restart }
          if mode == .related
            && (UserDefaults.standard.object(forKey: "detail.related") as? Bool ?? true)
          {
            do {
              let items = try await BiliAPI.shared.read(
                "/x/web-interface/archive/related", ["bvid": video.bvid], as: [Video].self)
              let seen = Set(chain.wrappedValue + [video.bvid])
              let filtering = Task.detached(priority: .userInitiated) {
                let policy = RecommendationFilter()
                return items.first { !Task.isCancelled && !seen.contains($0.bvid) && policy.allows($0, from: .related) }
              }
              let destination = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
              guard !Task.isCancelled, valid(), let dest = destination
              else { return .end }
              chain.wrappedValue = Array((chain.wrappedValue + [video.bvid]).suffix(80))
              nextArchive.wrappedValue = dest
              return .advanced
            } catch { return .failed }
          }
          return .end
        }
        if let cid, detailOwner == (accounts.state.active ?? "") {
          let key = ticket(video, cid)
          let mode = PlaybackEntryPolicy.mode(preinitialize: early, autoplay: autoplay,
            manual: manualTicket == key,
            continuation: outside != nil || following != nil || (lastOpened != nil && lastOpened != cid))
          lastOpened = cid
          if mode == .cover {
            prepared = nil; model.stop(); return
          }
          let start = startHint?.cid == cid ? startHint?.seconds : nil
          startHint = nil
          prepared = key
          await playArchive(video, source: source.bvid, cid: cid, start: start, playNow: mode == .play)
        } else {
          prepared = nil; manualTicket = nil; model.stop()
        }
      }.onChange(of: early) { _, enabled in
        if cid != nil && (prepared == nil || (!enabled && !autoplay && !model.hasPlayed && !model.playing)) {
          retryPlayback += 1
        }
      }.onChange(of: autoplay) { _, enabled in
        if enabled && cid != nil && prepared == nil { retryPlayback += 1 }
      }.modifier(
        AutoTheater(
          model: model, cid: cid, presented: $theater, inheritPresentation: resumeFullscreen)
      )
      .modifier(RotateToFullscreen(
        theater: $theater,
        // Only on a phone-sized window: the Duo's inner display and iPad ignore orientation
        // locks, and there turning the device just resizes the page.
        enabled: UIDevice.current.userInterfaceIdiom == .phone && !WindowCanvas.shared.large
          && !horizontal && cid != nil))
      .onChange(of: theater, initial: true) { _, open in
        if !open && theaterShown {
          // Closed from outside (turning the phone upright, end of video): fullscreen runs its
          // own exit (rotate upright, shrink back) and then dismisses itself.
          theaterCloseRequest += 1
        } else {
          var t = Transaction()
          t.disablesAnimations = true
          withTransaction(t) { theaterShown = open }
        }
      }
      .piliFullScreenCover(
        isPresented: Binding(get: { theaterShown }, set: { open in
          theaterShown = open
          if !open { theaterCovering = false }
          if theater != open { theater = open }
        })
      ) {
        TheaterSheet(
          subject: cid.map { TheaterSubject(cid: $0, oid: video.aid ?? ArchiveNumber.av(video.bvid), type: 1,
            bvid: video.bvid, aid: video.aid ?? ArchiveNumber.av(video.bvid), creator: video.owner?.mid,
            introduction: video.desc, interactive: video.rights?.is_stein_gate == 1, comments: showReplies,shortcutCanFollow: detail?.bvid==video.bvid && (video.staff ?? []).isEmpty) },
          playlist: JoinedPlaybackPanels.merge(libraryPanel, archivePlaylist(video), fullscreen: true),continueBadge:continueBadge(video),
          title: (video.pages?.count ?? 1) > 1
            ? video.pages?.first { $0.cid == cid }?.part ?? video.title : video.title,
          model:model, keyStep: keyboardStep,
          origin: { [player = model.engine] in InlinePlayerFrame.current(player) },
          covered: { theaterCovering = $0 }, closeRequest: theaterCloseRequest,
          engagement: video.aid.map {
            EngagementItem(bvid: video.bvid, aid: $0, episode: nil, copyright: video.copyright)
          })
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if composeBullet, let uid = accounts.state.active, let cid {
          BulletQuickBar(
            cid: cid, bvid: video.bvid, uid: uid, time: { model.seconds },
            posted: { model.didPost($0, cid: cid) },
            close: { withAnimation(.snappy(duration: 0.25)) { composeBullet = false } },
            draft: $bulletDraft)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .onChange(of: source.bvid) { _, _ in
        introExpanded = false; bulletDraft = ""; commentCount = nil; composeBullet = false
      }
      .piliSheet(isPresented: $sponsorPanel) {
        PiliNavigationStack {
          SponsorList(model: model).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { sponsorPanel = false } }
          }
        }
        .presentationDetents([.medium, .large])
      }
      .piliSheet(isPresented: $listen, onDismiss: {
        if let token = listenHandoff, let cid, let position = ListenQueue.shared.returnPosition(token, bvid: video.bvid, cid: cid) {
          model.seek(position)
        }
        listenHandoff = nil
      }) {
        PiliNavigationStack {
          ListenView().toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { listen = false } }
          }
        }
      }
      .modifier(VideoPageAppearance()).modifier(PlaybackEdgeInsets())
      .onAppear { if brightness == nil { brightness = WindowMetrics.brightness } }
      .onDisappear {
        if !theater && !sponsorPanel && !playbackOptions && !danmakuList && !listen {
          model.stop()
          if let brightness { WindowMetrics.brightness = brightness }
          brightness = nil
        }
      }
  }
}
