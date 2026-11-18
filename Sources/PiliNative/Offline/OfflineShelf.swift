import SwiftUI

struct OfflineShelfView: View {
  @ObservedObject private var downloads = Downloads.shared
  @EnvironmentObject private var accounts: AccountContext
  @State private var query = ""
  @State private var shelf = 0
  @State private var selecting = false
  @State private var checked = Set<String>()
  @State private var deleting = [OfflineVideo]()
  @State private var playing: OfflineVideo?
  @State private var updater: OfflineBatchRequest?
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  private var matching: [OfflineVideo] {
    OfflineShelfFilter.rows(downloads.list, search: query, shelf: shelf, owner: owner)
  }
  private var choices: [OfflineVideo] { matching.filter { checked.contains($0.token) } }
  var body: some View {
    List {
      if downloads.indexUnavailable { Button("重新读取缓存清单") { Task { await downloads.retryIndex() } } }
      if let msg = downloads.issue { Text(msg).font(.caption).foregroundStyle(.secondary) }
      if selecting {
        Button(checked.isSuperset(of: matching.map(\.token)) ? "取消全选" : "全选") { toggle(matching) }
        if !choices.isEmpty { actions(choices) }
      }
      if matching.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "暂无缓存记录" : "没有找到匹配的视频",
          systemImage: query.isEmpty ? "arrow.down.circle" : "magnifyingglass"
        )
        .listRowSeparator(.hidden).listRowBackground(Color.clear).padding(.top, 40)
      }
      if !query.isEmpty || shelf == 2 {
        ForEach(matching) { v in
          if selecting { check([v], name: v.part.isEmpty ? v.title : v.part) } else { row(v) }
        }
      } else {
        ForEach(OfflineGroup.groups(matching)) { g in
          if selecting {
            check(g.parts, name: g.title)
          } else if g.parts.count > 1 {
            PlainRowLink {
              OfflineGroupView(groupID: g.id, initialTitle: g.title)
            } label: {
              HStack(alignment: .top, spacing: 12) {
                if let p = g.parts.first {
                  OfflineCoverCell(row: p, size: CGSize(width: 140, height: 79))
                    .overlay(alignment: .bottomTrailing) {
                      Label("\(g.parts.count)", systemImage: "square.stack.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule()).padding(5)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(g.title).font(.subheadline.weight(.medium)).lineLimit(2)
                  Spacer(minLength: 0)
                  Text("\(g.parts.count) 个分集").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 79, alignment: .topLeading)
              }.padding(.vertical, 4).contentShape(Rectangle())
            }.contextMenu {
              Button("更新弹幕") { batch(g.parts, .comments) }
              Button("更新空降片段") { batch(g.parts, .segments) }
              Button("移除缓存", role: .destructive) { deleting = g.parts }
            }
          } else if let v = g.parts.first {
            row(v)
          }
        }
      }
    }
    .listStyle(.plain).environment(\.inListRows, true)
    .animation(.easeOut(duration: 0.2), value: matching.map(\.token))
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      ChipBar(items: [0, 1, 2], selection: $shelf, title: { ["全部", "已缓存", "下载中"][$0] })
        .padding(.vertical, 6)
    }
    .navigationTitle("离线缓存").searchable(text: $query, prompt: "搜索标题、分集或编号")
      .modifier(SelectionCancelBack(active: selecting) { checked = []; selecting = false })
      .toolbar {
        NavigationLink { OfflineLocationPanel() } label: {
          Image(systemName: "externaldrive").accessibilityLabel("存储位置")
        }
        Button(selecting ? "完成" : "选择") {
          selecting.toggle()
          checked = []
        }.disabled(matching.isEmpty && !selecting)
      }
      .onChange(of: shelf) { _, _ in checked = [] }
      .onChange(of: owner) { _, _ in
        checked = []
        deleting = []
        playing = nil
        updater = nil
      }
      .piliSheet(item:$playing){v in
        let available=OfflineGroup.groups(downloads.list.filter{$0.phase == .saved && $0.matchesOwner(owner)}).flatMap(\.parts)
        if let i=available.firstIndex(where:{$0.token==v.token}){OfflineQueuePlayer(items:available,initial:i){_ in}}else{Text("该视频已不在可播放缓存中")}
      }
      .piliSheet(item: $updater) { OfflineBatchPanel(request: $0) }
      .confirmationDialog(
        "移除 \(deleting.count) 个离线缓存？",
        isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
        titleVisibility: .visible, presenting: deleting
      ) { rows in
        Button("移除本机文件", role: .destructive) {
          Task {
            await downloads.remove(rows)
            checked.subtract(rows.map(\.token))
          }
        }
      }
  }
  @ViewBuilder private func row(_ v: OfflineVideo) -> some View {
    DownloadRow(v: v, play: { playing = $0 }).swipeActions {
      Button("移除", role: .destructive) { deleting = [v] }
    }
  }
  private func check(_ rows: [OfflineVideo], name: String) -> some View {
    let n = rows.filter { checked.contains($0.token) }.count
    return Button {
      toggle(rows)
    } label: {
      Label(
        name,
        systemImage: n == 0
          ? "circle" : n == rows.count ? "checkmark.circle.fill" : "minus.circle.fill")
    }
  }
  private func toggle(_ rows: [OfflineVideo]) {
    let ids = Set(rows.map(\.token))
    if checked.isSuperset(of: ids) { checked.subtract(ids) } else { checked.formUnion(ids) }
  }
  private func batch(_ rows: [OfflineVideo], _ mode: OfflineAttachment) {
    let allowed = rows.filter { $0.phase == .saved && $0.matchesOwner(owner) }
    if !allowed.isEmpty { updater = .init(items: allowed, mode: mode) }
  }
  private func actions(_ rows: [OfflineVideo]) -> some View {
    Menu("管理所选 \(rows.count) 项") {
      ForEach([OfflineAttachment.comments, .captions, .segments, .art, .all]) { m in
        Button(m.rawValue) { batch(rows, m) }
      }
      Button("暂停下载") {
        Task {
          for v in rows where v.phase == .transferring { await downloads.pause(v, toPaused: true) }
        }
      }
      Button("继续下载") {
        Task {
          for v in rows where v.phase == .paused { await downloads.pause(v, toPaused: false) }
        }
      }
      Button("重试失败项") {
        Task { for v in rows where v.phase == .failed { await downloads.start(v) } }
      }
      Button("移除所选缓存", role: .destructive) { deleting = rows }
    }
  }
}
struct OfflineBatchRequest: Identifiable {
  let id = UUID()
  let items: [OfflineVideo], mode: OfflineAttachment
}
struct OfflineBatchPanel: View {
  let request: OfflineBatchRequest
  @Environment(\.dismiss) private var dismiss
  @State private var finished = 0
  @State private var failed = 0
  @State private var done = false
  var body: some View {
    PiliNavigationStack {
      Form {
        if request.items.count > 1000 {
          Text("每次最多更新 1000 项")
        } else if done {
          Text(failed == 0 ? "全部更新成功" : "成功 \(finished-failed) 项，失败 \(failed) 项")
        } else {
          ProgressView(value: Double(finished), total: Double(max(1, request.items.count)))
          Text("\(finished) / \(request.items.count)")
        }
      }.navigationTitle(request.mode.rawValue).toolbar {
        Button(done || request.items.count > 1000 ? "完成" : "取消") { dismiss() }
      }
    }
    .task(id: request.id) {
      guard request.items.count <= 1000 else { return }
      for lower in stride(from: 0, to: request.items.count, by: 10) {
        if Task.isCancelled { return }
        await withTaskGroup(of: Bool.self) { g in
          for v in request.items[lower..<min(lower + 10, request.items.count)] {
            g.addTask { await Downloads.shared.refreshExtras(v, mode: request.mode) }
          }
          for await ok in g {
            guard !Task.isCancelled else {
              g.cancelAll()
              return
            }
            finished += 1
            if !ok { failed += 1 }
          }
        }
      }
      if !Task.isCancelled { done = true }
    }
  }
}
struct OfflineCoverCell: View {
  let row: OfflineVideo
  var size = CGSize(width: 72, height: 44)
  @State private var image: UIImage?
  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        ZStack {
          Color.secondary.opacity(0.09)
          Image(systemName: "film").foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: size.width, height: size.height).clipped()
    .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
    .task(id: row.token + ":" + (row.attachmentStamp?.uuidString ?? "")) {
      image = UIImage(
        contentsOfFile: Downloads.shared.extraDirectory(row).appendingPathComponent("cover.jpg")
          .path)
    }
  }
}
struct OfflineReceiptLine: View {
  let row: OfflineVideo
  @EnvironmentObject private var accounts: AccountContext
  @State private var point: OfflineWatchBook.Point?
  @AppStorage("play.remember") private var remember = true
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        if let bytes = row.mediaBytes {
          Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let name = row.uploader { Text(name).lineLimit(1) }
        if remember, let p = point {
          Text(p.completed ? "已看完" : clockText(p.seconds) + " / " + clockText(p.duration))
        } else if let seconds = row.seconds {
          Text(clockText(Double(seconds)))
        }
      }
      if remember, let p = point { ProgressView(value: min(1, max(0, p.seconds / p.duration))) }
    }.font(.caption).foregroundStyle(.secondary)
      .task(id: (accounts.state.active ?? "") + row.token + String(remember)) {
        point = OfflineWatchBook.read(row.token, viewer: accounts.state.active)
      }
      .onReceive(NotificationCenter.default.publisher(for: OfflineWatchBook.changed)) { note in
        if note.object as? String == row.token {
          point = OfflineWatchBook.read(row.token, viewer: accounts.state.active)
        }
      }
  }
}
struct OfflineMarkerList: View {
  let v: OfflineVideo
  @State private var rows = [SponsorSegment]()
  var body: some View {
    List {
      ForEach(v.episodeClips ?? []) { c in
        LabeledContent(c.title, value: clockText(c.start) + " – " + clockText(c.end))
      }
      ForEach(rows) { r in
        LabeledContent(
          r.detail?.title ?? r.category,
          value: clockText(r.segment[0]) + " – " + clockText(r.segment[1]))
      }
      if rows.isEmpty && (v.episodeClips ?? []).isEmpty { Text("暂无片段") }
    }.navigationTitle("缓存片段").task(id: v.token) {
      rows = await OfflineExtras.markers(Downloads.shared.extraDirectory(v))
    }
  }
}
