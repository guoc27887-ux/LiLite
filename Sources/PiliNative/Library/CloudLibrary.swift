import SwiftUI

struct CloudLibraryView: View {
  let kind: CloudLibraryKind, uid: String
  var allowChanges = true
  var heading: AnyView? = nil
  @State private var descending = false
  @State private var text = ""
  @State private var query = ""
  @State private var revision = 0
  @State private var clearKind: Int?
  @State private var viewed = 0
  @State private var ascending = false
  @State private var pages: [String: Int] = [:]
  @State private var resources = Set<String>()
  @State private var resourceOrder: [String] = []
  @State private var playlist: PlaylistStart?
  @AppStorage("library.playAll") private var playAll = true
  private var isLater: Bool { if case .later = kind { true } else { false } }
  @State private var order: FavoriteSort = .mtime
  @State private var selection: Set<String> = []
  @State private var selecting = false
  @State private var confirm = false
  @State private var busy = false
  @State private var chooseFolder = false
  @State private var copy = false
  @State private var issue: String?
  var body: some View {
    PageList(empty: "暂无内容", heading: heading) { p in
      let step = max(1, Int(p ?? "1") ?? 1)
      let last: Int = {
        if case .favorites(let folder) = kind {
          return max(1, ((folder.media_count ?? 0) + 19) / 20)
        }
        return 1
      }()
      let backwards = descending && query.isEmpty && kind.folder != nil
      let actual = backwards ? max(1, last - step + 1) : step
      let result = try await kind.fetch(
        backwards ? String(actual) : p, query: query, order: order, uid: uid, viewed: viewed,
        ascending: ascending)
      try Task.checkCancellation()
      if p == nil {
        pages = [:]
        resources = []
        resourceOrder = []
      }
      let display = backwards ? Array(result.items.reversed()) : result.items
      for row in display {
        if let key = kind.resource(row), resources.insert(key).inserted {
          resourceOrder.append(key)
        }
      }
      for item in result.items { pages[item.id] = actual }
      if backwards {
        return Page(
          items: Array(result.items.reversed()), next: actual > 1 ? String(step + 1) : nil)
      }
      return result
    } row: { v in
      if selecting {
        Button {
          if let k = kind.resource(v) { if !selection.insert(k).inserted { selection.remove(k) } }
        } label: {
          HStack(spacing: 10) {
            let on = kind.resource(v).map(selection.contains) == true
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
              .font(.title3).foregroundStyle(on ? Color.accentColor : Color.secondary)
              .contentTransition(.symbolEffect(.replace))
            v.label
          }
        }.disabled(kind.resource(v) == nil || busy)
      } else {
        Group {
          if playAll, kind.canTransfer, v.queueTarget != nil {
            Button {
              playlist = PlaylistStart(
                rowID: v.id, page: pages[v.id] ?? 1, descending: descending && query.isEmpty)
            } label: {
              v.label
            }.buttonStyle(.plain)
          } else {
            v.link
          }
        }.contextMenu {
          if allowChanges, let k = kind.resource(v) {
            Button("选择") {
              selection = [k]
              selecting = true
            }
          }
          if let cover = v.queueCover {
            ContextLink("查看封面", systemImage: "photo") { NativeGallery([.init(cover)]) }
          }
        }.swipeActions {
          if allowChanges, let k = kind.resource(v) {
            Button("移除", role: .destructive) {
              selection = [k]
              confirm = true
            }
          }
        }
      }
    }.id("\(revision):\(query):\(order.rawValue):\(viewed):\(ascending):\(descending)")
      .contextPushHost()
      .navigationTitle(
        kind.title
      )
      .piliSafeAreaBar(edge: .top, spacing: 0) {
        if isLater {
          ChipBar(items: [0, 2], selection: $viewed, title: { $0 == 0 ? "全部" : "未看完" })
            .padding(.vertical, 6).disabled(selecting)
        }
      }
      .piliFullScreenCover(item: $playlist, onDismiss: { revision += 1 }) { start in
        LibraryPlaylist(
          kind: kind, uid: uid, query: query, order: order, viewed: viewed, ascending: ascending,
          start: start, allowChanges: allowChanges)
      }
      .searchable(text: $text, prompt: "搜索\(kind.title)").onSubmit(of: .search) {
        query = text
        selection = []
      }
      .onChange(of: viewed) { _, _ in
        selection = []
        resources = []
      }
      .onChange(of: order) { _, _ in
        selection = []
        resources = []
      }
      .onChange(of: ascending) { _, _ in
        selection = []
        resources = []
      }
      .onChange(of: text) { _, s in
        if s.isEmpty {
          query = ""
          selection = []
        }
      }
      .confirmationDialog(
        clearKind == 1 ? "移除全部已失效视频？" : clearKind == 2 ? "移除全部已看完视频？" : "清空整个稍后再看列表？",
        isPresented: Binding(get: { clearKind != nil }, set: { if !$0 { clearKind = nil } }),
        titleVisibility: .visible, presenting: clearKind
      ) { value in
        Button("确认移除", role: .destructive) { Task { await clean(value) } }
      }
      .modifier(SelectionCancelBack(active: selecting) { selection = []; selecting = false })
      .toolbar {
        if kind.canTransfer && !selecting {
          Menu {
            Button("播放全部") {
              let last: Int = {
                if case .favorites(let folder) = kind {
                  return max(1, ((folder.media_count ?? 0) + 19) / 20)
                }
                return 1
              }()
              playlist = PlaylistStart(
                page: descending && query.isEmpty ? last : 1,
                descending: descending && query.isEmpty)
            }
            if PlaybackMemory.enabled { Button("继续播放") { playlist = PlaylistStart(resume: true) } }
            Toggle("点按视频时连续播放", isOn: $playAll)
            if isLater {
              Toggle("按添加时间正序", isOn: $ascending)
              if allowChanges { Menu("清理稍后再看") {
                Button("移除已失效视频") { clearKind = 1 }
                Button("移除已看完视频") { clearKind = 2 }
                Button("清空整个列表", role: .destructive) { clearKind = 0 }
              } }
            }
          } label: {
            Image(systemName: "list.bullet.rectangle").accessibilityLabel("播放列表与筛选")
          }
        }
        if let folder = kind.folder {
          Menu {
            Picker("显示顺序", selection: $order) {
              ForEach(FavoriteSort.allCases, id: \.self) { v in Text(v.label).tag(v) }
            }
            if query.isEmpty { Toggle("倒序浏览", isOn: $descending) }
            if allowChanges {
              if case .favorites(let metadata)=kind,(metadata.media_count ?? 0)>1000{
                Button("手动排序"){issue="超过 1000 条收藏，暂不支持手动排序"}
              }else{NavigationLink("手动排序") {
                FavoriteOrder(folder: folder, uid: uid) {
                  order = .mtime
                  revision += 1
                }
              }}
            }
          } label: {
            Image(systemName: "arrow.up.arrow.down").accessibilityLabel("收藏排序")
          }
        }
        if allowChanges {
          Button(selecting ? "完成" : "选择") {
            selecting.toggle()
            selection = []
          }.disabled(busy)
        }
      }
      .safeAreaInset(edge: .bottom) {
        if selecting {
          HStack {
            Text("已选 \(selection.count)").piliFont(.footnote)
            Spacer()
            Button(selection.isSuperset(of: resources) ? "取消全选" : "全选") {
              selection = selection.isSuperset(of: resources) ? [] : resources
            }.disabled(resources.isEmpty || busy)
            if kind.canTransfer {
              Menu("整理") {
                Button("复制到收藏夹") {
                  copy = true
                  chooseFolder = true
                }
                Button("移动到收藏夹") {
                  copy = false
                  chooseFolder = true
                }
              }.disabled(selection.isEmpty || busy)
            }
            Button("移除", role: .destructive) { confirm = true }.disabled(selection.isEmpty || busy)
          }
          .padding(.horizontal, 16).padding(.vertical, 10)
          .piliGlass(in: Capsule())
          .padding(.horizontal, 12).padding(.bottom, 6)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .piliSheet(isPresented: $chooseFolder) {
        PiliNavigationStack {
          PageList(empty: "没有其他收藏夹") { _ in
            Page(
              items: try await BiliAPI.shared.folders(uid: uid, expectedAccount: uid).filter {
                $0.id != kind.folder
              },
              next: nil)
          } row: { f in
            Button(f.title) {
              chooseFolder = false
              Task { await perform(f.id) }
            }
          }.navigationTitle(copy ? "复制到" : "移动到").toolbar { Button("取消") { chooseFolder = false } }
        }
      }
      .confirmationDialog("从\(kind.title)移除选中的 \(selection.count) 项？", isPresented: $confirm) {
        Button("移除", role: .destructive) { Task { await perform(nil) } }
      }
      .alert("操作失败", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
  }
  @MainActor private func clean(_ value: Int) async {
    guard isLater, allowChanges, !busy, (0...2).contains(value) else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v2/history/toview/clear", value == 0 ? [:] : ["clean_type": String(value)],
        expectedAccount: uid)
      selection = []
      revision += 1
    } catch { issue = error.localizedDescription }
  }
  private func perform(_ target: Int64?) async {
    guard !busy, !selection.isEmpty else { return }
    guard allowChanges else { return }
    busy = true
    defer { busy = false }
    do {
      let ids = try LibraryCheckedOrder.items(display: resourceOrder, selected: selection,
        movingFavorite: target != nil && kind.folder != nil).joined(separator: ",")
      if let target {
        try await kind.transfer(ids, to: target, copy: copy, uid: uid)
      } else {
        try await kind.remove(ids, uid: uid)
      }
      selection = []
      selecting = false
      revision += 1
    } catch { issue = error.localizedDescription }
  }
}
