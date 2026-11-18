import SwiftUI

struct OfflineCollectionSelection: View {
  typealias Entry = ArchiveCacheDetails.Collection.Entry
  let collection: ArchiveCacheDetails.Collection, quality: Int?, audio: Int?, owner: String,
    extras: Bool
  @EnvironmentObject private var accounts: AccountContext
  @State private var whole = Set<String>()
  @State private var picked = [String: Set<Int64>]()
  @State private var loaded = [String: ArchiveCacheDetails]()
  @State private var receipts = [String: String]()
  @State private var working = Set<String>()
  @State private var busy = false
  @State private var confirm = false
  private var all: [Entry] {
    var seen = Set<String>()
    return (collection.sections ?? []).flatMap { $0.episodes ?? [] }.filter {
      guard let bv = $0.archive else { return false }
      return seen.insert(bv).inserted
    }
  }
  private var sameOwner: Bool { (accounts.state.owner(.role(.video)) ?? "") == owner }
  private func parts(_ entry: Entry, bv: String) -> [ArchiveCacheDetails.Part] {
    loaded[bv]?.pages ?? entry.pages ?? []
  }
  var body: some View {
    let ids = Set(all.compactMap(\.archive))
    let count = whole.count + picked.values.filter { !$0.isEmpty }.count
    List {
      ForEach(collection.sections ?? []) { s in
        Section(s.title ?? "合集") {
          ForEach(s.episodes ?? []) { e in if let bv = e.archive { row(e, bv) } }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 12) {
        Button(whole.isSuperset(of: ids) && !ids.isEmpty ? "取消全选" : "全选") {
          if whole.isSuperset(of: ids) {
            whole = []
            picked = [:]
          } else {
            whole = ids
            picked = [:]
          }
        }
        NavigationLink("查看缓存") { DownloadsView() }
        Spacer()
        Button { confirm = true } label: {
          HStack {
            if busy { ProgressView().tint(.white) }
            Text(count == 0 ? "缓存" : "缓存 \(count) 个稿件").fontWeight(.semibold)
          }
        }
        .piliButtonStyle(.glassProminent)
        .disabled(whole.isEmpty && picked.values.allSatisfy(\.isEmpty))
      }
      .font(.subheadline)
      .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
      .piliGlass(in: Capsule())
      .padding(.horizontal, 16).padding(.bottom, 4)
    }
    .navigationTitle(collection.title ?? "合集缓存").navigationBarTitleDisplayMode(.inline)
    .disabled(busy || !sameOwner)
      .confirmationDialog("缓存所选稿件和分 P？", isPresented: $confirm, titleVisibility: .visible) {
        Button("加入缓存队列") { Task { await submit() } }
      }
  }
  private func row(_ e: Entry, _ bv: String) -> some View {
    DisclosureGroup {
      let children = parts(e, bv: bv)
      if children.isEmpty {
        Button(working.contains(bv) ? "正在载入…" : "载入可选分 P") { Task { _ = try? await fetch(bv) } }
          .disabled(working.contains(bv))
      }
      ForEach(children) { part in
        Button {
          if whole.remove(bv) != nil { picked[bv] = Set(children.map(\.cid)) }
          var ids = picked[bv] ?? []
          if !ids.insert(part.cid).inserted { ids.remove(part.cid) }
          picked[bv] = ids
        } label: {
          let on = whole.contains(bv) || picked[bv]?.contains(part.cid) == true
          HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(on ? Color.accentColor : Color.secondary)
            Text(part.part ?? "P\(part.page ?? 1)").font(.subheadline).foregroundStyle(.primary)
          }
        }
      }
    } label: {
      HStack(spacing: 10) {
        Button {
          if !whole.insert(bv).inserted { whole.remove(bv) }
          picked[bv] = nil
        } label: {
          Image(
            systemName: whole.contains(bv)
              ? "checkmark.circle.fill"
              : (picked[bv]?.isEmpty == false ? "minus.circle.fill" : "circle")
          )
          .font(.title3)
          .foregroundStyle(whole.contains(bv) || picked[bv]?.isEmpty == false ? Color.accentColor : Color.secondary)
          .accessibilityLabel("选择整稿")
        }.buttonStyle(.borderless)
        if let pic = e.arc?.pic, let url = httpsURL(pic) {
          SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(width: 80, height: 45).background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(e.title ?? bv).font(.subheadline).lineLimit(2)
          if let note = receipts[bv] { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
      }
    }
  }
  @MainActor private func fetch(_ bv: String) async throws -> ArchiveCacheDetails {
    if let d = loaded[bv] { return d }
    working.insert(bv)
    defer { working.remove(bv) }
    do {
      let d = try await BiliAPI.shared.offlineArchiveDetails(bv, owner: owner)
      try Task.checkCancellation()
      guard sameOwner else { throw CancellationError() }
      loaded[bv] = d
      return d
    } catch {
      if !Task.isCancelled { receipts[bv] = error.localizedDescription }
      throw error
    }
  }
  @MainActor private func submit() async {
    guard !busy, sameOwner else { return }
    busy = true
    defer { busy = false }
    for (i, e) in all.enumerated() {
      guard let bv = e.archive, whole.contains(bv) || picked[bv]?.isEmpty == false else { continue }
      guard !Task.isCancelled, sameOwner else { return }
      do {
        let d = try await fetch(bv)
        let ps: [ArchiveCacheDetails.Part] = (d.pages ?? []).filter { $0.cid > 0 }
        let parts: [ArchiveCacheDetails.Part] =
          ps.isEmpty
          ? (d.cid.map {
            [ArchiveCacheDetails.Part(cid: $0, part: d.title, page: 1, duration: nil)]
          } ?? []) : ps
        let chosen = whole.contains(bv) ? Set(parts.map(\.cid)) : (picked[bv] ?? [])
        guard !chosen.isEmpty else { throw ServiceError("没有可缓存的分 P") }
        let video = Video(
          aid: d.aid, bvid: bv, title: d.title ?? e.title ?? bv, pic: d.pic ?? e.arc?.pic ?? "",
          owner: nil, stat: nil, duration: nil, desc: nil, cid: d.cid,
          pages: parts.map {
            .init(
              cid: $0.cid, duration: $0.duration, page: $0.page ?? 1, part: $0.part ?? d.title ?? ""
            )
          })
        var count = 0
        var failed = [String]()
        var remaining = chosen
        for (j, p) in parts.enumerated() where chosen.contains(p.cid) {
          guard !Task.isCancelled, sameOwner else { return }
          do {
            try d.authorize(bv, cid: p.cid)
            let menu = try await BiliAPI.shared.offlineArchiveMenu(bv, cid: p.cid, owner: owner)
            let err = await Downloads.shared.add(
              video, cid: p.cid, quality: quality, audioQuality: audio, owner: owner,
              extras: extras, singleFile: menu.singleFile,
              collection: (collection.id, collection.title ?? "合集", i * 100_000 + j))
            if let err {
              failed.append(err)
            } else {
              count += 1
              remaining.remove(p.cid)
            }
          } catch { failed.append(error.localizedDescription) }
        }
        whole.remove(bv)
        picked[bv] = remaining
        receipts[bv] = failed.first.map { "已加入 \(count) 项 · " + $0 } ?? "已加入 \(count) 项"
      } catch { if !Task.isCancelled { receipts[bv] = error.localizedDescription } }
    }
  }
}
