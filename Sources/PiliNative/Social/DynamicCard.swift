import SwiftUI

/// Where tapping a whole moment card goes. Like the original's pushDynDetail, a video moment opens
/// the video and anything else the moment's detail page.
enum MomentTarget: Hashable {
  case detail(String, focusReplies: Bool = false)
  case video(Video)
  case link(SharedLink)
  case creator(Int64, String)
  case topic(TopicLink)
  case article(String)
  case vote(Int64, String)
  case web(URL)
}
private struct OpenMomentKey: EnvironmentKey {
  static let defaultValue: StableAction<MomentTarget>? = nil
}
extension EnvironmentValues {
  /// Set by the page that lists moment cards (`momentNavigation()`).
  var openMoment: StableAction<MomentTarget>? {
    get { self[OpenMomentKey.self] }
    set { self[OpenMomentKey.self] = newValue }
  }
}
/// Pushes card targets from the page itself. Cards hold no NavigationLinks of their own: inside a
/// tappable card SwiftUI fired one of them (the author, the cover) for taps anywhere on the card.
private struct MomentNavigation: ViewModifier {
  @State private var target: MomentTarget?
  @State private var token = UUID()
  func body(content: Content) -> some View {
    content
      // Compares equal for the page's life: a closure here re-rendered every card on each pass.
      .environment(\.openMoment, StableAction(token) { target = $0 })
      // On its own placeholder: pages that hold cards already declare destinations of their
      // own, and a second one on the same view can be ignored.
      .background {
        Color.clear.frame(width: 0, height: 0)
          .navigationDestination(item: $target) { AnyView(MomentTargetView(target: $0)) }
      }
  }
}
/// Closes the moment's own detail page (after deleting it there). A stable handle set only by
/// that page: cards reading `dismiss` re-rendered whenever any presentation around them changed.
@MainActor final class MomentPageCloser {
  private(set) var close: () -> Void = {}
  func bind(_ dismiss: DismissAction) -> MomentPageCloser {
    close = { dismiss() }
    return self
  }
}
private struct MomentPageCloserKey: EnvironmentKey { static let defaultValue: MomentPageCloser? = nil }
extension EnvironmentValues {
  var momentPageCloser: MomentPageCloser? {
    get { self[MomentPageCloserKey.self] }
    set { self[MomentPageCloserKey.self] = newValue }
  }
}
extension View {
  func momentNavigation() -> some View { modifier(MomentNavigation()) }
}
struct MomentTargetView: View {
  let target: MomentTarget
  var body: some View {
    switch target {
    case .detail(let id, let focus): DynamicDetail(id: id, focusReplies: focus)
    case .video(let video): DetailView(initial: video)
    case .link(let link): LinkDestination(item: link)
    case .creator(let mid, let name): CreatorSpace(mid: mid, name: name)
    case .topic(let topic): TopicFeed(topic: topic)
    case .article(let id): ArticleReader(opus: id)
    case .vote(let id, let dynamic): VoteView(id: id, dynamic: dynamic)
    case .web(let url): SitePage(url: url)
    }
  }
}
/// A tap target inside a moment card. It asks the page to push (`momentNavigation()`) instead of
/// being a NavigationLink of its own: inside a card those caught taps meant for the card itself.
struct MomentGo<Label: View>: View {
  let target: MomentTarget
  @ViewBuilder let label: () -> Label
  @Environment(\.openMoment) private var openMoment
  var body: some View {
    if let openMoment {
      Button {
        TouchFeedback.light()
        openMoment(target)
      } label: { label() }
      .buttonStyle(.plain)
    } else {
      // Destination type-erased: MomentTargetView resolves to DynamicDetail, which embeds
      // DynamicCard, closing a type cycle the iOS 18 runtime resolves by infinite recursion.
      NavigationLink { AnyView(DeferredPage { MomentTargetView(target: target) }) } label: { label() }.buttonStyle(.plain)
    }
  }
}

/// One moment, laid out like the original client's DynamicPanel and the official app: the author
/// row with its more menu, topic, text and pictures, the video cover, the reposted moment on a
/// tinted band, then forward / comment / like. In a list the whole card opens the video (a video
/// moment) or the detail page; the buttons inside it keep their own targets.
struct DynamicCard: View {
  let entry: DynamicEntry
  var inside = false
  var openPanel: ((MomentPanel) -> Void)? = nil
  var changed: () -> Void = {}
  init(entry: DynamicEntry, inside: Bool = false, changed: @escaping () -> Void = {}) {
    self.entry = entry
    self.inside = inside
    self.changed = changed
  }
  init(
    entry: DynamicEntry, inside: Bool, openPanel: @escaping (MomentPanel) -> Void,
    changed: @escaping () -> Void
  ) {
    self.init(entry: entry, inside: inside, changed: changed)
    self.openPanel = openPanel
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.momentPageCloser) private var pageCloser
  @Environment(\.openMoment) private var openMoment
  @AppStorage("social.dispute") private var showDispute = false
  @AppStorage("social.interaction") private var showInteraction = true
  @AppStorage(RecommendationRules.key) private var localRules = Data()
  @State private var hidden = false
  @State private var editing = false
  @State private var visibility: VisibilityRequest?
  @State private var ownerSettings = false
  @State private var reporting = false
  @State private var poster = false
  @State private var removing = false
  @State private var busy = false
  @State private var issue: String?

  var body: some View {
    let blocked = entry.authorID.map { RecommendationRules.read(localRules).blockedCreators.contains($0) } ?? false
    if !hidden && !blocked {
      if inside {
        content
      } else {
        VStack(spacing: 0) {
          content
            .background(Color(uiColor: .systemBackground))
            .contentShape(Rectangle())
            .onTapGesture { open(cardTarget) }
            .accessibilityAction(named: "打开") { open(cardTarget) }
          Rectangle().fill(Color(uiColor: .secondarySystemBackground)).frame(height: 8)
            .accessibilityHidden(true)
        }
      }
    }
  }

  // MARK: Layout

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.leading, 12).padding(.trailing, 4).padding(.top, 12).padding(.bottom, 6)
      if showDispute, let notice = entry.presentation.notice {
        Label(notice.title, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
          .padding(.horizontal, 12).padding(.bottom, 6)
      }
      main.padding(.horizontal, 12)
      if let orig = entry.originalID, orig != entry.id { forwarded(orig).padding(.bottom, 6) }
      if !inside {
        if showInteraction && !entry.interactionLines.isEmpty { interactions }
        DynamicActionBar(entry: entry, openComments: openPanel.map { open in { open(.replies) } }, changed: changed)
      } else {
        Color.clear.frame(height: 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .buttonStyle(.plain)
    .onChange(of: accounts.state.active) { _, _ in issue = nil }
    .piliSheet(item: $visibility) { VisibilityPanel(request: $0) }
    .piliSheet(isPresented: $editing) {
      if let uid = accounts.state.active, uid == entry.authorID.map(String.init) {
        DynamicEditView(id: entry.id, uid: uid, changed: changed)
      }
    }
    .piliSheet(isPresented: $ownerSettings) {
      if let uid = accounts.state.active, uid == entry.authorID.map(String.init) {
        PiliNavigationStack {
          MomentOwnerSettings(entry: entry, uid: uid, changed: changed)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { ownerSettings = false } } }
        }
      }
    }
    .piliSheet(isPresented: $reporting) {
      if let uid = accounts.state.active, let mid = entry.authorID {
        PiliNavigationStack {
          CommunityReport(target: .moment(id: entry.id, author: mid), uid: uid) { hidden = true }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { reporting = false } } }
        }
      }
    }
    .piliSheet(isPresented: $poster) {
      if let url = shareURL {
        PiliNavigationStack {
          SharePoster(content: .moment(entry, link: url))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { poster = false } } }
        }
      }
    }
    .confirmationDialog("删除这条动态？", isPresented: $removing, titleVisibility: .visible) {
      Button("删除", role: .destructive) {
        guard let uid = accounts.state.active, entry.authorID.map(String.init) == uid else { return }
        Task { await action("/x/dynamic/feed/operate/remove", ["dyn_id_str": entry.id], user: uid, remove: true) }
      }
    }
    .alert("动态", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }

  private var cardTarget: MomentTarget {
    if !entry.blockedAttachment, entry.originalID == nil, let card = entry.card {
      if let preview = card.preview { return .video(preview) }
      return .link(card.route)
    }
    return .detail(entry.id)
  }
  private func open(_ target: MomentTarget) {
    guard let openMoment else { return }
    TouchFeedback.light()
    openMoment(target)
  }
  private var vipName: Bool { entry.signature.vipStatus == 1 && entry.signature.vipType == 2 }
  private var shareURL: URL? { URL(string: "https://t.bilibili.com/" + entry.id) }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      authorLink(entry.authorNavigable ? entry.authorID : nil, name: entry.author) {
        HStack(spacing: 8) {
          ReplyAvatar(member: entry.signature, size: 40)
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.signature.uname ?? entry.author).font(.subheadline.weight(.medium)).lineLimit(1)
              .foregroundStyle(vipName ? Color.pink : Color.primary)
            Text(inside ? Self.fullDate(entry) : entry.date).font(.caption).foregroundStyle(.secondary)
              .lineLimit(1)
            if inside, let place = entry.location {
              Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
      }
      Spacer(minLength: 0)
      if !inside, let tag = entry.tag, !tag.isEmpty {
        Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.tint)
          .padding(.horizontal, 5).padding(.vertical, 2)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
      } else {
        ReplyCardBadge(card: entry.signature.card)
      }
      moreMenu
    }
  }

  @ViewBuilder private var main: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let topic = entry.topic { topicLink(topic, font: .subheadline) }
      if let title = entry.opusTitle, entry.hasOpus { Text(title).font(.headline) }
      text(entry.bodyNodes, plain: entry.body, lines: 6, id: entry.id)
      if entry.hasOpus, inside || entry.opusTitle != nil {
        MomentGo(target: .article(entry.id)) {
          HStack(spacing: 3) {
            Text("阅读图文")
            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
          }.font(.footnote.weight(.medium)).foregroundStyle(.tint)
        }
      }
      if !entry.blockedAttachment && !entry.media.isEmpty { pictures(entry.media) }
      if !entry.blockedAttachment, let card = entry.card { MomentVideoCover(video: card, fullTitle: inside) }
      MomentResourceViews(values: entry.resources, dynamic: entry.id)
      if !entry.blockedAttachment, let vote = entry.voteID {
        MomentGo(target: .vote(vote, entry.id)) {
          Label("查看投票", systemImage: "chart.bar.doc.horizontal").font(.subheadline).foregroundStyle(.tint)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 6)
  }

  /// The reposted moment on a tinted band (the original client's forwardPanel). Tapping the band
  /// opens that moment; its author, video and pictures keep their own links.
  private func forwarded(_ orig: String) -> some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        if let src = entry.originalAuthor {
          HStack(spacing: 6) {
            authorLink(entry.originalNavigable ? entry.originalAuthorID : nil, name: src.uname ?? "用户") {
              Text((entry.originalNavigable ? "@" : "") + (src.uname ?? "用户"))
                .font(.subheadline.weight(.medium)).foregroundStyle(.tint).lineLimit(1)
            }
            if let date = entry.originalDate {
              Text(date).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
        if let topic = entry.originalTopic { topicLink(topic, font: .footnote) }
        text(entry.originalNodes, plain: entry.originalAuthor == nil ? "" : (entry.summary ?? ""), lines: 5, id: orig)
        if entry.originalHasOpus, inside {
          MomentGo(target: .article(orig)) {
            Text("阅读图文").font(.footnote.weight(.medium)).foregroundStyle(.tint)
          }
        }
        if !entry.originalMedia.isEmpty { pictures(entry.originalMedia) }
        if let card = entry.originalCard { MomentVideoCover(video: card, fullTitle: inside) }
        if let extras = entry.originalExtras { MomentResourceViews(values: extras, dynamic: orig) }
        if let vote = entry.originalVote {
          MomentGo(target: .vote(vote, orig)) {
            Label("查看投票", systemImage: "chart.bar.doc.horizontal").font(.footnote).foregroundStyle(.tint)
          }
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(uiColor: .secondarySystemBackground))
      .contentShape(Rectangle())
      .onTapGesture { open(.detail(orig)) }
    }
  }

  private var interactions: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(entry.interactionLines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: line.type == 1 ? "text.bubble" : "hand.thumbsup").font(.caption)
          ReplyRichText(nodes: line.nodes, maxLines: 2, permitsPreview: false, dynamicID: entry.id,
            textStyle: .footnote)
        }
      }
    }
    .font(.footnote).foregroundStyle(.secondary)
    .padding(.horizontal, 12).padding(.bottom, 2)
    .allowsHitTesting(false)
  }

  // MARK: Pieces

  @ViewBuilder private func authorLink<Label: View>(
    _ mid: Int64?, name: String, @ViewBuilder label: () -> Label
  ) -> some View {
    let content = label()
    if let mid, mid > 0 {
      MomentGo(target: .creator(mid, name)) { content.contentShape(Rectangle()) }
    } else {
      content
    }
  }

  private func topicLink(_ topic: TopicLink, font: Font) -> some View {
    MomentGo(target: .topic(topic)) {
      HStack(spacing: 3) {
        Image(systemName: "number.square.fill")
        Text(topic.name).lineLimit(1)
      }.font(font).foregroundStyle(.tint)
    }
  }

  /// In a list the text is part of the card (a tap opens the detail page, which shows it all);
  /// on the detail page it is selectable and its links work.
  @ViewBuilder private func text(_ nodes: [RichNode], plain: String, lines: Int, id: String) -> some View {
    if !nodes.isEmpty {
      if inside {
        DynamicRichContent(nodes: nodes, maxLines: 0, permitsPreview: true, dynamicID: id)
      } else {
        DynamicRichContent(nodes: nodes, maxLines: lines, permitsPreview: false, dynamicID: id)
          .allowsHitTesting(false).overlay { readMore(id) }
      }
    } else if !plain.isEmpty {
      if inside {
        Text(plain).textSelection(.enabled)
      } else {
        Text(plain).lineLimit(lines).overlay { readMore(id) }
      }
    }
  }
  /// The text owns its taps (opening the moment, where all of it shows). Left to fall through,
  /// a tap on the words went to whichever button sat nearest, such as the video cover below.
  private func readMore(_ id: String) -> some View {
    Color.clear.contentShape(Rectangle()).onTapGesture { open(.detail(id)) }
  }

  /// One picture shows large; two or four sit in a 2-up grid; anything else in a 3-up grid.
  @ViewBuilder private func pictures(_ photos: [GalleryPicture]) -> some View {
    if photos.count == 1 {
      GalleryLink(photos, index: 0) {
        Color.clear.aspectRatio(4 / 3, contentMode: .fit)
          .overlay { GalleryThumb(photo: photos[0], fill: true) }
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .frame(maxWidth: 260, maxHeight: 320, alignment: .leading)
      }
    } else {
      let columns = photos.count == 2 || photos.count == 4 ? 2 : 3
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
        ForEach(photos.indices, id: \.self) { i in
          GalleryLink(photos, index: i) {
            Color.clear.aspectRatio(1, contentMode: .fit)
              .overlay { GalleryThumb(photo: photos[i], fill: true) }
              .background(.quaternary)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
        }
      }
      .frame(maxWidth: columns == 2 ? 280 : .infinity, alignment: .leading)
    }
  }

  private var moreMenu: some View {
    Menu {
      if let bvid = entry.laterBVID, let uid = accounts.state.active {
        Button("稍后再看", systemImage: "clock") { Task { await addLater(bvid, user: uid) } }.disabled(busy)
      }
      if let url = shareURL {
        ShareLink(item: url) { Label("分享动态", systemImage: "square.and.arrow.up") }
        Button("复制链接", systemImage: "link") { UIPasteboard.general.string = url.absoluteString }
      }
      if !entry.blockedAttachment, let kind = entry.replyType, [11, 12, 17].contains(kind),
        let resource = (kind == 17 ? entry.id : entry.shareResource), !resource.isEmpty
      {
        IMShareButton(
          card: .init(
            kind == 17 ? .dynamic : kind == 12 ? .article : .album, id: resource,
            title: entry.body.isEmpty ? entry.author + "的动态" : entry.body, author: entry.author,
            authorID: entry.authorID.map(String.init),
            thumb: kind == 17 ? entry.authorFace : entry.pictures.first))
      }
      Button("保存动态图片", systemImage: "photo") { poster = true }
      if let mid = entry.authorID, String(mid) == accounts.state.active {
        Section {
          Button("可见范围与评论", systemImage: "eye") { ownerSettings = true }
          Button("编辑动态", systemImage: "pencil") { editing = true }
          Button("检查公开可见性", systemImage: "checkmark.shield") {
            if let uid = accounts.state.active { visibility = VisibilityRequest(.moment(entry.id), user: uid) }
          }
          Button(entry.pinned ? "取消置顶" : "置顶", systemImage: entry.pinned ? "pin.slash" : "pin") {
            if let uid = accounts.state.active {
              Task {
                await action("/x/dynamic/feed/space/" + (entry.pinned ? "rm_top" : "set_top"),
                  ["dyn_str": entry.id], user: uid)
              }
            }
          }
          Button("删除", systemImage: "trash", role: .destructive) { removing = true }
        }
      } else if let mid = entry.authorID {
        Section {
          Button("本次隐藏这位 UP 主", systemImage: "eye.slash") {
            MomentSessionHides.shared.hide(mid, name: entry.author, owner: accounts.state.active)
            hidden = true
            if inside { pageCloser?.close() }
          }
          if accounts.state.active != nil {
            Button("举报", systemImage: "exclamationmark.bubble", role: .destructive) { reporting = true }
          } else {
            LocalMute(mid: mid) { hidden = true }
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis").rotationEffect(.degrees(90))
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
        .frame(width: 36, height: 36).contentShape(Rectangle())
    }
    .accessibilityLabel("更多操作")
  }

  static func fullDate(_ entry: DynamicEntry) -> String {
    guard let stamp = entry.timestamp else { return entry.date }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy年M月d日 HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(stamp)))
  }

  // MARK: Actions

  @MainActor private func addLater(_ bvid: String, user uid: String) async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit("/x/v2/history/toview/add", ["bvid": bvid], expectedAccount: uid)
      if uid == accounts.state.active { AppToast.show("已加入稍后再看") }
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
  private func action(_ path: String, _ body: [String: Any], user uid: String, remove: Bool = false) async {
    guard !busy, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
      guard accounts.state.active == uid, let source = DynamicEntry(row), source.authorID.map(String.init) == uid
      else { throw ServiceError("只能管理自己的动态") }
      if !remove && source.tag != nil && source.pinned == path.hasSuffix("/set_top") {
        changed()
        return
      }
      _ = try await BiliAPI.shared.dynPost(path, body, expectedAccount: uid)
      guard accounts.state.active == uid else { return }
      if remove { hidden = true }
      changed()
      if remove && inside { pageCloser?.close() }
    } catch { issue = error.localizedDescription }
  }
}

/// Forward / comment / like, three equal buttons as in the original client's ActionPanel. With
/// `share` it is the detail page's bottom bar (forward / share / comment / like).
struct DynamicActionBar: View {
  let entry: DynamicEntry
  var openComments: (() -> Void)? = nil
  var share = false
  var changed: () -> Void = {}
  @EnvironmentObject private var accounts: AccountContext
  @State private var likedReceipt: Bool?
  @State private var repost = false
  @State private var login = false
  @State private var busy = false
  @State private var issue: String?

  var body: some View {
    HStack(spacing: 0) {
      Button {
        if accounts.state.active == nil { login = true } else { repost = true }
      } label: {
        item("arrowshape.turn.up.right", count(entry.forwardCount) ?? "转发")
      }.accessibilityLabel("转发")
      if share, let url = URL(string: "https://t.bilibili.com/" + entry.id) {
        ShareLink(item: url) { item("square.and.arrow.up", "分享") }.accessibilityLabel("分享")
      }
      if let openComments {
        Button { TouchFeedback.light(); openComments() } label: {
          item("bubble.left", count(entry.commentCount) ?? "评论")
        }.accessibilityLabel("评论")
      } else {
        MomentGo(target: .detail(entry.id, focusReplies: true)) {
          item("bubble.left", count(entry.commentCount) ?? "评论")
        }.accessibilityLabel("评论")
      }
      likeButton
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .frame(height: 42)
    .onChange(of: accounts.state.active) { _, _ in likedReceipt = nil }
    .onChange(of: entry.liked) { _, _ in likedReceipt = nil }
    .piliSheet(isPresented: $repost) { DynamicComposer(repost: entry.id) { changed() } }
    .piliSheet(isPresented: $login) { PiliNavigationStack { QRLoginView() } }
    .alert("动态", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }

  @ViewBuilder private var likeButton: some View {
    if let uid = accounts.state.active {
      let liked = likedReceipt ?? entry.liked
      let shown = (entry.likeCount ?? 0) + (likedReceipt.map { $0 == entry.liked ? 0 : ($0 ? 1 : -1) } ?? 0)
      if likedReceipt == nil
        && (accounts.state.owner(.role(.heartbeat)) != uid || accounts.state.owner(.role(.recommend)) != uid)
      {
        // The list was read with another account, so its like state may not be this account's.
        Menu {
          Button("点赞") { Task { await thumb(true, user: uid) } }
          Button("取消点赞") { Task { await thumb(false, user: uid) } }
        } label: {
          item("hand.thumbsup", count(entry.likeCount) ?? "点赞")
        }.disabled(busy).accessibilityLabel("点赞")
      } else {
        Button {
          TouchFeedback.light()
          Task { await thumb(!liked, user: uid) }
        } label: {
          item(liked ? "hand.thumbsup.fill" : "hand.thumbsup", count(shown) ?? "点赞")
            .foregroundStyle(liked ? Color.accentColor : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
        }.disabled(busy).accessibilityLabel(liked ? "取消点赞" : "点赞")
      }
    } else {
      Button { login = true } label: { item("hand.thumbsup", count(entry.likeCount) ?? "点赞") }
        .accessibilityLabel("点赞")
    }
  }

  private func count(_ n: Int64?) -> String? {
    guard let n, n > 0 else { return nil }
    return n.formatted(.number.notation(.compactName))
  }
  private func item(_ symbol: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 15, weight: .medium))
      Text(label).font(.footnote).monospacedDigit().lineLimit(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }

  @MainActor private func thumb(_ add: Bool, user uid: String) async {
    guard !busy, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      let row = try await BiliAPI.shared.mainDynamicRow(entry.id, owner: uid)
      guard accounts.state.active == uid else { return }
      guard let before = MomentResources.likeStatus(row) else { throw ServiceError("未能读取点赞状态") }
      if before != add {
        _ = try await BiliAPI.shared.dynPost(
          "/x/dynamic/feed/dyn/thumb", ["dyn_id_str": entry.id, "up": add ? 1 : 2, "spmid": "333.1365.0.0"],
          expectedAccount: uid)
      }
      guard accounts.state.active == uid else { return }
      likedReceipt = add
      changed()
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
}

/// Full-width cover with the duration, plays and danmaku over a dark fade, and the title below
/// (the original client's videoSeasonWidget).
struct MomentVideoCover: View {
  let video: MomentVideo
  var fullTitle = false
  var body: some View {
    MomentGo(target: video.preview.map { .video($0) } ?? .link(video.route)) {
      VStack(alignment: .leading, spacing: 6) {
        Color.clear.aspectRatio(16 / 10, contentMode: .fit)
          .overlay {
            SiteThumbnail(url: video.cover) { $0.resizable().scaledToFill() } placeholder: {
              Color(uiColor: .tertiarySystemFill)
            }
          }
          .overlay(alignment: .bottom) { strip }
          .overlay(alignment: .topTrailing) {
            if let badge = video.badge {
              Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.pink, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(8)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        Text(video.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
          .lineLimit(fullTitle ? nil : 2).multilineTextAlignment(.leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
  private var strip: some View {
    HStack(alignment: .bottom, spacing: 8) {
      if let d = video.duration {
        Text(d).monospacedDigit().padding(.horizontal, 4).padding(.vertical, 1)
          .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      }
      if let p = video.plays { Text(p + "播放") }
      if let d = video.danmaku { Text(d + "弹幕") }
      Spacer(minLength: 0)
      Image(systemName: "play.circle.fill").font(.system(size: 30)).symbolRenderingMode(.palette)
        .foregroundStyle(.white, .black.opacity(0.25))
    }
    .font(.caption.weight(.medium)).foregroundStyle(.white).lineLimit(1)
    .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 28)
    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
  }
}
