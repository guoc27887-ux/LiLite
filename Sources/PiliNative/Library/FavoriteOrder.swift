import SwiftUI

struct FavoriteOrder: View {
  let folder: Int64, uid: String, changed: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var rows: [FavoriteMedia] = []
  @State private var ops: [String] = []
  @State private var page: Int? = 1
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    List {
      ForEach(rows) { item in
        MediaRow(cover: item.cover.flatMap(httpsURL), title: item.displayName,
          duration: item.duration.map { clockText(Double($0)) }, subtitle: item.upper?.name,
          dimmed: item.unavailable, thumbWidth: 112)
      }.onMove(perform: move)
      if busy { ProgressView().frame(maxWidth: .infinity) }
      if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
      if page != nil && !busy {
        Button(rows.isEmpty ? "载入收藏" : "加载更多") { Task { await load() } }.frame(maxWidth: .infinity)
      }
    }
    .listStyle(.plain)
    .overlay { if rows.isEmpty && page == nil { ContentUnavailableView("收藏夹为空", systemImage: "star") } }
    .environment(\.editMode, .constant(.active)).navigationTitle("收藏内容排序").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { Task { await save() } }.piliButtonStyle(.glassProminent).disabled(busy || ops.isEmpty)
        }
      }
      .task(id: folder) { if rows.isEmpty && page == 1 { await load() } }
  }
  private func move(_ offsets: IndexSet, _ destination: Int) {
    guard !busy, !offsets.isEmpty, offsets.allSatisfy(rows.indices.contains),
      (0...rows.count).contains(destination)
    else { return }
    let ids = Set(offsets.map { rows[$0].id })
    let before = rows.map(\.id)
    rows.move(fromOffsets: offsets, toOffset: destination)
    guard rows.map(\.id) != before else { return }
    for i in rows.indices where ids.contains(rows[i].id) {
      ops.append((i > 0 ? rows[i - 1].id : "0:0") + ":" + rows[i].id)
    }
  }
  @MainActor private func load() async {
    guard let page, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let r = try await BiliAPI.shared.favoriteMedia(folder, page: page, term: "", user: uid)
      try Task.checkCancellation()
      var seen = Set(rows.map(\.id))
      let added = r.items.filter { seen.insert($0.id).inserted }
      rows += added
      self.page = added.isEmpty ? nil : r.next.flatMap(Int.init)
      issue = nil
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  @MainActor private func save() async {
    guard !busy, !ops.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v3/fav/resource/sort",
        ["media_id": String(folder), "sort": ops.joined(separator: ",")], expectedAccount: uid)
      changed()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
