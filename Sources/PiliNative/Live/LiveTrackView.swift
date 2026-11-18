import AVFoundation
import SwiftUI

@MainActor final class LiveOverlayTimeline: ObservableObject {
  struct Entry { let bullet: Bullet, line: LiveLine }
  @Published private(set) var revision = UUID()
  private(set) var entries: [Entry] = []
  private var seen = Set<UUID>()
  private var clockID: ObjectIdentifier?, watermark: Double?
  func line(for bullet: Bullet) -> LiveLine? { entries.first { $0.bullet == bullet }?.line }
  func clear() {
    entries.removeAll()
    seen.removeAll()
    clockID = nil
    watermark = nil
    revision = UUID()
  }
  func update(lines: [LiveLine], player: AVPlayer, shield: LiveShield?, fresh: Bool) {
    let id = ObjectIdentifier(player)
    let position = player.currentTime().seconds
    let now = ProcessInfo.processInfo.systemUptime
    let current = Set(lines.map(\.id))
    if fresh || clockID != id || (position.isFinite && watermark.map { position + 1 < $0 } == true)
    {
      // A newly connected/reattached player starts at the live edge, without projecting history into the picture.
      clear()
      seen = current
      clockID = id
    }
    seen.formIntersection(current)
    let n = entries.count
    entries.removeAll {
      !current.contains($0.line.id) || shield?.hides($0.line) == true
        || (position.isFinite && $0.bullet.time < position - 90)
    }
    var changed = n != entries.count
    for line in lines where seen.insert(line.id).inserted {
      guard let arrival = line.arrived, now - arrival < 2, line.paidID == nil,
        shield?.hides(line) != true,
        player.timeControlStatus == .playing, position.isFinite, position >= 0
      else { continue }
      // Anchor the message to the actual AVPlayer media clock, so buffering also pauses the overlay.
      let time = max(
        0, position - max(0, now - arrival) * Double(max(0, player.rate)),
        entries.last?.bullet.time.nextUp ?? 0)
      let item = Bullet(
        time: time, mode: line.mode, rgb: line.rgb, text: line.text,
        sender: line.uid.map { DanmakuStyle.senderHash(String($0)) })
      entries.append(.init(bullet: item, line: line))
      changed = true
    }
    if position.isFinite { watermark = position }
    if changed { revision = UUID() }
  }
}
struct LiveTrackView: View {
  @ObservedObject var chat: LiveChat
  @ObservedObject var timeline: LiveOverlayTimeline
  let player: AVPlayer, shield: LiveShield?, inspector: BulletInspector?, fullscreen: Bool
  private var rules: [String] {
    (shield?.keyword_list ?? []).map { "k:" + $0 }
      + (shield?.shield_user_list ?? []).map { "u:" + String($0.uid) }
  }
  @ViewBuilder private func bulletOverlay() -> some View {
    BulletOverlay(
      items: timeline.entries.map(\.bullet), time: 0, revision: timeline.revision,
      clock: player, inspector: inspector, fullscreen: fullscreen
    )
  }
  var body: some View {
    bulletOverlay()
    .onAppear { timeline.update(lines: chat.lines, player: player, shield: shield, fresh: true) }
    .onChange(of: chat.lines.last?.id) { _, _ in
      timeline.update(lines: chat.lines, player: player, shield: shield, fresh: false)
    }
    .onChange(of: rules) { _, _ in
      timeline.update(lines: chat.lines, player: player, shield: shield, fresh: false)
    }
    .onChange(of: ObjectIdentifier(player)) { _, _ in
      timeline.update(lines: chat.lines, player: player, shield: shield, fresh: true)
    }
    .allowsHitTesting(false)
  }
}
