import SwiftUI

@MainActor final class MomentSessionHides: ObservableObject {
  static let shared = MomentSessionHides()
  @Published private(set) var byOwner = [String: [Int64: String]]()
  func hide(_ mid: Int64, name: String, owner: String?) {
    guard mid > 0 else { return }
    byOwner[owner ?? "", default: [:]][mid] = name
  }
  func show(_ mid: Int64, owner: String?) { byOwner[owner ?? ""]?[mid] = nil }
}

struct DynamicFeed: View {
  @EnvironmentObject var accounts: AccountContext
  var body: some View {
    PiliNavigationStack {
      Group {
        if let uid = accounts.state.active {
          AccountDynamicFeed(uid: uid).id(uid)
        } else {
          VStack(spacing: 16) {
            Image(systemName: "person.2").piliFont(.largeTitle)
            Text("登录后查看关注动态")
            NavigationLink("扫码登录") { QRLoginView() }
          }.navigationTitle("动态")
            .toolbar {
              NavigationLink("话题") { TopicDirectory() }
              NavigationLink("设置") { SettingsView() }
            }
        }
      }.piliTabRoot(.dynamics)
    }
  }
}

private struct AccountDynamicFeed: View {
  let uid: String
  @State private var compose = false
  @State private var revisions: [String: Int] = [:]
  @State private var visited = Set<String>()
  @State private var kind =
    (FeedScope(rawValue: UserDefaults.standard.integer(forKey: FeedScope.setting)) ?? .all).request
  @AppStorage(FeedScope.setting) private var defaultFeed = 0
  @State private var creator: DynamicPortal.Person?
  @ObservedObject private var sessionHides = MomentSessionHides.shared
  private var muted: [Int64: String] { sessionHides.byOwner[uid] ?? [:] }
  @State private var unfolded: [String: Set<String>] = [:]
  @AppStorage("social.dynamicRegex") private var regex = ""
  @AppStorage("social.hideGoods") private var goods = false
  @StateObject private var directory = FeedDirectoryState()
  @AppStorage("social.upPanelPosition") private var positionValue = FeedPanelPosition.leftFixed
    .rawValue
  @AppStorage("social.allFollowed") private var allFollowed = false
  @State private var expandedLive = UserDefaults.standard.bool(forKey: "social.expandLive")
  @State private var drawer = false
  @State private var destination: FeedPanelDestination?
  private var position: FeedPanelPosition {
    FeedPanelPosition(rawValue: positionValue) ?? .leftFixed
  }
  var body: some View {
    VStack(spacing: 0) {
      FeedPanelHost(position: position, shown: $drawer) {
        FeedPeoplePanel(
          uid: uid, position: position, selected: kind == "up" ? creator?.mid : nil,
          model: directory, expandedLive: $expandedLive, select: select, open: open
        )
        .buttonStyle(.plain)
      } content: {
        VStack(spacing: 0) {
          if kind == "up", let creator {
            Button {
              open(.creator(creator.mid, creator.uname ?? "UP 主"))
            } label: {
              HStack(spacing: 4) {
                Text("进入 " + (creator.uname ?? String(creator.mid)) + " 的空间")
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
              }.font(.footnote)
            }
            .piliButtonStyle(.glass).padding(.vertical, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
          ZStack {
            ForEach(FeedScope.allCases.map(\.request) + ["up"], id: \.self) { scope in
              if scope == kind || visited.contains(scope), scope != "up" || creator != nil {
                feed(scope).opacity(scope == kind ? 1 : 0)
                  .allowsHitTesting(scope == kind).accessibilityHidden(scope != kind)
                  .zIndex(scope == kind ? 1 : 0)
              }
            }
            if kind == "up", creator == nil {
              VStack(spacing: 12) {
                ContentUnavailableView("选择一位 UP 主", systemImage: "person.2")
                if position.drawer { Button("打开 UP 主面板") { drawer = true } }
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
    }
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      HStack(spacing: 0) {
        if position == .leftDrawer { drawerButton.padding(.leading, 12) }
        ChipBar(
          items: FeedScope.allCases.map(\.request) + ["up"], selection: $kind,
          title: { r in
            r == "up"
              ? (creator?.uname ?? "UP 主")
              : FeedScope.allCases.first { $0.request == r }?.label ?? r
          },
          reselect: { revisions[kind, default: 0] += 1 })
        if position == .rightDrawer { drawerButton.padding(.trailing, 12) }
      }.padding(.vertical, 6)
    }
    .animation(.snappy(duration: 0.25), value: kind)
    .navigationTitle("动态")
    .toolbarTitleDisplayMode(.inline)
    .toolbar(removing: .title)
    .toolbar {
      Menu {
        NavigationLink("动态筛选") { CommunityFilterPanel() }
        NavigationLink("设置") { SettingsView() }
        if !muted.isEmpty {
          Menu("取消本次隐藏") {
            ForEach(muted.keys.sorted(), id: \.self) { mid in
              Button(muted[mid] ?? String(mid)) {
                sessionHides.show(mid, owner: uid)
              }
            }
          }
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle").accessibilityLabel("动态选项")
      }
      NavigationLink { TopicDirectory() } label: {
        Image(systemName: "number").accessibilityLabel("话题")
      }
      Button {
        compose = true
      } label: {
        Image(systemName: "square.and.pencil").accessibilityLabel("发布动态")
      }
    }.piliSheet(isPresented: $compose) { DynamicComposer { revisions[kind, default: 0] += 1 } }
      .onChange(of: kind, initial: true) { old, current in
        visited.insert(old)
        visited.insert(current)
      }
      .onChange(of: positionValue) { _, _ in drawer = false }
      .onChange(of: defaultFeed) { _, value in kind = (FeedScope(rawValue: value) ?? .all).request }
      .navigationDestination(item: $destination) { value in
        switch value {
        case .creator(let mid, let name): CreatorSpace(mid: mid, name: name)
        case .room(let id, let title): LivePlayer(id: id, title: title)
        case .followedLive: LiveFollows()
        }
      }
      .task(id: allFollowed) { await directory.configure(uid, all: allFollowed) }
      .task { await directory.profile(uid) }
  }
  private var drawerButton: some View {
    Button {
      drawer.toggle()
    } label: {
      Image(systemName: position.leading ? "sidebar.left" : "sidebar.right")
        .font(.subheadline.weight(.medium)).frame(width: 36, height: 36)
        .contentShape(Circle())
    }
    .buttonStyle(.plain).piliGlass(in: Circle(), interactive: true)
    .accessibilityLabel(drawer ? "关闭 UP 主面板" : "打开 UP 主面板")
  }
  private func open(_ target: FeedPanelDestination) {
    drawer = false
    destination = target
  }
  private func select(_ person: DynamicPortal.Person?) {
    drawer = false
    if let person {
      if creator?.mid == person.mid && kind == "up" { revisions["up", default: 0] += 1 }
      if creator?.mid != person.mid { unfolded["up"] = nil }
      creator = person
      kind = "up"
    } else {
      if kind == "all" {
        revisions["all", default: 0] += 1
        Task { await directory.refresh(uid, all: allFollowed) }
      }
      kind = "all"
    }
  }
  private func feed(_ scope: String) -> some View {
    let expanded = unfolded[scope] ?? []
    let mid = scope == "up" ? creator?.mid : nil
    return PageList(
      empty: "暂无关注动态", dynamicCards: true, active: scope == kind,
      refreshed: { await directory.refresh(uid, all: allFollowed) }
    ) { cursor in
      var seen = Set<String>()
      var next = cursor
      for _ in 0..<4 {
        try Task.checkCancellation()
        let result = try await BiliAPI.shared.dynamics(
          offset: next, feedType: scope == "up" ? nil : scope,
          followedCreator: mid, user: uid)
        let filtered = result.items.filter { d in
          if scope != "up", let id = d.authorID, muted[id] != nil { return false }
          return true
        }
        next = result.next
        if let n = next, !seen.insert(n).inserted { next = nil }
        if !filtered.isEmpty || next == nil { return Page(items: filtered, next: next) }
      }
      return Page(items: [], next: next)
    } row: { (d: DynamicEntry) in
      if d.visible || expanded.contains(d.id) {
        VStack(alignment: .leading) {
          DynamicCard(entry: d, changed: { revisions[scope, default: 0] += 1 })
            .overlay(alignment: .bottom) {
              Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).opacity(0.6)
            }
          if !d.foldIDs.isEmpty, !Set(d.foldIDs).isSubset(of: expanded) {
            Button {
              withAnimation(.snappy) { unfolded[scope, default: []].formUnion(d.foldIDs) }
            } label: {
              HStack(spacing: 4) {
                Text(d.foldTitle)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
              }
              .font(.footnote).foregroundStyle(.tint)
              .frame(maxWidth: .infinity).padding(.vertical, 8)
              .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }.buttonStyle(.plain).padding(.horizontal, 12)
          }
        }
      }
    }.id(
      "\(uid):\(revisions[scope] ?? 0):\(scope == "up" ? "" : muted.keys.sorted().map(String.init).joined(separator:",")):\(scope):\(mid ?? 0):\(regex):\(goods)"
    )
  }
}
