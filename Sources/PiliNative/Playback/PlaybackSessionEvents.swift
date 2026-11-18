import AVFoundation
import UIKit

/// One vocabulary for both generations of the system audio-session notifications.
@MainActor final class PlaybackSessionEvents {
  enum Signal {
    case systemInterruption, recommendation(Bool), appInactive, outputLost
  }
  private var subscriptions = [NSObjectProtocol]()
  deinit { subscriptions.forEach(NotificationCenter.default.removeObserver) }
  init(_ receive: @escaping @MainActor (Signal) -> Void) {
    let center = NotificationCenter.default, session = AVAudioSession.sharedInstance()
    func observe(_ name: Notification.Name, _ decode: @escaping (Notification) -> Signal?) {
      subscriptions.append(center.addObserver(forName: name, object: session, queue: .main) { notice in
        guard let event = decode(notice) else { return }
        MainActor.assumeIsolated { receive(event) }
      })
    }
    // iOS 18 fork: upstream's iOS 27 audio-session notifications do not exist in the
    // iOS 26 SDK, so only the classic interruption notification path is kept.
    observe(AVAudioSession.interruptionNotification) { n in
      guard let code = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
        let kind = AVAudioSession.InterruptionType(rawValue: code.uintValue) else { return nil }
      switch kind {
      case .began:
        if let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber,
          reason.uintValue != AVAudioSession.InterruptionReason.default.rawValue { return .outputLost }
        return .systemInterruption
      case .ended:
        let flags = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        return .recommendation(AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume))
      @unknown default: return nil
      }
    }
    observe(AVAudioSession.routeChangeNotification) { n in
      (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ? .outputLost : nil
    }
  }
  func close() {
    for subscription in subscriptions { NotificationCenter.default.removeObserver(subscription) }
    subscriptions.removeAll()
  }
}

@MainActor final class VideoInterruptionRecovery {
  func register(_ engine: any PlaybackEngine) {
    if let player = engine as? AVPlayer { register(player) }
  }
  func clear(_ engine: any PlaybackEngine) {
    if let player = engine as? AVPlayer { clear(player as AVPlayer?) }
    else { (engine as? MPVPlayer)?.cancelInterruption() }
  }
  static let shared = VideoInterruptionRecovery()
  private let registered = NSHashTable<AVPlayer>.weakObjects()
  private weak var lastPlayer: AVPlayer?, lastItem: AVPlayerItem?
  private var record = PlaybackInterruptionIntent<ObjectIdentifier>()
  private var events: PlaybackSessionEvents?
  private var rateObserver: NSObjectProtocol?
  private init() {
    events = PlaybackSessionEvents { [weak self] event in self?.sessionChanged(event) }
    rateObserver = NotificationCenter.default.addObserver(
      forName: AVPlayer.rateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] n in
      MainActor.assumeIsolated {
        guard let self, let p = n.object as? AVPlayer, self.registered.contains(p) else { return }
        let cause = n.userInfo?[AVPlayer.rateDidChangeReasonKey]
        let why = (cause as? AVPlayer.RateDidChangeReason)?.rawValue ?? cause as? String
        if why == AVPlayer.RateDidChangeReason.audioSessionInterrupted.rawValue {
          if p === self.lastPlayer, let item = p.currentItem, item === self.lastItem {
            self.record.interrupt(ObjectIdentifier(item))
          }
        } else if p.rate > 0, let item = p.currentItem {
          self.claim(p, item: item)
        } else if p === self.lastPlayer { self.clear() }
      }
    }
  }
  func register(_ p: AVPlayer) {
    registered.add(p)
    if p.rate > 0, let item = p.currentItem { claim(p, item: item) }
  }
  private func claim(_ p: AVPlayer, item: AVPlayerItem) {
    lastPlayer = p
    lastItem = item
    record.play(ObjectIdentifier(item), rate: p.rate)
    VideoScenePause.shared.didPlay()
    PlaybackSleepTimer.shared.beganVideo(p, item: item)
    ListenQueue.shared.yieldPlaybackToVideo()
  }
  func cancelPending(_ p: AVPlayer) {
    if record.interrupted { clear(p) }
  }
  func clear(_ p: AVPlayer? = nil) {
    guard p == nil || p === lastPlayer else { return }
    record.cancel()
    lastPlayer = nil
    lastItem = nil
  }
  private func sessionChanged(_ event: PlaybackSessionEvents.Signal) {
    switch event {
    case .systemInterruption:
      guard let p = lastPlayer, let item = lastItem, p.currentItem === item else { clear(); return }
      record.interrupt(ObjectIdentifier(item))
    case .appInactive, .outputLost: clear()
    case let .recommendation(allowed):
      guard record.interrupted else { return }
      guard let p = lastPlayer, let item = lastItem, p.currentItem === item,
        item.status == .readyToPlay,
        let speed = record.finish(ObjectIdentifier(item), allowed: allowed),
        p.rate == 0,
        UIApplication.shared.applicationState != .background || VideoTransport.continuesInBackground(p)
      else { clear(); return }
      clear()
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        p.playImmediately(atRate: speed)
      } catch { /* The next explicit play may activate the session again. */ }
    }
  }
}
