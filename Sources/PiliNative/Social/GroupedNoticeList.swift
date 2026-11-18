import SwiftUI

struct GroupedNoticeList<Row: View>: View {
  let kind: NoticeKind
  let load: (String?) async throws -> Page<Notice>
  @ViewBuilder let row: (Notice) -> Row
  @State private var notices = [Notice]()
  @State private var groups: [String: [Notice]] = [:]
  @State private var noticeIDs: [String] = []
  @State private var next: String?
  @State private var busy = false
  @State private var loaded = false
  @State private var issue: String?
  @State private var request = UUID()
  @State private var manualLoad: Task<Void, Never>?
  @State private var manualID: UUID?
  var body: some View {
    List {
      if kind == .like {
        ForEach(["最新", "累计"], id: \.self) { title in
          let items = groups[title] ?? []
          if !items.isEmpty {
            Section {
              ForEach(items) { i in row(i) }
            } header: {
              Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
          }
        }
      } else {
        ForEach(notices) { i in row(i) }
      }
      Group {
        if busy {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, loaded ? 12 : 80)
        } else if let issue {
          VStack(spacing: 10) {
            Text(issue).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试") { startFetch(reset: !loaded) }.piliButtonStyle(.glass)
          }.frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if next != nil {
          Color.clear.frame(height: 1).onAppear { startFetch(reset: false) }
        } else if loaded && notices.isEmpty {
          ContentUnavailableView("暂无通知", systemImage: "bell").padding(.top, 40)
        } else if loaded {
          Text("没有更多了").font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
      }
      .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
    .listStyle(.plain).environment(\.inListRows, true)
    .animation(.easeOut(duration: 0.2), value: noticeIDs)
    .task { if !loaded { await fetch(reset: true) } }
    .piliRefreshable { cancelManual(); await fetch(reset: true) }
    .onDisappear {
      cancelManual()
      request = UUID()
      busy = false
    }
  }
  @MainActor private func cancelManual() {
    manualLoad?.cancel()
    manualLoad = nil
    manualID = nil
  }
  @MainActor private func startFetch(reset: Bool) {
    guard !busy else { return }
    cancelManual()
    let id = UUID()
    manualID = id
    manualLoad = Task {
      await fetch(reset: reset)
      if manualID == id { manualLoad = nil; manualID = nil }
    }
  }
  @MainActor private func fetch(reset: Bool) async {
    guard !Task.isCancelled else { return }
    let cursor = reset ? nil : next
    if !reset && (busy || cursor == nil) { return }
    let stamp = UUID()
    request = stamp
    busy = true
    issue = nil
    defer { if request == stamp { busy = false } }
    do {
      let p = try await load(cursor)
      try Task.checkCancellation()
      guard request == stamp else { return }
      var rows = reset ? [] : notices
      var seen = Set(rows.map(\.id))
      for n in p.items where seen.insert(n.id).inserted { rows.append(n) }
      notices = rows
      noticeIDs = rows.map(\.id)
      if kind == .like { groups = Dictionary(grouping: rows) { $0.group ?? "" } }
      next = p.next == cursor ? nil : p.next
      loaded = true
    } catch { if !Task.isCancelled && request == stamp { issue = error.localizedDescription } }
  }
}
