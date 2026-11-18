import PhotosUI
import PiliWire
import SwiftUI

struct Reply: Identifiable, Decodable {
  let rpid: Int64
  private let author: ServiceID?, rootID: ServiceID?, parentID: ServiceID?
  var mid: Int64? { author?.number }
  var threadRoot: Int64 {
    if let n = rootID?.number, n > 0 { return n }
    return id
  }
  var parent: Int64? { parentID?.number.flatMap { $0 > 0 ? $0 : nil } }
  var authorPinned = false, otherPinned = false, optionLabel: String?, optionID: Int64?,
    cardLabels = [String]()
  var dialogID: Int64?, initialTranslation: Content?
  var translateEnabled = false, showTranslation = false
  var previews: [Reply] = []
  var location = "", likedByOwner = false, repliedByOwner = false
  var nested: Bool { (rootID?.number ?? 0) != (parentID?.number ?? 0) }
  enum CodingKeys: String, CodingKey {
    case rpid
    case author = "mid"
    case rootID = "root"
    case parentID = "parent"
    case member, content, like, action, rcount, ctime, reply_control
  }
  let member: Member?
  let content: Content
  let like: Int?
  let action: Int?
  let rcount: Int?
  let ctime: Double?
  var id: Int64 { rpid }
  typealias Member = ReplyAuthor
  struct Content: Decodable {
    struct Picture: Decodable {
      let img_src: String?
      let live_url: String?
      var img_width: Double? = nil
      var img_height: Double? = nil
    }
    let message: String
    let pictures: [Picture]?
    struct Jump: Decodable {
      let title: String?, extra: Extra?
      var app_url_schema: String? = nil
      struct Extra: Decodable {
        let goods_cm_control: ServiceID?, goods_item_id: ServiceID?, goods_prefetched_cache: String?
        let isWordSearch: Bool
        enum CodingKeys: String, CodingKey {
          case isWordSearch = "is_word_search"
          case goods_cm_control, goods_item_id, goods_prefetched_cache
        }
        init(goods: Bool, word: Bool) {
          isWordSearch = word
          goods_cm_control = goods ? ServiceID(1) : nil
          goods_item_id = nil
          goods_prefetched_cache = nil
        }
        init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          isWordSearch =
            (try? c.decode(Bool.self, forKey: .isWordSearch))
            ?? ((try? c.decode(Int.self, forKey: .isWordSearch)) == 1)
          goods_cm_control = try? c.decode(ServiceID.self, forKey: .goods_cm_control)
          goods_item_id = (try? c.decodeIfPresent(ServiceID.self, forKey: .goods_item_id))?.number
            .map(ServiceID.init)
          goods_prefetched_cache =
            c.contains(.goods_prefetched_cache)
              && (try? c.decodeNil(forKey: .goods_prefetched_cache)) != true ? "" : nil
        }
      }
      var isGoods: Bool {
        extra?.goods_cm_control?.number == 1 || extra?.goods_item_id != nil
          || extra?.goods_prefetched_cache != nil
      }
    }
    let emote: [String: SiteEmote]?, at_name_to_mid: [String: Int64]?, jump_url: [String: Jump]?
    struct Ballot: Decodable { let id: ServiceID?, title: String? }
    let topics: Set<String>, vote: Ballot?
    init(_ p: ReplyGateway.Content) {
      topics = Set(p.topics.keys)
      vote = p.hasVote ? Ballot(id: ServiceID(p.vote.id), title: p.vote.title) : nil
      message = p.message
      pictures = p.pictures.map {
        Picture(img_src: $0.imgSrc, live_url: nil, img_width: $0.imgWidth, img_height: $0.imgHeight)
      }
      emote = p.emotes.mapValues {
        SiteEmote(
          text: $0.text, url: $0.url, meta: .init(size: Int($0.size), alias: nil),
          jump_url: $0.jumpURL, jump_title: $0.jumpTitle, webp_url: $0.webpURL, gif_url: $0.gifURL)
      }
      at_name_to_mid = p.atNameToMid
      jump_url = p.urls.mapValues { value in
        let x = value.extra
        return Jump(
          title: value.title,
          extra: .init(
            goods: value.hasExtra
              && (x.goodsCmControl == 1 || x.hasGoodsItemID || x.hasGoodsPrefetchedCache),
            word: x.isWordSearch), app_url_schema: value.appURLSchema)
      }
    }
    enum Keys: String, CodingKey {
      case message, pictures, emote, at_name_to_mid, jump_url, topics, vote
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      struct TopicInfo: Decodable {}
      topics = Set(((try? c.decode([String: TopicInfo].self, forKey: .topics)) ?? [:]).keys)
      vote = try? c.decode(Ballot.self, forKey: .vote)
      message = try c.decode(String.self, forKey: .message)
      pictures = try? c.decode([Picture].self, forKey: .pictures)
      emote = try? c.decode([String: SiteEmote].self, forKey: .emote)
      at_name_to_mid = (try? c.decode([String: ServiceID].self, forKey: .at_name_to_mid))?
        .compactMapValues(\.number)
      jump_url = try? c.decode([String: Jump].self, forKey: .jump_url)
    }
  }
  struct Control: Decodable { let is_up_top: Bool? }
  let reply_control: Control?
  init(_ r: ReplyGateway.Row, includePreviews: Bool = false) {
    rpid = r.id
    author = ServiceID(r.mid)
    rootID = ServiceID(r.root)
    parentID = ServiceID(r.parent)
    member = ReplyAuthor(row: r)
    content = Content(r.content)
    like = Int(r.like)
    action = Int(r.replyControl.action)
    rcount = Int(r.count)
    ctime = Double(r.ctime)
    reply_control = .init(
      is_up_top: r.replyControl.isUpTop || r.replyControl.isAdminTop || r.replyControl.isVoteTop)
    authorPinned = r.replyControl.isUpTop
    otherPinned = r.replyControl.isAdminTop || r.replyControl.isVoteTop
    if r.replyControl.hasVoteOption {
      let o = r.replyControl.voteOption
      optionLabel =
        (o.labelKind == .red ? "红方" : o.labelKind == .blue ? "蓝方" : "投票") + "  " + o.desc
      optionID = o.voteID > 0 ? o.voteID : nil
    }
    cardLabels = r.replyControl.cardLabels.map(\.textContent).filter { !$0.isEmpty }
    dialogID = r.dialog > 0 ? r.dialog : nil
    initialTranslation = r.hasTranslatedContent ? Content(r.translatedContent) : nil
    translateEnabled =
      r.replyControl.translationSwitch == .showTranslation
      || r.replyControl.translationSwitch == .showOrigin || initialTranslation != nil
    showTranslation =
      r.replyControl.showTranslation || r.replyControl.translationSwitch == .showOrigin
    location = r.replyControl.location
    likedByOwner = r.replyControl.upLike
    repliedByOwner = r.replyControl.upReply
    if includePreviews { previews = r.replies.map { Reply($0) } }
  }
}
extension ReplyFilter {
  func accepts(_ r: Reply) -> Bool {
    let c = r.content
    return !hides(
      author: r.mid, body: c.message, mentions: Set(c.at_name_to_mid?.keys.map { $0 } ?? []),
      hasMedia: c.emote?.isEmpty == false || c.pictures?.isEmpty == false,
      hasGoods: c.jump_url?.values.contains { $0.isGoods } == true, nested: r.nested)
  }
}
extension BiliAPI {
  func replies(
    oid: Int64, type: Int, root: Int64?, sort: Int, cursor: String?, intro: String? = nil,
    expectedViewer: String? = nil
  ) async throws
    -> Page<Reply>
  {
    struct Result: Decodable {
      struct Cursor: Decodable {
        struct Pagination: Decodable { let next_offset: String? }
        let is_end: Bool?
        let pagination_reply: Pagination?
      }
      struct Count: Decodable { let count: Int? }
      struct Top: Decodable { let upper: Reply? }
      let replies: [Reply]?, top_replies: [Reply]?, top: Top?, root: Reply?
      let cursor: Cursor?
      let page: Count?
    }
    let filter = ReplyFilter(
      rules: .current(), blocked: RecommendationRules.current().blockedCreators,
      intro: root == nil ? intro : nil)
    func visible(_ page: Result) -> [Reply] {
      var all: [Reply] = []
      if root != nil, cursor == nil, let first = page.root { all.append(first) }
      if root == nil, cursor == nil {
        if let upper = page.top?.upper { all.append(upper) }
        all.append(contentsOf: page.top_replies ?? [])
      }
      all.append(contentsOf: page.replies ?? [])
      var seen = Set<Int64>()
      return all.filter { row in
        seen.insert(row.id).inserted && filter.accepts(row)
      }
    }
    if let root {
      let n = Int(cursor ?? "1") ?? 1
      let result = try await read(
        "/x/v2/reply/reply",
        ["oid": "\(oid)", "type": "\(type)", "root": "\(root)", "pn": "\(n)", "ps": "20"],
        expectedAccount: expectedViewer, as: Result.self)
      return .init(
        items: visible(result), next: n * 20 < (result.page?.count ?? 0) ? "\(n+1)" : nil)
    }
    if try await AccountJar.shared.current(.role(.heartbeat)) != nil {
      let n = Int(cursor ?? "1") ?? 1
      let r = try await read(
        "/x/v2/reply",
        [
          "oid": "\(oid)", "type": "\(type)", "sort": sort == 3 ? "1" : "0", "pn": "\(n)",
          "ps": "20",
        ], expectedAccount: expectedViewer, as: Result.self)
      return Page(items: visible(r), next: n * 20 < (r.page?.count ?? 0) ? "\(n+1)" : nil)
    }
    let pagination = String(
      decoding: try JSONEncoder().encode(["offset": cursor ?? ""]), as: UTF8.self)
    let result = try await read(
      "/x/v2/reply/main",
      ["oid": "\(oid)", "type": "\(type)", "mode": "\(sort)", "pagination_str": pagination],
      expectedAccount: expectedViewer, as: Result.self)
    let next = result.cursor?.pagination_reply?.next_offset
    return .init(
      items: visible(result),
      next: result.cursor?.is_end == true || next == cursor || next == "" ? nil : next)
  }
}
struct Discussion: View {
  let oid: Int64
  let type: Int
  var root: Int64? = nil
  var owner: Int64? = nil
  var anchor: Int64? = nil
  var intro: String? = nil
  var dialogue: Int64? = nil
  var folded: ReplyGateway.Fold? = nil
  var embeddedTitle: String? = nil
  var readingHeader: AnyView? = nil, readingControls: AnyView? = nil
  var readingCount: ((Int64) -> Void)? = nil
  var mentionOwnerName: String? = nil
  private var suggestedMention: Creator? {
    if let r = target, let mid = r.mid, mid > 0 {
      return Creator(mid: mid, uname: r.member?.uname, face: r.member?.avatar, sign: nil)
    }
    if root == nil, let mid = owner, mid > 0, let name = mentionOwnerName, !name.isEmpty {
      return Creator(mid: mid, uname: name, face: nil, sign: nil)
    }
    return nil
  }
  @AppStorage("reply.mainSort") private var defaultMainSort = 1
  @AppStorage("reply.detailSort") private var defaultDetailSort = 0
  @State private var chosenSort: Int?
  @State private var subject: ReplyGateway.Subject?
  @State private var voteCard: ReplyGateway.Ballot?
  @State private var foldCard: ReplyGateway.Fold?
  @State private var simple = false
  @State private var foldTitle = ""
  private var sort: Int {
    chosenSort ?? ((root == nil ? defaultMainSort : defaultDetailSort) == 0 ? 2 : 3)
  }
  private var subjectOwner: Int64? { (subject?.upMid ?? 0) > 0 ? subject?.upMid : owner }
  private var inputDisabled: Bool {
    !loadedForWriting || subject?.inputDisable == true || subject?.readOnly == true
  }
  private var scope: ReplyGateway.Thread {
    if let folded { return .folded(folded.pagination) }
    if let root, let dialogue { return .dialogue(root: root, id: dialogue) }
    if let root { return .detail(root: root, anchor: anchor) }
    return .main(anchor: anchor)
  }
  private var title: String {
    if folded != nil { return foldTitle.isEmpty ? "折叠评论" : foldTitle }
    if dialogue != nil { return "对话" }
    return root == nil ? "评论" : "回复"
  }
  @AppStorage(ReplyFilterRules.key) private var replySettings = Data()
  private var lineLimit: Int { ReplyLineLimit.lines(replySettings) }
  @EnvironmentObject var accounts: AccountContext
  @State private var revision = 0
  @State private var editor = ReplyDraft()
  @State private var cursor: NSRange?
  @State private var editHint: (NSRange, String)?
  private var draft: String { editor.text }
  private var draftBinding: Binding<String> {
    Binding(
      get: { editor.text },
      set: {
        let change = editHint
        editor.change(to: $0, hint: change)
        editHint = nil
        if let (r, x) = change, x == "@",
          let v = Range(.init(location: r.location, length: 1), in: $0), $0[v] == "@"
        {
          atRange = .init(location: r.location, length: 1)
          mentionPicker = true
        }
      })
  }
  @State private var target: Reply?
  @State private var removal: Reply?
  @State private var removalOwner: String?
  @State private var copyItem: Reply?
  @State private var loadedForWriting = false
  @State private var hidden = Set<Int64>()
  @State private var reported: Reply?
  @State private var pictures = [ReplyComposePhoto]()
  @StateObject private var sessions = ReplyComposeSession()
  @Environment(\.panelTopInset) private var panelInset
  @Environment(\.replyPlayback) private var playback
  @Environment(\.replyPanelPresenter) private var panelPresenter
  @Environment(\.pendingReplyThread) private var pendingThread
  @State private var address: ReplyComposeAddress?
  @State private var importing = false
  @State private var mentionPicker = false
  @State private var atRange: NSRange?
  @State private var stagedAction = Set<Int64>()
  /// List rows may hold only one navigation link; every in-row destination goes through this.
  @State private var route: ReplyRoute?
  fileprivate enum ReplyRoute: Hashable {
    case space(Int64, String), thread(root: Int64, anchor: Int64?), dialogue(root: Int64, id: Int64)
    case poster(Int64), vote(Int64)
  }
  @ViewBuilder private func routeDestination(_ target: ReplyRoute) -> some View {
    switch target {
      case .space(let mid, let name): CreatorSpace(mid: mid, name: name)
      case .thread(let top, let anchor):
        Discussion(oid: oid, type: type, root: top, owner: subjectOwner, anchor: anchor)
      case .dialogue(let top, let id):
        Discussion(oid: oid, type: type, root: top, owner: subjectOwner, dialogue: id)
      case .vote(let id): VoteView(id: id, dynamic: "0")
      case .poster:
        if let r = posterReply { SharePoster(content: .comment(oid: oid, type: type, root: root, reply: r)) }
    }
  }
  /// Inside the video detail a thread or dialogue opens as a panel under the player, as in the
  /// original; everywhere else (and when no panel host is on screen) it opens as a page.
  private func open(_ r: ReplyRoute) {
    if embeddedTitle != nil, let panelPresenter {
      var panel: (String, Discussion)?
      switch r {
      case .thread(let top, let anchor):
        panel = ("评论详情", Discussion(
          oid: oid, type: type, root: top, owner: subjectOwner, anchor: anchor,
          embeddedTitle: "评论详情"))
      case .dialogue(let top, let id):
        panel = ("对话列表", Discussion(
          oid: oid, type: type, root: top, owner: subjectOwner, dialogue: id,
          embeddedTitle: "对话列表"))
      default:
        break
      }
      if let (title, view) = panel,
        panelPresenter.push(title, AnyView(view.environment(\.replyPlayback, playback)))
      {
        return
      }
    }
    route = r
  }
  @State private var posterReply: Reply?
  @State private var myActions = [Int64: Int]()
  private var allowPictures: Bool {
    address?.pictureAllowed == true && subject?.uploadPictureIconState != .hide
      && subject?.uploadPictureIconState != .disable
  }
  private var activePlayer: PlayerModel? {
    guard let m = playback?.model, m.ready, let origin = m.timeline.source, origin.cid > 0,
      (type == 1 && origin.aid == oid) || (type == 33 && m.replyCourseEpisode == oid)
    else { return nil }
    return m
  }
  private func begin(_ reply: Reply?, owner uid: String) {
    guard uid == accounts.state.active, !sending, !inputDisabled else { return }
    let top = root ?? reply?.threadRoot
    guard
      let key = ReplyComposeAddress(
        owner: uid, oid: oid, type: type, root: top, parent: reply?.id ?? top)
    else { return }
    TouchFeedback.light()
    address = key
    target = reply
    let slot = sessions.slots[key] ?? .init()
    editor = slot.text
    cursor = slot.cursor
    pictures = slot.photos
    share = slot.share
    editHint = nil
    atRange = nil
    issue = nil
    writing = true
  }
  private func keepDraft() {
    guard let key = address, key.owner == accounts.state.active else { return }
    if editor.text.isEmpty && pictures.isEmpty && !share {
      sessions.slots[key] = nil
    } else {
      sessions.slots[key] = .init(text: editor, cursor: cursor, photos: pictures, share: share)
    }
  }
  private func insertPeople(_ people: [Creator]) {
    guard address?.owner == accounts.state.active else { return }
    var position =
      atRange.flatMap { r in Range(r, in: editor.text).flatMap { editor.text[$0] == "@" ? r : nil }
      } ?? cursor
    for p in people {
      let t = "@" + (p.uname ?? String(p.mid))
      position = editor.replace(position, with: t, url: t, kind: 2, business: String(p.mid))
    }
    cursor = position
    atRange = nil
    mentionPicker = false
  }
  @State private var share = false
  @State private var writing = false
  @State private var composerHidden = false
  @State private var anchorGlow = true
  @State private var fabAnchor: CGFloat = 0
  private func setComposerHidden(_ value: Bool) {
    guard composerHidden != value else { return }
    withAnimation(.easeInOut(duration: 0.18)) { composerHidden = value }
  }
  // Composer panel state (the original's bottom panel: keyboard, emotes or "more" grid).
  @State private var composerFocus = false
  @State private var composerPanel: ComposerPanel?
  /// Last keyboard height, so the emote and "more" panels take its place without the toolbar moving.
  @State private var keyboardHeight: CGFloat = 0
  @State private var keyboardShown = false
  @State private var pickingPhotos = false
  @State private var capturingFrame = false
  @State private var referencePicker = false
  fileprivate enum ComposerPanel { case emote, more }
  @State private var visibility: VisibilityRequest?
  @State private var afterPublish: VisibilityRequest?
  @AppStorage("social.verifyReply") private var verifyReply = false
  @State private var sending = false
  @State private var issue: String?
  /// A reply thread lays out like the original: the first floor, a thick band, then
  /// "相关回复共N条" with the order toggle, then the replies.
  private var threadHeaderInRow: Bool { root != nil && dialogue == nil && folded == nil && !simple }
  private func threadSortRow(total: Int) -> some View {
    HStack(spacing: 8) {
      Text(total > 0 ? "相关回复共\(total.formatted(.number.notation(.compactName)))条" : "相关回复")
        .font(.footnote)
      Spacer(minLength: 8)
      Button {
        TouchFeedback.light()
        withAnimation(.snappy(duration: 0.25)) {
          chosenSort = sort == 3 ? 2 : 3
          loadedForWriting = false
        }
      } label: {
        Label(sort == 3 ? "按热度" : "按时间", systemImage: "arrow.up.arrow.down")
          .font(.footnote).contentTransition(.numericText())
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      .accessibilityLabel("回复排序：" + (sort == 3 ? "按热度" : "按时间"))
    }
    .padding(.vertical, 8)
  }
  @ViewBuilder private var sortControls: some View {
    let sortable = dialogue == nil && folded == nil && (!simple || root == nil)
      && (simple || subject?.title != "精选评论")
    let heading: String? = {
      if !simple, let subject, !subject.title.isEmpty {
        return subject.title + (root == nil && subject.count > 0
          ? " " + subject.count.formatted(.number.notation(.compactName)) : "")
      }
      // The original names the order on the left ("最热评论") and toggles it on the right.
      return sortable ? (root == nil ? (sort == 3 ? "最热评论" : "最新评论") : "回复") : nil
    }()
    if (heading != nil || sortable) && !threadHeaderInRow {
      HStack(spacing: 8) {
        if let heading { Text(heading).font(.subheadline.weight(.semibold)) }
        Spacer(minLength: 8)
        if sortable {
          Button {
            TouchFeedback.light()
            withAnimation(.snappy(duration: 0.25)) {
              chosenSort = sort == 3 ? 2 : 3
              loadedForWriting = false
              foldCard = nil
              voteCard = nil
            }
          } label: {
            Label(sort == 3 ? "最热" : "最新", systemImage: "arrow.up.arrow.down")
              .font(.footnote.weight(.medium)).contentTransition(.numericText())
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("评论排序：" + (sort == 3 ? "最热" : "最新"))
        }
      }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    if !simple, let ballot = voteCard {
      NavigationLink {
        VoteView(id: ballot.id, dynamic: "0")
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "chart.bar.fill").foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(ballot.title.isEmpty ? "投票" : ballot.title).font(.subheadline.weight(.medium))
            Text("\(ballot.count) 人参与").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 6)
    }
    if !simple, let f = foldCard {
      NavigationLink {
        Discussion(oid: oid, type: type, root: root, owner: subjectOwner, folded: f)
      } label: {
        Label(f.text.isEmpty ? "查看折叠评论" : f.text, systemImage: "rectangle.compress.vertical")
          .font(.footnote).foregroundStyle(.secondary)
      }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 6)
    }
  }
  /// Under the video detail's overlaid header everything has to scroll inside the list.
  private var controlsInList: Bool { readingHeader != nil || panelInset > 0 }
  private var embeddedControls: AnyView? {
    if !controlsInList { return nil }
    return AnyView(
      VStack(spacing: 8) {
        if let readingControls { readingControls }
        sortControls
      }.buttonStyle(.borderless))
  }
  var body: some View {
    VStack(spacing: 0) {
      if !controlsInList {
        if let readingControls { readingControls }
        sortControls
      }
      PageList(
        empty: subject?.emptyBackgroundTextPlain.nonemptyReplyText ?? "暂无评论", focus: anchor,
        embeddedComments: embeddedTitle != nil,
        heading: readingHeader, controls: embeddedControls
      ) { cursor in
        try await load(cursor)
      } row: { (r: Reply) in
        replyRow(r)
      }.id(
        "\(simple):\(sort):\(revision):\(replySettings.hashValue):\(accounts.state.active ?? ""):\(accounts.state.owner(.role(.heartbeat)) ?? "")"
      )
      // The original slides the floating composer away while reading down and brings it
      // back on any scroll up (fab_mixin: UserScrollNotification, 100ms easeInOut).
      .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
        guard embeddedTitle != nil else { return }
        if y <= 8 { setComposerHidden(false); fabAnchor = y; return }
        if composerHidden {
          if fabAnchor - y > 24 { setComposerHidden(false); fabAnchor = y } else { fabAnchor = max(fabAnchor, y) }
        } else {
          if y - fabAnchor > 24 { setComposerHidden(true); fabAnchor = y } else { fabAnchor = min(fabAnchor, y) }
        }
      }
    }.environment(\.replyPlayback, activePlayer == nil ? nil : playback).modifier(
      ReplyEdgeDismiss(standalone: embeddedTitle == nil)
    ).navigationTitle(
      embeddedTitle ?? title
    )
    .task(id: pendingThread.map { ObjectIdentifier($0) }) {
      // A link to a reply (消息 → 回复我的, shared comment links): open its floor exactly as a
      // tap would, once this embedded list is on screen.
      guard embeddedTitle != nil, root == nil, folded == nil, dialogue == nil,
        let link = pendingThread?.take(oid: oid) else { return }
      try? await Task.sleep(for: .milliseconds(250))
      open(.thread(root: link.root, anchor: link.anchor))
    }
    .onChange(of: subject?.count) { _, value in
      if let value, value >= 0 { readingCount?(Int64(value)) }
    }
    .onChange(of: accounts.state.active) { _, _ in
      subject = nil
      foldCard = nil
      hidden.removeAll()
      voteCard = nil
      reported = nil
      loadedForWriting = false
      copyItem = nil
      sessions.slots.removeAll()
      address = nil
      myActions = [:]
      removal = nil
      visibility = nil
      afterPublish = nil
      writing = false
      editor = ReplyDraft()
      cursor = nil
      editHint = nil
      target = nil
      pictures = []
      share = false
    }
    .navigationDestination(item: $route) { target in
      routeDestination(target).environment(\.replyPanelPresenter, nil)
    }
    .overlay(alignment: .bottomTrailing) {
      // Embedded under a player there is no navigation bar of our own: offer a floating composer.
      if embeddedTitle != nil, accounts.state.active != nil {
        Button {
          if let active = accounts.state.active { begin(nil, owner: active) }
        } label: {
          Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .semibold))
            .frame(width: 50, height: 50)
        }
        .piliButtonStyle(.glassProminent).buttonBorderShape(.circle)
        .disabled(inputDisabled).accessibilityLabel("发表评论")
        .padding(.trailing, 18).padding(.bottom, 18)
        .offset(y: composerHidden ? 120 : 0)
        .opacity(composerHidden ? 0 : 1)
        .allowsHitTesting(!composerHidden)
        .transition(.scale.combined(with: .opacity))
      }
    }
    .toolbar {
      if embeddedTitle == nil, folded == nil, dialogue == nil {
        Menu {
          Button(simple ? "显示完整讨论" : "使用简洁列表") {
            simple.toggle()
            loadedForWriting = false
            foldCard = nil
          }
        } label: {
          Image(systemName: "list.bullet").accessibilityLabel("评论列表")
        }
      }
      if embeddedTitle == nil {
        Button {
          if let active = accounts.state.active { begin(nil, owner: active) }
        } label: {
          Image(systemName: "square.and.pencil")
        }.disabled(accounts.state.active == nil || inputDisabled)
      }
    }
    .piliSheet(item: $reported) { r in
      if let uid = accounts.state.active {
        PiliNavigationStack {
          CommunityReport(
            target: .comment(oid: oid, type: type, id: r.id, author: r.mid), uid: uid
          ) {
            hidden.insert(r.id)
            revision += 1
          }.toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { reported = nil } }
          }
        }
      }
    }
    .piliSheet(item: $copyItem) { ReplySelection(reply: $0) }
    .piliSheet(item: $visibility) { VisibilityPanel(request: $0) }
    // A transparent full-screen layer like the original's route: the page and video stay visible
    // above, the panel sits on the keyboard. (A system sheet resizes and jumps with the keyboard.)
    .fullScreenCover(
      isPresented: $writing,
      onDismiss: {
        keepDraft()
        address = nil
        composerPanel = nil
        composerFocus = false
        if let pending = afterPublish {
          afterPublish = nil
          visibility = pending
        }
      }
    ) {
      writingPanel.modifier(NativeInterfaceScale()).presentationBackground(.clear)
    }.confirmationDialog(
      "删除这条评论？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
      presenting: removal
    ) { r in
      Button("删除", role: .destructive) {
        Task { if let uid = removalOwner { await change(r, "del", "1", as: uid) } }
      }
    }
    .alert(
      "评论",
      isPresented: Binding(get: { issue != nil && !writing }, set: { if !$0 { issue = nil } })
    ) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  /// The original's comment panel: anchored to the bottom over a transparent layer (tap above to
  /// close) with the text on top, a toolbar row, and below it either the keyboard, the emote
  /// palette or the "more" grid at the keyboard's height.
  private var writingPanel: some View {
    let canSend =
      !(sending || importing || inputDisabled
        || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pictures.isEmpty))
    var prompt = "输入回复内容"
    if let target {
      let name: String = target.member?.uname ?? "用户"
      prompt = "回复 @" + name
    } else if let hint = subject?.rootText, !hint.isEmpty {
      prompt = hint
    }
    // The space under the toolbar: the keyboard's height while typing, the panel's while an
    // emote or "more" panel is open. Keyboard and panels swap inside it, so the toolbar holds
    // still, as in the original.
    let keyboardSpace = max(0, keyboardHeight - WindowMetrics.homeIndicator)
    let base: CGFloat = composerPanel == .emote ? 280 : 170
    let reserve: CGFloat =
      composerPanel != nil ? max(base, keyboardSpace) : (keyboardShown ? keyboardSpace : 0)
    return VStack(spacing: 0) {
      Color.clear.contentShape(.rect)
        .onTapGesture { if !sending && !importing { writing = false } }
        .accessibilityLabel("关闭评论面板").accessibilityAddTraits(.isButton)
      composerBody(canSend: canSend, prompt: prompt, reserve: reserve)
    }
    .ignoresSafeArea(.keyboard)
    .animation(.easeOut(duration: 0.25), value: reserve)
    .onReceive(
      NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    ) { n in
      guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
      let height = WindowMetrics.keyboardOverlap(end)
      if height > 120 { keyboardHeight = height }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) {
      _ in
      keyboardShown = true
      // The keyboard now covers the panel's space; drop the panel underneath it.
      composerPanel = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
      _ in keyboardShown = false
    }
    .onAppear {
      // Opening the panel goes straight to typing, as in the original.
      composerPanel = nil
      composerFocus = true
    }
    .piliSheet(isPresented: $mentionPicker) {
      if let key = address {
        PiliNavigationStack {
          MentionChooser(uid: key.owner, suggested: suggestedMention) { insertPeople($0) }
            .toolbar {
              Button("取消") {
                mentionPicker = false
                atRange = nil
              }
            }
        }
      }
    }
    .piliSheet(isPresented: $referencePicker) {
      if let uid = accounts.state.active {
        PiliNavigationStack {
          ReplyReferencePicker(oid: oid, type: type, uid: uid) { r in
            guard address?.owner == uid, accounts.state.active == uid else { return }
            cursor = editor.replace(cursor, with: r.title.isEmpty ? r.id : r.title, url: r.id)
            referencePicker = false
          }
          .toolbar { Button("取消") { referencePicker = false } }
        }
      }
    }
  }
  private func composerBody(canSend: Bool, prompt: String, reserve: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text(prompt).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            .padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true)
        }
        CursorEditor(
          text: draftBinding, selection: $cursor, name: prompt, minimum: 88, maximum: 176,
          willEdit: { editHint = ($0, $1) }, focused: $composerFocus)
      }
      .padding(.horizontal, 15).padding(.top, 14).padding(.bottom, 8)
      if let issue {
        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2)
          .padding(.horizontal, 15).padding(.bottom, 6)
      }
      if let key = address {
        ReplyComposePhotos(
          pictures: $pictures, session: sessions, owner: key.owner,
          player: subject?.screenshotIconState == .hide
            || subject?.screenshotIconState == .disable || activePlayer?.isPreview == true
            ? nil : activePlayer, current: { address == key && writing && allowPictures },
          importing: $importing, picking: $pickingPhotos, shot: $capturingFrame
        ) { issue = $0 }
      }
      Divider().opacity(0.5)
      composerToolbar(canSend: canSend)
      ZStack(alignment: .top) {
        switch composerPanel {
        case .emote:
          EmotePalette(select: { token in cursor = editor.replace(cursor, with: token) }, inline: true)
        case .more:
          composerMoreGrid
        case nil:
          Color.clear
        }
      }
      .frame(height: reserve, alignment: .top)
      .clipped()
    }
    .disabled(sending)
    .frame(maxWidth: 640)
    .frame(maxWidth: .infinity)
    .background {
      // Fixed top corners; the bottom follows the display's corners (iPhone Duo, iPad, iPhone).
      ConcentricRectangle(uniformTopCorners: .fixed(14), uniformBottomCorners: .concentric)
        .fill(Color(uiColor: .systemBackground))
        .shadow(color: .black.opacity(0.12), radius: 12, y: -2)
        .ignoresSafeArea(.container, edges: .bottom)
    }
  }
  /// Emote, picture, @, formula, more and share-to-dynamic, then the send button.
  private func composerToolbar(canSend: Bool) -> some View {
    HStack(spacing: 6) {
      composerTool(
        composerPanel == .emote ? "keyboard" : "face.smiling",
        label: composerPanel == .emote ? "键盘" : "表情", selected: composerPanel == .emote
      ) {
        if composerPanel == .emote {
          composerFocus = true
        } else {
          composerFocus = false
          composerPanel = .emote
        }
      }
      if root == nil {
        composerTool(allowPictures ? "photo" : "photo.badge.exclamationmark", label: "图片") {
          if allowPictures {
            if pictures.count >= 9 { AppToast.show("最多选择 9 张图片") } else { pickingPhotos = true }
          } else {
            AppToast.show("当前评论区不支持发送图片")
          }
        }
      }
      composerTool("at", label: "提到用户") {
        atRange = nil
        mentionPicker = true
      }
      composerTool("function", label: "公式", selected: editor.showingMath) {
        issue = editor.toggleMath()
        cursor = nil
      }
      composerTool("plus.circle", label: "更多", selected: composerPanel == .more) {
        if composerPanel == .more {
          composerFocus = true
        } else {
          composerFocus = false
          composerPanel = .more
        }
      }
      composerTool("arrow.2.squarepath", label: "转到动态", selected: share) { share.toggle() }
      Spacer(minLength: 4)
      Button {
        Task { await send() }
      } label: {
        Group {
          if sending { ProgressView().controlSize(.small) } else { Text("发送") }
        }
        .font(.subheadline.weight(.semibold)).frame(minWidth: 40)
      }
      .piliButtonStyle(.glassProminent)
      .disabled(!canSend)
    }
    .padding(.horizontal, 12).frame(height: 52)
  }
  private func composerTool(
    _ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button {
      TouchFeedback.light()
      action()
    } label: {
      Image(systemName: symbol).font(.system(size: 19, weight: .regular))
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .frame(width: 36, height: 36)
        .background(
          selected ? Color.accentColor.opacity(0.14) : Color.clear,
          in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
    }
    .buttonStyle(.plain).accessibilityLabel(label)
  }
  /// The original's "more" grid: insert a video or article, the playback time, a video frame.
  private var composerMoreGrid: some View {
    let player = activePlayer
    let canShoot =
      root == nil && allowPictures && player != nil
      && subject?.screenshotIconState != .hide && subject?.screenshotIconState != .disable
      && player?.isPreview != true
    return LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 58, maximum: 72), spacing: 12)], alignment: .leading,
      spacing: 12
    ) {
      if accounts.state.active != nil {
        composerMoreItem("doc.badge.plus", "插入内容") { referencePicker = true }
      }
      if let m = player {
        composerMoreItem("location", "视频进度") {
          if let t = ReplyComposeAddress.timestamp(m.seconds) {
            cursor = editor.replace(cursor, with: " " + t + " ")
          }
        }
      }
      if canShoot {
        composerMoreItem("camera.viewfinder", "视频截图") {
          if pictures.count >= 9 { AppToast.show("最多选择 9 张图片") } else { capturingFrame = true }
        }
      }
    }
    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
  }
  private func composerMoreItem(_ symbol: String, _ title: String, action: @escaping () -> Void)
    -> some View
  {
    Button {
      TouchFeedback.light()
      action()
    } label: {
      VStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
          .background(
            Color(uiColor: .tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        Text(title).font(.footnote).foregroundStyle(.primary).lineLimit(1)
      }
    }
    .buttonStyle(.plain)
  }
  /// One comment, laid out like the original client: avatar column, name and meta, the body under
  /// the name with an inline "展开", a quiet action row, then a grey box of reply previews.
  private func replyRow(_ r: Reply) -> some View {
    let isOwner = r.mid != nil && r.mid == subjectOwner
    let opensThread = root == nil && dialogue == nil
    return HStack(alignment: .top, spacing: 10) {
      Group {
        if let mid = r.mid, mid > 0 {
          Button {
            TouchFeedback.light()
            route = .space(mid, r.member?.uname ?? "用户")
          } label: { ReplyAvatar(member: r.member, size: 34) }
            .buttonStyle(.plain).accessibilityLabel((r.member?.uname ?? "用户") + "的空间")
        } else {
          ReplyAvatar(member: r.member, size: 34)
        }
      }.padding(.top, 1)
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 5) {
          let author = ReplyAuthorLabel(member: r.member, isOwner: isOwner, showsAvatar: false)
            .font(.footnote.weight(.medium))
          if let mid = r.mid, mid > 0 {
            Button { TouchFeedback.light(); route = .space(mid, r.member?.uname ?? "用户") }
              label: { author }.buttonStyle(.plain)
          } else { author }
          if isOwner { replyTag("UP", tint: .pink) }
          Spacer(minLength: 4)
        }
        // The decoration card floats in the corner without growing the row, as in the original.
        .padding(.trailing, r.member?.card != nil ? 84 : 0)
        .overlay(alignment: .topTrailing) {
          ReplyCardBadge(card: r.member?.card).offset(y: -4).allowsHitTesting(false)
        }
        replyMeta(r).font(.caption2).foregroundStyle(.secondary).padding(.top, 1)
        VStack(alignment: .leading, spacing: 6) {
          if let label = r.optionLabel {
            if let id = r.optionID {
              Button(label) { route = .vote(id) }.font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
            } else {
              Text(label).font(.caption).foregroundStyle(.secondary)
            }
          }
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            if r.reply_control?.is_up_top == true { replyTag("置顶", tint: .orange) }
            VStack(alignment: .leading, spacing: 4) {
              TranslatableReply(
                reply: r, lines: lineLimit, oid: oid, type: type, uid: accounts.state.active)
            }
          }
          ReplyPictures(items: r.content.pictures ?? [])
        }.padding(.top, 8)
        replyActions(r).padding(.top, 2)
        if root == nil, !r.previews.isEmpty || (r.rcount ?? 0) > 0 {
          previewBox(r).padding(.top, 2)
        }
      }
    }
    .modifier(ThreadFirstFloor(
      isFirst: threadHeaderInRow && r.id == root,
      sortRow: AnyView(threadSortRow(total: r.rcount ?? 0))))
    .padding(.top, 12).padding(.bottom, 6)
    // The located reply flashes like the original's colorAnimController, then settles.
    .background {
      if r.id == anchor {
        Color.accentColor.opacity(anchorGlow ? 0.16 : 0).padding(.horizontal, -14)
          .task {
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.6)) { anchorGlow = false }
          }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { if opensThread { open(.thread(root: r.id, anchor: nil)) } }
    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12))
    .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
    .contextMenu {
      if let active = accounts.state.active {
        Button("回复", systemImage: "arrowshape.turn.up.left") { begin(r, owner: active) }
          .disabled(inputDisabled)
      }
      Button("复制全部", systemImage: "doc.on.doc") { UIPasteboard.general.string = r.content.message }
      Button("自由复制", systemImage: "selection.pin.in.out") { copyItem = r }
      Button("分享评论", systemImage: "square.and.arrow.up") { posterReply = r; route = .poster(r.id) }
      if let active = accounts.state.active {
        Button("举报评论", systemImage: "exclamationmark.bubble") { reported = r }
        if r.mid.map(String.init) == active || subjectOwner.map(String.init) == active {
          Button("删除评论", systemImage: "trash", role: .destructive) {
            removalOwner = active
            removal = r
          }
        }
      }
    }
  }
  private func replyTag(_ text: String, tint: Color) -> some View {
    Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
      .padding(.horizontal, 4).padding(.vertical, 1)
      .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 0.8))
  }
  private func replyMeta(_ r: Reply) -> Text {
    var parts: [String] = []
    if let d = r.ctime {
      parts.append(Date(timeIntervalSince1970: d).formatted(.relative(presentation: .named)))
    }
    if !r.location.isEmpty { parts.append(r.location) }
    // "UP主觉得很赞" arrives as a card label in the action row, as in the original client.
    if r.likedByOwner, r.cardLabels.isEmpty { parts.append("UP 主觉得很赞") }
    return Text(parts.joined(separator: " · "))
  }
  /// Grey box with up to three replies, each a single two-line run "name: text", then the total.
  private func previewBox(_ r: Reply) -> some View {
    let total = r.rcount ?? 0
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(r.previews) { child in
        Button {
          open(.thread(root: r.id, anchor: child.id))
        } label: {
          previewLine(child).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu {
          if let mid = child.mid, mid > 0 {
            Button("查看作者空间", systemImage: "person.crop.circle") {
              TouchFeedback.light()
              route = .space(mid, child.member?.uname ?? "用户")
            }
          }
        }
      }
      if total > r.previews.count {
        Button {
          open(.thread(root: r.rpid, anchor: nil))
        } label: {
          HStack(spacing: 2) {
            if r.repliedByOwner { Text("UP 主等人 ").foregroundStyle(.primary.opacity(0.85)) }
            Text("共 \(total) 条回复").foregroundStyle(.tint)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
          }.font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }
    .padding(.vertical, 3)
    .background(Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
  private func previewLine(_ child: Reply) -> some View {
    let name = Text(child.member?.uname ?? "用户").foregroundStyle(.tint)
    let up = child.mid != nil && child.mid == subjectOwner ? Text(" UP").font(.caption2.weight(.bold)).foregroundStyle(.pink) : Text("")
    let pictures = (child.content.pictures?.count ?? 0) > 0 ? Text(" [图片]").foregroundStyle(.secondary) : Text("")
    return (name + up + Text(": ") + Text(child.content.message).foregroundStyle(.primary.opacity(0.85)) + pictures)
      .font(.subheadline).lineSpacing(2).lineLimit(2).multilineTextAlignment(.leading)
  }
  @ViewBuilder private func replyActions(_ r: Reply) -> some View {
    HStack(spacing: 14) {
      if let active = accounts.state.active {
        Button { begin(r, owner: active) } label: {
          HStack(spacing: 3) {
            Image(systemName: "arrowshape.turn.up.left")
            Text("回复")
          }
        }.buttonStyle(.plain).disabled(inputDisabled)
      }
      if !r.cardLabels.isEmpty {
        Text(r.cardLabels.joined(separator: "  ")).foregroundStyle(.tint).lineLimit(1)
      }
      if let p = r.parent, dialogue != nil, p != r.threadRoot {
        Button("跳转回复") { open(.thread(root: r.threadRoot, anchor: p)) }.buttonStyle(.plain)
      }
      if !simple, dialogue == nil, let d = r.dialogID, d != r.id, r.threadRoot != r.id {
        Button("查看对话") { open(.dialogue(root: r.threadRoot, id: d)) }.buttonStyle(.plain)
      }
      Spacer(minLength: 0)
      likeButton(r)
      if let active = accounts.state.active {
        if let state = readAction(r, viewer: active) {
          Button {
            Task { await change(r, "hate", state == 2 ? "0" : "1", as: active) }
          } label: {
            Image(systemName: state == 2 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
              .foregroundStyle(state == 2 ? Color.accentColor : Color.secondary)
          }.buttonStyle(.plain).accessibilityLabel(state == 2 ? "取消点踩" : "点踩")
        }
        Menu {
          if readAction(r, viewer: active) == nil {
            Button("点踩") { Task { await change(r, "hate", "1", as: active) } }
            Button("取消点踩") { Task { await change(r, "hate", "0", as: active) } }
          }
          if let owner = subjectOwner, String(owner) == active, r.threadRoot == r.id,
            !r.otherPinned
          {
            Button(r.reply_control?.is_up_top == true ? "取消置顶" : "置顶") {
              Task {
                await change(r, "top", r.reply_control?.is_up_top == true ? "0" : "1", as: active)
              }
            }
          }
          Button("分享评论", systemImage: "square.and.arrow.up") { posterReply = r; route = .poster(r.id) }
          Button("举报评论", systemImage: "exclamationmark.bubble") { reported = r }
          if r.mid.map(String.init) == active {
            Button("检查公开可见性") {
              visibility = VisibilityRequest(
                .reply(oid: oid, kind: type, root: r.threadRoot, id: r.id), user: active)
            }
          }
          if r.mid.map(String.init) == active || subjectOwner.map(String.init) == active {
            Button("删除评论", systemImage: "trash", role: .destructive) {
              removalOwner = active
              removal = r
            }
          }
        } label: {
          Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
        }.accessibilityLabel("更多操作")
      } else if let mid = r.mid {
        LocalMute(mid: mid) { revision += 1 }.labelStyle(.iconOnly)
      }
    }
    .font(.caption).foregroundStyle(.secondary).frame(minHeight: 30)
  }
  @MainActor private func load(_ cursor: String?) async throws -> Page<Reply> {
    if simple {
      let viewer = accounts.state.owner(.role(.heartbeat))
      let p = try await BiliAPI.shared.replies(
        oid: oid, type: type, root: root, sort: sort, cursor: cursor, intro: intro,
        expectedViewer: viewer ?? "")
      try Task.checkCancellation()
      guard simple, accounts.state.owner(.role(.heartbeat)) == viewer else {
        throw CancellationError()
      }
      loadedForWriting = true
      return .init(items: p.items.filter { !hidden.contains($0.id) }, next: p.next)
    }
    let uid = accounts.state.active
    let ordering = sort
    let p = try await BiliAPI.shared.commentService(for: uid).list(
      oid: oid, type: Int64(type), thread: scope, newest: ordering == 2, offset: cursor)
    try Task.checkCancellation()
    guard !simple, sort == ordering, accounts.state.active == uid else { throw CancellationError() }
    loadedForWriting = true
    if cursor == nil || p.subject != nil { subject = p.subject }
    if cursor == nil || p.fold != nil { foldCard = p.fold }
    if cursor == nil { voteCard = p.vote }
    if !p.title.isEmpty { foldTitle = p.title }
    let base = ReplyFilter(
      rules: .current(), blocked: RecommendationRules.current().blockedCreators, intro: nil)
    let top = ReplyFilter(
      rules: .current(), blocked: RecommendationRules.current().blockedCreators,
      intro: root == nil ? intro : nil)
    // Converting and filtering a page (rich text, regex filters) runs off the main thread.
    let hiddenIDs = hidden
    let previews = root == nil && folded == nil
    let rows = await Task.detached(priority: .userInitiated) { () -> [Reply] in
      p.rows.compactMap { wire -> Reply? in
        var row = Reply(wire, includePreviews: previews)
        guard !hiddenIDs.contains(row.id), top.accepts(row) else { return nil }
        row.previews = row.previews.filter { !hiddenIDs.contains($0.id) && base.accepts($0) }
        return row
      }
    }.value
    try Task.checkCancellation()
    guard !simple, sort == ordering, accounts.state.active == uid else { throw CancellationError() }
    return .init(items: rows, next: p.next)
  }
  private func readAction(_ r: Reply, viewer uid: String) -> Int? {
    if let confirmed = myActions[r.id] { return confirmed }
    if simple {
      guard accounts.state.owner(.role(.heartbeat)) == uid else { return nil }
    } else {
      guard accounts.state.accounts.first(where: { $0.id == uid })?.mobileToken?.isEmpty == false
      else { return nil }
    }
    return r.action.flatMap { (0...2).contains($0) ? $0 : nil }
  }
  @ViewBuilder private func likeButton(_ r: Reply) -> some View {
    if let uid = accounts.state.active {
      if let state = readAction(r, viewer: uid) {
        Button {
          Task { await change(r, "action", state == 1 ? "0" : "1", as: uid) }
        } label: {
          likeLabel(r, active: state == 1)
        }.buttonStyle(.plain).disabled(stagedAction.contains(r.id))
      } else {
        Menu {
          Button("点赞") { Task { await change(r, "action", "1", as: uid) } }
          Button("取消点赞") { Task { await change(r, "action", "0", as: uid) } }
        } label: {
          likeLabel(r, active: false)
        }.disabled(stagedAction.contains(r.id))
      }
    } else {
      likeLabel(r, active: false)
    }
  }
  private func likeLabel(_ r: Reply, active: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: active ? "hand.thumbsup.fill" : "hand.thumbsup")
      if let n = r.like, n > 0 {
        Text(Int64(n).formatted(.number.notation(.compactName))).monospacedDigit()
      }
    }
    .foregroundStyle(active ? Color.accentColor : Color.secondary)
    .accessibilityElement(children: .combine).accessibilityLabel("点赞 \(r.like ?? 0)")
  }
  @MainActor private func change(_ r: Reply, _ kind: String, _ flag: String, as uid: String) async {
    guard accounts.state.active == uid, ["top", "del", "hate", "action"].contains(kind),
      ["0", "1"].contains(flag), stagedAction.insert(r.id).inserted
    else { return }
    defer { stagedAction.remove(r.id) }
    if kind == "top" {
      guard subjectOwner.map(String.init) == uid, r.threadRoot == r.id, !r.otherPinned else {
        return
      }
    }
    if kind == "del" {
      guard subjectOwner.map(String.init) == uid || r.mid.map(String.init) == uid else { return }
    }
    if kind == "hate" || kind == "action" { TouchFeedback.light() }
    do {
      var fields = ["oid": String(oid), "type": String(type), "rpid": String(r.id)]
      if kind != "del" { fields["action"] = flag }
      try await BiliAPI.shared.submit("/x/v2/reply/" + kind, fields, expectedAccount: uid)
      if kind == "del" {
        do { try await ReplyArchive.shared.remove(r.id, uid: uid) } catch {
          if accounts.state.active == uid { issue = "评论已删除，本机记录未更新：" + error.localizedDescription }
        }
      }
      guard accounts.state.active == uid else { return }
      if kind == "del" { hidden.insert(r.id) }
      if ["hate", "action"].contains(kind) {
        let selected = kind == "hate" ? 2 : 1
        if flag == "1" {
          myActions[r.id] = selected
        } else if readAction(r, viewer: uid) == selected {
          myActions[r.id] = 0
        }
      }
      revision += 1
    } catch { if accounts.state.active == uid { issue = error.localizedDescription } }
  }
  private func send() async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard !sending, !importing, !inputDisabled, let key = address,
      key.owner == accounts.state.active
    else { return }
    TouchFeedback.light()
    sending = true
    defer { sending = false }
    do {
      let submittingUser = key.owner
      var p = try key.fields(
        text: editor.raw, mentionIDs: editor.mentionIDs(), share: share,
        targetName: target?.member?.uname)
      guard pictures.isEmpty || allowPictures else { throw ServiceError("这条回复不能发送图片") }
      if !pictures.isEmpty {
        guard let account = try await AccountJar.shared.current(), account.id == submittingUser
        else {
          throw ServiceError("请先登录")
        }
        var rows: [[String: Any]] = []
        for selected in pictures {
          guard accounts.state.active == submittingUser, address == key else {
            throw ServiceError("账号或回复对象已变更")
          }
          let jpeg = try Data(contentsOf: selected.file, options: .mappedIfSafe)
          let up = try await BiliAPI.shared.upload(jpeg, account: account)
          rows.append([
            "img_src": up.image_url, "img_width": up.image_width, "img_height": up.image_height,
            "img_size": up.img_size ?? Double(jpeg.count) / 1024,
          ])
        }
        p["pictures"] = String(
          decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
      }
      guard key.owner == accounts.state.active, address == key, !inputDisabled else {
        throw ServiceError("账号或回复对象已变更")
      }
      let published = try await BiliAPI.shared.submitResponse(
        "/x/v2/reply/add", p, expectedAccount: submittingUser)
      let confirmed = key.receiptID(published)
      var localIssue: String?
      if let confirmed {
        do {
          try await ReplyArchive.shared.capture(
            published, oid: oid, type: type, root: key.root, uid: submittingUser)
        } catch { localIssue = "评论已发表，本机记录未保存：" + error.localizedDescription }
        if verifyReply, accounts.state.active == submittingUser, address == key {
          afterPublish = .init(
            .reply(oid: oid, kind: type, root: key.root ?? confirmed, id: confirmed),
            user: submittingUser, after: 8)
        }
      } else {
        localIssue = "评论已提交，暂未返回可核对的评论编号"
      }
      sessions.slots[key] = nil
      guard accounts.state.active == submittingUser, address == key else { return }
      address = nil
      editor = ReplyDraft()
      cursor = nil
      editHint = nil
      target = nil
      pictures = []
      share = false
      issue = localIssue
      writing = false
      revision += 1
    } catch {
      if accounts.state.active == key.owner, address == key { issue = error.localizedDescription }
    }
  }
}

extension String { fileprivate var nonemptyReplyText: String? { isEmpty ? nil : self } }

/// Under a thread's first floor: the original's 6pt band across the row, then the sort row.
private struct ThreadFirstFloor: ViewModifier {
  let isFirst: Bool
  let sortRow: AnyView
  func body(content: Content) -> some View {
    if isFirst {
      VStack(alignment: .leading, spacing: 0) {
        content
        Rectangle().fill(Color(uiColor: .secondarySystemBackground)).frame(height: 6)
          .padding(.horizontal, -20).padding(.top, 8)
        sortRow
      }
      .listRowSeparator(.hidden, edges: .bottom)
    } else {
      content
    }
  }
}

/// The reply line limit, decoded once per settings change instead of once per row.
@MainActor private enum ReplyLineLimit {
  private static var source: Data?
  private static var value = 6
  static func lines(_ data: Data) -> Int {
    if data != source {
      source = data
      value = (try? JSONDecoder().decode(ReplyFilterRules.self, from: data))?.lines ?? 6
    }
    return value
  }
}
