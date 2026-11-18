import SwiftUI
import UniformTypeIdentifiers

struct LegacyCacheImportView: View {
  @EnvironmentObject private var accounts: AccountContext
  @State private var pick = false
  @State private var source: URL?
  @State private var list = [LegacyCacheCatalog.Item]()
  @State private var checked = Set<String>()
  @State private var result = [String: String]()
  @State private var skipped = 0
  @State private var busy = false
  @State private var preserve = false
  @State private var confirm = false
  @State private var issue: String?
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  var body: some View {
    List {
      Section {
        Button { pick = true } label: {
          LabeledContent {
            if busy { ProgressView() } else if let source { Text(source.lastPathComponent).lineLimit(1) }
          } label: {
            SettingsRowLabel(title: "选择原版缓存目录", symbol: "folder.badge.plus", color: .blue)
          }
        }
        if !list.isEmpty {
          SettingToggle(title: "沿用原缓存音画质", symbol: "sparkles.tv", color: .purple, isOn: $preserve)
        }
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          if let issue { Text(issue).foregroundStyle(.red) }
          if skipped > 0 { Text("已跳过 \(skipped) 个无效条目") }
          if list.isEmpty && issue == nil { Text("选择原版客户端的下载目录，按当前账号重新缓存其中的视频") }
        }
      }
      if !list.isEmpty {
        Section("找到 \(list.count) 项") {
          ForEach(list) { v in
            Button {
              if !checked.insert(v.id).inserted { checked.remove(v.id) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: checked.contains(v.id) ? "checkmark.circle.fill" : "circle")
                  .font(.title3).foregroundStyle(checked.contains(v.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                  Text(v.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                  Text(result[v.id] ?? (v.part + " · " + (v.complete ? "原缓存已完成" : "原缓存未完成")))
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              .contentShape(Rectangle())
            }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if !list.isEmpty {
        HStack {
          Button(checked.count == list.count ? "取消全选" : "全选") {
            checked = checked.count == list.count ? [] : Set(list.map(\.id))
          }
          Spacer()
          Button("重新缓存 \(checked.count) 项") { confirm = true }
            .piliButtonStyle(.glassProminent).disabled(checked.isEmpty)
        }
        .font(.subheadline)
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
        .piliGlass(in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 4)
      }
    }
    .navigationTitle("恢复原版缓存清单").navigationBarTitleDisplayMode(.inline).disabled(busy)
      .fileImporter(isPresented: $pick, allowedContentTypes: [.folder]) { res in
        do { source = try res.get() } catch {
          if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
        }
      }
      .task(id: source) {
        guard let source else { return }
        busy = true
        defer { busy = false }
        list = []
        checked = []
        result = [:]
        issue = nil
        do {
          let r = try await Self.read(source)
          try Task.checkCancellation()
          list = r.items
          skipped = r.skipped
          if list.isEmpty { issue = "没有找到原版缓存清单" }
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
      .confirmationDialog("按当前账号重新缓存？", isPresented: $confirm, titleVisibility: .visible) {
        Button("开始") {
          let uid = owner
          Task { await restore(uid) }
        }
      }
      .onChange(of: owner) { _, _ in
        checked = []
        result = [:]
      }
  }
  private nonisolated static func read(_ url: URL) async throws -> LegacyCacheCatalog.Scan {
    let worker = Task.detached(priority: .userInitiated) { () throws -> LegacyCacheCatalog.Scan in
      guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
        throw ServiceError("无法读取所选文件夹")
      }
      defer { url.stopAccessingSecurityScopedResource() }
      var error: NSError?
      var result: Result<LegacyCacheCatalog.Scan, Error>?
      NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: url, options: .withoutChanges, error: &error
      ) { inside in result = Result { try LegacyCacheCatalog.scan(inside) } }
      if let error { throw error }
      guard let result else { throw ServiceError("文件夹未响应") }
      return try result.get()
    }
    return try await withTaskCancellationHandler(
      operation: { try await worker.value }, onCancel: { worker.cancel() })
  }
  @MainActor private func restore(_ uid: String) async {
    guard !busy, uid == owner else { return }
    busy = true
    defer { busy = false }
    for item in list where checked.contains(item.id) {
      guard !Task.isCancelled, uid == owner else { return }
      var v = item.row(owner: uid)
      if !preserve {
        v.quality = nil
        v.audioQuality = nil
      }
      do {
        if let prior = Downloads.shared.existing(v, owner: uid), prior.phase != .failed {
          result[item.id] = "已在本机缓存列表"
          checked.remove(item.id)
          continue
        }
        if v.episode == nil {
          v.singleFile = try await BiliAPI.shared.offlineArchiveMenu(v.bvid, cid: v.cid, owner: uid)
            .singleFile
        }
        await Downloads.shared.start(v)
        guard !Task.isCancelled, uid == owner else { return }
        guard let row = Downloads.shared.existing(v, owner: uid), row.phase != .failed else {
          throw ServiceError(
            Downloads.shared.existing(v, owner: uid)?.error ?? Downloads.shared.issue ?? "无法恢复")
        }
        result[item.id] = "已加入缓存队列"
        checked.remove(item.id)
      } catch {
        if !Task.isCancelled && uid == owner { result[item.id] = error.localizedDescription }
      }
    }
  }
}
