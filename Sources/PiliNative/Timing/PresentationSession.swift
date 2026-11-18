import AVFoundation
import UIKit

@MainActor final class PresentationSession: NSObject {
  private static let sessions = NSHashTable<PresentationSession>.weakObjects(),
    pip = NSHashTable<AVPlayer>.weakObjects()
  private static let primaries = NSMapTable<AVPlayer, PresentationSession>.weakToWeakObjects()
  private static var serial = 0
  private var order = 0
  let surface = ClockPicture(frame: .zero)
  private weak var player: AVPlayer?, item: AVPlayerItem?
  private weak var source: (any PictureTimingSource)?
  private var output: AVPlayerItemVideoOutput?, link: CADisplayLink?, watch: NSKeyValueObservation?,
    playing: NSKeyValueObservation?
  private var pictures: ClockFrameSource?
  private var itemTask: Task<Void, Never>?, partTask: Task<Void, Never>?, jump: NSObjectProtocol?
  private var sound: ClockSound?, generation = 0
  private var clock = PresentationClock(
    PresentationMode.current, smoothing: PresentationMode.smoothing)
  private var fps = 0.0, measuredTimes: [Double] = [], lastPTS = Double.nan
  private var selected = Double.nan, selectedHost = 0.0, speed = 1.0, wroteRate: Float?
  private var lastRateHost = -Double.infinity
  private var level: Float?, deadline = 0.0, retryAfter = 0.0, attempts = 0, hasPicture = false
  private var notes: [NSObjectProtocol] = [], frameHost = 0.0, lastLocate = 0.0, steadySince = 0.0
  private var finished = false, allowed = false
  private var continuity = PlaybackDiscontinuity()
  private var diagnosticState = "", diagnosticHost = -Double.infinity, skippedDiagnostics = 0
  override init() {
    super.init()
    Self.sessions.add(self)
    surface.moved = { [weak self] in self?.visibility() }
    let n = NotificationCenter.default
    // iOS 18 fork: the iOS 27 didBecomeInactiveNotification does not exist in the
    // iOS 26 SDK; the classic interruption notification is used instead.
    let inactiveSession: Notification.Name = AVAudioSession.interruptionNotification
    for name in [
      UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
      UIApplication.didReceiveMemoryWarningNotification, AVAudioSession.routeChangeNotification,
      inactiveSession,
    ] {
      notes.append(
        n.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.suspend(String(describing: name.rawValue))
            if name == UIApplication.didReceiveMemoryWarningNotification {
              self?.retryAfter = CACurrentMediaTime() + 12
            }
          }
        })
    }
    notes.append(n.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, self.sound?.configurationStopped(note.object) == true else { return }
        self.suspend("engine-configuration")
      }
    })
    notes.append(
      n.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.transportChanged() }
      })
  }
  private static func owner(_ p: AVPlayer) -> PresentationSession? {
    if let s = primaries.object(forKey: p), s.player === p, s.surface.window != nil, !s.finished {
      return s
    }
    let active = sessions.allObjects.filter {
      $0.player === p && $0.surface.window != nil && !$0.finished
    }.max { $0.order < $1.order }
    if let active { primaries.setObject(active, forKey: p) }
    return active
  }
  static func volume(_ p: AVPlayer) -> Float { owner(p)?.level ?? p.volume }
  static func volume(_ p: AVPlayer, set v: Float) {
    let value = min(1, max(0, v))
    if let s = owner(p), s.level != nil {
      s.level = value
      s.sound?.level(p.isMuted ? 0 : value)
    } else {
      p.volume = value
    }
  }
  static func time(for p: AVPlayer, host: Double) -> CMTime? {
    guard let s = owner(p), s.level != nil, s.selected.isFinite, abs(host - s.selectedHost) < 0.12
    else { return nil }
    return CMTime(seconds: s.selected, preferredTimescale: 60000)
  }
  static func pictureInPicture(_ p: AVPlayer?, _ on: Bool) {
    guard let p else { return }
    if on { pip.add(p) } else { pip.remove(p) }
    for s in sessions.allObjects where s.player === p {
      if on {
        s.suspend("pip")
        s.link?.isPaused = true
      } else {
        s.transportChanged()
      }
    }
  }
  func bind(_ p: AVPlayer, mode m: PresentationMode, smoothing n: Int) {
    if player !== p {
      if let old = player, Self.primaries.object(forKey: old) === self {
        Self.primaries.removeObject(forKey: old)
      }
      resetItem()
      watch = nil
      playing = nil
      player = p
      playing = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor in self?.transportChanged() }
      }
      if surface.window != nil { visibility() }
      watch = p.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor in self?.attachItem() }
      }
    }
    if clock.mode != m || clock.smoothing != n {
      suspend("mode")
      clock = PresentationClock(m, smoothing: n)
      attempts = 0
      retryAfter = 0
    }
  }
  @objc private func visibility() {
    guard !finished else { return }
    if surface.window == nil {
      suspend("hidden")
      link?.isPaused = true
      if let p = player, Self.primaries.object(forKey: p) === self {
        Self.primaries.removeObject(forKey: p)
        Self.owner(p)?.schedule()
      }
      return
    }
    Self.serial += 1
    order = Self.serial
    if let player {
      Self.primaries.setObject(self, forKey: player)
      for s in Self.sessions.allObjects where s !== self && s.player === player {
        s.suspend("other-surface")
        s.link?.isPaused = true
      }
    }
    if allowed { schedule() }
  }
  private func transportChanged() {
    guard let p = player else { return }
    let pause =
      p.timeControlStatus != .playing
      || surface.window?.windowScene?.activationState != .foregroundActive || Self.owner(p) !== self
      || Self.pip.contains(p)
    link?.isPaused = pause
    if pause && (sound != nil || partTask != nil) { suspend("transport") }
  }
  private func schedule() {
    if link != nil {
      transportChanged()
      return
    }
    guard link == nil, allowed, surface.window != nil else { return }
    retryAfter = max(retryAfter, CACurrentMediaTime() + 0.8)
    let l = CADisplayLink(target: self, selector: #selector(refresh(_:)))
    link = l
    if let screen = surface.window?.windowScene?.screen {
      let hz = Float(screen.maximumFramesPerSecond)
      l.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, hz), maximum: hz, preferred: hz)
    }
    l.add(to: .main, forMode: .common)
    transportChanged()
  }
  private func attachItem() {
    guard !finished, let player else { return }
    let current = player.currentItem
    if item === current { return }
    resetItem()
    item = current
    guard let current, let u = (current.asset as? AVURLAsset)?.url,
      let source = PictureTimingRegistry.shared.source(u)
    else { return }
    self.source = source
    let n = NotificationCenter.default
    jump = n.addObserver(forName: .AVPlayerItemTimeJumped, object: current, queue: .main) {
      [weak self, weak current] _ in
      MainActor.assumeIsolated {
        guard let self, let current, self.item === current, let player = self.player else { return }
        let host = CACurrentMediaTime(), rate = player.timeControlStatus == .playing ? Double(player.rate) : 0
        guard self.continuity.jumped(to: current.currentTime().seconds, host: host, rate: rate) else { return }
        self.resetClock("seek")
        self.attempts = 0
        self.retryAfter = host + 0.8
        self.transportChanged()
      }
    }
    itemTask = Task { [weak self, weak current] in
      guard let current, (try? await current.asset.load(.hasProtectedContent)) == false else {
        return
      }
      let track = try? await current.asset.loadTracks(withMediaType: .video).first
      let declared = try? await track?.load(.nominalFrameRate)
      let rotation = try? await track?.load(.preferredTransform)
      guard let self, !Task.isCancelled, self.item === current else { return }
      fps = source.clockFPS ?? Double(declared ?? 0)
      surface.transformPicture(rotation ?? .identity)
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
      current.add(output)
      self.output = output
      pictures = ClockFrameSource(output)
      allowed = true
      schedule()
    }
  }
  private func diagnose(_ reason: String) {
    guard UserDefaults.standard.object(forKey: DiagnosticJournal.key) as? Bool ?? true else { return }
    let pcm = sound.map { "pcm_s32/\($0.rate)/\($0.layout.count)" } ?? "native"
    let state = "\(reason) mode=\(clock.mode.rawValue) format=\(pcm)"
    let now = CACurrentMediaTime()
    // Position/buffer changes alone are not new sync states. Limit even alternating seek/start bursts.
    guard now - diagnosticHost >= 10, state != diagnosticState || now - diagnosticHost >= 60 else {
      skippedDiagnostics += 1; return
    }
    diagnosticState = state; diagnosticHost = now
    let pos = item?.currentTime().seconds ?? 0
    let position = pos.isFinite ? String(format: "%.3f", pos) : "unknown"
    let detail = "\(state) pos=\(position) fps=\(fps) buffered=\(sound?.buffered ?? 0) index=\(sound?.supply?.index ?? -1) merged=\(skippedDiagnostics)"
    skippedDiagnostics = 0
    Task { await DiagnosticJournal.shared.add("播放同步", detail) }
  }
  private func suspend(_ reason: String) {
    resetClock(reason)
    retryAfter = CACurrentMediaTime() + 0.2
  }
  private func resetClock(_ reason: String) {
    if sound != nil || partTask != nil { diagnose(reason) }
    generation += 1
    partTask?.cancel()
    partTask = nil
    sound?.stop()
    sound = nil
    if let p = player, let level { if p.volume == 0 { p.volume = level } }
    level = nil
    if let p = player, let wroteRate, abs(p.rate - wroteRate) < 0.00005, p.rate > 0 {
      p.rate = Float(speed)
    }
    wroteRate = nil
    lastRateHost = -Double.infinity
    pictures?.reset()
    surface.clear()
    hasPicture = false
    selected = .nan
    lastPTS = .nan
    deadline = 0
    measuredTimes.removeAll(keepingCapacity: true)
  }
  private func resetItem() {
    resetClock("item")
    continuity = PlaybackDiscontinuity()
    allowed = false
    itemTask?.cancel()
    itemTask = nil
    link?.invalidate()
    link = nil
    if let jump { NotificationCenter.default.removeObserver(jump) }
    jump = nil
    if let item, let output { item.remove(output) }
    output = nil
    pictures = nil
    item = nil
    source = nil
    attempts = 0
    retryAfter = 0
  }
  func close() {
    guard !finished else { return }
    finished = true
    resetItem()
    watch = nil
    playing = nil
    notes.forEach(NotificationCenter.default.removeObserver)
    notes = []
    surface.removeFromSuperview()
    if let p = player {
      if Self.primaries.object(forKey: p) === self { Self.primaries.removeObject(forKey: p) }
      Self.owner(p)?.schedule()
    }
  }
  private func fail(_ reason: String) {
    resetClock(reason)
    attempts += 1
    retryAfter = CACurrentMediaTime() + min(30, Double(attempts * 3))
    if attempts >= 4 { link?.isPaused = true }
  }
  private func fetch(_ src: any PictureTimingSource, _ i: Int) {
    let gen = generation
    partTask = Task { [weak self] in
      var device: ClockSound?
      var adopted = false
      // A detached producer may already be running when prime throws or this task expires.
      defer { if !adopted { device?.stop() } }
      do {
        let part = try await src.clockPart(i)
        guard !Task.isCancelled, let self, generation == gen, let p = player, let item else {
          return
        }
        guard let part else {
          fail("audio-part-missing")
          return
        }
        let now = item.currentTime().seconds
        guard p.timeControlStatus == .playing, now.isFinite, (1.0 / 32...32).contains(Double(p.rate)) else {
          resetClock("audio-start-transport")
          return
        }
        // AVKit remains audible while the network/decoder prepares a reserve. Fix the ring's
        // epoch only after that work, using the then-current position rather than the request time.
        if now >= part.start + part.pcm.duration, let live = src.clockIndex(at: now), live != i {
          fetch(src, live)
          return
        }
        let prepared = try await ClockAudioPrebuffer.prepare(part, source: src, at: now, speed: Double(p.rate))
        guard !Task.isCancelled, generation == gen else { return }
        let anchor = item.currentTime().seconds, rate = Double(p.rate)
        guard p.timeControlStatus == .playing, (1.0 / 32...32).contains(rate),
          prepared.ready(at: anchor, speed: rate) else {
          fail("audio-prebuffer-drift")
          return
        }
        let candidate = try ClockSound(pcm: part.pcm, at: max(0, anchor), speed: rate)
        device = candidate
        try await candidate.prime(prepared, source: src, speed: rate)
        guard !Task.isCancelled, generation == gen else { return }
        guard p.timeControlStatus == .playing, abs(Double(p.rate) - rate) < 0.00005,
          ClockAudioSupply.handoff(anchor: anchor, current: item.currentTime().seconds, speed: rate)
        else { fail("audio-handoff-drift"); return }
        speed = rate
        let host = CACurrentMediaTime()
        clock.reset(media: anchor, host: host)
        let first = clock.tick(
          host: host, refresh: 1 / 60, fps: fps, rate: speed, audio: nil,
          blockSeconds: 1024 / Double(candidate.rate))
        candidate.rates(first, mode: clock.mode, speed: speed)
        try candidate.start()
        guard !Task.isCancelled, generation == gen else { return }
        guard ClockAudioSupply.handoff(anchor: anchor, current: item.currentTime().seconds, speed: rate)
        else { fail("audio-engine-start-drift"); return }
        // Engine startup can take time. Its first samples belong to anchor at this host epoch.
        clock.reset(media: anchor, host: CACurrentMediaTime())
        sound = candidate
        adopted = true
        partTask = nil
        deadline = CACurrentMediaTime() + 2
      } catch {
        if !Task.isCancelled, let self, self.generation == gen {
          self.fail("audio-start: \(error)")
        }
      }
    }
  }
  @objc private func refresh(_ l: CADisplayLink) {
    guard let p = player, let current = item, p.currentItem === current, let pictures, let source
    else { return }
    let host = l.targetTimestamp
    guard surface.window?.windowScene?.activationState == .foregroundActive, Self.owner(p) === self,
      !Self.pip.contains(p), !p.isExternalPlaybackActive, p.timeControlStatus == .playing,
      (1.0 / 32...32).contains(Double(p.rate))
    else {
      if sound != nil || partTask != nil { suspend("display-transport") }
      return
    }
    let pos = current.currentTime().seconds
    guard pos.isFinite, pos >= 0 else { return }
    continuity.record(pos, host: CACurrentMediaTime(), rate: Double(p.rate))
    guard host >= retryAfter, attempts < 4 else { return }
    if let dated = source as? any DatedPictureTimingSource, host - lastLocate > 0.25 {
      lastLocate = host
      dated.locate(itemTime: pos, date: current.currentDate())
    }
    if sound == nil {
      if partTask == nil, let i = source.clockIndex(at: pos) { fetch(source, i) }
      return
    }
    guard let sound else { return }
    if let last = wroteRate, abs(last - p.rate) > 0.00005 {
      speed = Double(p.rate)
      wroteRate = nil
    } else if wroteRate == nil {
      speed = Double(p.rate)
    }
    if !sound.canRun(speed) {
      resetClock("audio-speed-route")
      return
    }
    guard let supply = sound.supply, !supply.failed else { fail("audio-feed-failed"); return }
    if supply.ended && sound.buffered == 0 { fail("audio-feed-ended"); return }
    let audible = sound.now(host)
    if level != nil, audible == nil, sound.buffered < sound.rate / 25 {
      fail("audio-underrun")
      return
    }
    if (audible == nil || !hasPicture) && host > deadline {
      fail("presentation-start-timeout")
      return
    }
    let step = clock.tick(
      host: host, refresh: l.targetTimestamp - l.timestamp, fps: fps, rate: speed, audio: audible,
      blockSeconds: 1024 / Double(sound.rate))
    sound.rates(step, mode: clock.mode, speed: speed)
    let time = CMTime(seconds: step.video, preferredTimescale: 60000)
    pictures.request(time)
    if let frame = pictures.take(),
      abs(frame.pts.seconds - step.video) < ClockPicturePolicy.tolerance(fps: fps)
    {
      if surface.show(frame.image, pts: frame.pts) {
        let actual = frame.pts.seconds
        if speed <= 1.05 {
          let d = actual - lastPTS
          if d.isFinite, d >= 1 / 240, d <= 1 / 5 { measuredTimes.append(d) }
          if measuredTimes.count >= 32 {
            let sorted = measuredTimes.sorted()
            let mid = sorted[sorted.count / 2]
            if measuredTimes.filter({ abs($0 - mid) < mid * 0.025 }).count >= 27 { fps = 1 / mid }
            measuredTimes.removeAll(keepingCapacity: true)
          }
        }
        lastPTS = actual
        hasPicture = true
        frameHost = host
      }
    }
    if hasPicture, host - frameHost > ClockPicturePolicy.staleAfter(fps: fps) {
      fail("picture-stale")
      return
    }
    guard hasPicture, let audible, abs(audible - pos) < 0.7, abs(step.video - pos) < 0.7 else {
      if host > deadline { fail("presentation-drift") }
      return
    }
    if level == nil {
      level = p.volume
      p.volume = 0
      steadySince = host
    } else if p.volume != 0 {
      level = p.volume
      p.volume = 0
    }
    if host - steadySince > 5 { attempts = 0 }
    sound.level(p.isMuted ? 0 : level ?? 0)
    surface.isHidden = false
    selected = step.video
    selectedHost = host
    // Keep the AVKit decoder's available frame window centred on the independently scheduled
    // picture. Never overwrite defaultRate; UI-requested rate changes enter through the branch above.
    // Refresh-rate estimates can vary each vsync. Rate writes also notify AVKit/system media
    // observers, so apply this slow drift correction at most four times per wall-clock second.
    if abs(Double(p.rate) - step.videoRate) > 0.00005, host - lastRateHost >= 0.25 {
      lastRateHost = host
      wroteRate = Float(step.videoRate)
      p.rate = Float(step.videoRate)
    }
    deadline = host + 0.65
  }
}

@MainActor extension AVPlayer {
  var presentationVolume: Float {
    get { PresentationSession.volume(self) }
    set { PresentationSession.volume(self, set: newValue) }
  }
}
