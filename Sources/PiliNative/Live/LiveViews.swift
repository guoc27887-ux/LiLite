import AVKit
import SwiftUI

struct LiveDirectory: View {
  let area: Int?
  let child: String?
  var title = "直播"
  var embedded = false
  @Environment(\.activeCatalogPage) private var catalogActive
  @Environment(\.colorScheme) private var colorScheme
  @State private var room = ""
  @AppStorage("live.directoryMobile") private var mobile = false
  @State private var firstFrame = false
  @State private var followed: [LiveRoom] = []
  @State private var areas: [LiveFeedCards.Tab] = []
  @State private var tags: [LiveDirectoryPage.Tag] = []
  @State private var sort: String?
  @State private var feedback: LiveRoom?
  @EnvironmentObject private var accounts: AccountContext
  private var owner: String? { accounts.state.owner(.role(.recommend)) }
  private var scope: String {
    "\(area ?? -1):\(child ?? ""):\(mobile):\(sort ?? ""):\(owner ?? "")"
  }
  var body: some View {
    VStack(spacing: 0) {
      if area == nil {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "number").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
              TextField("输入直播间号", text: $room).keyboardType(.numberPad)
              if let id = Int64(room), id > 0 {
                NavigationLink { LivePlayer(id: id, title: "直播间 \(id)") } label: {
                  Text("进入").font(.subheadline.weight(.semibold))
                }
                .piliButtonStyle(.glassProminent).controlSize(.small)
                .transition(.scale.combined(with: .opacity))
              }
            }
            .padding(.leading, 14).padding(.trailing, 5).frame(height: 42)
            .piliGlass(in: Capsule())
            .animation(.snappy(duration: 0.2), value: Int64(room) ?? 0 > 0)
            NavigationLink { LiveSearchView() } label: {
              Image(systemName: "magnifyingglass").font(.body.weight(.medium))
                .frame(width: 42, height: 42).contentShape(Circle())
            }
            .buttonStyle(.plain).piliGlass(in: Circle(), interactive: true)
            .accessibilityLabel("直播搜索")
            if embedded {
              // Embedded in the home deck: keep options here, not in the shared toolbar, so
              // swiping between channels never changes the navigation bar.
              Menu { optionItems } label: {
                Image(systemName: "slider.horizontal.3").font(.body.weight(.medium))
                  .frame(width: 42, height: 42).contentShape(Circle())
              }
              .buttonStyle(.plain).piliGlass(in: Circle(), interactive: true)
              .accessibilityLabel("直播列表选项")
            }
          }
          HStack(spacing: 8) {
            NavigationLink { LiveAreaCatalog() } label: {
              Label("分区", systemImage: "square.grid.2x2").font(.subheadline)
            }.piliButtonStyle(.glass)
            NavigationLink { LiveFollows() } label: {
              Label("关注", systemImage: "heart").font(.subheadline)
            }.piliButtonStyle(.glass)
            NavigationLink {
              SitePage(url: URL(string: colorScheme == .dark ? "https://www.bilibili.com/h5/match/data/home?navhide=1&native.theme=2&night=1" : "https://www.bilibili.com/h5/match/data/home?navhide=1&native.theme=1&night=0")!)
            } label: {
              Label("赛事", systemImage: "gamecontroller").font(.subheadline)
            }.piliButtonStyle(.glass)
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
      }
      if mobile && area == nil && (!followed.isEmpty || !areas.isEmpty) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(followed) { r in
              NavigationLink { LivePlayer(id: r.id, title: r.title) } label: {
                HStack(spacing: 6) {
                  Circle().fill(.red).frame(width: 6, height: 6)
                  Text(r.uname ?? r.title).lineLimit(1)
                }
                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
              }
            }
            ForEach(areas, id: \.self) { tab in
              if let parent = tab.area_v2_parent_id, let sub = tab.area_v2_id, let label = tab.title
              {
                NavigationLink {
                  LiveAreaChannels(parent: parent, initial: String(sub), title: label, initialTitle: label)
                } label: {
                  Text(label).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
              }
            }
          }.buttonStyle(.plain).padding(.horizontal, 16)
        }.scrollIndicators(.hidden).scrollClipDisabled().padding(.bottom, 4)
      }
      PageList(empty: "暂无直播", grid: true) { p in
        let page = Int(p ?? "1") ?? 1
        let snapshot = scope
        if mobile {
          let data = try await BiliAPI.shared.mobileLiveRooms(
            page: page, owner: owner, area: area, child: child, sort: sort)
          try Task.checkCancellation()
          if page == 1 && snapshot == scope {
            followed = data.followed
            areas = data.areas
            tags = data.tags
          }
          return data.page
        }
        return try await BiliAPI.shared.rooms(area: area, child: child, page: page)
      } row: { r in
        LiveDirectoryCard(room: r, firstFrame: firstFrame, mobile: mobile) { feedback = r }
      }.id(scope)
    }.piliCatalogTitle(title, embedded: embedded).toolbar {
      if !embedded {Menu {
        optionItems
      } label: {
        Image(systemName: "slider.horizontal.3").accessibilityLabel("直播列表选项")
      }}
    }
    .onChange(of: "\(mobile):\(owner ?? ""):\(area ?? -1):\(child ?? "")") { _, _ in
      feedback = nil
      areas = []
      followed = []
      tags = []
      sort = nil
    }
    .piliSheet(item: $feedback) { r in LiveFeedbackSheet(room: r) }
  }
  @ViewBuilder private var optionItems: some View {
        Picker("直播来源", selection: $mobile) {
          Text("网页推荐").tag(false)
          Text("移动端推荐").tag(true)
        }
        Toggle("显示直播首帧", isOn: $firstFrame)
        if mobile && area != nil && !tags.isEmpty {
          Picker("排序", selection: $sort) {
            Text("默认").tag(String?.none)
            ForEach(tags, id: \.self) { tag in
              if let name = tag.name, let value = tag.sort_type { Text(name).tag(Optional(value)) }
            }
          }
        }
  }
}
struct LivePlayer: View {
  let id: Int64, title: String
  @StateObject private var chat = LiveChat()
  @StateObject private var liveTrack = LiveOverlayTimeline()
  @StateObject private var liveInspector = BulletInspector()
  @AppStorage("dm.tap") private var inspectLive = false
  @State private var readingOlder = false
  @State private var systemFullscreen = false
  @StateObject private var upscale = UpscaleSession()
  @StateObject private var transport = NativeLivePlayback()
  private var player: AVPlayer? { transport.player }
  @State private var error: String?
  @State private var qn: Int? = nil
  private var options: [Int] { transport.selected?.choices ?? [] }
  private var current: Int {
    guard let row = transport.selected, row.endpoints.indices.contains(transport.line) else {
      return 0
    }
    return row.endpoints[transport.line].quality
  }
  @State private var reload = 0
  @State private var chatReload = 0
  @State private var identity: LiveRoomIdentity?
  @State private var liveCard: IMShareCard?
  @State private var header: LiveRoomHeader?
  @State private var headerRevision = 0
  @State private var headerUnavailable = false
  private var roomTitle: String { chat.roomTitle ?? header?.room_info?.title ?? title }
  private var headerOwner: String? { accounts.state.owner(.role(.heartbeat)) }
  @State private var resolvingError: String?
  @State private var resolveAttempt = 0
  @State private var visitAttempts = Set<String>()
  @AppStorage("history.sync") private var recordVisits = true
  @State private var ranks = false
  @EnvironmentObject var accounts: AccountContext
  @State private var shield: LiveShield?
  @State private var keyboardChat=false
  @State private var editShield = false
  @State private var paidSettings = false
  @State private var showPaid = false
  @State private var selectedMessage: LiveActionSelection?
  @State private var replyTo: LiveReplyTarget?
  @State private var enlarged = false
  @State private var locked = false
  @State private var startedRoom: Int64?
  @AppStorage("theater.autoEnter") private var autoEnter = false
  @AppStorage("theater.orientation") private var orientationPref: Int?
  @State private var entryOrientation = TheaterOrientation.defaultMode
  private var orientation: Int { orientationPref ?? entryOrientation }
  @AppStorage("theater.lockButton") private var allowLock = true
  @AppStorage("theater.captureButton") private var allowCapture = true
  private func expand() { guard !locked else{return};enlarged.toggle();chat.presentation(enlarged) }
  @State private var audioOnly = false
  @State private var expandedChat = false
  @State private var showFacts = false
  @State private var liveStarted: Int64?
  @AppStorage("live.paidMode") private var paidMode = 0
  @AppStorage("live.paidFullscreen") private var paidFullscreen = true
  @StateObject private var preferences = PlayerSessionPreferences()
  private var showChat: Bool {
    get { preferences.liveBullets }
    nonmutating set { preferences.liveBullets = newValue }
  }
  private var visible: [LiveLine] {
    chat.lines.filter { shield?.hides($0) != true }
  }
  @ViewBuilder private var theater: some View {
    if let player {
      ViewportAspect(expanded: enlarged) {
        Theater(
          player: player,
          overlay: AnyView(
            ZStack {
              if showChat {
                LiveTrackView(
                  chat: chat, timeline: liveTrack, player: player, shield: shield,
                  inspector: inspectLive ? liveInspector : nil,
                  fullscreen: enlarged || systemFullscreen)
              }
              SuperChatOverlay(
                chat: chat, enabled: showChat && paidFullscreen && paidMode != 2, shield: shield)
            }),
          live: true, showsControls: !locked,
          onPresentation: { full in
            systemFullscreen = full
            chat.presentation(enlarged || full)
          },
          interaction: locked ? nil : AnyView(LiveTouchSurface(player:player,fullscreen:enlarged,
            inspector:inspectLive && showChat ? liveInspector:nil,expand:expand)),
          fullscreen: enlarged,
          expand: expand, upscale: upscale
        ).allowsHitTesting(!locked)
          .modifier(PlayerKeyboard(player:player,live:true,locked:locked,fullscreen:{if locked{locked=false};expand()},bullets:{showChat.toggle()},
            lock:{if enlarged {locked.toggle()}},allowCapture:!audioOnly,full:enlarged,cid:identity?.room_id,liveRefresh:{reload+=1},liveSend:{keyboardChat=true}))
          .onReceive(player.publisher(for:\.timeControlStatus).removeDuplicates()){ state in
            guard state == .playing, let room=identity?.room_id, startedRoom != room else{return}
            startedRoom=room
            if autoEnter && !systemFullscreen && !enlarged {expand()}
          }
      }
    } else if let error = error ?? transport.issue {
      Text(error).padding()
      Button("重新连接") { reload += 1 }.padding(.horizontal)
    } else {
      ProgressView().frame(maxWidth: .infinity, minHeight: 130)
    }
  }
  private var controls: some View {
    WrappingActions {
      Menu {
        SessionPlaybackSettings(session: preferences)
        Toggle("仅播放音频", isOn: $audioOnly)
        Button("重新连接") { reload += 1 }
        Button("播放信息") { showFacts = true }
        Toggle("显示直播弹幕", isOn: preferences.binding(\.liveBullets))
        Button("醒目留言设置") { paidSettings = true }
        if identity != nil, accounts.state.active != nil {
          Button("管理屏蔽规则") { editShield = true }
        }
      } label: {
        Label("直播弹幕", systemImage: "text.bubble").piliFont(.headline)
      }
      SleepTimerButton(live: true).labelStyle(.iconOnly)
      if paidMode != 2, identity != nil {
        Button {
          showPaid = true
        } label: {
          Image(systemName: "star.bubble").accessibilityLabel("醒目留言")
        }
      }
      if let identity {
        LiveLikeButton(room: identity, owner: accounts.state.owner(.role(.heartbeat)))
          .id("\(identity.room_id):\(accounts.state.owner(.role(.heartbeat)) ?? "")")
        Menu {
          NavigationLink("主播主页") { CreatorSpace(mid: identity.uid, name: liveCard?.author ?? "主播") }
          if headerUnavailable { Button("重新读取直播间资料") { headerRevision += 1 } }
          Button("贡献榜") { ranks = true }
          if enlarged { Button("直播聊天") { expandedChat = true } }
          if let url = URL(string: "https://live.bilibili.com/\(identity.room_id)") {
            Button("复制直播间链接") { UIPasteboard.general.url = url }
            ShareLink("分享直播间", item: url)
            Link("用浏览器打开", destination: url)
          }
          IMShareButton(
            card: liveCard
              ?? .init(
                .live, id: String(identity.room_id), title: title,
                authorID: String(identity.uid))
          )
        } label: {
          Image(systemName: "ellipsis.circle").accessibilityLabel("直播间选项")
        }
      }
      if !transport.variants.isEmpty {
        Menu {
          if let host = transport.currentHost { Text("当前线路：" + host) }
          Section("直播格式") {
            Button("自动选择") { transport.clearPreference() }
            ForEach(transport.variants) { v in
              Button {
                transport.choose(v.id)
              } label: {
                if transport.format == v.id {
                  Label(v.id.label, systemImage: "checkmark")
                } else {
                  Text(v.id.label)
                }
              }
            }
          }
          if transport.audioTracks.count>1 || transport.hasAudioOverride {
            Section("直播音轨") {
              Button("自动选择") {transport.chooseAudio(nil)}
              ForEach(transport.audioTracks) { choice in
                Button {transport.chooseAudio(choice)} label: {
                  if transport.selectedAudio?.id==choice.id {Label(choice.title,systemImage:"checkmark")}
                  else {Text(choice.title)}
                }
              }
            }
          }
          if let v = transport.selected, v.sources.count > 1 {
            Section("播放线路") {
              ForEach(v.sources.indices, id: \.self) { i in
                Button {
                  transport.choose(v.id, i, persist: false)
                } label: {
                  let name = "线路 " + String(i + 1) + " · " + (v.sources[i].host ?? "")
                  if i == transport.line {
                    Label(name, systemImage: "checkmark")
                  } else {
                    Text(name)
                  }
                }
              }
            }
          }
        } label: {
          Label("直播线路", systemImage: "point.3.connected.trianglepath.dotted").labelStyle(
            .iconOnly)
        }
      }
      if !options.isEmpty {
        Menu("画质 · \(qualityName(current))") {
          ForEach(options, id: \.self) { n in Button(qualityName(n)) { qn = n } }
        }
      }
    }.padding(.horizontal)
  }
  @ViewBuilder private var conversation: some View {
    let visible = self.visible
    if let online = chat.online { Label("在线 " + online.formatted(),systemImage:"person.2").font(.caption).padding(.horizontal) }
    if let n = chat.popularity, n > 0 {
      Label("直播人气 " + String(n), systemImage: "person.2").piliFont(.caption).padding(
        .horizontal)
    }
    if let err = chat.status {
      HStack {
        Text(err).piliFont(.caption).foregroundStyle(.secondary)
        Button("重新连接弹幕") { chatReload += 1 }
      }.padding(.horizontal)
    }
    ScrollViewReader { proxy in
      List(visible) { line in
        Button {
          guard let room = identity?.room_id, line.room == room else { return }
          let paid = line.paidID.flatMap { id in
            chat.paid.items.first { $0.id == id && $0.uid == line.uid }
          }
          selectedMessage = .init(line: line, paid: paid, room: room, owner: accounts.state.active)
        } label: {
          LiveMessageRow(line: line, anchor: identity?.uid)
        }.buttonStyle(.plain).id(line.id)
          .onAppear {
            if readingOlder, line.id == visible.last?.id { readingOlder = false }
          }
      }
      .listStyle(.plain)
      .simultaneousGesture(
        DragGesture(minimumDistance: 16).onChanged { drag in
          if drag.translation.height > 16 { readingOlder = true }
        }
      )
      .overlay(alignment: .bottomTrailing) {
        if readingOlder {
          Button("回到底部") {
            readingOlder = false
            if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }.buttonStyle(.borderedProminent).padding(8)
        }
      }.onChange(of: visible.last?.id) { _, n in
        if let n, !readingOlder, selectedMessage == nil { proxy.scrollTo(n, anchor: .bottom) }
      }
    }
    if let identity {
      LiveComposer(room: identity.room_id, reply: $replyTo)
        .id("\(identity.room_id):\(accounts.state.active ?? "")")
    } else if let resolvingError {
      Button("重新读取房间") { resolveAttempt += 1 }.accessibilityHint(resolvingError)
    }
  }
  private var screen: some View {
    GeometryReader { geometry in
    let w = geometry.size.width, h = geometry.size.height
    let pictureHeight = min(w * 9 / 16, max(80, h * 0.38))
    if !enlarged, h > 0, w / h >= 1.2, w >= 540 {
      // The original's landscape room (`_buildBodyH`): the picture on the left, chat on the
      // right at most 400 pt wide. Used on iPad, the unfolded iPhone Duo and phones held sideways.
      let chatWidth = min(400, w - min(0.7, max(0.56, h / w * 1.08)) * w)
      let pictureWidth = w - chatWidth
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          theater.frame(height: min(pictureWidth * 9 / 16, max(120, h - 96))).clipped().background(.black)
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if let identity { LiveAnchorLine(room: identity, info: header, watched: chat.watched) }
              controls
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.scrollBounceBehavior(.basedOnSize)
        }.frame(width: pictureWidth)
        Divider()
        VStack(alignment: .leading, spacing: 8) { conversation }.frame(width: chatWidth)
          .frame(maxHeight: .infinity, alignment: .top)
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    } else {
    VStack(alignment: .leading, spacing: 8) {
      theater.frame(height: enlarged ? nil : pictureHeight).clipped().background(.black)
      if enlarged && !locked {
        HStack {
          Text(roomTitle).font(.caption.bold()).lineLimit(1)
          if let count = chat.online { Text("在线 " + count.formatted()).font(.caption) }
          LiveStartedLabel(timestamp:liveStarted)
          Spacer()
          if let player, allowCapture, !audioOnly { CaptureButton(player:player) }
          if identity != nil { Button { expandedChat = true } label:{Label("聊天",systemImage:"text.bubble")} }
        }.padding(.horizontal)
        controls
      } else if !enlarged {
        if let identity { LiveAnchorLine(room: identity, info: header, watched: chat.watched) }
        controls
        conversation
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    }.overlay(alignment:.topTrailing){
      if enlarged && (allowLock || locked) {
        Button {TouchFeedback.light(); locked.toggle()} label:{
          Image(systemName:locked ? "lock.fill":"lock.open").padding(9).foregroundStyle(.white).background(.black.opacity(0.6),in:Circle())
        }.accessibilityLabel(locked ? "解锁播放控件":"锁定播放控件").padding(6)
      }
    }.background {
      if enlarged {TheaterGeometry(mode:FullscreenMode(rawValue:orientation) ?? .video,size:player?.currentItem?.presentationSize ?? .zero).allowsHitTesting(false)}
    }.onChange(of:allowLock){ _,on in if !on {locked=false} }
      .onChange(of:enlarged){ _,on in if !on{locked=false} }
      .modifier(PlaybackEdgeInsets(fullscreen: enlarged))
      .toolbar(enlarged ? .hidden : .automatic, for: .navigationBar, .tabBar)
      .navigationTitle(roomTitle)
      .task(id: "\(identity?.room_id ?? 0):\(accounts.state.active ?? "")") {
        shield = nil
        guard let identity, let user = accounts.state.active else { return }
        let fresh = try? await BiliAPI.shared.shield(room: identity.room_id, user: user)
        if !Task.isCancelled, shield == nil { shield = fresh }
      }
  }
  private func actions(_ selection: LiveActionSelection) -> some View {
    LiveChatActions(selection: selection, shield:$shield) { target in
      if target.room == identity?.room_id && target.account == accounts.state.active { replyTo = target }
    }
  }
  private var panels: some View {
    screen.piliSheet(item:Binding(get:{ expandedChat ? nil:selectedMessage },set:{ selectedMessage=$0 })) { selection in actions(selection) }
    .onChange(
      of:
        "\(identity?.room_id ?? 0):\(accounts.state.active ?? ""):\(accounts.state.owner(.role(.heartbeat)) ?? "")"
    ) { _, _ in
      selectedMessage = nil
      replyTo = nil
      editShield = false
      showPaid = false
      readingOlder = false
      liveTrack.clear()
      liveInspector.locate = nil
      liveInspector.pick = nil
    }
    .onChange(of: liveInspector.pick?.id) { _, id in
      guard id != nil, let pick = liveInspector.pick else { return }
      liveInspector.pick = nil
      guard let line = liveTrack.line(for: pick.bullet), let room = identity?.room_id,
        line.room == room, shield?.hides(line) != true
      else { return }
      selectedMessage = .init(line: line, paid: nil, room: room, owner: accounts.state.active)
    }
    .piliSheet(isPresented: $expandedChat) {
      PiliNavigationStack { VStack { conversation }.navigationTitle("直播聊天")
        .toolbar { Button("完成"){expandedChat=false} }
        .piliSheet(item:$selectedMessage){ selection in actions(selection) } }
    }
    .piliSheet(isPresented: $showFacts) {
      PiliNavigationStack { LiveProgramInfo(transport:transport,started:liveStarted,audioOnly:audioOnly)
        .toolbar { Button("完成"){showFacts=false} } }
    }
    .piliSheet(isPresented: $editShield) {
      if let identity, let user = accounts.state.active {
        PiliNavigationStack {
          LiveShieldView(room: identity.room_id, user: user, rules: $shield).toolbar {
            Button("关闭") { editShield = false }
          }
        }
      }
    }
    .onChange(of: paidMode, initial: true) { _, mode in
      chat.configurePaid(SuperChatDisplay(rawValue: mode) ?? .current)
      if mode == 2 { showPaid = false }
    }
    .piliSheet(isPresented:$keyboardChat){
      if let room=identity?.room_id{PiliNavigationStack{VStack{LiveComposer(room:room,reply:$replyTo,focusOnEntry:true);Spacer()}.navigationTitle("直播弹幕").toolbar{Button("完成"){keyboardChat=false}}}.presentationDetents([.medium])}
    }
    .piliSheet(isPresented: $paidSettings) {
      PiliNavigationStack { SuperChatSettings().toolbar { Button("完成") { paidSettings = false } } }
    }
    .piliSheet(isPresented: $showPaid) {
      if let identity {
        PiliNavigationStack {
          SuperChatFeed(chat: chat, room: identity.room_id, shield: $shield).toolbar {
            Button("关闭") { showPaid = false }
          }
        }
      }
    }
    .piliSheet(isPresented: $ranks) {
      if let identity {
        PiliNavigationStack {
          LiveContributionRank(room: identity).toolbar { Button("关闭") { ranks = false } }
        }
      }
    }
  }
  var body: some View {
    panels.task(id: "\(identity?.room_id ?? 0):\(headerOwner ?? ""):\(headerRevision)") {
      liveCard = nil; header = nil; headerUnavailable = false
      guard let identity else { return }
      let user = headerOwner
      if let info = try? await BiliAPI.shared.read(
        "/xlive/web-room/v1/index/getH5InfoByRoom", ["room_id": String(identity.room_id)],
        host: "api.live.bilibili.com", expectedAccount: user ?? "", as: LiveRoomHeader.self),
        !Task.isCancelled, user == headerOwner, self.identity?.room_id == identity.room_id {
        header = info
        let text = chat.roomTitle ?? info.room_info?.title ?? title, author = info.anchor_info?.base_info?.uname
        let cover = info.room_info?.cover.flatMap(httpsURL)
        liveCard = .init(.live, id: String(identity.room_id), title: text, author: author,
          authorID: String(identity.uid), thumb: cover)
        transport.updateRoom(identity.room_id, title: text, artist: author, cover: cover)
      } else if !Task.isCancelled, user == headerOwner { headerUnavailable = true }
    }
    .task(id: "\(id):\(resolveAttempt)") {
      resolvingError = nil
      identity = nil
      do {
        let info = try await BiliAPI.shared.read(
          "/room/v1/Room/room_init", ["id": String(id)], host: "api.live.bilibili.com",
          as: LiveRoomIdentity.self)
        try Task.checkCancellation()
        identity = info
      } catch { if !Task.isCancelled { resolvingError = error.localizedDescription } }
    }
    .task(id: "\(identity?.room_id ?? 0):\(accounts.state.owner(.role(.heartbeat)) ?? ""):\(recordVisits)") {
      guard recordVisits, let room = identity?.room_id, room > 0,
        let owner = accounts.state.owner(.role(.heartbeat)) else { return }
      let key = "\(owner):\(room)"
      guard visitAttempts.insert(key).inserted else { return }
      try? await BiliAPI.shared.recordLiveVisit(room: room, owner: owner)
    }
    .onChange(of: chat.roomTitle) { _,latest in
      guard let room=identity?.room_id, let latest else {return}
      liveCard = .init(.live,id:String(room),title:latest,author:header?.anchor_info?.base_info?.uname,
        authorID:identity.map{String($0.uid)},thumb:header?.room_info?.cover.flatMap(httpsURL))
      transport.updateRoom(room,title:latest,artist:header?.anchor_info?.base_info?.uname,cover:header?.room_info?.cover.flatMap(httpsURL))
    }
    .onChange(of: preferences.background) { _, _ in transport.setSessionPreferences(preferences) }
    .onChange(of: preferences.controls) { _, _ in transport.setSessionPreferences(preferences) }
    .task(id: "\(qn ?? 0):\(reload):\(identity?.room_id ?? 0):\(audioOnly):\(headerOwner ?? "")") {
      transport.stop()
      liveStarted = nil
      error = nil
      guard let room = identity?.room_id, room > 0 else { return }
      let owner = headerOwner ?? ""
      do {
        let rules = NetworkMediaRules.current()
        let preferred = qn ?? (MediaNetwork.shared.cellular ? rules.cellLive : rules.wifiLive)
        let s = try await BiliAPI.shared.liveStream(room, quality: preferred, audioOnly: audioOnly, owner: owner)
        try Task.checkCancellation()
        guard owner == (headerOwner ?? ""), self.identity?.room_id == room else { return }
        liveStarted = s.live_status == 1 ? s.live_time : nil
        upscale.begin(id: "live:" + String(identity?.room_id ?? id), anime: false)
        transport.setSessionPreferences(preferences)
        transport.open(s, room: room, audioOnly: audioOnly, title: roomTitle, artist: header?.anchor_info?.base_info?.uname, cover: header?.room_info?.cover.flatMap(httpsURL))
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    .task(
      id:
        "\(identity?.room_id ?? 0):\(chatReload):\(accounts.state.owner(.role(.heartbeat)) ?? "")"
    ) {
      if let identity {
        await chat.connect(identity.room_id, reader: accounts.state.owner(.role(.heartbeat)))
      } else {
        chat.close()
      }
    }
    .onDisappear {
      if !expandedChat && !keyboardChat && !showFacts && !editShield && !paidSettings
        && !showPaid && !ranks && selectedMessage == nil {
        chat.close()
        transport.stop()
      }
    }
  }
  private func qualityName(_ q: Int) -> String {
    PlaybackOption.liveName(q)
  }
}
