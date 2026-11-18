import SwiftUI

struct SeasonBatchCache: View {
  let episodes: [SeasonInfo.Episode], course: Bool, title: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var selection = Set<Int64>()
  @State private var receipt = [Int64: String]()
  @State private var busy = false
  @State private var extras = true
  @State private var quality = 0
  @State private var audio = 0
  @State private var videoChoices: [Int] = []
  @State private var audioChoices: [Int] = []
  @State private var fetching = false
  @State private var menuIssue: String?
  private var available: [SeasonInfo.Episode] { episodes.filter(\.allowCacheEntry) }
  private var uid: String { accounts.state.owner(.role(.video)) ?? "" }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(title).piliFont(.headline).lineLimit(2)
        HStack(spacing: 10) {
          if videoChoices.isEmpty {
            Button {
              let viewer = uid; Task { await fetchOptions(viewer) }
            } label: {
              Label(fetching ? "正在读取音画质" : "选择画质", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .disabled(selection.isEmpty || fetching)
          } else {
            Menu {
              Picker("画质", selection: $quality) {
                Text(OfflineQuality.video(videoChoices).map { "默认 · " + StreamQuality.name($0) } ?? "默认").tag(0)
                ForEach(videoChoices, id: \.self) { Text(StreamQuality.name($0)).tag($0) }
              }
            } label: {
              ComposerMenuLabel(title: quality == 0 ? "默认画质" : StreamQuality.name(quality), symbol: "sparkles.tv")
            }
            if !audioChoices.isEmpty {
              Menu {
                Picker("音质", selection: $audio) {
                  Text(OfflineQuality.audio(audioChoices).map { "默认 · " + PlaybackOption.audioName($0) } ?? "默认").tag(0)
                  ForEach(audioChoices, id: \.self) { Text(PlaybackOption.audioName($0)).tag($0) }
                }
              } label: {
                ComposerMenuLabel(title: audio == 0 ? "默认音质" : PlaybackOption.audioName(audio), symbol: "waveform")
              }
            }
          }
          Spacer()
          Toggle(isOn: $extras) { Text("字幕与弹幕") }.toggleStyle(LoginCheckbox()).font(.subheadline)
        }
        if let menuIssue { Text(menuIssue).font(.caption).foregroundStyle(.red) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
          ForEach(available) { e in
            let on = selection.contains(e.id)
            Button {
              if !selection.insert(e.id).inserted { selection.remove(e.id) }
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(e.label).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                  .foregroundStyle(on ? Color.accentColor : Color.primary)
                if let r = receipt[e.id] {
                  Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .padding(.horizontal, 12).padding(.vertical, 8)
              .background(on ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(on ? Color.accentColor : Color.clear, lineWidth: 1)
              }
              .overlay(alignment: .topTrailing) {
                if receipt[e.id] == "已加入缓存" || receipt[e.id] == "已在缓存列表" {
                  Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.green).padding(5)
                }
              }
            }
            .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
          }
        }
      }
      .padding(16)
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 12) {
        Button(selection.count == available.count && !available.isEmpty ? "取消全选" : "全选") {
          selection = selection.count == available.count ? [] : Set(available.map(\.id))
        }
        NavigationLink("查看缓存") { DownloadsView() }
        Spacer()
        Button {
          let owner = uid
          Task { await run(owner) }
        } label: {
          HStack {
            if busy { ProgressView().tint(.white) }
            Text(selection.isEmpty ? "缓存" : "缓存 \(selection.count) 集").fontWeight(.semibold)
          }
        }
        .piliButtonStyle(.glassProminent).disabled(selection.isEmpty)
      }
      .font(.subheadline)
      .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
      .piliGlass(in: Capsule())
      .padding(.horizontal, 16).padding(.bottom, 4)
    }
    .disabled(busy).navigationTitle("离线缓存").navigationBarTitleDisplayMode(.inline).onChange(of: uid) { _, _ in
      selection = []
      receipt = [:]; videoChoices = []; audioChoices = []; quality = 0; audio = 0; menuIssue = nil
    }
  }
  @MainActor private func fetchOptions(_ owner: String) async {
    guard !fetching, let e = available.first(where: { selection.contains($0.id) }) else { return }
    fetching = true; defer { fetching = false }
    do {
      let plan = try await BiliAPI.shared.cacheEpisode(
        .init(id: e.id, course: course), cid: e.cid, bvid: e.bvid, owner: owner);
      try Task.checkCancellation(); guard uid == owner else { return }
      videoChoices = plan.qualities
      audioChoices = Set((plan.formats?.audio ?? []).filter(PlaybackOption.supportsAudio).map(\.id))
        .sorted(by: >)
      if !videoChoices.contains(quality) { quality = 0 };
      if !audioChoices.contains(audio) { audio = 0 }; menuIssue = nil
    } catch { if !Task.isCancelled && uid == owner { menuIssue = error.localizedDescription } }
  }
  @MainActor private func run(_ owner: String) async {
    guard !busy, owner == uid else { return }
    busy = true
    defer { busy = false }
    let rows = available.filter { selection.contains($0.id) }
    for e in rows {
      guard !Task.isCancelled, uid == owner else { return }
      var v = OfflineVideo(bvid: e.bvid, cid: e.cid, title: title, part: e.label)
      v.episode = .init(id: e.id, course: course)
      v.cacheOwner = owner; v.scoped = true; v.cover = e.cover
      v.quality = quality == 0 ? nil : quality; v.audioQuality = audio == 0 ? nil : audio
      v.includeExtras = extras
      v.aid = e.aid
      if let row = Downloads.shared.existing(v, owner: owner), row.phase != .failed {
        receipt[e.id] = "已在缓存列表"
        selection.remove(e.id)
        continue
      }
      // Downloads resolves a fresh entitlement and clear media plan per episode under the selected playback account.
      await Downloads.shared.start(v)
      guard !Task.isCancelled, uid == owner else { return }
      if let row = Downloads.shared.existing(v, owner: owner), row.phase != .failed {
        receipt[e.id] = "已加入缓存"
        selection.remove(e.id)
      } else {
        receipt[e.id] =
          Downloads.shared.existing(v, owner: owner)?.error ?? Downloads.shared.issue
          ?? "未能缓存"
      }
    }
  }
}
