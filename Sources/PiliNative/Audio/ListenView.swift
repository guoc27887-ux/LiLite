import AVKit
import PiliWire
import SwiftUI

/// The original client's audio page: artwork, title and actions, the progress bar and large
/// transport controls; the queue and playback options open in a sheet.
struct ListenView: View {
  @ObservedObject private var queue = ListenQueue.shared
  @ObservedObject private var catalog = ListenQueue.shared.catalog
  @AppStorage("listen.repeat") private var mode = AudioSequence.list.rawValue
  @EnvironmentObject private var accounts: AccountContext
  @State private var scrub: Double?
  @State private var local = false
  @State private var clear = false
  @State private var showInfo = false
  @State private var showQueue = false
  @State private var segments = false
  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        if let t = queue.current {
          if queue.media?.preview == true {
            Label("试听", systemImage: "headphones").font(.caption.weight(.semibold))
              .padding(.horizontal, 10).padding(.vertical, 4)
              .background(Color.accentColor.opacity(0.12), in: Capsule()).foregroundStyle(.tint)
          }
          ListenMetadata(track: t, queue: queue, catalog: catalog, transport: AnyView(transport)).id(t.id)
          if let err = queue.issue {
            PageFailure(message: err) { queue.resume() }
          }
          Button("结束播放", role: .destructive) { queue.stop() }
            .font(.subheadline).piliButtonStyle(.glass).padding(.top, 4)
        } else {
          ContentUnavailableView("没有正在收听的内容", systemImage: "headphones",
            description: Text("在视频详情页选择“听视频”开始收听"))
          if let mark = queue.mark, PlaybackMemory.enabled {
            Button {
              queue.continueListening()
            } label: {
              Label("继续收听：" + mark.track.title, systemImage: "play.fill").lineLimit(1)
            }.piliButtonStyle(.glassProminent)
          }
        }
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
      .frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
    .navigationTitle("听视频")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { local = !queue.serviceQueue }
    .onChange(of: queue.serviceQueue) { _, v in local = !v }
    .onChange(of: queue.current?.id) { _, _ in scrub = nil }
    .toolbar {
      OutputRouteButton(video: false).frame(width: 34, height: 32)
      SleepTimerButton().labelStyle(.iconOnly)
      Menu {
        if queue.current != nil { Button("播放信息", systemImage: "info.circle") { showInfo = true } }
        if let t = queue.current, t.songID == nil, UserDefaults.standard.bool(forKey: "sponsor.enabled") {
          Button("空降标记", systemImage: "forward.frame") { segments = true }
        }
        if queue.tracks.count > 1 && !queue.serviceQueue, queue.current != nil {
          Button("仅保留正在播放", systemImage: "line.3.horizontal.decrease") { queue.clearOthers() }
        }
        if !queue.tracks.isEmpty {
          Button("清空本机待播", systemImage: "trash", role: .destructive) { clear = true }
        }
      } label: {
        Image(systemName: "ellipsis")
      }.accessibilityLabel("更多")
    }
    .navigationDestination(isPresented: $segments) { ListenSegments(queue: queue) }
    .confirmationDialog("清空本机待播列表？", isPresented: $clear, titleVisibility: .visible) {
      Button("清空", role: .destructive) { queue.clearList() }
    }
    .piliSheet(isPresented: $showQueue) {
      PiliNavigationStack {
        List {
          playbackSettings
          queueRows
        }
        .navigationTitle("播放列表").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if local { ToolbarItem(placement: .topBarLeading) { EditButton() } }
          ToolbarItem(placement: .confirmationAction) { Button("完成") { showQueue = false } }
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .piliSheet(isPresented: $showInfo) {
      PiliNavigationStack {
        Form {
          if let m = queue.media {
            LabeledContent("来源", value: m.kind)
            if let q = m.quality { LabeledContent("音质", value: PlaybackOption.audioName(q)) }
            if let c = m.codec { LabeledContent("编码", value: c) }
            if let n = m.bitrate { LabeledContent("码率", value: "\(n/1000) kbps") }
            LabeledContent("可选线路", value: String(m.urls.count))
          }
          if let t = queue.current {
            LabeledContent("内容编号", value: t.bvid)
            LabeledContent("分段编号", value: String(t.cid))
          }
        }.navigationTitle("播放信息").toolbar { Button("完成") { showInfo = false } }
      }
    }
  }
  private var sequence: AudioSequence { AudioSequence(rawValue: mode) ?? .list }
  private func symbol(_ m: AudioSequence) -> String {
    switch m {
    case .pause: "pause.circle"
    case .list: "arrow.right"
    case .one: "repeat.1"
    case .all: "repeat"
    case .shuffle: "shuffle"
    }
  }
  private var transport: some View {
    VStack(spacing: 14) {
      VStack(spacing: 4) {
        Slider(
          value: Binding(
            get: { queue.duration > 0 ? max(0, min(scrub ?? queue.clock, queue.duration)) : 0 },
            set: { scrub = $0 }),
          in: 0...max(1, queue.duration)
        ) { edit in
          if !edit, let scrub {
            queue.seek(scrub)
            self.scrub = nil
          }
        }.disabled(queue.duration <= 0)
        if !queue.segments.isEmpty {
          SponsorMarkers(rows: queue.segments, duration: queue.duration, rules: .current())
        }
        HStack {
          Text(clockText(scrub ?? queue.clock))
          Spacer()
          Text(clockText(queue.duration))
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      HStack {
        Menu {
          Picker("播放模式", selection: $mode) {
            ForEach(AudioSequence.allCases, id: \.self) { m in
              Label(m.rawValue, systemImage: symbol(m)).tag(m.rawValue)
            }
          }
        } label: {
          Image(systemName: symbol(sequence)).font(.title3).frame(width: 44, height: 44)
            .contentTransition(.symbolEffect(.replace))
        }.accessibilityLabel("播放模式").accessibilityValue(sequence.rawValue)
        Spacer()
        Button { queue.step(-1) } label: {
          Image(systemName: "backward.fill").font(.title2).frame(width: 52, height: 52)
        }.accessibilityLabel("上一首")
        Spacer()
        Button {
          if queue.playing { queue.pause() } else { queue.resume() }
        } label: {
          ZStack {
            if queue.loading {
              ProgressView().tint(.white)
            } else {
              Image(systemName: queue.playing ? "pause.fill" : "play.fill").font(.title)
                .foregroundStyle(.white).contentTransition(.symbolEffect(.replace))
            }
          }
          .frame(width: 70, height: 70)
          .background(Color.accentColor, in: Circle())
          .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
        }.accessibilityLabel(queue.playing ? "暂停" : "播放")
        Spacer()
        Button { queue.step(1) } label: {
          Image(systemName: "forward.fill").font(.title2).frame(width: 52, height: 52)
        }.accessibilityLabel("下一首")
        Spacer()
        Button { showQueue = true } label: {
          Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44)
        }.accessibilityLabel("播放列表")
      }
      .buttonStyle(PlayerPressStyle()).foregroundStyle(.primary)
      HStack(spacing: 10) {
        Menu {
          Picker("倍速", selection: Binding(get: { (queue.speed * 10).rounded() / 10 }, set: { queue.setSpeed($0) })) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text($0.formatted() + "×").tag($0) }
          }
        } label: {
          Text(String(format: "%.2g×", queue.speed)).font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .piliGlass(in: Capsule(), interactive: true)
        }
        Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
        Slider(value: Binding(get: { queue.playerVolume }, set: { queue.setVolume($0) }), in: 0...1)
          .accessibilityLabel("播放器音量")
        Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
      }
      if let s = queue.requestedSkip {
        Button("跳过" + (s.detail?.title ?? "片段")) { queue.skip(s) }.piliButtonStyle(.glass)
      }
      if let hint = queue.skipHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
    }
  }
  private var playbackSettings: some View {
    Section("播放设置") {
      Picker("播放模式", selection: $mode) {
        ForEach(AudioSequence.allCases, id: \.self) { m in Text(m.rawValue).tag(m.rawValue) }
      }
      HStack {
        Text("倍速")
        Slider(
          value: Binding(get: { queue.speed }, set: { queue.setSpeed($0) }), in: 0.5...2, step: 0.1)
        Text(String(format: "%.1f×", queue.speed)).monospacedDigit()
      }
    }
  }
  @ViewBuilder private var queueRows: some View {
    Section {
      if queue.serviceQueue {
        ChipBar(items: [false, true], selection: $local, title: { $0 ? "本机待播" : "来源队列" })
          .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      if local || !queue.serviceQueue {
        if queue.tracks.isEmpty { Text("暂无待播音频").foregroundStyle(.secondary) }
        ForEach(queue.tracks) { t in trackRow(t, local: true) }.onDelete { queue.remove($0) }.onMove
        { queue.move($0, to: $1) }
      } else {
        if let t = queue.current, catalog.usesListener {
          Picker(
            "队列排序",
            selection: Binding(get: { catalog.order }, set: { catalog.sort($0, current: t) })
          ) {
            ForEach(Array(["无序", "正序", "倒序", "随机"].enumerated()), id: \.offset) { i, s in
              Text(s).tag(i)
            }
          }
        }
        if let issue = catalog.issue {
          Text(issue).foregroundStyle(.secondary)
          Button("重新载入队列") { Task { await catalog.load(.first) } }
        }
        if catalog.before != nil { Button("载入之前的曲目") { Task { await catalog.load(.previous) } } }
        ForEach(catalog.tracks) { t in
          trackRow(t, local: false).swipeActions {
            if queue.current?.bvid != t.bvid {
              Button("移除", role: .destructive) { catalog.omit(t) }
            }
          }
        }
        if catalog.after != nil { Button("载入更多曲目") { Task { await catalog.load(.next) } } }
        if catalog.busy {
          ProgressView()
        } else if catalog.tracks.isEmpty && catalog.issue == nil {
          Text("暂无其他曲目").foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("待播列表")
    }
  }
  @ViewBuilder private func trackRow(_ t: ListenTrack, local: Bool) -> some View {
    if let parts = t.parts, parts.count > 1 {
      DisclosureGroup {
        ForEach(parts, id: \.cid) { p in
          Button {
            queue.playRow(t, local: local, part: p)
          } label: {
            Label(
              p.title,
              systemImage: queue.current?.cid == p.cid && queue.current?.bvid == t.bvid
                ? "speaker.wave.2" : "play.circle")
          }
        }
      } label: {
        Text(t.archiveTitle ?? t.title)
      }
    } else {
      let playing = queue.current?.bvid == t.bvid && queue.current?.cid == t.cid
      Button {
        queue.playRow(t, local: local)
      } label: {
        HStack(spacing: 10) {
          SiteThumbnail(url: httpsURL(t.cover)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(width: 64, height: 40).background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(t.title).font(.subheadline.weight(playing ? .semibold : .regular)).lineLimit(1)
              .foregroundStyle(playing ? Color.accentColor : Color.primary)
            if !t.artist.isEmpty { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
          }
          Spacer(minLength: 0)
          if playing {
            Image(systemName: "waveform").foregroundStyle(.tint)
              .symbolEffect(.variableColor.iterative, options: .repeating, isActive: queue.playing)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
    }
  }
}
private struct ListenSegments: View {
  @ObservedObject var queue: ListenQueue
  @State private var message: String?
  var body: some View {
    List {
      if let text = message ?? queue.segmentError { Text(text) }
      ForEach(queue.segments) { s in
        VStack(alignment: .leading) {
          Text(s.detail?.title ?? s.category)
          Text(clockText(s.segment[0]) + " – " + clockText(s.segment[1])).font(
            .caption.monospacedDigit())
          HStack {
            Button("定位") { queue.seek(s.segment[0]) }
            if s.segment[1] > s.segment[0] { Button("跳过") { queue.skip(s) } }
            Spacer()
            Menu("反馈") {
              Button("赞同") { vote(s, 1, nil) }
              Button("不赞同") { vote(s, 0, nil) }
              Menu("建议修改类别") {
                ForEach(SponsorCategory.all) { c in Button(c.title) { vote(s, nil, c.id) } }
              }
            }
          }.buttonStyle(.borderless)
        }
      }
      if queue.segments.isEmpty, queue.segmentError == nil {
        Text("暂无片段标记").foregroundStyle(.secondary)
      }
    }.navigationTitle("空降标记").piliRefreshable { queue.reloadSegments() }
  }
  private func vote(_ s: SponsorSegment, _ type: Int?, _ category: String?) {
    Task {
      do {
        try await SponsorAPI().vote(s.id, type: type, category: category)
        message = "已提交反馈"
      } catch { message = error.localizedDescription }
    }
  }
}
