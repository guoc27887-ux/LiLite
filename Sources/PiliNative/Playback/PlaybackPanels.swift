import SwiftUI
import UIKit
import Combine

/// Height of the status bar area of the key window, used to keep an immersive player below it.
@MainActor enum WindowMetrics {
  private static var window: UIWindow? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first
    return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
  }
  static var statusBar: CGFloat { window?.safeAreaInsets.top ?? 0 }
  static var homeIndicator: CGFloat { window?.safeAreaInsets.bottom ?? 0 }
  /// Brightness of the screen the window is on (not `UIScreen.main`: on iPhone Duo the inner
  /// and outer displays are different screens).
  static var brightness: CGFloat {
    get { window?.screen.brightness ?? 0.5 }
    set { window?.screen.brightness = newValue }
  }
  /// How far the keyboard (frame in screen coordinates) covers the window, which in Split
  /// View, Stage Manager or on a Duo is not the whole screen.
  static func keyboardOverlap(_ end: CGRect) -> CGFloat {
    guard let w = window else { return 0 }
    let local = w.convert(end, from: w.screen.coordinateSpace)
    return max(0, w.bounds.maxY - local.minY)
  }
}

/// Underlined text tabs, as in Apple's media apps, with an optional trailing accessory.
struct PlaybackTab: Identifiable, Equatable { let id: Int, title: String }
struct PlaybackTabBar<Accessory: View>: View {
  let items: [PlaybackTab]
  let selected: Int
  let select: (Int) -> Void
  @ViewBuilder let accessory: () -> Accessory
  @Namespace private var underline
  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 30) {
        ForEach(items) { item in
          let current = item.id == selected
          Button {
            TouchFeedback.light()
            select(item.id)
          } label: {
            Text(item.title)
              .font(.body.weight(current ? .semibold : .regular))
              .foregroundStyle(current ? Color.primary : Color.secondary)
              .padding(.vertical, 12)
              .overlay(alignment: .bottom) {
                if current {
                  Capsule().fill(Color.accentColor).frame(width: 18, height: 3)
                    .matchedGeometryEffect(id: "underline", in: underline)
                }
              }
              .contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : [])
        }
      }
      Spacer(minLength: 8)
      accessory()
    }
    .padding(.horizontal, 16).frame(height: 46)
    .overlay(alignment: .bottom) { Divider() }
    .animation(.snappy(duration: 0.25), value: selected)
  }
}

/// Keep the same player mounted while selecting a side panel or resizing the window.
struct PlaybackPanels<Surface: View, Info: View, Replies: View>: View {
  let model: PlayerModel
  let key: String, canDiscuss: Bool
  @Binding var selection: Bool?
  let full: () -> Void
  var startDeferred: (() -> Void)? = nil
  var playlist: AnyView? = nil
  var creator: AnyView? = nil
  /// Trailing controls in the tab bar (bullet toggle, send bullet).
  var accessory: AnyView? = nil
  /// Total comments, shown after the comments tab title.
  var commentCount: Int64? = nil
  /// Related videos, shown as the first right-hand tab in the side layout (the original's
  /// 相关视频 tab); everywhere else they stay at the end of the intro.
  var related: AnyView? = nil
  @ViewBuilder let surface: () -> Surface
  @ViewBuilder let info: () -> Info
  @ViewBuilder let replies: () -> Replies
  @AppStorage("reply.openFirst") private var defaultComments = false
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage("layout.playlist") private var playlistPref: Bool?
  @AppStorage("layout.verticalMedia") private var enlarge = false
  @AppStorage("player.edgeToEdge") private var edgeToEdge = false
  @State private var wantsList = false
  @State private var playback = PanelPlaybackState()
  @State private var gallery: GalleryRailRequest?
  @State private var fold = PanelFold()
  /// Comment threads opened from the comments, shown as panels under the player.
  @State private var replyPanels: [ReplyPanelItem] = []
  /// False while another page is pushed over this one, so stray threads open as pages there.
  @State private var onScreen = false
  /// Mirrors the player's controls, so our back / home buttons hide and show with them.
  @State private var chromeShown = true
  @Environment(\.dismiss) private var dismiss
  @AppStorage("images.sidePreview") private var galleryEnabled = false
  private var comments: Bool { canDiscuss && (selection ?? defaultComments) }
  var body: some View {
    let topInset = edgeToEdge ? 0 : WindowMetrics.statusBar
    GeometryReader { layout in
      let p = plan(
        width: layout.size.width, height: layout.size.height, topInset: topInset,
        fold: DeviceFold.division(in: layout))
      let wide = p.wide
      Group {
        switch p.mode {
        case .square: squareLayout(playerWidth: p.playerWidth, playerHeight: p.playerHeight, list: p.list)
        case .side: sideLayout(p)
        case .tabletop: tabletopLayout(p)
        case .stacked: stackedLayout(p)
        }
      }
      .environment(\.presentGalleryRail, wide && galleryEnabled ? { gallery = $0 } : nil)
      .environment(\.replyPanelPresenter, ReplyPanelPresenter { title, content in
        guard onScreen else { return false }
        replyPanels.append(ReplyPanelItem(title: title, content: content))
        return true
      })
      .overlay {
        if wide && galleryEnabled, let gallery { GalleryRailPanel(request: gallery) { self.gallery = nil } }
      }
      .onChange(of: p.selected, initial: true) { _, tab in
        fold.offset = 0
      }
      .background {
        VideoNavigationChrome(player: model.engine, contentPop: p.selected == p.tabs.first && replyPanels.isEmpty)
          .frame(width: 0, height: 0)
      }
      .onChange(of: p.playerHeight, initial: true) { _, h in fold.limit = max(1, h - PanelFold.bar) }.onChange(of: wide && galleryEnabled) { _, show in if !show { gallery = nil } }
    }
    .padding(.top, topInset)
    .background(alignment: .top) {
      FoldStatusFill(fold: fold, active: !playback.playing).frame(height: topInset + 1)
        .ignoresSafeArea(edges: .top)
    }
    .ignoresSafeArea(.container, edges: .top)
    .toolbarBackground(.hidden, for: .navigationBar)
    .modifier(HorizontalBarsOnly())
    .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
    // Light status bar over the black player; the system's own once it has folded into the bar.
    .toolbarColorScheme(fold.folded && !playback.playing ? nil : .dark, for: .navigationBar)
    .onReceive(model.$playing.combineLatest(model.$hasPlayed, model.$pictureSize)
      .map { PanelPlaybackState(playing: $0.0, hasPlayed: $0.1, pictureSize: $0.2) }.removeDuplicates()) {
        if playback != $0 { playback = $0 }
      }
    .onPreferenceChange(PlayerControlsVisibleKey.self) { shown in
      withAnimation(.smooth(duration: 0.28)) { chromeShown = shown }
    }
    // The original has no system back button: back and home live in the player header and hide
    // with its controls. Like the original's page route, `VideoNavigationChrome` provides its
    // own finger-following edge swipe back.
    .navigationBarBackButtonHidden(true)
    .onAppear { onScreen = true }
    .onDisappear { onScreen = false }
    .onChange(of: key) { _, _ in
      replyPanels = []
      gallery = nil
      selection = nil
      wantsList = false
    }
  }

  @ViewBuilder private func panelsContent(layout: GeometryProxy, topInset: CGFloat) -> some View {
  let width = layout.size.width
  let height = layout.size.height
  let wide = width > height && width >= 540
  let side = wide && (horizontal || creator != nil)
  let list: AnyView? = wide && (playlistPref ?? horizontal) ? playlist : nil
  let selected = wantsList && list != nil && selection == nil ? 2 : comments ? 1 : 0
  let vertical =
    enlarge && playback.pictureSize.height > playback.pictureSize.width && playback.pictureSize.width > 0
  let ratio: CGFloat = vertical ? (side ? 9.0 / 16 : 1) : 16.0 / 9
  let usable = max(1, height - topInset)
  let playerWidth = side ? max(130, min(width * 0.63, (usable - 44) * ratio)) : width
  let playerHeight = max(
    1,
    min(
      playerWidth / ratio,
      side ? max(1, usable - 44) : usable * (vertical ? 0.72 : 0.6)))
  let showTabs = !(wide && creator != nil) && (canDiscuss || list != nil || accessory != nil)
  let tabs = [0] + (canDiscuss ? [1] : []) + (list != nil ? [2] : [])
  Group {
    if side {
      HStack(alignment: .top, spacing: 8) {
        surface().frame(width: playerWidth, height: playerHeight).clipped().background(.black)
          .recordsInlinePlayerFrame(model.engine)
          .overlay(alignment: .topLeading) { headerButtons }
        VStack(spacing: 0) {
          if wide, let creator {
            creator
          } else {
            if showTabs { tabBar(list: list, selected: selected) }
            pager(tabs: tabs, selected: selected, list: list)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .overlay { ReplyPanelStack(items: $replyPanels) }
      }
    } else {
      // The original client's nested scroll: the player and tabs sit over the panels. While
      // playing they stay pinned; while paused they move up 1:1 with the list, so the
      // comments slide over the player following the finger.
      let header = playerHeight + (showTabs ? 46 : 0)
      ZStack(alignment: .top) {
        pager(tabs: tabs, selected: selected, list: list)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .background(Color(uiColor: .systemBackground))
          .environment(\.panelTopInset, header)
          // Only changes inside the fold range are published, so a fully folded player
          // stops invalidating on every scroll frame.
          .environment(\.panelScroll, { [fold] y in
            let v = min(max(y, 0), fold.limit + 1)
            if v != fold.offset { fold.offset = v }
          })
        FoldingHeader(fold: fold, active: !playback.playing) {
          VStack(spacing: 0) {
            surface().frame(width: playerWidth, height: playerHeight).clipped().background(.black)
              .recordsInlinePlayerFrame(model.engine)
              .overlay(alignment: .topLeading) { headerButtons }
              .overlay(alignment: .bottom) {
                FoldBar(
                  fold: fold, active: !playback.playing, played: playback.hasPlayed,
                  back: { dismiss() }
                ) {
                  model.toggle()
                }
              }
            if showTabs {
              tabBar(list: list, selected: selected)
                .background(Color(uiColor: .systemBackground))
            }
          }
        }
        FoldAwareReplyPanels(
          fold: fold, active: !playback.playing, playerHeight: playerHeight, items: $replyPanels)
      }
      .clipped()
    }
  }
  .environment(\.presentGalleryRail, wide && galleryEnabled ? { gallery = $0 } : nil)
  .environment(\.replyPanelPresenter, ReplyPanelPresenter { title, content in
    guard onScreen else { return false }
    replyPanels.append(ReplyPanelItem(title: title, content: content))
    return true
  })
  .overlay {
    if wide && galleryEnabled, let gallery { GalleryRailPanel(request: gallery) { self.gallery = nil } }
  }
  .onChange(of: selected, initial: true) { _, tab in
    fold.offset = 0
  }
  .background {
    VideoNavigationChrome(player: model.engine, contentPop: selected == 0 && replyPanels.isEmpty)
      .frame(width: 0, height: 0)
  }
  .onChange(of: playerHeight, initial: true) { _, h in fold.limit = max(1, h - PanelFold.bar) }.onChange(of: wide && galleryEnabled) { _, show in if !show { gallery = nil } }
  }

  /// The original header's left side: back, then home. Drawn here (not in the player) so it is
  /// there before the video is ready too.
  private var headerButtons: some View {
    HStack(spacing: 0) {
      Button {
        TouchFeedback.light()
        dismiss()
      } label: {
        PlayerGlyph(symbol: "arrow.left", size: 17)
      }
      .accessibilityLabel("返回")
      PlayerHomeButton()
    }
    .buttonStyle(PlayerPressStyle())
    .padding(.leading, 4).padding(.top, 4)
    .opacity(chromeShown ? 1 : 0)
    .allowsHitTesting(chromeShown)
  }
  /// Sizes and tabs for one window size.
  private struct Plan {
    var wide = false, mode = PlayerPageLayout.stacked
    var list: AnyView?
    var playerWidth: CGFloat = 1, playerHeight: CGFloat = 1
    var introBelow = false, showTabs = false
    var tabs = [0], selected = 0
    /// Width (side) or height (tabletop) of the hinge region kept clear between the halves.
    var foldGap: CGFloat = 0
  }
  private func plan(width: CGFloat, height: CGFloat, topInset: CGFloat, fold: CGRect?) -> Plan {
    var p = Plan()
    let full = height + topInset
    p.wide = width > height && width >= 540
    p.mode = PlayerPageLayout.resolve(width: width, height: full, horizontal: horizontal || (p.wide && creator != nil))
    // A partly folded Duo: lay the halves out on either side of the hinge, as the system's own
    // split views do, instead of drawing the player or a list across it.
    var foldEdge: CGFloat?
    if let d = fold, d.width >= width * 0.8, d.minY >= 120, d.maxY <= height - 120 {
      p.mode = .tabletop
      foldEdge = d.minY
      p.foldGap = d.height
    } else if let d = fold, d.height >= height * 0.8, d.minX >= width * 0.3, d.maxX <= width * 0.8 {
      p.mode = .side
      foldEdge = d.minX
      p.foldGap = d.width
    }
    let side = p.mode == .side
    p.list = p.mode != .stacked && (playlistPref ?? horizontal) ? playlist : nil
    let picture = playback.pictureSize
    let vertical = enlarge && picture.width > 0 && picture.height > picture.width
    let ratio: CGFloat = vertical ? (side ? 9.0 / 16 : 1) : 16.0 / 9
    let usable = max(1, height - topInset)
    // Side: the original's player width, capped so the picture fits the window's height.
    let sideWidth = max(130, min(PlayerPageLayout.sideWidth(width: width, height: full), usable * ratio))
    p.playerWidth = side ? (foldEdge ?? sideWidth) : width
    let cap: CGFloat
    switch p.mode {
    case .side: cap = usable
    case .square: cap = full / 2.5
    case .tabletop: cap = max(1, foldEdge ?? usable)  // the region is in this view's space
    case .stacked: cap = usable * (vertical ? 0.72 : 0.6)
    }
    // Above the fold the picture takes the whole upper half (letterboxed by the player).
    p.playerHeight = p.mode == .tabletop ? cap : max(1, min(p.playerWidth / ratio, cap))
    // In the side layout the intro sits under the player when there is room for it; the
    // right-hand tabs are then related videos, comments and episodes.
    var others: [Int] = []
    if canDiscuss { others.append(1) }
    if p.list != nil { others.append(2) }
    let besideIntro: [Int] = (related != nil ? [3] : []) + others
    p.introBelow = side && creator == nil && usable - p.playerHeight >= 160 && !besideIntro.isEmpty
    p.tabs = p.introBelow ? besideIntro : [0] + others
    let preferred: Int
    if wantsList && p.list != nil && selection == nil { preferred = 2 }
    else if comments { preferred = 1 }
    else { preferred = p.introBelow ? 3 : 0 }
    p.selected = p.tabs.contains(preferred) ? preferred : p.tabs[0]
    p.showTabs = !(p.wide && creator != nil)
      && (canDiscuss || p.list != nil || accessory != nil || p.tabs.count > 1)
    return p
  }
  private func playerSurface(_ p: Plan) -> some View {
    surface().frame(width: p.playerWidth, height: p.playerHeight).clipped().background(.black)
      .recordsInlinePlayerFrame(model.engine)
      .overlay(alignment: .topLeading) { headerButtons }
  }
  /// The original's landscape page: player (and intro, when it fits) on the left, tabs on the right.
  private func sideLayout(_ p: Plan) -> some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(spacing: 0) {
        playerSurface(p)
        if p.introBelow {
          info().environment(\.relatedHoisted, related != nil)
            .frame(width: p.playerWidth).frame(maxHeight: .infinity, alignment: .top)
        }
      }.frame(width: p.playerWidth).frame(maxHeight: .infinity, alignment: .top)
      if p.foldGap > 0 { Color.clear.frame(width: p.foldGap) } else { Divider() }
      VStack(spacing: 0) {
        if p.wide, let creator {
          creator
        } else {
          if p.showTabs { tabBar(tabs: p.tabs, selected: p.selected) }
          pager(tabs: p.tabs, selected: p.selected, list: p.list)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(uiColor: .systemBackground))
      .overlay { ReplyPanelStack(items: $replyPanels) }
    }
  }
  /// Tabletop posture: the picture fills the half above the hinge, the tabs the half below.
  private func tabletopLayout(_ p: Plan) -> some View {
    VStack(spacing: 0) {
      playerSurface(p)
      Color.clear.frame(height: p.foldGap)
      VStack(spacing: 0) {
        if p.showTabs { tabBar(tabs: p.tabs, selected: p.selected) }
        pager(tabs: p.tabs, selected: p.selected, list: p.list)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(uiColor: .systemBackground))
      .overlay { ReplyPanelStack(items: $replyPanels) }
    }
  }
  /// The original client's nested scroll: the player and tabs sit over the panels. While
  /// playing they stay pinned; while paused they move up 1:1 with the list, so the comments
  /// slide over the player following the finger.
  private func stackedLayout(_ p: Plan) -> some View {
    let header = p.playerHeight + (p.showTabs ? 46 : 0)
    return ZStack(alignment: .top) {
      pager(tabs: p.tabs, selected: p.selected, list: p.list)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .environment(\.panelTopInset, header)
        // Only changes inside the fold range are published, so a fully folded player stops
        // invalidating on every scroll frame.
        .environment(\.panelScroll, { [fold] y in
          let v = min(max(y, 0), fold.limit + 1)
          if v != fold.offset { fold.offset = v }
        })
      FoldingHeader(fold: fold, active: !playback.playing) {
        VStack(spacing: 0) {
          playerSurface(p)
            .overlay(alignment: .bottom) {
              FoldBar(
                fold: fold, active: !playback.playing, played: playback.hasPlayed,
                back: { dismiss() }
              ) {
                model.toggle()
              }
            }
          if p.showTabs {
            tabBar(tabs: p.tabs, selected: p.selected)
              .background(Color(uiColor: .systemBackground))
          }
        }
      }
      FoldAwareReplyPanels(
        fold: fold, active: !playback.playing, playerHeight: p.playerHeight, items: $replyPanels)
    }
    .clipped()
  }
  /// Tabs: 0 intro, 1 comments, 2 episodes, 3 related videos (side layout only).
  private func choose(_ tab: Int) {
    wantsList = tab == 2
    selection = tab == 2 ? nil : tab == 1
  }
  private func tabBar(tabs: [Int], selected: Int) -> some View {
    PlaybackTabBar(items: tabs.map { PlaybackTab(id: $0, title: tabTitle($0)) }, selected: selected) { tab in
      choose(tab)
    } accessory: {
      if let accessory { accessory }
    }
    // No swipe on the tab bar itself: it fired its buttons (and 发弹幕) on sideways drags. The
    // pages below swipe, like the original's TabBarView.
  }
  private func pager(tabs: [Int], selected: Int, list: AnyView?) -> some View {
    // Both pages remain mounted before a drag begins. Only UIKit changes their intermediate
    // frames; selection and pending page roots are committed after deceleration ends.
    NativePager(count: tabs.count, page: Binding(
      get: { tabs.firstIndex(of: selected) ?? 0 },
      set: { i in
        guard tabs.indices.contains(i), tabs[i] != selected else { return }
        choose(tabs[i])
      })) { i in
        ActivePlaybackPanel(active: tabs[i] == selected) {
          switch tabs[i] {
          case 1: replies()
          case 2: list
          case 3:
            if let related {
              ScrollView { related.padding(.horizontal, 16).padding(.vertical, 12) }.reportsScrollCollapse()
            }
          default: info()
          }
        }
      }
  }
  private func tabTitle(_ tab: Int) -> String {
    switch tab {
    case 1:
      let n = commentCount.map { $0 > 0 ? " " + $0.formatted(.number.notation(.compactName)) : "" } ?? ""
      return "评论" + n
    case 2: return "选集"
    case 3: return "相关视频"
    default: return "简介"
    }
  }
  /// The original's "almost square" page (`childWhenDisabledAlmostSquare`): the player across
  /// the top, then intro, comments and episodes side by side, each column titled.
  private func squareLayout(playerWidth: CGFloat, playerHeight: CGFloat, list: AnyView?) -> some View {
    VStack(spacing: 0) {
      surface().frame(width: playerWidth, height: playerHeight).clipped().background(.black)
        .recordsInlinePlayerFrame(model.engine)
        .overlay(alignment: .topLeading) { headerButtons }
      HStack(alignment: .top, spacing: 0) {
        squareColumn(0, trailing: true) { info() }
        if canDiscuss {
          Divider()
          squareColumn(1, trailing: false) { replies() }
            .overlay { ReplyPanelStack(items: $replyPanels) }
        }
        if let list {
          Divider()
          squareColumn(2, trailing: false) { list }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(uiColor: .systemBackground))
    }
  }
  private func squareColumn<C: View>(_ tab: Int, trailing: Bool, @ViewBuilder content: () -> C) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(tabTitle(tab)).font(.body.weight(.semibold))
        Spacer(minLength: 8)
        if trailing, let accessory { accessory }
      }
      .padding(.horizontal, 16).frame(height: 46)
      .overlay(alignment: .bottom) { Divider() }
      content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

/// The player page draws the original's header (back, home, tools) inside the picture; on the
/// iPhone Duo's inner display the system would otherwise turn the hidden navigation bar into a
/// vertical bar beside the player.
private struct HorizontalBarsOnly: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 27.1, *) { content.toolbarVerticalBehavior(.disabled) } else { content }
  }
}

private struct RelatedHoistedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  /// True when the page shows related videos in their own panel, so the intro leaves them out.
  var relatedHoisted: Bool {
    get { self[RelatedHoistedKey.self] }
    set { self[RelatedHoistedKey.self] = newValue }
  }
}
/// Related videos at the end of the intro, unless the page shows them in their own panel.
struct IntroRelated<Content: View>: View {
  @Environment(\.relatedHoisted) private var hoisted
  @ViewBuilder let content: () -> Content
  var body: some View { if !hoisted { content() } }
}

private struct PanelPlaybackState: Equatable {
  var playing = false
  var hasPlayed = false
  var pictureSize = CGSize.zero
}

/// An off-screen page must not move the shared header when its list loads or changes size.
private struct ActivePlaybackPanel<Content: View>: View {
  let active: Bool
  @ViewBuilder let content: () -> Content
  var body: some View {
    content().transformEnvironment(\.panelScroll) { if !active { $0 = nil } }
  }
}

/// Scroll offset of the visible detail panel; only the folding views observe it.
@MainActor @Observable final class PanelFold {
  var offset: CGFloat = 0 {
    didSet {
      let f = offset > limit * 0.6
      if f != folded { folded = f }
    }
  }
  /// Changes only when crossing the threshold, so the page re-renders rarely while scrolling.
  private(set) var folded = false
  /// How far the player can fold away (its height minus the bar it leaves behind).
  var limit: CGFloat = 1
  static let bar: CGFloat = 44
  func progress(_ active: Bool) -> CGFloat {
    active ? min(max(offset, 0), limit) / max(limit, 1) : 0
  }
}

/// While paused the player folds away with the list, leaving the original client's toolbar:
/// a surface-coloured bar with "继续播放" that fades in as the player leaves.
struct FoldingHeader<Content: View>: View {
  let fold: PanelFold
  /// Folding follows the list only while paused.
  let active: Bool
  @ViewBuilder let content: () -> Content
  var body: some View {
    content()
      .offset(y: -fold.progress(active) * fold.limit)
      .animation(.smooth(duration: 0.32), value: active)
  }
}

/// The bar left at the bottom of the folded player.
struct FoldBar: View {
  let fold: PanelFold
  let active: Bool
  let played: Bool
  var back: (() -> Void)? = nil
  let resume: () -> Void
  var body: some View {
    let p = fold.progress(active)
    Button(action: resume) {
      Label(played ? "继续播放" : "立即播放", systemImage: "play.fill")
        .font(.subheadline.weight(.semibold))
        // Explicit: the player chrome tints its subtree white.
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // The original's folded bar keeps back on the left.
    .overlay(alignment: .leading) {
      if let back {
        Button(action: back) {
          Image(systemName: "arrow.left").font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary).frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("返回").padding(.leading, 4)
      }
    }
    .frame(height: PanelFold.bar)
    .background(Color(uiColor: .systemBackground))
    .opacity(p)
    .allowsHitTesting(p > 0.6)
    .animation(.smooth(duration: 0.32), value: active)
  }
}

/// The status bar strip above the player turns the bar's colour as the player folds away.
struct FoldStatusFill: View {
  let fold: PanelFold
  let active: Bool
  var body: some View {
    ZStack {
      Color.black
      Color(uiColor: .systemBackground).opacity(fold.progress(active))
    }
    .animation(.smooth(duration: 0.32), value: active)
  }
}
