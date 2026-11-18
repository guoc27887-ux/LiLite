import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
  var initialHint: String
  let embedded: Bool
  let placement: SearchFieldPlacement
  init(initialHint: String = "", keyword: String? = nil, embedded: Bool = false,
       placement: SearchFieldPlacement = .automatic) {
    self.embedded = embedded
    self.initialHint = initialHint
    self.placement = placement
    _draft = State(initialValue: keyword ?? "")
    _term = State(initialValue: keyword ?? "")
  }
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("search.defaultWord") private var useHint = false
  @AppStorage("search.hot") private var showHot = true
  @AppStorage("search.picks") private var showPicks = true
  @AppStorage("search.suggest") private var suggest = true
  @AppStorage("search.history") private var history = Data()
  @AppStorage("search.save") private var saveHistory = true
  @State private var hint = ""
  @State private var destination: SharedLink?
  @State private var resolveTask: Task<Void, Never>?
  @State private var resolvingDraft: String?
  @State private var recent = [String]()
  @State private var issue: String?
  @State private var draft = ""
  @State private var term = ""
  @State private var domain = SearchDomain.mixed
  @State private var suggestions = [String]()
  @State private var videoFilters = [SearchDomain: VideoSearchOptions]()
  @State private var otherFilters = [SearchDomain: OtherSearchOptions]()
  @State private var showFilter = false
  @State private var counts = [SearchDomain: Int]()
  @State private var numericOpened: String?
  @State private var confirmClear = false
  @State private var showImporter = false
  @State private var showExporter = false
  @State private var exportFile: SearchHistoryFile?
  @State private var openLink = false
  @FocusState private var fieldFocused: Bool
  private var owner: String { accounts.state.owner(.role(.recommend)) ?? "" }
  private func effectiveDomain(_ section: SearchDomain) -> SearchDomain {
    section == .mixed && (videoFilters[section] ?? VideoSearchOptions()).filtered ? .video : section
  }
  private func fields(_ section: SearchDomain) -> [String: String] {
    switch effectiveDomain(section) {
    case .video: return (videoFilters[section] ?? VideoSearchOptions()).fields()
    case .mixed: return [:]
    default: return (otherFilters[section] ?? OtherSearchOptions()).fields(section)
    }
  }
  private func identity(_ section: SearchDomain) -> String {
    [
      owner, term, section.rawValue,
      fields(section).sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: ","),
    ].joined(separator: "\n")
  }
  private func videoBinding(_ section: SearchDomain) -> Binding<VideoSearchOptions> {
    Binding(get: { videoFilters[section] ?? VideoSearchOptions() }, set: { videoFilters[section] = $0 })
  }
  private func otherBinding(_ section: SearchDomain) -> Binding<OtherSearchOptions> {
    Binding(get: { otherFilters[section] ?? OtherSearchOptions() }, set: { otherFilters[section] = $0 })
  }
  var body: some View {
    if embedded { searchInterface(page) }
    else { searchInterface(PiliNavigationStack { page }) }
  }
  private var page: some View {
      searchContent
        .piliTabRoot(.search).navigationTitle(term.isEmpty ? "搜索" : term)
        // Pushed from Discover the page is compact like the original; the search tab keeps its
        // large title on the start page.
        .navigationBarTitleDisplayMode(embedded || !term.isEmpty ? .inline : .large)
        .navigationDestination(isPresented: $openLink) { OpenSharedLink() }
        .navigationDestination(item: $destination) { LinkDestination(item: $0) }
        .alert("搜索", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
          Button("好") {}
        } message: {
          Text(issue ?? "")
        }
        .confirmationDialog("清空搜索历史？", isPresented: $confirmClear, titleVisibility: .visible) {
          Button("清空", role: .destructive) { changeHistory(.clear) }
        }
        .piliSheet(isPresented: $showFilter) {
          SearchFilterForm(domain: domain, videos: videoBinding(domain), others: otherBinding(domain))
        }
        .toolbar { toolbar }
        .onDisappear { cancelResolution() }
        .task(id: history) {
          let bytes = history
          let first = await Task.detached(priority: .userInitiated) { SearchHistoryStore.preview(bytes) }.value
          if !Task.isCancelled { recent = first }
        }
        .fileExporter(
          isPresented: $showExporter, document: exportFile, contentType: .json,
          defaultFilename: "search"
        ) { result in if case .failure(let e) = result { issue = e.localizedDescription } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText]) {
          result in
          Task {
            do {
              let url = try result.get()
              let bytes = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard (size ?? 0) <= SearchHistoryStore.importLimit else { throw ServiceError("文件过大") }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                return try file.read(upToCount: SearchHistoryStore.importLimit + 1) ?? Data()
              }.value
              changeHistory(.replace(bytes))
            } catch { issue = error.localizedDescription }
          }
        }
  }
  private var searchContent: some View {
    Group { if term.isEmpty { landing } else { results } }
  }
  private func searchInterface<Content: View>(_ content: Content) -> some View {
    content
      .searchable(text: $draft, placement: placement,
        prompt: useHint && !hint.isEmpty ? hint : "输入关键词或粘贴链接")
      .searchFocused($fieldFocused)
      .onAppear {
        // Opening search should go straight to typing, as in the original client.
        if embedded && term.isEmpty {
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
          }
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .searchSuggestions {
        if let n = SearchNumber.positive(draft) {
          Button("访问 UID \(n)") { destination = .creator(n) }
        }
        ForEach(suggestions, id: \.self) { word in
          Button {
            submit(word)
          } label: {
            Label(word, systemImage: "magnifyingglass")
          }
        }
      }
      .task(id: "\(useHint):\(owner)") {
        hint = useHint ? initialHint : ""
        guard useHint else { return }
        if let s = try? await BiliAPI.shared.defaultSearchWord(owner: owner), !Task.isCancelled {
          hint = s
        }
      }
      .task(id: "\(suggest):\(draft):\(owner):\(term)") {
        suggestions = []
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggest, !q.isEmpty, q != term else { return }
        do {
          try await Task.sleep(for: .milliseconds(200))
          let r = try await BiliAPI.shared.searchSuggestions(q, owner: owner)
          try Task.checkCancellation()
          suggestions = r
        } catch {}
      }
      .onSubmit(of: .search) {
        submit(
          draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && useHint ? hint : draft)
      }
      .onChange(of: draft) { _, new in
        if let resolvingDraft, new != resolvingDraft { cancelResolution() }
        if new.isEmpty { term = "" }
      }
      .onChange(of: term) { _, _ in
        counts = [:]
        numericOpened = nil
      }
      .onChange(of: owner) { _, _ in
        cancelResolution()
        counts = [:]
        numericOpened = nil
        videoFilters = [:]
        otherFilters = [:]
      }
  }
  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      if let n = SearchNumber.positive(draft) {
        Button {
          destination = .creator(n)
        } label: {
          Image(systemName: "person.crop.circle")
        }.accessibilityLabel("访问 UID \(n)")
      }
      Menu {
        Button {
          saveHistory.toggle()
        } label: {
          Label(
            saveHistory ? "切换为无痕搜索" : "开启搜索记录", systemImage: saveHistory ? "eye.slash" : "clock")
        }
        Menu("搜索历史") {
          Button("从文件导入") { showImporter = true }
          Button("导出到文件") {
            Task { exportFile = SearchHistoryFile(data: await SearchHistoryStore.snapshot()); showExporter = true }
          }
          Button("从剪贴板导入") {
            changeHistory(.replace(Data((UIPasteboard.general.string ?? "").utf8)))
          }
          Button("复制到剪贴板") {
            Task {
              let data = await SearchHistoryStore.snapshot()
              let text = await Task.detached { String(decoding: data, as: UTF8.self) }.value
              UIPasteboard.general.string = text
            }
          }
        }
        Button("打开链接或视频编号", systemImage: "link") { openLink = true }
        NavigationLink("设置") { SettingsView() }
      } label: {
        Image(systemName: "ellipsis")
      }.accessibilityLabel("搜索选项")
    }
  }
  /// Search home in the original client's arrangement: history chips, then two-column lists of
  /// trending and suggested keywords.
  private var landing: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        if useHint, !hint.isEmpty, draft.isEmpty {
          Button { submit(hint) } label: {
            Label(hint, systemImage: "magnifyingglass").font(.subheadline).lineLimit(1)
          }.piliButtonStyle(.glass)
        }
        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("搜索历史").font(.headline)
              Spacer()
              Button { confirmClear = true } label: {
                Image(systemName: "trash").font(.subheadline).foregroundStyle(.secondary)
              }.buttonStyle(.plain).accessibilityLabel("清空搜索历史")
            }
            WrappingActions(spacing: 8, rowSpacing: 8) {
              ForEach(recent, id: \.self) { w in
                Button { submit(w) } label: {
                  Text(w).font(.subheadline).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }.buttonStyle(.plain).contextMenu { deleteWord(w) }
              }
            }
          }
        }
        if showHot {
          SearchSuggestionsSection(owner: owner, hot: true, select: submit).id("hot:" + owner)
        }
        if showPicks {
          SearchSuggestionsSection(owner: owner, hot: false, select: submit).id("picks:" + owner)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollDismissesKeyboard(.immediately)
  }
  private func deleteWord(_ w: String) -> some View {
    Button("删除", role: .destructive) {
      changeHistory(.remove(w))
    }
  }
  private var results: some View {
    RetainedDeck(choices: SearchDomain.allCases, selection: $domain) { section in
      resultList(section).id(identity(section))
    }.id(owner + "\n" + term)
      .piliSafeAreaBar(edge: .top, spacing: 0) { domainBar }
  }
  private var domainBar: some View {
    HStack(spacing: 4) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(SearchDomain.allCases, id: \.self) { d in
              let current = domain == d
              Button {
                TouchFeedback.light()
                withAnimation(.snappy(duration: 0.25)) { domain = d }
              } label: {
                HStack(spacing: 4) {
                  Text(d.rawValue)
                  if let n = counts[d] {
                    Text(n > 99 ? "99+" : "\(n)").font(.caption2).monospacedDigit()
                      .foregroundStyle(.secondary)
                  }
                }
                .font(.subheadline.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                  if current { Capsule().fill(Color(uiColor: .tertiarySystemFill)) }
                }
                .contentShape(Capsule())
              }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : []).id(d)
            }
          }.padding(.horizontal, 16)
        }
          .onChange(of: domain, initial: true) { _, d in withAnimation(.snappy) { proxy.scrollTo(d, anchor: .center) } }
      }
      if [.mixed, .video, .creator, .article].contains(domain) {
        Button {
          showFilter = true
        } label: {
          Image(systemName: "line.3.horizontal.decrease")
        }.piliButtonStyle(.glass).accessibilityLabel("筛选").padding(.trailing, 16)
      }
    }.padding(.vertical, 6)
  }
  private func resultList(_ section: SearchDomain) -> some View {
    let key = identity(section)
    let t = term
    let effective = effectiveDomain(section)
    let parameters = fields(section)
    let reader = owner
    return PageList(empty: "没有匹配结果",autoMore:true,discoveryArchive:{(hit:SearchHit)->Video? in if case .video(let v)=hit.content{return v};return nil}) { cursor in
      let page = Int(cursor ?? "1") ?? 1
      let p = try await BiliAPI.shared.searchPage(
        t, domain: effective, page: page, fields: parameters, owner: reader)
      try Task.checkCancellation()
      if page == 1, key == identity(section) {
        counts[section] = p.reportedTotal
        if domain == section, draft.trimmingCharacters(in: .whitespacesAndNewlines) == t, effective == .video || effective == .mixed,
          let n = SearchNumber.matched(t, rows: p.items), numericOpened != reader + "\n" + t
        {
          numericOpened = reader + "\n" + t
          destination = .archive(n, nil)
        }
      }
      return p
    } row: {
      SearchHitRow(hit: $0)
    }
  }
  private func changeHistory(_ change: SearchHistoryStore.Change) {
    SearchHistoryStore.enqueue(change) { issue = $0.localizedDescription }
  }
  private func cancelResolution() {
    resolveTask?.cancel()
    resolveTask = nil
    resolvingDraft = nil
  }
  private func submit(_ input: String) {
    let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    cancelResolution()
    issue = nil
    if let link = SharedResolver.candidate(q) {
      draft = q
      resolvingDraft = q
      resolveTask = Task { @MainActor in
        defer { if !Task.isCancelled { resolvingDraft = nil; resolveTask = nil } }
        do {
          let target = try await link.resolve()
          try Task.checkCancellation()
          guard draft == q else { return }
          destination = target
        } catch { if !Task.isCancelled && draft == q { issue = error.localizedDescription } }
      }
      return
    }
    if q != term {
      videoFilters = [:]
      otherFilters = [:]
      counts = [:]
      numericOpened = nil
    }
    draft = q
    term = q
    if saveHistory {
      changeHistory(.record(q))
    }
  }
}
private struct SearchHistoryFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
private struct SearchSuggestionsSection: View {
  let owner: String, hot: Bool, select: (String) -> Void
  @State private var data = [BiliAPI.Trend]()
  @State private var attempt = 0
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Text(hot ? "大家都在搜" : "猜你想搜").font(.headline)
        Spacer()
        Button { attempt += 1 } label: {
          Label(hot ? "刷新" : "换一换", systemImage: "arrow.clockwise").font(.footnote)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
        if hot {
          NavigationLink { TrendingSearchPage(select: select) } label: {
            HStack(spacing: 2) {
              Text("完整榜单")
              Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }.font(.footnote)
          }.buttonStyle(.plain).foregroundStyle(.tint)
        }
      }
      if let issue {
        HStack {
          Text(issue).font(.caption).foregroundStyle(.secondary)
          Button("重试") { attempt += 1 }.font(.caption)
        }
      }
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
        alignment: .leading, spacing: 14) {
        ForEach(Array(data.enumerated()), id: \.element.id) { index, t in
          Button { select(t.keyword) } label: {
            HStack(spacing: 8) {
              if hot {
                Text("\(index + 1)").font(.subheadline.weight(.bold)).monospacedDigit()
                  .lineLimit(1).fixedSize().frame(minWidth: 22, alignment: .leading)
                  .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary).frame(width: 18)
              }
              Text(t.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
              if t.show_live_icon == true {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.pink)
              }
              if let u = t.icon.flatMap(httpsURL) {
                SiteThumbnail(url: u) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                  .frame(maxWidth: 26, maxHeight: 14)
              }
              Spacer(minLength: 0)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
      .animation(.easeOut(duration: 0.2), value: data.map(\.id))
    }
    .task(id: attempt) {
      issue = nil
      do {
        let r: [BiliAPI.Trend]
        if hot {
          r = try await BiliAPI.shared.trends(owner: owner).list ?? []
        } else {
          r = try await BiliAPI.shared.searchPicks(owner: owner)
        }
        try Task.checkCancellation()
        data = r
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
