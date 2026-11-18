import SwiftUI

struct PickFolder: View {
  let uid: String, aid: Int64
  var resourceType = 2
  @Environment(\.dismiss) var dismiss
  @State private var folders: [Folder] = []
  @State private var original: Set<Int64> = []
  @State private var selected: Set<Int64> = []
  @State private var issue: String?
  @State private var limitIssue: String?
  @State private var loading = true
  @State private var saving = false
  @State private var creating = false
  @State private var revision = 0
  var body: some View {
    List {
      if let limitIssue {
        Label(limitIssue, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
      }
      if let issue {
        Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
        Button("重新加载") { revision += 1 }
      }
      ForEach(folders) { f in
        Button {
          if selected.contains(f.id) {
            selected.remove(f.id)
          } else if !original.contains(f.id), let count = f.media_count, let attr = f.attr,
            count >= ((attr & 2) == 0 ? 50_000 : 1_000)
          {
            limitIssue = "这个收藏夹已满"
          } else {
            selected.insert(f.id)
          }
        } label: {
          let on = selected.contains(f.id)
          HStack(spacing: 12) {
            Image(systemName: ((f.attr ?? 0) & 1) == 1 ? "lock.fill" : "folder.fill")
              .font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
              Text(f.title).foregroundStyle(.primary)
              let count = max(0, (f.media_count ?? 0) + (on ? 1 : 0) - (original.contains(f.id) ? 1 : 0))
              Text("\(count) 个内容" + (((f.attr ?? 0) & 1) == 1 ? " · 私密" : ""))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
              .foregroundStyle(on ? Color.accentColor : Color.secondary)
          }
          .contentShape(Rectangle())
        }.accessibilityAddTraits(selected.contains(f.id) ? [.isSelected] : [])
      }.disabled(loading || saving)
      Button { creating = true } label: {
        Label("新建收藏夹", systemImage: "plus.circle.fill")
      }.disabled(loading || saving)
    }
    .overlay {
      if loading && folders.isEmpty { ProgressView() }
      else if !loading && issue == nil && folders.isEmpty { ContentUnavailableView("暂无收藏夹", systemImage: "folder") }
    }
    .navigationTitle("选择收藏夹").navigationBarTitleDisplayMode(.inline).toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("完成") { Task { await save() } }.piliButtonStyle(.glassProminent)
          .disabled(saving || loading || folders.isEmpty)
      }
    }
    .task(id: revision) {
      loading = true
      defer { loading = false }
      do {
        let rows = try await BiliAPI.shared.folders(
          uid: uid, videoID: aid, resourceType: resourceType, expectedAccount: uid)
        guard rows.allSatisfy({ $0.fav_state == 0 || $0.fav_state == 1 }) else {
          throw ServiceError("无法读取收藏状态")
        }
        try Task.checkCancellation()
        let before = Set(rows.filter { $0.fav_state == 1 }.map(\.id))
        let known = Set(rows.map(\.id))
        let additions = selected.subtracting(original)
        let removals = original.subtracting(selected)
        original = before
        selected = before.union(additions.intersection(known)).subtracting(removals)
        folders = rows
        issue = nil
      } catch {
        if !Task.isCancelled {
          issue = error.localizedDescription
          folders = []
          original = []
          selected = []
        }
      }
    }
    .piliSheet(isPresented: $creating) { FolderEditor(folder: nil, uid: uid) { revision += 1 } }
  }
  private func save() async {
    guard !saving, !loading, !folders.isEmpty else { return }
    TouchFeedback.light()
    guard original != selected else { dismiss(); return }
    saving = true
    defer { saving = false }
    func field(_ ids: Set<Int64>) -> String { ids.sorted().map(String.init).joined(separator: ",") }
    do {
      try await BiliAPI.shared.submit(
        "/x/v3/fav/resource/batch-deal",
        [
          "resources": "\(aid):\(resourceType)",
          "add_media_ids": field(selected.subtracting(original)),
          "del_media_ids": field(original.subtracting(selected)),
        ], expectedAccount: uid)
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
