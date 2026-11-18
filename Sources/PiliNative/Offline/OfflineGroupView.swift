import SwiftUI

struct OfflineGroupView: View {
  let groupID: String, initialTitle: String
  var archiveFilter: String? = nil
  @ObservedObject private var downloads = Downloads.shared
  @EnvironmentObject private var accounts: AccountContext
  @State private var reverse = false
  @State private var selecting = false
  @State private var updater: OfflineBatchRequest?
  @State private var checked = Set<String>()
  @State private var removing: [OfflineVideo] = []
  @State private var queue: Queue?
  @State private var busy = false
  @State private var query = ""
  private struct Queue: Identifiable { let id = UUID(), items: [OfflineVideo], start: Int }
  private var group: OfflineGroup? {
    OfflineGroup.groups(
      downloads.list.filter {
        $0.groupKey == groupID && $0.visible(to: accounts.state.owner(.role(.video)) ?? "")
      }
    ).first
  }
  private var rows: [OfflineVideo] {
    var r = (group?.parts ?? []).filter { archiveFilter == nil || $0.bvid == archiveFilter }
    if reverse { r.reverse() }
    return query.isEmpty
      ? r
      : r.filter {
        $0.part.localizedCaseInsensitiveContains(query)
          || $0.title.localizedCaseInsensitiveContains(query) || String($0.cid).contains(query)
      }
  }
  private var choices: [OfflineVideo] { rows.filter { checked.contains($0.token) } }
  private var key: String {
    "offline.last." + (accounts.state.active ?? "guest") + ":" + groupID + ":"
      + (archiveFilter ?? "")
  }
  private var last: String? {
    PlaybackMemory.enabled ? UserDefaults.standard.string(forKey: key) : nil
  }
  private func play(_ v: OfflineVideo?) {
    let r = rows.filter {
      $0.phase == .saved && $0.matchesOwner(accounts.state.owner(.role(.video)) ?? "")
    }
    guard !r.isEmpty else { return }
    queue = .init(items: r, start: r.firstIndex(where: { $0.token == v?.token }) ?? 0)
  }
  private var scope: String {
    (accounts.state.active ?? "") + ":" + (accounts.state.owner(.role(.video)) ?? "")
  }
  private var entries: some View {
    List {
      if let error = downloads.issue {
        Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
      }
      if !selecting {
        let ready = rows.filter {
          $0.phase == .saved && $0.matchesOwner(accounts.state.owner(.role(.video)) ?? "")
        }
        if !ready.isEmpty {
          HStack(spacing: 10) {
            Button { play(ready.first) } label: {
              Label("播放全部", systemImage: "play.fill").font(.subheadline.weight(.semibold))
            }
            .piliButtonStyle(.glassProminent).buttonBorderShape(.capsule)
            if let last,
              let v = ready.first(where: {
                $0.token == last || ($0.scoped != true && $0.id == last)
              })
            {
              Button { play(v) } label: {
                Label("继续播放", systemImage: "clock.arrow.circlepath").font(.subheadline)
              }
              .piliButtonStyle(.glass).buttonBorderShape(.capsule)
            }
            Spacer()
            Text("\(ready.count) 个已缓存").font(.caption).foregroundStyle(.secondary)
          }
          .listRowSeparator(.hidden)
        }
      }
      trackListing
    }
    .listStyle(.plain)
    .overlay { if rows.isEmpty && query.isEmpty { ContentUnavailableView("暂无离线缓存", systemImage: "arrow.down.circle") } }
    .safeAreaInset(edge: .bottom) {
      if selecting {
        HStack(spacing: 12) {
          Button(checked.isSuperset(of: rows.map(\.token)) && !rows.isEmpty ? "取消全选" : "全选") {
            let ids = Set(rows.map(\.token))
            if checked.isSuperset(of: ids) { checked.subtract(ids) } else { checked.formUnion(ids) }
          }
          Spacer()
          Menu {
            Button("暂停下载", systemImage: "pause") { run(.pause) }
            Button("继续下载", systemImage: "play") { run(.resume) }
            Button("重试失败项", systemImage: "arrow.clockwise") { run(.retry) }
            Section("更新附加内容") {
              ForEach([OfflineAttachment.comments, .captions, .segments, .art, .all]) { m in
                Button(m.rawValue) {
                  let r = choices.filter {
                    $0.phase == .saved && $0.matchesOwner(accounts.state.owner(.role(.video)) ?? "")
                  }; if !r.isEmpty { updater = .init(items: r, mode: m) }
                }
              }
            }
          } label: {
            Label("管理", systemImage: "ellipsis.circle")
          }
          .disabled(choices.isEmpty)
          Button(role: .destructive) { removing = choices } label: {
            Label("删除", systemImage: "trash")
          }
          .tint(.red).disabled(choices.isEmpty)
        }
        .labelStyle(.titleAndIcon).font(.subheadline.weight(.medium))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .piliGlass(in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 4)
      }
    }
  }
  var body: some View {
    entries.disabled(busy).searchable(text: $query, prompt: "搜索分集")
      .navigationTitle(selecting ? "已选 \(choices.count) 项" : archiveFilter == nil ? (group?.title ?? initialTitle) : initialTitle)
      .navigationBarTitleDisplayMode(.inline)
      .modifier(SelectionCancelBack(active: selecting) { checked = []; selecting = false })
      .toolbar {
        if !selecting {
          Button {
            reverse.toggle()
          } label: {
            Image(systemName: "arrow.up.arrow.down").accessibilityLabel(
              reverse ? "改为正序" : "改为倒序")
          }
        }
        Button {
          withAnimation(.snappy) { selecting.toggle() }
          checked = []
        } label: {
          if selecting { Text("完成") } else { Label("多选", systemImage: "checklist") }
        }
      }.confirmationDialog(
        "移除 \(removing.count) 个离线缓存？",
        isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }),
        titleVisibility: .visible, presenting: removing
      ) { snapshots in
        Button("移除本机文件", role: .destructive) {
          Task {
            await downloads.remove(snapshots)
            checked.subtract(snapshots.map(\.token))
          }
        }
      }.piliSheet(item: $updater) { OfflineBatchPanel(request: $0) }.piliSheet(item: $queue) { q in
        OfflineQueuePlayer(items: q.items, initial: q.start) { v in
          if PlaybackMemory.enabled { UserDefaults.standard.set(v.token, forKey: key) }
        }
      }.onChange(of: scope) { _, _ in
        queue = nil; updater = nil
        checked = []
        removing = []
      }
  }
  @ViewBuilder private var trackListing: some View {
    let list = rows
    let archives = list.reduce(into: [OfflineVideo]()) { seen, v in
      if !seen.contains(where: { $0.bvid == v.bvid }) { seen.append(v) }
    }
    if archiveFilter == nil && groupID.hasPrefix("ugc:") && archives.count > 1 && !selecting
      && query.isEmpty
    {
      ForEach(archives) { v in
        NavigationLink {
          OfflineGroupView(groupID: groupID, initialTitle: v.title, archiveFilter: v.bvid)
        } label: {
          HStack(spacing: 12) {
            OfflineCoverCell(row: v)
            VStack(alignment: .leading, spacing: 4) {
              Text(v.title).font(.subheadline.weight(.medium)).lineLimit(2)
              Text("\(list.filter { $0.bvid == v.bvid }.count) 个分集").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    } else {
      ForEach(rows) { v in
        if selecting {
          Button {
            if !checked.insert(v.token).inserted { checked.remove(v.token) }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: checked.contains(v.token) ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(checked.contains(v.token) ? Color.accentColor : Color.secondary)
              OfflineCoverCell(row: v)
              Text(v.part.isEmpty ? v.title : v.part).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
        } else {
          DownloadRow(v: v, play: play).swipeActions {
            Button("移除", role: .destructive) { removing = [v] }
          }
        }
      }
    }
  }
  private enum Action { case pause, resume, retry, extras }
  private func run(_ action: Action) {
    guard !busy else { return }
    let snapshot = choices
    busy = true
    Task { @MainActor in
      defer { busy = false }
      for v in snapshot {
        guard !Task.isCancelled, downloads.list.contains(where: { $0.token == v.token }) else {
          continue
        }
        switch action {
        case .pause: if v.phase == .transferring { await downloads.pause(v, toPaused: true) }
        case .resume: if v.phase == .paused { await downloads.pause(v, toPaused: false) }
        case .retry: if v.phase == .failed { await downloads.start(v) }
        case .extras: if v.phase == .saved { await downloads.refreshExtras(v) }
        }
      }
    }
  }
}
struct OfflineQueuePlayer: View {
  let items: [OfflineVideo], changed: (OfflineVideo) -> Void
  @State private var index: Int
  @State private var playRate:Float?
  init(items: [OfflineVideo], initial: Int, changed: @escaping (OfflineVideo) -> Void) {
    self.items = items
    self.changed = changed
    _index = State(initialValue: initial)
  }
  var body: some View {
    if items.indices.contains(index) {
      let v = items[index]
      OfflinePlayer(
        video:v,previous: index > 0 ? { index -= 1 } : nil,
        next: index + 1 < items.count ? { index += 1 } : nil,
        rewindList: items.count > 1 ? { index = 0 } : nil,sessionSpeed:$playRate,
        playingRows:items,pickOffline:{selected in if let i=items.firstIndex(where:{$0.token==selected.token}){index=i}}
      )
      .id(v.token).onAppear { changed(v) }
    }
  }
}
