import SwiftUI

/// Horizontal cards for multi-part videos, like the episode rails in Apple's TV app.
struct ArchivePartStrip: View {
  let pages: [Video.Part]
  let current: Int64?
  let descending: Bool
  let pick: (Int64) -> Void
  let reorder: () -> Void
  var body: some View {
    let order = descending ? Array(pages.reversed()) : pages
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("选集").font(.headline)
        Text("共 \(pages.count) P").font(.footnote).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button(action: reorder) {
          Label(descending ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
            .font(.footnote.weight(.medium))
        }.buttonStyle(.plain).foregroundStyle(.secondary)
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 10) {
            ForEach(order) { part in
              let selected = part.cid == current
              Button { if !selected { TouchFeedback.light(); pick(part.cid) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 4) {
                    if selected {
                      Image(systemName: "waveform").font(.caption2.weight(.bold))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Text("P\(part.page)").font(.caption.weight(.semibold)).monospacedDigit()
                    if let d = part.duration, d > 0 {
                      Text(clockText(Double(d))).font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                  }.foregroundStyle(selected ? Color.accentColor : Color.secondary)
                  Text(part.part).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                  Spacer(minLength: 0)
                }
                .frame(width: 148, height: 58, alignment: .topLeading)
                .padding(12)
                .background(
                  selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                  in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              }.buttonStyle(.plain).id(part.cid)
                .accessibilityLabel("P\(part.page) \(part.part)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
          }.padding(.horizontal, 16)
        }.scrollClipDisabled().padding(.horizontal, -16)
          .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
          .onChange(of: current) { _, id in
            if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
          }
      }
    }
  }
}

/// One tappable card for a collection; the full list opens in the existing panel.
struct ArchiveCollectionCard: View {
  let catalog: VideoCollection
  let currentBVID: String
  let open: () -> Void
  var body: some View {
    let entries = (catalog.sections ?? []).flatMap { $0.episodes ?? [] }
    let index = entries.firstIndex { $0.bvid == currentBVID }
    Button(action: open) {
      HStack(spacing: 12) {
        Image(systemName: "rectangle.stack.fill").font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.white).frame(width: 40, height: 40)
          .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        VStack(alignment: .leading, spacing: 3) {
          Text(catalog.title ?? "视频合集").font(.subheadline.weight(.semibold)).lineLimit(1)
          Text(index.map { "第 \($0 + 1) 个 · 共 \(entries.count) 个视频" } ?? "共 \(entries.count) 个视频")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(12)
      .background(Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
    }.buttonStyle(.plain)
  }
}

/// Related videos shown inline below the introduction, as in the original client.
struct ArchiveRelatedList: View {
  let bvid: String
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("detail.related") private var enabled = true
  @State private var items: [Video] = []
  @State private var failed = false
  @State private var loaded = false
  var body: some View {
    // Always keep a concrete container: an empty Group would never run the load task.
    VStack(alignment: .leading, spacing: 14) {
      if enabled {
        Text("相关推荐").font(.headline)
        if failed && items.isEmpty {
          Button("重新加载相关推荐") { failed = false; Task { await load() } }
            .piliButtonStyle(.glass).frame(maxWidth: .infinity)
        } else if !loaded {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if items.isEmpty {
          Text("暂无相关视频").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(items) { video in
          ArchiveRelatedRow(video: video)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
    .task(id: "\(bvid):\(accounts.state.owner(.role(.recommend)) ?? "")") { await load() }
    .environment(\.discoveryCardRemoval, { change in
      items.removeAll { v in v.bvid == change.archive || (change.creator != nil && v.owner?.mid == change.creator) }
    })
  }
  @MainActor private func load() async {
    guard enabled else { items = []; return }
    let owner = accounts.state.owner(.role(.recommend)) ?? ""
    do {
      let list = try await BiliAPI.shared.read(
        "/x/web-interface/archive/related", ["bvid": bvid], expectedAccount: owner, as: [Video].self)
      guard !Task.isCancelled else { return }
      let filtering = Task.detached(priority: .userInitiated) {
        let policy = RecommendationFilter()
        return list.filter { !Task.isCancelled && policy.allows($0, from: .related) }
      }
      let filtered = await withTaskCancellationHandler { await filtering.value } onCancel: { filtering.cancel() }
      try Task.checkCancellation()
      items = filtered
      failed = false
      loaded = true
    } catch {
      if !Task.isCancelled { failed = true; loaded = true }
    }
  }
}

struct ArchiveRelatedRow: View {
  let video: Video
  var body: some View {
    NavigationLink {
      DetailView(initial: video)
    } label: {
      MediaRow(
        cover: video.cover, title: video.title,
        duration: video.duration.map { clockText(Double($0)) },
        subtitle: video.owner?.name,
        detail: MediaStats.line(views: video.stat?.view, danmaku: video.stat?.danmaku))
    }.buttonStyle(.plain).archiveCover(video)
  }
}

/// Gives existing labelled buttons (cast, sleep timer) the same chip appearance.
struct ToolChipLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) { configuration.icon; configuration.title }
      .font(.footnote.weight(.medium)).foregroundStyle(.primary)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
      .contentShape(Capsule())
  }
}
/// Text chips for secondary tools, kept on one horizontally scrolling line.
struct ArchiveToolChip: View {
  let title: String, symbol: String
  var body: some View {
    Label(title, systemImage: symbol).font(.footnote.weight(.medium))
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
      .contentShape(Capsule())
  }
}
