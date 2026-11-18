import AVKit
import SwiftUI

struct SponsorEditor: View {
  @ObservedObject var model: PlayerModel
  var embedded = false
  @Environment(\.dismiss) private var dismiss
  @State private var confirm = false
  @State private var busy = false
  @State private var issue: String?
  @State private var preview: SponsorDraft?
  private var fallback: Double { min(max(0, model.seconds), model.duration) }
  var body: some View {
    if embedded { form } else { PiliNavigationStack { form } }
  }
  @State private var editing: (id: SponsorDraft.ID, start: Bool)?
  @State private var editText = ""
  private static func actionTitle(_ a: String) -> String {
    ["skip": "跳过", "mute": "静音", "poi": "精彩时刻", "full": "整段视频"][a] ?? a
  }
  /// The original's 提交片段 panel: one rounded card per segment (开始/结束 with 当前 · 开头/结尾 ·
  /// 编辑 icons, then 分类 ▾ and 行为类别 ▾), preview and remove in the card's corners, a ✓ button
  /// floating at the bottom right.
  private var form: some View {
    ScrollView {
      LazyVStack(spacing: 10) {
        if model.sponsorDrafts.isEmpty {
          Text("暂无数据").foregroundStyle(.secondary).padding(.top, 80)
        }
        ForEach($model.sponsorDrafts) { $row in card($row) }
        if let issue { Text(issue).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16) }
      }
      .padding(.vertical, 8).padding(.bottom, 88)
    }
    .overlay(alignment: .bottomTrailing) {
      if !model.sponsorDrafts.isEmpty {
        Button {
          do {
            _ = try SponsorDraft.payload(model.sponsorDrafts, duration: model.duration)
            issue = nil
            confirm = true
          } catch { issue = error.localizedDescription }
        } label: {
          Group { if busy { ProgressView() } else { Image(systemName: "checkmark").font(.system(size: 19, weight: .semibold)) } }
            .frame(width: 50, height: 50)
        }
        .piliButtonStyle(.glassProminent).buttonBorderShape(.circle).disabled(busy)
        .accessibilityLabel("提交").padding(18)
      }
    }
    .disabled(busy).modifier(ReplyEdgeDismiss(standalone: !busy))
    .navigationTitle("提交片段").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) }
      ToolbarItem(placement: .primaryAction) {
        Button { model.sponsorDrafts.insert(.init(end: fallback), at: 0) } label: { Image(systemName: "plus") }
          .accessibilityLabel("添加片段").disabled(busy)
      }
    }
    .alert("确定无误再提交", isPresented: $confirm) {
      Button("取消", role: .cancel) {}
      Button("确定提交") { Task { await publish() } }
    }
    .alert((editing?.start ?? true) ? "开始" : "结束", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
      TextField("时:分:秒", text: $editText).keyboardType(.numbersAndPunctuation)
      Button("取消", role: .cancel) {}
      Button("确定") { applyEdit() }
    }
    .piliSheet(item: $preview) { row in SponsorPreview(model: model, draft: row) }
    .interactiveDismissDisabled(busy)
  }
  private func card(_ row: Binding<SponsorDraft>) -> some View {
    let r = row.wrappedValue
    return VStack(alignment: .leading, spacing: 8) {
      if r.action != "full" {
        point(row, start: true)
        if r.action != "poi" { point(row, start: false) }
      }
      HStack(spacing: 16) {
        Menu {
          ForEach(SponsorCategory.all) { c in
            Button(c.title) { row.wrappedValue.select(c.id) }
          }
        } label: { menuText("分类", SponsorCategory.all.first { $0.id == r.category }?.title ?? r.category) }
        Menu {
          ForEach(r.kind.actions, id: \.self) { a in Button(Self.actionTitle(a)) { row.wrappedValue.action = a } }
        } label: { menuText("行为类别", Self.actionTitle(r.action)) }
      }
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 12)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(alignment: .topLeading) {
      iconButton("eye", "预览") {
        do { _ = try r.range(duration: model.duration); preview = r }
        catch { issue = error.localizedDescription }
      }
    }
    .overlay(alignment: .topTrailing) {
      iconButton("xmark", "移除") { model.sponsorDrafts.removeAll { $0.id == r.id } }
    }
    .padding(.horizontal, 16)
  }
  private func point(_ row: Binding<SponsorDraft>, start: Bool) -> some View {
    let value = start ? row.wrappedValue.start : row.wrappedValue.end
    return HStack(spacing: 5) {
      Text((start ? "开始: " : "结束: ") + clockText(value)).monospacedDigit()
      iconButton("location", "设为当前") { set(row, start, fallback) }
      iconButton(start ? "backward.end" : "forward.end", start ? "视频开头" : "视频结尾") {
        set(row, start, start ? 0 : model.duration)
      }
      iconButton("pencil", "编辑") { editText = clockText(value); editing = (row.wrappedValue.id, start) }
    }
  }
  private func set(_ row: Binding<SponsorDraft>, _ start: Bool, _ value: Double) {
    if start { row.wrappedValue.start = value } else { row.wrappedValue.end = value }
    if row.wrappedValue.action == "poi" { row.wrappedValue.end = row.wrappedValue.start }
  }
  /// "1:02:03", "2:03" or "123" seconds, as the original parses it.
  private func applyEdit() {
    guard let target = editing, let i = model.sponsorDrafts.firstIndex(where: { $0.id == target.id }) else { return }
    let parts = editText.split(separator: ":").reversed().compactMap { Double($0) }
    guard !parts.isEmpty else { return }
    let seconds = parts.enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
    guard seconds >= 0, seconds <= model.duration else { issue = "时间超出视频长度"; return }
    if target.start { model.sponsorDrafts[i].start = seconds } else { model.sponsorDrafts[i].end = seconds }
    if model.sponsorDrafts[i].action == "poi" { model.sponsorDrafts[i].end = model.sponsorDrafts[i].start }
  }
  private func menuText(_ title: String, _ value: String) -> some View {
    HStack(spacing: 2) {
      Text(title + ": ").foregroundStyle(.primary)
      Text(value).foregroundStyle(.tint)
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
    }
  }
  private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        .frame(width: 30, height: 30).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(label)
  }
  @MainActor private func publish() async {
    guard !busy, let source = model.timeline.source, let bv = source.bvid else { return }
    let rows = model.sponsorDrafts
    busy = true
    defer { busy = false }
    do {
      _ = try await SponsorAPI().publish(
        bvid: bv, cid: source.cid, duration: model.duration, drafts: rows)
      guard model.timeline.source == source else { return }
      let sent = Set(rows.map(\.id))
      model.sponsorDrafts.removeAll { sent.contains($0.id) }
      await model.reloadSponsors()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
private struct SponsorPreview: View {
  @ObservedObject var model: PlayerModel
  let draft: SponsorDraft
  @Environment(\.dismiss) private var dismiss
  @State private var player: (any PlaybackEngine)?
  @State private var replay = 0
  @State private var resume = false
  @State private var source: TimelineSource?
  @State private var issue: String?
  var body: some View {
    PiliNavigationStack {
      VStack {
        Group {
          if let native = player?.nativePlayer { VideoPlayer(player: native) }
          else if let mpv = player as? MPVPlayer { MPVVideoView(player: mpv).id(ObjectIdentifier(mpv)) }
          else { Color.black }
        }.aspectRatio(16 / 9, contentMode: .fit)
        if let issue { Text(issue) }
        Button("重新预览") { replay += 1 }
      }.navigationTitle("片段预览").toolbar { Button("完成") { dismiss() } }
    }.onAppear {
      source = model.timeline.source
      resume = model.engine.rate != 0
      if resume { model.engine.pause() }
    }.task(id: replay) { await run() }
      .onDisappear {
        player?.pause()
        player?.nativePlayer?.replaceCurrentItem(with: nil)
        (player as? MPVPlayer)?.stop()
        player = nil
        if resume, source == model.timeline.source {
          model.engine.playImmediately(atRate: model.rate)
        }
      }
  }
  @MainActor private func run() async {
    guard let item = model.engine.playbackItem else {
      issue = "没有可预览的视频"
      return
    }
    do {
      let range = try draft.range(duration: model.duration)
      player?.pause()
      let next: any PlaybackEngine
      if let native = item as? AVPlayerItem { next = AVPlayer(playerItem: AVPlayerItem(asset: native.asset)) }
      else if let copy = (model.engine as? MPVPlayer)?.previewCopy() { next = copy }
      else { throw ServiceError("没有可预览的视频") }
      self.player = next
      let player = next
      player.isMuted = false
      for _ in 0..<400 where !player.playbackReady {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard player.playbackReady else { throw ServiceError("无法播放预览") }
      let a = range[0]
      let b = range[1]
      let begin = draft.action == "full" ? 0 : max(0, a - 3)
      func seek(_ t: Double) async -> Bool {
        await player.seek(
          to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero,
          toleranceAfter: .zero)
      }
      guard await seek(begin), !Task.isCancelled else { return }
      player.play()
      var crossed = false
      while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(65))
        if !player.playbackReady { throw ServiceError("无法播放预览") }
        let t = player.currentTime().seconds
        if t.isFinite && t >= a && !crossed {
          crossed = true
          if draft.action == "skip" { _ = await seek(b) }
        }
        if draft.action == "mute" { player.isMuted = t >= a && t < b }
        if t.isFinite && t >= min(model.duration, b + 4) {
          player.pause()
          break
        }
      }
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
