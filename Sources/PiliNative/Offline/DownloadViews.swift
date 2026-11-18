import AVKit
import SwiftUI

struct DownloadsView: View { var body: some View { OfflineShelfView() } }
struct DownloadRow: View {
  let v: OfflineVideo, play: (OfflineVideo) -> Void
  @ObservedObject private var downloads = Downloads.shared
  private var playable: Bool { v.cacheOwner != nil && v.phase == .saved }
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      OfflineCoverCell(row: v, size: CGSize(width: 140, height: 79))
        .overlay {
          if playable {
            Image(systemName: "play.fill").font(.footnote).foregroundStyle(.white)
              .frame(width: 30, height: 30).background(.black.opacity(0.35), in: Circle())
          }
        }
      VStack(alignment: .leading, spacing: 4) {
        Text(v.title).font(.subheadline.weight(.medium)).lineLimit(2)
        if !v.part.isEmpty && v.part != v.title {
          Text(v.part).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        status
        OfflineLocationStatus(video: v)
      }
      .frame(maxWidth: .infinity, minHeight: 79, alignment: .topLeading)
      if v.cacheOwner != nil && v.phase == .saved {
        Menu {
          Button("离线播放", systemImage: "play") { play(v) }
          ForEach([OfflineAttachment.comments, .captions, .segments, .art, .all]) { m in
            Button(m.rawValue) { Task { await downloads.refreshExtras(v, mode: m) } }
          }
          NavigationLink("查看缓存片段") { DeferredPage { OfflineMarkerList(v: v) } }
        } label: {
          Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 28, height: 36).contentShape(Rectangle())
        }.accessibilityLabel("管理附件")
      }
    }
    .padding(.vertical, 4)
    .buttonStyle(.borderless)
    .contentShape(Rectangle())
    .onTapGesture { if playable { play(v) } }
    .animation(.easeOut(duration: 0.2), value: v.phase)
  }


  @ViewBuilder private var status: some View {
    if v.cacheOwner == nil {
      VStack(alignment: .leading, spacing: 4) {
        Text("旧缓存未记录视频账号").font(.caption).foregroundStyle(.secondary)
        Button("重新取得授权并缓存") { Task { await downloads.renewLegacy(v) } }.font(.caption)
      }
    } else {
      switch v.phase {
      case .queued:
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("正在获取地址")
        }.font(.caption).foregroundStyle(.secondary)
      case .transferring:
        let value = downloads.progress[v.id] ?? 0
        HStack(spacing: 8) {
          ProgressView(value: value).tint(.accentColor)
          Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          Button { Task { await downloads.pause(v) } } label: {
            Image(systemName: "pause.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
          }.accessibilityLabel("暂停")
        }
      case .paused:
        HStack(spacing: 8) {
          Text("已暂停").font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button { Task { await downloads.pause(v) } } label: {
            Image(systemName: "play.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
          }.accessibilityLabel("继续下载")
        }
      case .saved:
        VStack(alignment: .leading, spacing: 2) {
          OfflineReceiptLine(row: v)
          if let q = v.quality {
            Text(StreamQuality.name(q)).font(.caption2).foregroundStyle(.tertiary)
          }
          if let msg = v.extrasIssue { Text(msg).font(.caption2).foregroundStyle(.secondary) }
        }
      case .failed:
        HStack(spacing: 8) {
          Text(v.error ?? "下载中断").font(.caption).foregroundStyle(.red).lineLimit(2)
          Spacer(minLength: 0)
          Button("重试") { Task { await downloads.start(v) } }.font(.caption.weight(.semibold))
        }
      }
    }
  }
}
struct OfflinePlayer: View {
  @StateObject private var upscale = UpscaleSession()
  @StateObject private var systemMedia = SystemMediaControls()
  @StateObject private var inspector = BulletInspector()
  @AppStorage("dm.tap") private var tapBullet = true
  @AppStorage("theater.lockButton") private var lockButton = true
  @AppStorage("theater.captureButton") private var captureButton = true
  @State private var locked=false
  @AppStorage(SpeedPresets.key) private var speedList=Data()
  @AppStorage("play.rate") private var regularSpeed=1.0
  var sessionSpeed:Binding<Float?>?=nil
  let video: OfflineVideo
  var previous: (() -> Void)? = nil
  var next: (() -> Void)? = nil
  var rewindList: (() -> Void)? = nil
  let playingRows:[OfflineVideo]
  let pickOffline:((OfflineVideo)->Void)?
  @State private var showPlayingRows=false
  init(video:OfflineVideo,previous:(()->Void)?=nil,next:(()->Void)?=nil,rewindList:(()->Void)?=nil,sessionSpeed:Binding<Float?>?=nil,playingRows:[OfflineVideo]=[],pickOffline:((OfflineVideo)->Void)?=nil){
    self.video=video;self.previous=previous;self.next=next;self.rewindList=rewindList;self.sessionSpeed=sessionSpeed;self.playingRows=playingRows;self.pickOffline=pickOffline
  }
  @EnvironmentObject private var accounts: AccountContext
  @State private var resumeID: String?
  @State private var resumeViewer: String?
  @State private var cachedSegments: [SponsorSegment] = []
  @State private var sponsorVisits = SponsorVisits()
  @State private var lastSaved = -1
  @AppStorage("play.episodeSkip") private var skipMode = EpisodeSkipMode.once.rawValue
  @State private var skipHistory = EpisodeSkipHistory()
  @State private var player: AVPlayer?
  @State private var observer: Any?
  @State private var seconds = 0.0
  @StateObject private var captions=SubtitleSession()
  @State private var bullets: [Bullet] = []
  @State private var revision = UUID()
  @StateObject private var sessionPrefs = PlayerSessionPreferences()
  private var showComments: Bool {
    get { sessionPrefs.bullets }
    nonmutating set { sessionPrefs.bullets = newValue }
  }
  private var dir: URL { Downloads.shared.extraDirectory(video) }
  private var segment: Int { 1 + Int(seconds) / 360 }
  @State private var issue: String?
  @Environment(\.dismiss) var dismiss
  private func seek(_ player: AVPlayer, _ t: Double) {
    guard t.isFinite, t >= 0 else { return }
    OfflineDecoderItem.aboutToSeek(player, to: t)
    player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }
  private func closePlayer() {
    if let player {
      if player.defaultRate>0{sessionSpeed?.wrappedValue=player.defaultRate}
      if let observer { player.removeTimeObserver(observer); self.observer = nil }
      if let key = resumeID {
        if Downloads.shared.list.contains(where: { $0.token == key }) {
          OfflineWatchBook.store(
            key, viewer: resumeViewer, seconds: player.currentTime().seconds,
            duration: player.currentItem?.duration.seconds ?? 0)
        }
      }
      PlaybackSleepTimer.shared.unbind(player)
      OfflineDecoderItem.stop(player)
      player.pause(); player.replaceCurrentItem(with: nil)
    }
    systemMedia.close(); player = nil; resumeID = nil
  }
  private func offlineScreen(_ player: AVPlayer) -> some View {
    let overlay = ZStack {
      if showComments {
        BulletOverlay(
          items: bullets, time: seconds, revision: revision, clock: player,
          inspector: inspector, fullscreen: true)
      }
    }
    let input = ZStack(alignment: .topTrailing) {
      FilePlayerGestures(player:player,inspector:showComments && tapBullet ? inspector:nil,exit:{dismiss()})
      if showComments && tapBullet {
        PinnedBullet(
          inspector: inspector, cid: video.cid, duration: player.currentItem?.duration.seconds ?? 0,
          seek: { t in seek(player, t) })
      }
      if UserDefaults.standard.bool(forKey: "sponsor.enabled"),
        let s = cachedSegments.first(where: {
          $0.valid && SponsorRules.current().mode($0) == 2 && $0.segment[0] <= seconds
            && seconds < $0.segment[1]
        })
      {
        Button("跳过" + (s.detail?.title ?? "片段")) { seek(player, s.segment[1]) }.buttonStyle(
          .borderedProminent)
      }
      if let clip =
        (Downloads.shared.list.first(where: { $0.token == video.token })?.episodeClips
        ?? video.episodeClips)?.first(where: { $0.contains(seconds) })
      {
        if skipMode == EpisodeSkipMode.manual.rawValue {
          Button("跳过" + clip.title) {
            seek(player, clip.end)
          }
          .buttonStyle(.borderedProminent).padding(6)
        } else if skipMode == EpisodeSkipMode.show.rawValue {
          Text(clip.title).padding(5).background(.thinMaterial, in: Capsule()).padding(6)
        }
      }
    }
    let line=captions.timeline.active(at:seconds)
    return Theater(
      player: player, overlay: AnyView(overlay), showsControls: !locked, interaction: locked ? nil : AnyView(input),
      caption: line.map { AnyView(CaptionLine(text: $0, fullscreen:true,interactive: !locked, controlInset: 32)) },
      fullscreen: true, seek:{seek(player,$0)},expand:{dismiss()},upscale: upscale
    ).environment(\.styledSubtitles,captions)
    .modifier(
      PlayerKeyboard(
        player:player,locked:locked,fullscreen:{locked=false;dismiss()},bullets:{showComments.toggle()},lock:{locked.toggle();inspector.pick=nil},
        step:(next != nil || previous != nil) ? {forward in if forward{next?()}else{previous?()}}:nil,allowCapture:true,full:true,cid:video.cid,skipOffline:{
          let t=player.currentTime().seconds;guard t.isFinite else{return false}
          if UserDefaults.standard.bool(forKey:"sponsor.enabled"),let s=cachedSegments.last(where:{$0.valid && SponsorRules.current().mode($0)==2 && $0.segment[0]<=t && t<$0.segment[1]}){seek(player,s.segment[1]);return true}
          if skipMode==EpisodeSkipMode.manual.rawValue,let clip=video.episodeClips?.first(where:{$0.contains(t)}){seek(player,clip.end);return true}
          return false
        }))
  }
  @ViewBuilder private func playerContent() -> some View {
  Group {
    if let player {
      offlineScreen(player)
    } else if let issue {
      Text(issue)
    } else {
      ProgressView()
    }
  }
  .modifier(PlaybackEdgeInsets(fullscreen: true))
  .navigationTitle(video.part.isEmpty ? video.title : video.part).navigationBarTitleDisplayMode(
    .inline
  )
  .interactiveDismissDisabled(locked)
  .toolbar {
    if lockButton || locked{
      Button {locked.toggle();inspector.pick=nil} label:{Image(systemName:locked ? "lock.fill":"lock.open")}
        .accessibilityLabel(locked ? "解锁播放控件":"锁定播放控件")
    }
    if !locked{
    Menu {
      Toggle("弹幕", isOn: sessionPrefs.binding(\.bullets))
      NavigationLink("缓存片段") { DeferredPage { OfflineMarkerList(v: video) } }
      if let player{NavigationLink("播放信息"){ArchiveProgramInfo(player:player)}}
      if let player{
        Menu("播放速度"){ForEach(SpeedPresets.decode(speedList),id:\.self){speed in
          Button(speed.formatted()+"×"){player.defaultRate=Float(speed);sessionSpeed?.wrappedValue=Float(speed)
            if let item=player.currentItem{VideoTransport.prepare(player,item)}
            if player.rate != 0{player.rate=Float(speed)}
          }
        }}
      }
      RepeatPicker(session: sessionPrefs)
      SessionPlaybackSettings(session: sessionPrefs)
    } label: {
      Label("字幕和弹幕", systemImage: "captions.bubble")
    }
    SubtitleButton(session:captions,title:video.part.isEmpty ? video.title:video.part,cid:video.cid).labelStyle(.iconOnly)
    if captureButton,let player { CaptureButton(player: player) }
    if previous != nil || next != nil {
      Menu {
        if pickOffline != nil{Button("查看缓存列表"){showPlayingRows=true}}
        Button("上一集") { previous?() }.disabled(previous == nil)
        Button("下一集") { next?() }.disabled(next == nil)
      } label: {
        Image(systemName: "list.bullet").accessibilityLabel("播放队列")
      }
    }
    SleepTimerButton().labelStyle(.iconOnly)
    Button("关闭") { dismiss() }
    }
  }
  }
private func startPlayer() async {
      closePlayer(); cachedSegments = []; sponsorVisits = SponsorVisits();
      skipHistory = EpisodeSkipHistory(); captions.reset(); bullets = []; revision = UUID()
      issue = nil
      do {
        let i = try await Downloads.shared.playerItem(video)
        try Task.checkCancellation()
        upscale.begin(id: "offline:" + video.token, anime: false)
        let p = AVPlayer(playerItem:i)
        p.defaultRate=sessionSpeed?.wrappedValue ?? (SpeedPresets.valid(regularSpeed) ? Float(regularSpeed):1)
        VideoTransport.prepare(p,i)
        ItemAudioGain.attach(i)
        OfflineDecoderItem.bind(p) { [weak p] message in
          guard let p, player === p else { return }
          closePlayer(); issue = message
        }
        VideoTransport.background(
          p, temporary: sessionPrefs.temporary ? sessionPrefs.background : nil)
        systemMedia.setTemporary(sessionPrefs.temporary ? sessionPrefs.controls : nil)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        systemMedia.bind(
          p,
          title: .init(
            title: video.part.isEmpty ? video.title : video.part,
            artist: video.part.isEmpty ? nil : video.title), next: next, previous: previous)
        player = p
        let key = video.token
        let viewer = accounts.state.active; resumeViewer = viewer; resumeID = key
        cachedSegments = await OfflineExtras.markers(dir)
        try Task.checkCancellation()
        let t = OfflineWatchBook.read(key, viewer: viewer)?.start ?? 0
        if t > 0, let duration = try? await i.asset.load(.duration),
          t < max(0, duration.seconds - 0.4)
        {
          try Task.checkCancellation()
          OfflineDecoderItem.aboutToSeek(p, to: t)
          _ = await p.seek(
            to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
        }
        try Task.checkCancellation()
        PlaybackSleepTimer.shared.bind(p, item: i, handlesEnd: true, onSleep: { [weak p, weak i] in
          guard let p, let i, p.currentItem === i else { return }
          OfflineWatchBook.store(key, viewer: viewer, seconds: p.currentTime().seconds, duration: i.duration.seconds)
        })
        observer = p.addPeriodicTimeObserver(
          forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { t in MainActor.assumeIsolated {
            if t.seconds.isFinite && t.seconds >= 0 && t.seconds < Double(Int32.max) {
            seconds = t.seconds
            if p.rate > 0,
              let marker = video.episodeClips?.first(where: { $0.contains(t.seconds) }),
              let target = skipHistory.target(
                marker, mode: EpisodeSkipMode(rawValue: skipMode) ?? .once)
            {
              seek(p, target)
            }
              if p.rate > 0, UserDefaults.standard.bool(forKey: "sponsor.enabled"),
                let seg = sponsorVisits.next(cachedSegments, time: t.seconds, rules: .current())
              {
                seek(p, seg.segment[1])
              }
            let tick = Int(t.seconds / 6)
            if lastSaved != tick {
              lastSaved = tick
                if Downloads.shared.list.contains(where: { $0.token == key }) {
                  OfflineWatchBook.store(
                    key, viewer: viewer, seconds: t.seconds, duration: i.duration.seconds)
                }
            }
          }
        } }
        p.playImmediately(atRate:p.defaultRate)
        let saved = await OfflineExtras.captions(dir)
        try Task.checkCancellation()
        await captions.offline(saved)
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
private func handlePlayToEnd(_ event: Notification) { event in
      guard let player, let item = event.object as? AVPlayerItem, player.currentItem === item else {
        return
      }
      if let key = resumeID {
        if Downloads.shared.list.contains(where: { $0.token == key }) {
          OfflineWatchBook.store(
            key, viewer: resumeViewer, seconds: item.duration.seconds,
            duration: item.duration.seconds, completed: true)
        }
      }
      guard !PlaybackSleepTimer.shared.didFinish(player) else { return }
      switch sessionPrefs.repeatMode {
      case .pause: break
      case .one:
        seek(player, 0)
        player.play()
      case .order, .related: next?()
      case .cycle:
        if let next {
          next()
        } else if let rewindList {
          rewindList()
        } else {
          seek(player, 0)
          player.play()
        }
      }
      }
  var body: some View {
    PiliNavigationStack {
      playerContent()

    }.piliSheet(isPresented:$showPlayingRows){if let pickOffline{OfflinePlayingList(rows:playingRows,current:video.token,choose:pickOffline)}}.task(
      id: (accounts.state.active ?? "guest") + ":"
        + (accounts.state.owner(.role(.video)) ?? "guest")
    ) { await startPlayer() }.onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in handlePlayToEnd(event) }.onChange(of: sessionPrefs.background) { _, v in
      if let player {
        VideoTransport.background(player, temporary: sessionPrefs.temporary ? v : nil)
      }
    }
    .onChange(of: sessionPrefs.controls) { _, v in
      systemMedia.setTemporary(sessionPrefs.temporary ? v : nil)
    }
    .task(id: String(segment) + ":" + (accounts.state.owner(.role(.video)) ?? "")) {
      guard video.matchesOwner(accounts.state.owner(.role(.video)) ?? "") else {
        bullets = []; return
      }
      let rows = await OfflineExtras.comments(dir, segment: segment)
      if !Task.isCancelled {
        bullets = rows.filter { BulletRecall.shared.visible($0, cid: video.cid) }
        revision = UUID()
      }
    }.onReceive(BulletRecall.shared.changes) { key in
      if key.cid == video.cid {
        bullets.removeAll { $0.entryID == key.dmid }
        revision = UUID()
      }
    }.onReceive(NotificationCenter.default.publisher(for: SleepAppExit.checkpoint)) { _ in
      if let key = resumeID, let p = player, let i = p.currentItem {
        OfflineWatchBook.store(key, viewer: resumeViewer, seconds: p.currentTime().seconds, duration: i.duration.seconds)
      }
    }.onDisappear { closePlayer() }
  }
}
struct CacheSelection: View {
  let video: Video, cid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var owner: String?
  @State private var audio = 0
  @State private var audioChoices: [Int] = []
  @State private var reload = 0
  @State private var collection: ArchiveCacheDetails.Collection?
  @State private var singleFile = false
  @State private var quality = 0
  @State private var extras = true
  @State private var available: [Int] = []
  @State private var selected: Set<Int64> = []
  @State private var busy = false
  @State private var issue: String?
  @State private var confirmAll = false
  @ObservedObject private var downloads = Downloads.shared
  @Environment(\.dismiss) var dismiss
  private struct Row: Identifiable { let cid: Int64, title: String, duration: Int?; var id: Int64 { cid } }
  private var rows: [Row] {
    if let parts = video.pages, !parts.isEmpty {
      return parts.map { Row(cid: $0.cid, title: $0.part.isEmpty ? video.title : $0.part, duration: $0.duration) }
    }
    return [Row(cid: cid, title: video.title, duration: video.duration)]
  }
  private func cached(_ id: Int64) -> Bool {
    downloads.list.contains { $0.bvid == video.bvid && $0.cid == id }
  }
  /// The original's download panel: 画质/音质 menus on top, one row per part (tap to cache it
  /// right away), and 缓存全部 | 查看缓存 along the bottom.
  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.5)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(rows) { row in partRow(row).id(row.cid) }
          }.padding(.vertical, 6).padding(.bottom, 40)
        }
        .onAppear { proxy.scrollTo(cid, anchor: .top) }
      }
      Divider().opacity(0.5)
      footer
    }
    .navigationTitle("缓存视频").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Toggle("同时缓存字幕和弹幕", isOn: $extras)
          if let collection, let owner {
            NavigationLink {
              OfflineCollectionSelection(
                collection: collection, quality: quality == 0 ? nil : quality,
                audio: audio == 0 ? nil : audio, owner: owner, extras: extras)
            } label: { Label("缓存合集中的视频", systemImage: "square.stack") }
          }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("缓存选项")
      }
    }
    .confirmationDialog("确定缓存全部？", isPresented: $confirmAll, titleVisibility: .visible) {
      Button("缓存全部") { enqueue(rows.map(\.cid).filter { !cached($0) }) }
    }
    .interactiveDismissDisabled(busy)
      .task(id: (accounts.state.owner(.role(.video)) ?? "") + ":" + String(reload)) {
        selected = [cid]; owner = nil; collection = nil; singleFile = false; audio = 0; quality = 0;
        available = []; audioChoices = []; issue = nil
        do {
          let uid = try await AccountJar.shared.current(.role(.video))?.id ?? ""
          let result = try await BiliAPI.shared.offlineArchiveMenu(video.bvid, cid: cid, owner: uid)
          try Task.checkCancellation()
          available = result.video; audioChoices = result.audio; singleFile = result.singleFile;
          collection = result.archive.ugc_season
          owner = uid
        } catch { issue = error.localizedDescription }
      }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Text("画质").foregroundStyle(.secondary)
        Menu {
          Picker("画质", selection: $quality) {
            Text(OfflineQuality.video(available).map { "默认 · " + StreamQuality.name($0) } ?? "默认").tag(0)
            ForEach(available, id: \.self) { Text(StreamQuality.name($0)).tag($0) }
          }
        } label: { menuLabel(quality == 0 ? "默认" : StreamQuality.name(quality)) }
        if !audioChoices.isEmpty {
          Text("音质").foregroundStyle(.secondary)
          Menu {
            Picker("音质", selection: $audio) {
              Text(OfflineQuality.audio(audioChoices).map { "默认 · " + PlaybackOption.audioName($0) } ?? "默认").tag(0)
              ForEach(audioChoices, id: \.self) { Text(PlaybackOption.audioName($0)).tag($0) }
            }
          } label: { menuLabel(audio == 0 ? "默认" : PlaybackOption.audioName(audio)) }
        }
        Spacer(minLength: 0)
        if busy { ProgressView().controlSize(.small) }
      }
      .font(.subheadline)
      if let issue {
        HStack(spacing: 8) {
          Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2)
          if owner == nil { Button("重试") { reload += 1 }.font(.caption.weight(.semibold)) }
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
  }
  private func menuLabel(_ text: String) -> some View {
    HStack(spacing: 2) {
      Text(text).foregroundStyle(.primary)
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
  }
  private func partRow(_ row: Row) -> some View {
    let current = row.cid == cid
    let done = cached(row.cid)
    return Button {
      guard !done else { return }
      TouchFeedback.light()
      enqueue([row.cid])
    } label: {
      HStack(spacing: 10) {
        Rectangle().fill(.quaternary).frame(width: 160, height: 100)
          .overlay {
            SiteThumbnail(url: video.cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
          }
          .overlay(alignment: .bottomTrailing) {
            if let d = row.duration, d > 0 {
              Text(clockText(Double(d))).font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)).padding(6)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title).font(.subheadline.weight(current ? .semibold : .regular))
            .foregroundStyle(current ? Color.accentColor : Color.primary)
            .lineLimit(2).multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          HStack {
            if let stat = video.stat, rows.count == 1 {
              Text(MediaStats.line(views: stat.view, danmaku: stat.danmaku)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if done {
              Image(systemName: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("已加入缓存")
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(height: 100)
      .padding(.horizontal, 12).padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(owner == nil)
  }
  private var footer: some View {
    HStack(spacing: 0) {
      Button { confirmAll = true } label: {
        Text("缓存全部").frame(maxWidth: .infinity, minHeight: 44)
      }.disabled(owner == nil || busy)
      Divider().frame(height: 20)
      NavigationLink { DeferredPage { DownloadsView() } } label: {
        Text("查看缓存").frame(maxWidth: .infinity, minHeight: 44)
      }
    }
    .buttonStyle(.plain).font(.subheadline)
    .background(.bar)
  }
  /// Queues the given parts at the chosen quality; failures show under the menus.
  private func enqueue(_ ids: [Int64]) {
    guard !busy, let owner, !ids.isEmpty else { return }
    busy = true
    issue = nil
    Task {
      defer { busy = false }
      let q = quality == 0 ? nil : quality
      for id in ids {
        guard !Task.isCancelled, owner == (accounts.state.owner(.role(.video)) ?? "") else {
          issue = "视频账号已切换"; return
        }
        if let err = await Downloads.shared.add(
          video, cid: id, quality: q, audioQuality: audio == 0 ? nil : audio, owner: owner,
          extras: extras, singleFile: singleFile)
        {
          issue = err
        }
      }
    }
  }
}
