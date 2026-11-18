import SwiftUI
import UIKit

/// The video page has no system back button (back and home live in the player, like the original
/// client). UIKit ties its edge-swipe pop to that button, so this page brings its own, the way
/// the original's page route does: a screen-edge pan that drives the pop transition with the
/// finger, finishing or cancelling on release. While the page is on top the empty navigation bar
/// also stops taking touches, so it cannot swallow the player's back / home buttons.
///
/// iOS 26's swipe-from-anywhere back gesture is switched off here: anywhere but the screen edge a
/// rightward drag seeks the video or pages the tabs, as in the original.
struct VideoNavigationChrome: UIViewControllerRepresentable {
  let player: any PlaybackEngine
  let contentPop: Bool
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ controller: Probe, context: Context) { controller.scheduleInstall() }
  static func dismantleUIViewController(_ controller: Probe, coordinator: ()) { controller.leave() }

  @MainActor final class Probe: UIViewController, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var owner: UIViewController?
    private var saved: (interaction: Bool, contentPop: Bool?)?
    private var edge: UIScreenEdgePanGestureRecognizer?
    private var scheduled = false
    private var driver: VideoPopDriver?
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
      view.accessibilityElementsHidden = true
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      install()
    }
    override func viewWillDisappear(_ animated: Bool) {
      // An in-flight swipe keeps its gesture until the transition ends.
      if driver == nil { leave() }
      super.viewWillDisappear(animated)
    }
    func scheduleInstall() {
      guard !scheduled else { return }
      scheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scheduled = false
        if self.viewIfLoaded?.window != nil { self.install() }
      }
    }
    private func findOwner(in nav: UINavigationController) -> UIViewController? {
      var c: UIViewController? = parent
      while let current = c {
        if nav.viewControllers.contains(where: { $0 === current }) { return current }
        c = current.parent
      }
      return nil
    }
    private func install() {
      guard driver == nil, let nav = navigationController, nav.viewControllers.count > 1,
        let owner = findOwner(in: nav), owner === nav.topViewController
      else { return }
      if navigation !== nav || saved == nil {
        leave()
        navigation = nav
        saved = (nav.navigationBar.isUserInteractionEnabled, nav.piliContentPopGesture?.isEnabled)
      }
      self.owner = owner
      nav.navigationBar.isUserInteractionEnabled = false
      if let content = nav.piliContentPopGesture,
        content.state != .began, content.state != .changed
      {
        content.isEnabled = false
      }
      if edge == nil {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
        g.edges = nav.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        g.delegate = self
        nav.view.addGestureRecognizer(g)
        edge = g
      }
    }
    func leave() {
      if let g = edge { g.view?.removeGestureRecognizer(g) }
      edge = nil
      guard let nav = navigation, let saved else { return }
      self.saved = nil
      navigation = nil
      nav.navigationBar.isUserInteractionEnabled = saved.interaction
      if let enabled = saved.contentPop { nav.piliContentPopGesture?.isEnabled = enabled }
    }

    // MARK: Gesture

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
      guard driver == nil, let nav = navigation, let owner, nav.topViewController === owner,
        nav.viewControllers.count > 1, nav.transitionCoordinator == nil,
        nav.presentedViewController == nil
      else { return false }
      return true
    }
    func gestureRecognizer(
      _ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
      // Everything on the page (pager, lists, player drags) waits for the edge swipe to fail.
      guard let view = other.view, let host = owner?.viewIfLoaded else { return false }
      return view.isDescendant(of: host)
    }
    func gestureRecognizer(
      _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }

    @objc private func panned(_ g: UIScreenEdgePanGestureRecognizer) {
      guard let nav = navigation, let container = nav.view else { return }
      let width = max(1, container.bounds.width)
      let sign: CGFloat = g.edges == .right ? -1 : 1
      let progress = min(1, max(0, g.translation(in: container).x * sign / width))
      switch g.state {
      case .began:
        let d = VideoPopDriver(navigation: nav)
        driver = d
        d.begin { [weak self] in
          // The transition is over (finished or cancelled).
          guard let self else { return }
          self.driver = nil
          if let nav = self.navigation, let owner = self.owner, nav.topViewController === owner {
            self.install()
          } else {
            self.leave()
          }
        }
      case .changed:
        driver?.update(progress)
      case .ended:
        let v = g.velocity(in: container).x * sign
        driver?.end(finish: v > 500 || (progress > 0.4 && v > -300))
      case .cancelled, .failed:
        driver?.end(finish: false)
      default:
        break
      }
    }
  }
}

/// Drives one interactive pop: a navigation-delegate proxy supplies the slide animation and the
/// percent-driven interaction for exactly this pop, then hands the delegate back.
@MainActor final class VideoPopDriver: NSObject, UINavigationControllerDelegate {
  private weak var navigation: UINavigationController?
  private weak var original: UINavigationControllerDelegate?
  private let interaction = UIPercentDrivenInteractiveTransition()
  private var done: (() -> Void)?
  private var finished = false
  init(navigation: UINavigationController) {
    self.navigation = navigation
    super.init()
    interaction.completionCurve = .easeOut
  }
  func begin(_ done: @escaping () -> Void) {
    guard let nav = navigation else {
      done()
      return
    }
    self.done = done
    original = nav.delegate
    nav.delegate = self
    // Keep the proxy alive for the transition.
    objc_setAssociatedObject(nav, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    nav.popViewController(animated: true)
    if nav.transitionCoordinator == nil { cleanUp() }
  }
  func update(_ progress: CGFloat) { interaction.update(progress) }
  func end(finish: Bool) {
    if finish {
      // Faster finish for a short remaining distance.
      interaction.completionSpeed = max(0.6, 1 - interaction.percentComplete)
      interaction.finish()
    } else {
      interaction.completionSpeed = max(0.6, interaction.percentComplete)
      interaction.cancel()
    }
  }
  fileprivate func transitionEnded() {
    guard !finished else { return }
    finished = true
    cleanUp()
  }
  private func cleanUp() {
    if let nav = navigation {
      if nav.delegate === self { nav.delegate = original }
      objc_setAssociatedObject(nav, &Self.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    let callback = done
    done = nil
    callback?()
  }
  private static var key: UInt8 = 0

  // Everything else goes to SwiftUI's own delegate.
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
  func navigationController(
    _ nav: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController, to toVC: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    operation == .pop ? VideoPopAnimator(driver: self) : nil
  }
  func navigationController(
    _ nav: UINavigationController,
    interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
  ) -> UIViewControllerInteractiveTransitioning? {
    animationController is VideoPopAnimator ? interaction : nil
  }
  func navigationController(
    _ nav: UINavigationController, willShow viewController: UIViewController, animated: Bool
  ) {
    original?.navigationController?(nav, willShow: viewController, animated: animated)
  }
  func navigationController(
    _ nav: UINavigationController, didShow viewController: UIViewController, animated: Bool
  ) {
    original?.navigationController?(nav, didShow: viewController, animated: animated)
  }
}

/// The system's pop look: the page slides off to the right with a soft shadow while the page
/// below slides in from a third of the way left, slightly dimmed.
private final class VideoPopAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  weak var driver: VideoPopDriver?
  init(driver: VideoPopDriver) { self.driver = driver }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.35 }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    guard let from = ctx.view(forKey: .from), let to = ctx.view(forKey: .to),
      let toVC = ctx.viewController(forKey: .to)
    else {
      ctx.completeTransition(false)
      return
    }
    let container = ctx.containerView
    let w = container.bounds.width
    let rtl = container.effectiveUserInterfaceLayoutDirection == .rightToLeft
    let finalFrame = ctx.finalFrame(for: toVC)
    to.frame = finalFrame.isEmpty ? container.bounds : finalFrame
    container.insertSubview(to, belowSubview: from)
    let dim = UIView(frame: to.bounds)
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.1)
    dim.isUserInteractionEnabled = false
    to.addSubview(dim)
    let shadowOpacity = from.layer.shadowOpacity
    from.layer.shadowColor = UIColor.black.cgColor
    from.layer.shadowOpacity = 0.18
    from.layer.shadowRadius = 8
    from.layer.shadowOffset = .zero
    from.layer.shadowPath = UIBezierPath(rect: from.bounds).cgPath
    to.transform = CGAffineTransform(translationX: (rtl ? 1 : -1) * w * 0.3, y: 0)
    UIView.animate(
      withDuration: transitionDuration(using: ctx), delay: 0, options: [.curveLinear],
      animations: {
        from.transform = CGAffineTransform(translationX: (rtl ? -1 : 1) * w, y: 0)
        to.transform = .identity
        dim.alpha = 0
      },
      completion: { [weak self] _ in
        let cancelled = ctx.transitionWasCancelled
        from.transform = .identity
        to.transform = .identity
        dim.removeFromSuperview()
        from.layer.shadowOpacity = shadowOpacity
        from.layer.shadowPath = nil
        if cancelled { to.removeFromSuperview() }
        ctx.completeTransition(!cancelled)
        let driver = self?.driver
        DispatchQueue.main.async { driver?.transitionEnded() }
      })
  }
}
