import AVKit
import SwiftUI

/// The AVKit renderer stays attached to its player. Only its picture is resized while its system
/// controls are off. Captions, hit targets and app controls continue to use the unscaled viewport.
struct Theater: View {
  let player: any PlaybackEngine
  let overlay: AnyView
  var live = false
  var showsControls = true
  var onPresentation: ((Bool) -> Void)? = nil
  var interaction: AnyView? = nil
  var caption: AnyView? = nil, marks: AnyView? = nil
  var timeline:TimelineState?=nil
  var detached = false
  var fullscreen = false
  var toggle: (() -> Void)? = nil, seek: ((Double) -> Void)? = nil, expand: (() -> Void)? = nil
  var upscale: UpscaleSession? = nil
  @Environment(\.styledSubtitles) private var scripts
  @Environment(\.playerChrome) private var slots
  @StateObject private var clock = ViewportClock()
  @StateObject private var touch = ViewportTouch()
  @AppStorage("play.gravity") private var gravity = "fit"
  @AppStorage("player.bottomProgress") private var progress = 0
  @AppStorage("player.longControls") private var longer = false
  @AppStorage("player.shrink") private var shrinks = true
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var visible = true
  @State private var editing = false
  @State private var system = false
  @State private var pipError: String?
  @State private var zoom = ViewportZoom()
  @State private var initialZoom: ViewportZoom?
  @AppStorage("player.scrollVolume") private var scrollVolume = true
  @State private var volumeHint: Int?
  @State private var routeVolume = false
  @State private var volumeSequence = 0
  @State private var pulse = 0
  @AccessibilityFocusState private var controlsFocused: Bool
  var body: some View {
    GeometryReader { geo in viewportContent(size: geo.size) }.preference(key: PlayerControlsVisibleKey.self, value: visible && showsControls && !system)
    .onReceive(AVAudioSession.sharedInstance().publisher(for:\.outputVolume).removeDuplicates().dropFirst()){level in
      guard !detached,level.isFinite else{return}
      routeVolume=true;volumeHint=Int((min(1,max(0,level))*100).rounded());volumeSequence &+= 1
    }.task(id: volumeSequence) {
      guard volumeHint != nil else { return }
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      volumeHint = nil
    }.onAppear {
      clock.attach(player)
      wake()
    }
    .background { if let native = player.nativePlayer { VideoSceneMarker(player: native) } }
    .background { if let mpv = player as? MPVPlayer, let upscale { MPVUpscaleBinding(player: mpv, session: upscale) } }
    .alert("画中画", isPresented: Binding(get: { pipError != nil }, set: { if !$0 { pipError = nil } })) {
      Button("好") {}
    } message: { Text(pipError ?? "") }
    .onReceive(NotificationCenter.default.publisher(for: .piliStartPictureInPicture)) { n in
      if (n.object as AnyObject?) === player { resetZoom() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .piliMPVPiPError)) { n in
      if (n.object as AnyObject?) === player { pipError = "画中画启动失败，请稍后重试" }
    }
    .onChange(of: ObjectIdentifier(player)) { _, _ in
      clock.attach(player)
      wake()
    }
    .onChange(of: clock.item) { _, _ in
      resetZoom()
      visible = true
      wake()
    }
    .onChange(of: showsControls) { _, v in
      if !v { system = false }
      visible = v
      wake()
    }
    .onChange(of: shrinks) { _, enabled in if !enabled && zoom.scale < 1 { resetZoom() } }
    .onChange(of: clock.playing) { _, _ in wake() }
    .onChange(of: controlsFocused) { _, _ in wake() }
    .onChange(of: longer) { _, _ in wake() }
    .onChange(of: voiceOver) { _, on in
      if on { visible = true }
      wake()
    }
    .onDisappear {
      clock.close()
      touch.pinching = false
      touch.horizontalSeek = nil
    }
    .task(id: pulse) {
      guard visible, !system, showsControls, !editing else { return }
      do { try await Task.sleep(for: .seconds(longer ? 30 : 3)) } catch { return }
      if !Task.isCancelled, !touch.pinching, touch.horizontalSeek == nil, !editing,
        !controlsFocused, !voiceOver
      {
        visible = false
      }
    }
  }

  @ViewBuilder private func viewportContent(size: CGSize) -> some View {
  let chosen = PictureFit(rawValue: gravity) ?? .fit
  let canvas = chosen.geometry(view: size, source: player.playbackSize, firstChoice: clock.picture.changedItem != clock.item)
  let frame = system ? size : canvas.size
  ZStack {
    Color.black
    ZStack {
      if !detached {
        Group {
        if let native = player.nativePlayer {
        SystemTheater(
          player: native,
          overlay: system && !clock.picture.inPictureInPicture
            ? AnyView(
              ZStack(alignment: .bottom) {
                overlay
                if let scripts{StyledSubtitleLayer(session:scripts,player:player,gravity:gravity)}
                if let caption { caption }
              }) : nil, live: live,
          showsControls: showsControls && system, onPresentation: onPresentation, pictureGravity: system ? gravity : canvas.gravity,
          pipError: { pipError = $0 }
        )
        } else if let mpv = player as? MPVPlayer {
          MPVVideoView(player: mpv, gravity: canvas.gravity)
        }
        }
        .scaleEffect(x: !system && clock.picture.mirrorX ? -1 : 1, y: !system && clock.picture.mirrorY ? -1 : 1)
        .frame(width: frame.width * zoom.scale, height: frame.height * zoom.scale)
        .position(x: size.width / 2 + zoom.x, y: size.height / 2 + zoom.y)
      }
      if !system && !clock.picture.inPictureInPicture {
        if let upscale, !detached, let native = player.nativePlayer, let item = native.currentItem {
          UpscaleLayer(
            player: native, session: upscale, item: item, gravity: canvas.gravity
          )
          .scaleEffect(x: !system && clock.picture.mirrorX ? -1 : 1, y: !system && clock.picture.mirrorY ? -1 : 1)
        .frame(width: frame.width * zoom.scale, height: frame.height * zoom.scale)
          .position(x: size.width / 2 + zoom.x, y: size.height / 2 + zoom.y)
        }
        if !detached,let scripts{StyledSubtitleLayer(session:scripts,player:player,gravity:canvas.gravity)
          .frame(width:frame.width*zoom.scale,height:frame.height*zoom.scale)
          .position(x:size.width/2+zoom.x,y:size.height/2+zoom.y)}
        overlay.allowsHitTesting(false)
        if let interaction { interaction.environment(\.viewportTouch, touch) }
        if let caption {
          VStack {
            Spacer()
            caption.environment(\.captionMinimumBottom, visible && showsControls ? (size.width < 600 || textSize.isAccessibilitySize ? 118 : 70) : 0)
          }
        }
      }
    }.frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
      .simultaneousGesture(
        MagnifyGesture().onChanged { v in
          guard showsControls, !system, !clock.picture.inPictureInPicture else { return }
          if initialZoom == nil { initialZoom = zoom }
          touch.pinching = true
          touch.horizontalSeek = nil
          zoom = (initialZoom ?? zoom).magnified(
            v.magnification,
            anchor: CGPoint(x: v.startAnchor.x, y: v.startAnchor.y), size: size,
            shrinks: shrinks)
          if !visible { visible = true }
        }.onEnded { _ in
          if touch.pinching {
            touch.ignorePanBefore = ProcessInfo.processInfo.systemUptime + 0.2
          }
          initialZoom = nil
          touch.pinching = false
          wake()
        }, including: system || !showsControls ? .subviews : .all
      )
      .simultaneousGesture(
        TapGesture(count:2).exclusively(before:TapGesture()).onEnded{value in
          guard case .second=value,showsControls,!system,!clock.picture.inPictureInPicture,touch.acceptsPan else{return}
          DispatchQueue.main.async{
            guard ProcessInfo.processInfo.systemUptime-touch.lastBulletTap>0.08 else{return}
            visible.toggle();wake()
          }
        },including:system || !showsControls ? .subviews:.all)
    if showsControls && !clock.picture.inPictureInPicture {
      if system {
        VStack {
          HStack {
            Spacer()
            Button {
              system = false
              visible = true
              wake()
            } label: {
              Label("应用控件", systemImage: "rectangle.and.hand.point.up.left")
                .font(.caption).padding(6).background(.black.opacity(0.65), in: Capsule())
            }.foregroundStyle(.white)
            Spacer()
          }
          Spacer()
        }.padding(.top, 4)
      } else {
        appControls(width: size.width)
      }
    }
    if scrollVolume && !detached {
      PointerVolume(player: player) { level in
        routeVolume=false;volumeHint = level; volumeSequence &+= 1
      }
    }
    if let volumeHint {
      PlayerLevelPill(
        symbol: PlayerLevelPill.volumeSymbol(Double(volumeHint) / 100), percent: volumeHint
      ).accessibilityHidden(true)
    }
  }.frame(width: size.width, height: size.height)
  }

  /// The original client's player chrome: a header (back/title left, tools right) and a bottom
  /// bar (progress, then play/time left and menus/fullscreen right), each on a 75 % black
  /// gradient that slides in from its own edge. Fullscreen adds the action row under the header
  /// and edge buttons at mid-height.
  @ViewBuilder private func appControls(width: CGFloat) -> some View {
    ZStack {
      if visible {
        VStack(spacing: 0) {
          topBar(width: width)
          if fullscreen, let under = slots.underHeader {
            HStack(spacing: 0) {
              Spacer(minLength: 0)
              under
            }
            .padding(.trailing, 6)
          }
          Spacer(minLength: 0)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          bottomBar(width: width)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        if fullscreen && (slots.edgeLeading != nil || slots.edgeTrailing != nil) {
          HStack(spacing: 0) {
            slots.edgeLeading
            Spacer(minLength: 0)
            slots.edgeTrailing
          }
          .padding(.horizontal, 14)
          .offset(y: -16)
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      } else if !live, clock.duration > 0,
        (ViewportProgress(rawValue: progress) ?? .always).visible(
          fullscreen: fullscreen, controls: visible,
          seeking: touch.horizontalSeek != nil || editing)
      {
        VStack {
          Spacer()
          ViewportSeekBar(
            clock: clock, readout: clock.readout, seek: jump, editing: edit, compact: true, external: touch.horizontalSeek,
            marks: marks,timeline:timeline)
        }
        .transition(.opacity)
      }
    }
    .foregroundStyle(.white).buttonStyle(PlayerPressStyle())
    .environment(\.colorScheme, .dark)
    .animation(.smooth(duration: 0.28), value: visible)
    .accessibilityElement(children: .contain).accessibilityFocused($controlsFocused)
  }
  private func topBar(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      if let lead = slots.headerLeading {
        lead
      } else if !fullscreen {
        // Inline, the page draws back and home over this corner (they exist before the player
        // is ready), hiding with these controls.
        Color.clear.frame(width: 80, height: 40)
      }
      if let title = slots.title, fullscreen || width >= 600 {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1)
          if let sub = slots.subtitle {
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
          }
        }
        .padding(.leading, 4).padding(.trailing, 10)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .layoutPriority(-1)
      }
      Spacer(minLength: 8)
      PlayerHeaderStatus(fullscreen: fullscreen)
      if let trailing = slots.headerTrailing { trailing }
    }
    .frame(height: 40)
    .padding(.horizontal, fullscreen ? 10 : 4)
    .padding(.top, fullscreen ? 8 : 4)
    .padding(.bottom, 22)
    .background {
      LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea(edges: .top).allowsHitTesting(false)
    }
  }
  private func bottomBar(width: CGFloat) -> some View {
    VStack(spacing: 0) {
      if !live, clock.duration > 0 {
        ViewportSeekBar(
          clock: clock, readout: clock.readout, seek: jump, editing: edit, compact: false,
          external: touch.horizontalSeek, marks: marks, timeline: timeline)
          .padding(.horizontal, 10)
          // Its 30 pt touch band ends where the buttons begin, so it never steals their taps.
          .padding(.bottom, -2)
      }
      HStack(spacing: 0) {
        playControl
        if !live, clock.duration > 0 {
          ViewportTimeLabel(readout: clock.readout, external: touch.horizontalSeek, duration: clock.duration)
            .padding(.leading, 2)
        } else if live {
          Text("直播").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
        }
        if let lead = slots.bottomLeading { lead }
        Spacer(minLength: 4)
        accessoryControls(wide: fullscreen || width >= 500)
      }
      .frame(height: 40)
    }
    .padding(.horizontal, fullscreen ? 10 : 2)
    .padding(.top, 30).padding(.bottom, fullscreen ? 6 : 0)
    .background(alignment: .bottom) {
      LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
    }
  }
  private var playControl: some View {
    Button { playPause(); wake() } label: {
      PlayerGlyph(symbol: clock.playing ? "pause.fill" : "play.fill", size: 21)
    }.accessibilityLabel(clock.playing ? "暂停" : "播放").disabled(!clock.ready)
  }
  /// The original's order on the right: super resolution, episodes, picture fit (wide only),
  /// subtitles / speed / quality from the page, then fullscreen.
  @ViewBuilder private func accessoryControls(wide: Bool) -> some View {
    if let upscale { UpscaleButton(session: upscale) }
    if let episode = slots.bottomEpisode { episode }
    if wide { PlayerFitMenu(player: player, session: clock.picture) }
    if let trailing = slots.bottomTrailing { trailing }
    if wide, let extra = slots.bottomWide { extra }
    if abs(zoom.scale - 1) > 0.005 {
      Button {
        withAnimation(.easeOut(duration: 0.22)) { resetZoom() }
        wake()
      } label: {
        PlayerGlyph(symbol: "arrow.up.left.and.down.right.magnifyingglass")
      }.accessibilityLabel("还原画面").accessibilityValue(String(format: "%.2f 倍", zoom.scale))
      .transition(.scale.combined(with: .opacity))
    }
    if let expand {
      Button {
        expand()
      } label: {
        PlayerGlyph(
          symbol: fullscreen
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          size: 18)
      }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
      .contextMenu {
        Button("系统播放控件", systemImage: "rectangle.and.hand.point.up.left") {
          resetZoom()
          system = true
        }.disabled(!player.supportsSystemVideo)
      }
    }
  }
  private func wake() { pulse &+= 1 }
  private func edit(_ value: Bool) {
    editing = value
    wake()
  }
  private func jump(_ seconds: Double) {
    guard !live, clock.ready, clock.duration > 0, seconds.isFinite else { return }
    if let seek {
      seek(seconds)
    } else {
      PictureSession.shared(player).seek(player, to: min(clock.duration, max(0, seconds)))
    }
  }
  private func playPause() {
    if let toggle {
      toggle()
      return
    }
    if player.timeControlStatus == .paused { player.play() } else { player.pause() }
  }
  private func resetZoom() {
    zoom = ViewportZoom()
    initialZoom = nil
    touch.pinching = false
  }
}
