import SwiftUI

struct Creator: Decodable, Identifiable {
  let mid: Int64
  let uname: String?
  let face: String?
  let sign: String?
  var mtime: Int64? = nil
  var id: Int64 { mid }
}
struct FollowGroup: Decodable, Identifiable {
  let tagid: Int
  let name: String?
  let count: Int?
  var tip: String? = nil
  var id: Int { tagid }
}
extension BiliAPI {
  func connections(uid: String, fans: Bool, page: Int, term: String, order: Int = 0,expectedAccount:String?=nil) async throws
    -> Page<Creator>
  {
    struct List: Decodable {
      let list: [Creator]?
      let total: Int?
    }
    let search = !fans && !term.isEmpty
    var query = ["vmid": uid, "pn": String(page), "ps": "20", "order": "desc"]
    if search {
      query["name"] = term
    } else if !fans {
      query["order_type"] = order == 1 ? "attention" : ""
    }
    let r = try await read(
      search
        ? "/x/relation/followings/search" : fans ? "/x/relation/fans" : "/x/relation/followings",
      query,expectedAccount:expectedAccount,as: List.self)
    return Page(items: r.list ?? [], next: page * 20 < (r.total ?? 0) ? "\(page+1)" : nil)
  }
  func uploads(uid: Int64, page: Int, keyword: String) async throws -> Page<Video> {
    struct Result: Decodable {
      struct List: Decodable {
        struct Item: Decodable {
          let bvid: String, title: String, pic: String
          let author: String?
        }
        let vlist: [Item]?
      }
      struct Count: Decodable { let count: Int? }
      let list: List?
      let page: Count?
    }
    let r = try await read(
      "/x/space/wbi/arc/search",
      try await sign([
        "mid": "\(uid)", "pn": "\(page)", "ps": "25", "keyword": keyword, "order": "pubdate",
      ]), as: Result.self)
    return Page(
      items: (r.list?.vlist ?? []).map {
        .preview(id: $0.bvid, title: $0.title, cover: $0.pic, author: $0.author)
      }, next: page * 25 < (r.page?.count ?? 0) ? "\(page+1)" : nil)
  }
}
struct CreatorLinks: View {
  let uid: String
  /// Only the group and blacklist rows (the profile lists following and fans itself).
  var extrasOnly = false
  var body: some View {
    if !extrasOnly {
      NavigationLink { RelationsList(uid: uid, fans: false) } label: {
        SettingsRowLabel(title: "我的关注", symbol: "person.2.fill", color: .indigo)
      }
      NavigationLink { RelationsList(uid: uid, fans: true) } label: {
        SettingsRowLabel(title: "我的粉丝", symbol: "heart.fill", color: .pink)
      }
    }
    NavigationLink { FollowGroupsView() } label: {
      SettingsRowLabel(title: "关注分组", symbol: "folder.fill", color: .cyan)
    }
    NavigationLink { BlacklistView(uid: uid) } label: {
      SettingsRowLabel(title: "黑名单", symbol: "hand.raised.fill", color: .gray)
    }
  }
}
private struct FollowSortMenu: View {
  @Binding var order: Int
  var body: some View {
    Menu {
      Picker("关注排序", selection: $order) {
        Text("最近关注").tag(0)
        Text("最常访问").tag(1)
      }
    } label: {
      Label("关注排序", systemImage: "arrow.up.arrow.down")
    }
  }
}
struct RelationsList: View {
  let uid: String, fans: Bool
  @AppStorage("follow.sort") private var order = 0
  @EnvironmentObject private var accounts: AccountContext
  @State private var remoteName: String?
  @State private var removing: Creator?
  @State private var revision = 0
  @State private var busy = false
  @State private var issue: String?
  @State private var draft = ""
  @State private var query = ""
  private var creatorsList: some View {
    PageList(empty: fans ? "暂无粉丝" : "暂无关注") { p in
      try await BiliAPI.shared.connections(
        uid: uid, fans: fans, page: Int(p ?? "1") ?? 1, term: query, order: order, expectedAccount: accounts.state.active ?? "")
    } row: { person in
      HStack {
        CreatorLink(person: person)
        if !fans && uid == accounts.state.active { CreatorQuickRelation(mid: person.mid, knownFollowing: true) }
      }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if fans && uid == accounts.state.active {
          Button("移除粉丝", role: .destructive) { removing = person }.disabled(busy)
        }
      }.contextMenu {
        if fans && uid == accounts.state.active {
          Button("移除粉丝", role: .destructive) { removing = person }.disabled(busy)
        }
      }
    }
  }
  var body: some View {
    let list = creatorsList
    .id("\(query):\(revision):\(fans || !query.isEmpty ? 0 : order):\(accounts.state.active ?? "")")
    .navigationTitle((remoteName.map { $0 + "的" } ?? "") + (fans ? "粉丝" : "关注"))
    .task(id: uid + ":" + (accounts.state.active ?? "")) {
      let actor = accounts.state.active
      remoteName = nil
      guard actor != uid else { return }
      let name = try? await BiliAPI.shared.creatorCardName(uid, owner: actor)
      if !Task.isCancelled, accounts.state.active == actor { remoteName = name }
    }
    .toolbar {
      if !fans && query.isEmpty { FollowSortMenu(order: $order) }
      if !fans, uid == accounts.state.active {
        NavigationLink("分组") { FollowGroupsView() }
        NavigationLink("黑名单") { BlacklistView(uid: uid) }
      }
    }
    .confirmationDialog(
      "移除这位粉丝？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { p in
      Button("移除 " + (p.uname ?? String(p.mid)), role: .destructive) { Task { await remove(p) } }
    }.alert("未能移除", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
    .onChange(of: accounts.state.active) { _, _ in removing = nil }
    if fans {
      list
    } else {
      list.searchable(text: $draft, prompt: "搜索关注").onSubmit(of: .search) { query = draft }
        .onChange(of: draft) { _, s in if s.isEmpty { query = "" } }
    }
  }
  @MainActor private func remove(_ p: Creator) async {
    guard !busy, fans, accounts.state.active == uid else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/modify", ["fid": String(p.mid), "act": "7", "re_src": "11"],
        expectedAccount: uid)
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
struct CreatorLink: View {
  let person: Creator
  var body: some View {
    PlainRowLink {
      CreatorSpace(mid: person.mid, name: person.uname ?? "用户空间")
    } label: {
      HStack(spacing: 12) {
        SiteThumbnail(url: httpsURL(person.face ?? "")) {
          $0.resizable().scaledToFill()
        } placeholder: {
          Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
        }.frame(width: 44, height: 44).clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(person.uname ?? "\(person.mid)").font(.body.weight(.medium)).lineLimit(1)
          if let s = person.sign, !s.isEmpty {
            Text(s).piliFont(.caption).lineLimit(1).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 2).contentShape(Rectangle())
    }.piliTapFeedback()
  }
}
struct CreatorSpace: View {
  let mid: Int64, name: String
  @EnvironmentObject var accounts: AccountContext
  @AppStorage(CreatorSection.preference) private var defaultSection = 0
  @AppStorage("creator.shop") private var showShop = false
  @State private var reservations: [CreatorSpaceRecord.Reservation] = []
  @State private var space: CreatorSpaceRecord?
  @State private var selectedTab: String?
  @State private var loadingError: String?
  @State private var revision = 0
  @State private var showPerson = false
  private struct LoadKey: Equatable { let mid: Int64, owner: String?, revision: Int }
  @State private var loadedKey: LoadKey?
  @State private var contentKey: LoadKey?
  @State private var loadToken = UUID()
  private var header: CreatorSpaceRecord.Person? { space?.person }
  @State private var relation: CreatorRelation?
  @State private var confirmUnfollow = false
  @State private var confirmBlock = false
  @State private var confirmRemoveFan = false
  @State private var reviewedOwner: String?
  @State private var removedFan = false
  @State private var issue: String?
  @State private var busy = false
  @State private var collapse = ScrollCollapse()
  @State private var route: Route?
  @State private var sectionMotion = CreatorSectionMotion()
  @Environment(\.colorScheme) private var scheme
  private enum Route: Hashable {
    case library, relations(fans: Bool), report(String), shared(String, also: Bool), chat
    case groups(String), account, edit, reservations, search, live(Int64)
  }
  private var tabs: [CreatorSpaceRecord.Tab] { space?.sections(shop: showShop) ?? [] }
  private var selected: CreatorSpaceRecord.Tab? {
    tabs.first { $0.param == selectedTab }
      ?? tabs.first { $0.param == space?.preferred(defaultSection, in: tabs) }
  }
  var body: some View {
    VStack(spacing: 0) {
      if let space {
        CollapsibleHeader(state: collapse) { profile(space) }
        if let loadingError {
          HStack {
            Text(loadingError).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("重试") { revision += 1 }.font(.caption.weight(.semibold))
          }.padding(.horizontal, 16).padding(.bottom, 6)
        }
        if !tabs.isEmpty, let selected {
          if tabs.count > 1 {
            CreatorSectionBar(tabs: tabs, selected: selected.param, motion: sectionMotion) { param in
              if param == selected.param { collapse.expand() } else { selectedTab = param }
            }
          }
          // Sections page horizontally like the original's TabBarView; visited ones stay alive.
          RetainedDeck(
            choices: tabs.map(\.param),
            selection: Binding(get: { selected.param }, set: { selectedTab = $0 }),
            swipe: tabs.count > 1, onProgress: sectionMotion.update
          ) { param in
            if let tab = tabs.first(where: { $0.param == param }) {
              section(tab, space).id("\(mid):\(accounts.state.active ?? ""):\(tab.param)")
                .frame(maxHeight: .infinity, alignment: .top)
                // Retained neighbours can report offsets while loading or resizing too.
                .environment(\.scrollCollapse, selected.param == param ? collapse : nil)
            }
          }
          .frame(maxHeight: .infinity, alignment: .top)
        } else {
          ContentUnavailableView("暂无公开栏目", systemImage: "person.crop.rectangle")
            .frame(maxHeight: .infinity)
        }
      } else if let loadingError {
        PageFailure(message: loadingError) { revision += 1 }.frame(maxHeight: .infinity)
      } else {
        PageLoading().frame(maxHeight: .infinity)
      }
    }
    .scrollCollapse(collapse)
    .navigationTitle(header?.name ?? name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        CollapsedTitle(state: collapse, title: header?.name ?? name)
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if !reservations.isEmpty {
          Button { route = .reservations } label: { Image(systemName: "calendar.badge.clock") }
            .accessibilityLabel("预约")
        }
        Button { route = .search } label: { Image(systemName: "magnifyingglass") }
          .accessibilityLabel("搜索空间")
        moreMenu
      }
    }
    .navigationDestination(item: $route) { destination($0) }
    .piliSheet(isPresented: $showPerson) {
      if let person = header {
        PiliNavigationStack {
          CreatorIdentityView(person: person, mid: mid, medals: space?.medalsVisible == true, ownsMedal: space?.ownsMedal == true, header: space?.headerDetails)
            .toolbar { Button("完成") { showPerson = false } }
        }
      }
    }
    .onChange(of: defaultSection) { _, _ in selectedTab = nil }
    .task(id: LoadKey(mid: mid, owner: accounts.state.active, revision: revision)) {
      let uid = accounts.state.active
      let key = LoadKey(mid: mid, owner: uid, revision: revision)
      if loadedKey == key {
        if let uid, relation == nil { await loadRelation(uid) }
        return
      }
      let token = UUID()
      loadToken = token
      reviewedOwner = nil
      confirmRemoveFan = false
      confirmBlock = false
      confirmUnfollow = false
      if contentKey?.mid != mid || contentKey?.owner != uid {
        loadedKey = nil
        removedFan = false
        space = nil
        reservations = []
        selectedTab = nil
        relation = nil
      }
      contentKey = key
      loadingError = nil
      async let relationLoad: Void = loadRelation(uid)
      do {
        let result = try await BiliAPI.shared.read(
          "/x/v2/space", CreatorSpaceRequest.fields(mid),
          host: "app.bilibili.com", expectedAccount: uid ?? "", as: CreatorSpaceRecord.self)
        try Task.checkCancellation()
        if accounts.state.active == uid, loadToken == token {
          space = result
          reservations = result.reservations
          loadedKey = key
          if let selectedTab, !result.sections(shop: showShop).contains(where: { $0.param == selectedTab }) {
            self.selectedTab = nil
          }
        }
      } catch {
        if !Task.isCancelled, accounts.state.active == uid, loadToken == token {
          loadingError = error.localizedDescription
        }
      }
      await relationLoad
    }
    .confirmationDialog("将这位用户移出粉丝列表？", isPresented: $confirmRemoveFan) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        Button("移除", role: .destructive) { Task { await act(uid, 7) } }
      }
    }
    .confirmationDialog("取消关注这位 UP 主？", isPresented: $confirmUnfollow) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        Button("取消关注", role: .destructive) { Task { await act(uid, 2) } }
      }
    }
    .confirmationDialog(
      relation?.attribute == 128 ? "将此用户移出黑名单？" : "将此用户加入黑名单？", isPresented: $confirmBlock
    ) {
      if let uid = reviewedOwner, accounts.state.active == uid {
        let code = relation?.attribute == 128 ? 6 : 5
        Button("确认", role: .destructive) { Task { await act(uid, code) } }
      }
    }.alert("关注", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  // MARK: Header (the original client's layout: banner, avatar over it with counts and
  // actions beside it, then name, badges, bio and tags)
  @ViewBuilder private func profile(_ space: CreatorSpaceRecord) -> some View {
    let p = space.person
    let author = ReplyAuthor(
      name: p?.name ?? name, avatar: p?.face,
      badge: p?.verifyType.map { .init(type: $0, desc: p?.verifyText) },
      pendant: p?.pendant, vipStatus: p?.vipStatus ?? 0, vipType: p?.vipType ?? 0, card: nil)
    VStack(alignment: .leading, spacing: 12) {
      banner(space.headerDetails)
      HStack(alignment: .top, spacing: 12) {
        Button { showPerson = true } label: {
          ReplyAvatar(member: author, size: 74)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
          if space.onAir, let room = space.room {
            Button { route = .live(room) } label: {
              Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.pink, in: Capsule())
            }.buttonStyle(.plain).offset(y: 4)
          }
        }
        .padding(.top, -48).padding(.leading, 4)
        VStack(spacing: 10) {
          stats(p)
          actions(p)
        }
      }
      identity(p, space.headerDetails)
    }
    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
  }
  private func banner(_ h: CreatorSpaceRecord.HeaderDetails) -> some View {
    let url = (scheme == .dark ? h.night ?? h.day : h.day).flatMap(httpsURL)
    return Rectangle().fill(.quaternary).frame(height: 132)
      .overlay {
        SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: {
          LinearGradient(
            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: NativeGlass.panelRadius, style: .continuous))
      .accessibilityHidden(true)
  }
  private func stats(_ p: CreatorSpaceRecord.Person?) -> some View {
    HStack(spacing: 0) {
      Button { route = .relations(fans: true) } label: { statCell(p?.fans, "粉丝") }
      Button { route = .relations(fans: false) } label: { statCell(p?.following, "关注") }
      statCell(p?.likes, "获赞")
    }.buttonStyle(.plain)
  }
  private func statCell(_ n: Int64?, _ label: String) -> some View {
    VStack(spacing: 1) {
      Text(n.map { $0.formatted(.number.notation(.compactName)) } ?? "–")
        .font(.headline.monospacedDigit()).contentTransition(.numericText())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity).contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
  @ViewBuilder private func actions(_ p: CreatorSpaceRecord.Person?) -> some View {
    HStack(spacing: 8) {
      if accounts.state.active == String(mid) {
        Button { route = .edit } label: { Text("编辑资料").frame(maxWidth: .infinity) }
          .piliButtonStyle(.glass)
        Button { route = .account } label: { Image(systemName: "person.badge.key") }
          .piliButtonStyle(.glass).accessibilityLabel("账号")
      } else if let uid = accounts.state.active {
        followButton(uid, followsViewer: p?.followsViewer == true)
        Button { route = .chat } label: { Text("发消息").frame(maxWidth: .infinity) }
          .piliButtonStyle(.glass)
      } else {
        NavigationLink { QRLoginView() } label: { Text("登录后关注").frame(maxWidth: .infinity) }
          .piliButtonStyle(.glassProminent)
      }
    }
    .font(.subheadline.weight(.semibold)).disabled(busy)
  }
  @ViewBuilder private func followButton(_ uid: String, followsViewer: Bool) -> some View {
    if let relation, relation.attribute == 128 {
      Button { reviewedOwner = uid; confirmBlock = true } label: {
        Text("已拉黑").frame(maxWidth: .infinity)
      }.piliButtonStyle(.glass).tint(.red)
    } else if let relation, relation.followed {
      Menu {
        Button(relation.special == 1 ? "取消特别关注" : "设为特别关注",
          systemImage: relation.special == 1 ? "star.slash" : "star") {
          Task { await special(uid, enabled: relation.special != 1) }
        }
        Button("设置关注分组", systemImage: "folder") { route = .groups(uid) }
        if let stamp = relation.mtime, stamp > 0 {
          Button("关注于 " + Date(timeIntervalSince1970: Double(stamp)).formatted(date: .abbreviated, time: .omitted),
            systemImage: "clock") {}
            .disabled(true)
        }
        Button("取消关注", systemImage: "person.badge.minus", role: .destructive) {
          TouchFeedback.light(); reviewedOwner = uid; confirmUnfollow = true
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: relation.special == 1 ? "star.fill" : "checkmark")
          Text(relation.special == 1 ? "特别关注" : followsViewer ? "互相关注" : "已关注")
        }.frame(maxWidth: .infinity)
      }.piliButtonStyle(.glass)
    } else {
      Button {
        TouchFeedback.light()
        Task { await act(uid, 1) }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "plus")
          Text(followsViewer ? "回关" : "关注")
        }.frame(maxWidth: .infinity)
      }.piliButtonStyle(.glassProminent)
    }
  }
  private func identity(_ p: CreatorSpaceRecord.Person?, _ h: CreatorSpaceRecord.HeaderDetails) -> some View {
    Button { showPerson = true } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(p?.name ?? name).font(.title3.weight(.bold)).lineLimit(1)
            .foregroundStyle(p?.vipStatus == 1 && p?.vipType == 2 ? Color.pink : Color.primary)
          if let level = p?.level {
            UserLevelBadge(level: Int(level), height: 13)
          }
          if (p?.vipStatus ?? 0) > 0 {
            Text(p?.vipType == 2 ? "年度大会员" : "大会员").font(.caption2.weight(.semibold))
              .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1.5)
              .background(Color.pink, in: Capsule())
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        if let type = p?.verifyType, type >= 0, let text = p?.verifyText, !text.isEmpty {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(type == 1 ? Color.blue : Color.orange)
            Text(text).lineLimit(2).multilineTextAlignment(.leading)
          }.font(.footnote).foregroundStyle(.secondary)
        }
        if let sign = p?.sign, !sign.isEmpty {
          Text(sign).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        let tags = h.tags.compactMap(\.title).prefix(4)
        if !tags.isEmpty {
          HStack(spacing: 6) {
            ForEach(Array(tags), id: \.self) { t in
              Text(t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityHint("查看空间资料")
  }
  private static func levelColor(_ level: Int64) -> Color {
    switch level {
    case ...1: Color(white: 0.62)
    case 2: Color(red: 0.55, green: 0.78, blue: 0.47)
    case 3: Color(red: 0.42, green: 0.71, blue: 0.93)
    case 4: Color(red: 0.98, green: 0.73, blue: 0.27)
    case 5: Color(red: 1, green: 0.55, blue: 0.21)
    default: Color(red: 0.96, green: 0.31, blue: 0.31)
    }
  }
  private var moreMenu: some View {
    Menu {
      Section {
        Button("空间内容", systemImage: "square.grid.2x2") { route = .library }
        if let r = space?.room, space?.onAir == true {
          Button("直播间", systemImage: "dot.radiowaves.left.and.right") { route = .live(r) }
        }
      }
      Section {
        if let url = URL(string: "https://space.bilibili.com/" + String(mid)) {
          ShareLink("分享主页", item: url)
        }
        Button("复制空间链接", systemImage: "link") {
          UIPasteboard.general.string = "https://space.bilibili.com/" + String(mid)
        }
        if let shortcut = URL(string: "https://www.bilibili.com/blackboard/disablelink/go-to-up-space.html?mid=" + String(mid)) {
          Link(destination: shortcut) { Label("添加主页快捷方式", systemImage: "plus.app") }
        }
      }
      if let uid = accounts.state.active, uid != String(mid) {
        Section {
          Button("共同关注", systemImage: "person.2") { route = .shared(uid, also: false) }
          Button("我关注的人也关注了 TA", systemImage: "person.3") { route = .shared(uid, also: true) }
        }
        Section {
          if header?.followsViewer == true && !removedFan {
            Button("移除粉丝", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
              reviewedOwner = uid; confirmRemoveFan = true
            }
          }
          if let relation {
            Button(relation.attribute == 128 ? "移出黑名单" : "加入黑名单",
              systemImage: "hand.raised", role: .destructive) {
              reviewedOwner = uid; confirmBlock = true
            }
          }
          Button("举报用户", systemImage: "exclamationmark.bubble", role: .destructive) {
            route = .report(uid)
          }
        }
      } else if accounts.state.active == nil {
        Button("在本机屏蔽", systemImage: "hand.raised") {
          do { _ = try LocalCreatorBlockFile.merge([mid]); issue = "已在本机屏蔽" }
          catch { issue = error.localizedDescription }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }.accessibilityLabel("更多")
  }
  @ViewBuilder private func destination(_ r: Route) -> some View {
    switch r {
    case .library: CreatorLibrary(mid: mid)
    case .relations(let fans): RelationsList(uid: String(mid), fans: fans)
    case .report(let uid): CommunityReport(target: .person(id: mid), uid: uid)
    case .shared(let uid, let also): SharedFollowing(mid: mid, uid: uid, alsoFollowsCreator: also)
    case .chat:
      ChatHistory(
        conversation: .init(talker_id: mid, session_type: 1, unread_count: nil, last_msg: nil),
        name: header?.name ?? name)
    case .groups(let uid): CreatorGroupEditor(mid: mid, uid: uid)
    case .account:
      Form {
        if (header?.vipStatus ?? 0) > 0 { MemberExperienceButton(uid: String(mid)) { revision += 1 } }
        NavigationLink("登录设备") { LoginDevices(uid: String(mid)) }
        ForEach(AccountLogs.Kind.allCases, id: \.self) { kind in
          NavigationLink(kind.rawValue) { AccountLogs(kind: kind, uid: String(mid)) }
        }
        NavigationLink("空间隐私") { SpacePrivacy(uid: String(mid)) }
      }.navigationTitle("我的账号")
    case .edit: ProfileEditor(uid: String(mid)) { revision += 1 }
    case .reservations: CreatorReservations(items: $reservations)
    case .search: CreatorSearch(mid: mid)
    case .live(let room): LivePlayer(id: room, title: space?.roomTitle ?? "直播间")
    }
  }
  @ViewBuilder private func section(_ tab: CreatorSpaceRecord.Tab, _ data: CreatorSpaceRecord)
    -> some View
  {
    switch CreatorSection(param: tab.param) {
    case .home: CreatorHomePanel(data: data, mid: mid, owner: accounts.state.active == String(mid))
    case .dynamic: CreatorDynamics(mid: mid)
    case .contribute: CreatorContributions(mid: mid, categories: data.contributions(tab))
    case .favorite: CreatorFavorites(mid: mid)
    case .bangumi:
      CreatorMobileMedia(mid: mid, kind: .season, initial: data.groups.first { $0.kind == .season })
    case .cheese: CoursesView(mid: String(mid))
    case .shop: CreatorShop(mid: mid)
    default: EmptyView()
    }
  }
  @MainActor private func loadRelation(_ uid: String?) async {
    guard let uid, !Task.isCancelled else { return }
    do {
      let r = try await BiliAPI.shared.read(
        "/x/relation", ["fid": String(mid)], expectedAccount: uid, as: CreatorRelation.self)
      try Task.checkCancellation()
      if accounts.state.active == uid { relation = r }
    } catch {
      if accounts.state.active == uid && !Task.isCancelled { issue = error.localizedDescription }
    }
  }
  @MainActor private func act(_ uid: String, _ action: Int) async {
    guard !busy, uid == accounts.state.active, uid != String(mid) else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/modify", ["fid": String(mid), "act": String(action), "re_src": "11"],
        expectedAccount: uid)
      guard accounts.state.active == uid else { return }
      if action == 7 { removedFan = true }
      if action == 5 || action == 6 {
        var rules = RecommendationRules.current()
        if action == 5 {
          rules.blockedCreators.insert(mid)
        } else {
          rules.blockedCreators.remove(mid)
        }
        try rules.save()
      }
      await loadRelation(uid)
    } catch { issue = error.localizedDescription }
  }
  @MainActor private func special(_ uid: String, enabled: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/relation/tag/special/" + (enabled ? "add" : "del"), ["fid": String(mid)],
        expectedAccount: uid)
      await loadRelation(uid)
    } catch { issue = error.localizedDescription }
  }
}
private struct FollowGroupsView: View {
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active { ScopedFollowGroups(owner: uid).id(uid) }
    else { ContentUnavailableView("请先登录", systemImage: "person.crop.circle") }
  }
}
private struct ScopedFollowGroups: View {
  let owner: String
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("follow.sort") private var order = 0
  @State private var revision = 0
  @State private var removing: FollowGroup?
  @State private var editing: FollowGroup?
  @State private var naming = false
  @State private var busy = false
  @State private var name = ""
  @State private var issue: String?
  var body: some View {
    PageList(empty: "没有分组") { _ in
      Page(items: try await BiliAPI.shared.read("/x/relation/tags", [:], expectedAccount: owner, as: [FollowGroup].self), next: nil)
    } row: { g in
      PlainRowLink { members(g) } label: {
        VStack(alignment: .leading) {
          Text((g.name ?? "分组") + "（" + String(g.count ?? 0) + "）")
          if let tip = g.tip, !tip.isEmpty { Text(tip).font(.caption).foregroundStyle(.secondary) }
        }
      }.swipeActions(allowsFullSwipe: false) { groupActions(g) }.contextMenu { groupActions(g) }
    }.id(revision).navigationTitle("关注分组").disabled(busy)
      .toolbar {
        NavigationLink("排序") { CloudOrder(uid: nil, expectedGroupOwner: owner) { revision += 1 } }
        Button("新建分组", systemImage: "plus") { editing = nil; name = ""; naming = true }
      }
      .confirmationDialog("删除这个关注分组？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { g in
        Button("删除", role: .destructive) { Task { await perform(.remove(g.id)) } }
      } message: { _ in Text("分组中的用户仍会保留在关注列表") }
      .alert(editing == nil ? "新建分组" : "修改分组", isPresented: $naming) {
        TextField("名称", text: $name).onChange(of: name) { _, value in if value.count > 16 { name = String(value.prefix(16)) } }
        Button("取消", role: .cancel) {}
        Button("保存") {
          let edit = editing.map { FollowGroupCommand.Edit.rename($0.id, name) } ?? .add(name)
          Task { await perform(edit) }
        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .alert("分组", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("好") {} } message: { Text(issue ?? "") }
  }
  @ViewBuilder private func groupActions(_ g: FollowGroup) -> some View {
    if FollowGroupCommand.custom(g.id) {
      Button("删除", role: .destructive) { removing = g }
      Button("改名") { editing = g; name = g.name ?? ""; naming = true }
    }
  }
  private func members(_ group: FollowGroup) -> some View {
    PageList(empty: "分组中没有关注", autoMore: true) { cursor in
      let n = Int(cursor ?? "1") ?? 1
      let rows = try await BiliAPI.shared.read("/x/relation/tag",
        ["mid": owner, "tagid": String(group.id), "pn": String(n), "ps": "20", "order_type": order == 1 ? "attention" : ""],
        expectedAccount: owner, as: [Creator].self)
      return Page(items: rows, next: !rows.isEmpty && (group.count.map { n * 20 < $0 } ?? (rows.count == 20)) ? String(n + 1) : nil)
    } row: { person in HStack {
      CreatorLink(person: person)
      CreatorQuickRelation(mid: person.mid, knownFollowing: true)
    } }.id(order).navigationTitle(group.name ?? "分组").toolbar { FollowSortMenu(order: $order) }
  }
  @MainActor private func perform(_ action: FollowGroupCommand.Edit) async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    do {
      let cmd = try FollowGroupCommand(action, owner: owner)
      try await cmd.apply(active: accounts.state.active) { path, fields, account in
        try await BiliAPI.shared.submit(path, fields, expectedAccount: account)
      }
      guard accounts.state.active == owner else { return }
      name = ""; revision += 1
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}
