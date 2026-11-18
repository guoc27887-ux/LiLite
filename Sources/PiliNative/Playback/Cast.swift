import AVKit
import SwiftUI

@MainActor final class CastDirectory: ObservableObject {
  @Published private(set) var devices: [CastDevice] = []
  @Published private(set) var searching = false
  @Published var issue: String?
  private var scan: Task<Void, Never>?, pending: [URL: Task<Void, Never>] = [:],
    expires: [String: Double] = [:], advertised: [String: String] = [:],
    departures: [String: Int] = [:], ticket = UUID()
  func search() {
    stop()
    let mark = ticket
    searching = true
    devices = []
    expires = [:]
    advertised = [:]
    departures = [:]
    issue = nil
    scan = Task { [weak self] in
      guard let self else { return }
      defer { if ticket == mark { searching = false } }
      do {
        let useSSDP=Bundle.main.object(forInfoDictionaryKey:"PiliMulticastDiscovery") as? Bool ?? false
        let events=useSSDP ? CastSSDP.events():CastBonjour.events()
        for try await e in events {
          guard !Task.isCancelled, ticket == mark else { return }
          if !e.alive {
            departures[e.udn, default: 0] += 1
            if let id = advertised[e.udn] {
              devices.removeAll { $0.id == id }
              expires[id] = nil
            }
            continue
          }
          let now = ProcessInfo.processInfo.systemUptime
          devices.removeAll { self.expires[$0.id].map { $0 < now } ?? false }
          guard let raw = e.location else { continue }
          if let id = advertised[e.udn], devices.contains(where: { $0.id == id }) {
            expires[id] = now + e.age
            continue
          }
          guard pending[raw] == nil, pending.count < 6, devices.count < 64 else { continue }
          let death = departures[e.udn, default: 0]
          pending[raw] = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == mark { pending[raw] = nil } }
            do {
              let u = try await CastLAN.location(raw, peer: e.sender)
              let d = try await CastHTTP().device(u, alias: CastAddress.host(raw))
              try Task.checkCancellation()
              guard ticket == mark, departures[e.udn, default: 0] == death else { return }
              add(d)
              if !e.udn.isEmpty { advertised[e.udn] = d.id }
              expires[d.id] = now + e.age
            } catch {}
          }
        }
        for t in Array(pending.values) { await t.value }
      } catch { if !Task.isCancelled, ticket == mark { issue = error.localizedDescription } }
    }
  }
  private func add(_ d: CastDevice) {
    devices.removeAll { $0.id == d.id }
    devices.append(d)
    devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  func manual(_ text: String) async throws {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw.contains("://") ? raw : "http://" + raw) else {
      throw CastProblem.address
    }
    let mark = ticket
    var location = try await CastLAN.location(url)
    var alias = CastAddress.host(url)
    if !raw.contains("://"), !raw.contains("/"), url.port == nil,
      let host = CastAddress.host(location), CastAddress.ipv4(host) != nil {
      var found: URL?
      for try await event in CastSSDP.unicast(host) {
        if let raw = event.location, event.alive {
          alias = CastAddress.host(raw)
          found = try await CastLAN.location(raw, peer: event.sender)
          break
        }
      }
      guard let found else { throw ServiceError("设备未响应，请开启电视投屏，或填写设备描述地址") }
      location = found
    }
    let d = try await CastHTTP().device(location, alias: alias)
    try Task.checkCancellation()
    guard ticket == mark else { return }
    add(d)
    expires[d.id] = ProcessInfo.processInfo.systemUptime + 120
  }
  func stop() {
    ticket = UUID()
    scan?.cancel()
    scan = nil
    pending.values.forEach { $0.cancel() }
    pending = [:]
    searching = false
  }
}
@MainActor private enum CastPlayerBinding {
  static func make(_ player: (any PlaybackEngine)?) -> CastLocalPlayback {
    let weakPlayer = player
    let original = player?.playbackItem
    return .init(
      position: { [weak weakPlayer, weak original] in
        guard let p = weakPlayer, let i = original, p.playbackItem === i,
          p.currentTime().seconds.isFinite
        else { return 0 }
        return max(0, p.currentTime().seconds)
      },
      hold: { [weak weakPlayer, weak original] in
        guard let p = weakPlayer, let i = original, p.playbackItem === i else { return }
        p.pause()
      },
      resume: { [weak weakPlayer, weak original] t in
        guard let p = weakPlayer, let i = original, p.playbackItem === i, t.isFinite else {
          throw CastProblem.stale
        }
        let value = CMTime(seconds: max(0, t), preferredTimescale: 600)
        guard await p.seek(to: value, toleranceBefore: .zero, toleranceAfter: .zero),
          p.playbackItem === i
        else { throw CastProblem.stale }
        p.playImmediately(atRate: p.defaultRate)
      },
      available: { [weak weakPlayer, weak original] in
        guard let p = weakPlayer, let i = original else { return false }
        return p.playbackItem === i
      })
  }
}
struct CastButton: View {
  let subject: CastSubject
  let player: any PlaybackEngine
  @State private var sheet = false
  var body: some View {
    Button {
      sheet = true
    } label: {
      Label("投屏", systemImage: "airplayvideo")
    }.disabled(!subject.valid)
      .piliSheet(isPresented: $sheet) {
        PiliNavigationStack { CastView(subject: subject, player: player) }
      }
  }
}
struct CastView: View {
  let subject: CastSubject
  let player: (any PlaybackEngine)?
  init(subject: CastSubject, player: (any PlaybackEngine)?) {
    self.subject = subject
    self.player = player
  }
  @StateObject private var directory = CastDirectory()
  @ObservedObject private var cast = CastState.shared
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var address = ""
  @State private var message: String?
  @State private var working = false
  @State private var seekValue: Double?
  @State private var volume: Double?
  @State private var action: Task<Void, Never>?
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  private func run(_ f: @escaping @MainActor () async throws -> Void) {
    guard !working else { return }
    working = true
    message = nil
    action = Task {
      do { try await f() } catch { if !Task.isCancelled { message = error.localizedDescription } }
      working = false
    }
  }
  private func select(_ d: CastDevice) {
    let owner = owner
    let program = subject
    let local = CastPlayerBinding.make(player)
    run {
      try await cast.start(subject: program, device: d, local: local) { device in
        try await handoff(program, to: device, owner: owner)
      }
    }
  }
  private func handoff(_ program: CastSubject, to device: CastDevice, owner: String) async throws
    -> CastLease
  {
    let original = try await AccountJar.shared.current(.role(.video),credentials:.mobile)
    guard (original?.id ?? "") == owner else { throw CastProblem.stale }
    let src = try await BiliAPI.shared.castSource(program, owner: owner)
    try Task.checkCancellation()
    // TV playurl supplies one receiver-ready movie, as in Flutter onCast(). The TV
    // fetches it directly, so locking/backgrounding the phone cannot suspend a relay.
    return CastLease(src.url, mime: "video/mp4") {}
  }
  @State private var manual = false
  /// The original's 投屏 page: a linear loader while searching, then just the devices (name, and
  /// the address under it; the one in use tinted). An empty search shows 没有设备 with a retry.
  /// The connected device's controls follow; manual add and AirPlay sit in the toolbar.
  var body: some View {
    List {
      if directory.searching {
        ProgressView().progressViewStyle(.linear).listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      ForEach(directory.devices) { d in
        let current = cast.device?.id == d.id
        Button { if !current { select(d) } } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(d.name).foregroundStyle(current ? Color.accentColor : Color.primary)
            Text(d.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      if !directory.searching, directory.devices.isEmpty {
        VStack(spacing: 14) {
          Text(directory.issue ?? "没有设备").foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("重试") { directory.search() }.piliButtonStyle(.glass)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
        .listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      if let d = cast.device {
        Section {
          if let s = cast.subject { Text(s.title).font(.subheadline.weight(.medium)).lineLimit(2) }
          Text(cast.offline ? "设备已断开" : cast.now.state.label).font(.caption).foregroundStyle(.secondary)
          if let length = cast.now.duration, length > 0, cast.supports(.seek) {
            let at = min(length, max(0, seekValue ?? cast.now.position ?? 0))
            Slider(
              value: .init(get: { at }, set: { seekValue = $0 }), in: 0...length,
              onEditingChanged: { editing in
                if !editing, let t = seekValue {
                  seekValue = nil
                  run { try await cast.perform(.seek(t)) }
                }
              }
            ).accessibilityLabel("投屏进度")
            HStack {
              Text(CastProtocol.time(at))
              Spacer()
              Text(CastProtocol.time(length))
            }.font(.caption.monospacedDigit())
          }
          HStack {
            Button {
              run { try await cast.perform(.play) }
            } label: {
              Label("播放", systemImage: "play.fill")
            }.disabled(!cast.supports(.play))
            Spacer()
            Button {
              run { try await cast.perform(.pause) }
            } label: {
              Label("暂停", systemImage: "pause.fill")
            }.disabled(!cast.supports(.pause))
          }.buttonStyle(.borderless)
          if let level = cast.now.volume, cast.supports(.setVolume) {
            HStack {
              Image(systemName: "speaker.fill")
              Slider(
                value: .init(get: { volume ?? level }, set: { volume = $0 }), in: 0...100,
                onEditingChanged: { editing in
                  if !editing, let v = volume {
                    volume = nil
                    run { try await cast.perform(.volume(v)) }
                  }
                }
              ).accessibilityLabel("电视音量")
              Image(systemName: "speaker.wave.3.fill")
            }
          }
          if let m = cast.now.muted, cast.supports(.setMute) {
            Toggle(
              "静音", isOn: .init(get: { m }, set: { v in run { try await cast.perform(.mute(v)) } }))
          }
          if let previous = cast.subject, previous != subject {
            Button("在这台设备播放当前视频") { select(d) }
          }
          if cast.offline {
            Button("重新连接设备") {
              let who = owner
              run {
                try await cast.reconnect { program, device in
                  try await handoff(program, to: device, owner: who)
                }
              }
            }
          }
          HStack(spacing: 12) {
            Button(player?.isExternalPlaybackActive == true ? "交回系统播放器" : "在此设备继续") {
              run { try await cast.perform(.phone) }
            }
            Spacer()
            Button("停止投屏", role: .destructive) { run { try await cast.perform(.stop) } }
            Button("断开") { cast.end() }
          }.buttonStyle(.borderless).font(.subheadline)
        } header: { Text("正在投屏 · " + d.name) }
      }
      if let player, player.supportsSystemVideo { Section { CastSystemRoute(player: player) } }
      if let text = message ?? cast.issue {
        Text(text).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
      }
      if working || cast.busy { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
    }.listStyle(.plain).navigationTitle("投屏").navigationBarTitleDisplayMode(.inline).toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
      ToolbarItemGroup(placement: .primaryAction) {
        Button { directory.search() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("搜索")
        Menu {
          Button("手动添加设备", systemImage: "plus") { manual = true }
          Button("本地网络设置", systemImage: "gear") {
            if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
          }
        } label: { Image(systemName: "ellipsis") }
      }
    }
    .alert("手动添加设备", isPresented: $manual) {
      TextField("电视 IP 或设备描述地址", text: $address).keyboardType(.URL)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Button("取消", role: .cancel) {}
      Button("添加") { run { try await directory.manual(address) } }
    }
    .onAppear { directory.search() }.onDisappear {
      directory.stop()
      action?.cancel()
    }
    .onChange(of: owner) { _, _ in
      cast.end()
      directory.stop()
      dismiss()
    }
  }
}

private struct CastSystemRoute: View {
  let player: any PlaybackEngine
  @State private var video = false
  @State private var audio = false
  private func update() {
    video = player.isExternalPlaybackActive
    audio = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
      $0.portType == .airPlay
    }
  }
  var body: some View {
    HStack {
      Text(video ? "正在使用 AirPlay 播放视频" : audio ? "正在使用 AirPlay 输出声音" : "选择系统播放设备")
      Spacer()
      OutputRouteButton(video: player.supportsSystemVideo).frame(width: 42, height: 32)
    }
    .onAppear { update() }.onReceive(player.statePublisher) { _ in
      update()
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) {
      _ in update()
    }
  }
}
