import SwiftUI

/// The moment in full (selectable text, full date and IP), then 转发 / 评论 / 点赞 lists, with
/// the forward / share / comment / like bar along the bottom (the original's DynamicDetailPage).
struct DynamicDetail: View {
  let id: String
  var byAlbum = false, privateOwner: String? = nil, resolveArticle = false
  /// Opened from a card's comment button: scroll to the comments once loaded.
  var focusReplies = false
  @EnvironmentObject private var accounts: AccountContext
  @State private var revision = 0
  @State private var entry: DynamicEntry?
  @State private var error: String?
  @State private var selected = MomentPanel.replies
  @State private var counts: [MomentPanel: Int64] = [:]
  @State private var jump = 0
  @State private var focused = false
  @State private var closer = MomentPageCloser()
  @Environment(\.dismiss) private var dismiss
  private func picker(_ d: DynamicEntry) -> AnyView {
    AnyView(
      UnderlineTabBar(items: MomentPanel.allCases, selection: $selected, title: { kind in
        let value =
          counts[kind]
          ?? (kind == .replies ? d.commentCount : kind == .likes ? d.likeCount : d.forwardCount)
        return kind.rawValue + (value.map { " " + $0.formatted(.number.notation(.compactName)) } ?? "")
      }, fill: false)
      .background(Color(uiColor: .systemBackground))
      .overlay(alignment: .bottom) { Divider() }
      .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear))
  }
  var body: some View {
    let user = accounts.state.active
    let source = accounts.state.owner(.role(.heartbeat))
    Group {
      if let d = entry, resolveArticle, d.replyType == 12 {
        ArticleReader(opus: d.id)
      } else if let d = entry {
        ScrollViewReader { proxy in
          ReadingSplit(hasPanel: true) {
            AnyView(
              DynamicCard(
                entry: d, inside: true,
                openPanel: { kind in
                  selected = kind
                  jump += 1
                }
              ) { revision += 1 })
            .environment(\.momentPageCloser, closer.bind(dismiss))
          } panel: { header in
            let bar = picker(d)
            if selected == .replies {
              if let oid = d.replyOID, let kind = d.replyType {
                Discussion(
                  oid: oid, type: kind, owner: d.authorID, embeddedTitle: "动态详情",
                  readingHeader: header, readingControls: bar,
                  readingCount: { counts[.replies] = $0 })
              } else {
                ScrollView {
                  VStack(alignment: .leading) {
                    if let header { header }
                    bar.id("pili.page.controls")
                    ContentUnavailableView("评论暂不可用", systemImage: "text.bubble")
                  }
                }
              }
            } else {
              let which = selected
              DynamicActivityList(
                id: d.id, panel: which, heading: header, controls: bar, title: "动态详情",
                updated: { counts[which] = $0 })
            }
          }
          .onChange(of: selected) { _, _ in jump += 1 }
          .onChange(of: jump) { _, _ in
            DispatchQueue.main.async {
              withAnimation { proxy.scrollTo("pili.page.controls", anchor: .top) }
            }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          DynamicActionBar(entry: d, openComments: {
            selected = .replies
            jump += 1
          }, share: true) { revision += 1 }
          .background(.bar, ignoresSafeAreaEdges: .bottom)
          .overlay(alignment: .top) { Divider() }
        }
      } else if let error {
        ContentUnavailableView {
          Label("动态未能加载", systemImage: "text.bubble")
        } description: {
          Text(error)
        } actions: {
          Button("重试") { revision += 1 }
        }
      } else {
        PageLoading()
      }
    }.navigationTitle(resolveArticle && entry?.replyType == 12 ? "阅读" : "动态详情").navigationBarTitleDisplayMode(.inline)
      .linkedDiscussion(oid: entry?.replyOID, type: entry?.replyType ?? 0, author: entry?.authorID)
      .momentNavigation()
      .task(id: "\(id):\(byAlbum):\(privateOwner ?? ""):\(user ?? ""):\(source ?? ""):\(revision)")
    {
      error = nil
      do {
        let result: DynamicEntry
        if let privateOwner {
          guard privateOwner == user else { throw ServiceError("账号已切换") }
          let row = try await BiliAPI.shared.mainDynamicRow(id, owner: privateOwner)
          guard let d = DynamicEntry(row), d.authorID.map(String.init) == privateOwner else {
            throw ServiceError("无法核实动态作者")
          }
          result = d
        } else {
          result = try await BiliAPI.shared.dynamic(
            id, byAlbum: byAlbum, expectedAccount: source ?? "")
        }
        try Task.checkCancellation()
        guard accounts.state.active == user, accounts.state.owner(.role(.heartbeat)) == source
        else { return }
        entry = result
        counts = [:]
        error = nil
        if focusReplies && !focused {
          focused = true
          try? await Task.sleep(for: .milliseconds(350))
          jump += 1
        }
      } catch {
        if !Task.isCancelled, accounts.state.active == user {
          self.error = error.localizedDescription
          entry = nil
        }
      }
    }.onChange(of: "\(id):\(byAlbum):\(user ?? ""):\(source ?? "")") { _, _ in
      entry = nil
      error = nil
      counts = [:]
      selected = .replies
    }
  }
}
struct TopicDirectory: View {
  var select: ((TopicLink) -> Void)? = nil
  @State private var input = ""
  @State private var term = ""
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    let search = select != nil || !term.isEmpty
    let owner = search ? accounts.state.active : accounts.state.owner(.role(.recommend))
    PageList(empty: "暂无话题") { cursor in
      let page = max(1, Int(cursor ?? "") ?? 1)
      var q = ["web_location": "333.1365"]
      if search {
        q["keywords"] = term
        q["content"] = ""
        if page == 1 {
          q["page_num"] = "1"
          q["page_size"] = "20"
        } else {
          q["offset"] = String((page - 1) * 20)
        }
      } else {
        q["source"] = "Web"
        q["page_size"] = "25"
      }
      return try await BiliAPI.shared.topicIndex(
        search: search, fields: q, owner: owner ?? "", page: page)
    } row: { t in
      if let select {
        Button {
          select(t)
        } label: {
          label(t)
        }
      } else {
        PlainRowLink {
          TopicFeed(topic: t)
        } label: {
          label(t)
        }
      }
    }.id("\(term):\(owner ?? "")")
      .navigationTitle(select == nil ? "动态话题" : "选择话题").searchable(text: $input, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索话题")
      .onSubmit(of: .search) { term = input.trimmingCharacters(in: .whitespacesAndNewlines) }
      .task(id: input) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
        if !Task.isCancelled { term = value }
      }
  }
  private func label(_ topic: TopicLink) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(topic.name, systemImage: "number")
      if topic.view != nil || topic.discuss != nil {
        Text(
          "\((topic.view ?? 0).formatted(.number.notation(.compactName))) 浏览 · \((topic.discuss ?? 0).formatted(.number.notation(.compactName))) 讨论"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct CreatorDynamics: View {
  let mid: Int64
  @EnvironmentObject private var accounts:AccountContext
  @AppStorage("social.hideGoods") private var goods=false
  @AppStorage("social.dynamicRegex") private var pattern=""
  @State private var rev = 0
  var body: some View {
    PageList(empty: "暂无动态", dynamicCards: true) { cursor in
      try await BiliAPI.shared.dynamics(offset:cursor,author:mid,user:accounts.state.active ?? "")
    } row: { d in
      DynamicCard(entry: d) { rev += 1 }
    }.id("\(mid):\(accounts.state.active ?? ""):\(goods):\(pattern):\(rev)").navigationTitle("空间动态")
      .momentNavigation()
  }
}
