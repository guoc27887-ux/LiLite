import SwiftUI
import UIKit

struct PiliNavigationStack<Content: View>: View {
  private let content: Content
  @State private var tabBarHidden = false
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    SwiftUI.NavigationStack {
      content.background(MotionProbe().frame(width: 0, height: 0))
        .background(NavigationTabBarProbe { hidden in
          if tabBarHidden != hidden { tabBarHidden = hidden }
        }.frame(width: 0, height: 0))
    }.toolbarVisibility(tabBarHidden ? .hidden : .visible, for: .tabBar)
  }
}

struct MotionProbe: UIViewControllerRepresentable {
  @AppStorage(PageMotion.key) private var setting = PageMotion.native.rawValue
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ c: Probe, context: Context) { _ = setting; c.attach() }
  final class Probe: UIViewController {
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
    func attach() {
      guard isViewLoaded, view.window != nil, let nav = navigationController else { return }
      MotionDelegate.install(nav)
    }
  }
}
private final class MotionDelegate: NSObject, UINavigationControllerDelegate {
  private static var key: UInt8 = 0
  private weak var original: UINavigationControllerDelegate?
  private static var scrollKey: UInt8 = 0
  static func install(_ nav: UINavigationController) {
    if objc_getAssociatedObject(nav, &scrollKey) == nil {
      objc_setAssociatedObject(nav, &scrollKey, ScrollRebound(host: nav.view), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    if [.native, .cupertino, .cupertinoDialog].contains(PageMotion.current) {
      if let proxy = nav.delegate as? MotionDelegate {
        nav.delegate = proxy.original
        objc_setAssociatedObject(nav, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      }
      return
    }
    if nav.delegate is MotionDelegate { return }
    let proxy = MotionDelegate()
    proxy.original = nav.delegate
    objc_setAssociatedObject(nav, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    nav.delegate = proxy
  }
  override func responds(to sel: Selector!) -> Bool { super.responds(to: sel) || original?.responds(to: sel) == true }
  override func forwardingTarget(for sel: Selector!) -> Any? {
    if original?.responds(to: sel) == true { return original }
    return super.forwardingTarget(for: sel)
  }
  func navigationController(_ nav: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    let mode = PageMotion.current
    let state = nav.interactivePopGestureRecognizer?.state
    let contentState = nav.piliContentPopGesture?.state
    let interactive = operation == .pop && (state == .began || state == .changed || contentState == .began
      || contentState == .changed || nav.transitionCoordinator?.isInteractive == true)
    if !mode.custom(reduced:UIAccessibility.isReduceMotionEnabled,interactivePop:interactive) {
      return original?.navigationController?(nav, animationControllerFor: operation, from: fromVC, to: toVC)
    }
    return MotionAnimator(mode: mode, opening: operation != .pop)
  }
}
private final class MotionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  let mode: PageMotion, opening: Bool
  init(mode: PageMotion, opening: Bool) { self.mode = mode; self.opening = opening }
  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { mode == .none ? 0 : 0.3 }
  func animateTransition(using ctx: UIViewControllerContextTransitioning) {
    guard let old = ctx.view(forKey: .from), let new = ctx.view(forKey: .to), let dest = ctx.viewController(forKey: .to) else {
      ctx.completeTransition(false); return
    }
    let parent = ctx.containerView, frame = ctx.finalFrame(for: dest)
    new.frame = frame.isEmpty ? parent.bounds : frame
    if opening { parent.addSubview(new) } else { parent.insertSubview(new, belowSubview: old) }
    let front = opening ? new : old, back = opening ? old : new
    let w = parent.bounds.width, h = parent.bounds.height
    let duration = transitionDuration(using: ctx)
    let f0 = front.transform, b0 = back.transform, a0 = front.alpha, bAlpha = back.alpha
    let previousMask = front.layer.mask
    var f = CGAffineTransform.identity, b = CGAffineTransform.identity, alpha: CGFloat = 1
    switch mode {
    case .fromRight, .rightFade: f = .init(translationX: w, y: 0); b = .init(translationX: -w * (mode == .rightFade ? 1 : 0.22), y: 0)
    case .fromLeft, .leftFade: f = .init(translationX: -w, y: 0); b = .init(translationX: w * (mode == .leftFade ? 1 : 0.22), y: 0)
    case .fromTop: f = .init(translationX: 0, y: -h)
    case .fromBottom: f = .init(translationX: 0, y: h)
    case .fade: f = .init(translationX: 0, y: min(32, h * 0.08)); alpha = 0
    case .fadeIn: alpha = 0
    case .zoom, .topLevel: f = .init(scaleX: 0.86, y: 0.86); b = .init(scaleX: 1.04, y: 1.04); alpha = 0
    case .revealSize: f = .init(scaleX: 1, y: 0.01); alpha = 0
    case .sharedAxis: f = .init(translationX: w * 0.12, y: 0); b = .init(translationX: -w * 0.12, y: 0); alpha = 0
    default: break
    }
    if mode == .rightFade || mode == .leftFade { alpha = 0 }
    if mode == .circle {
      let bounds = front.bounds, center = CGPoint(x: bounds.midX, y: bounds.midY)
      let radius = hypot(bounds.width, bounds.height) / 2 + 1
      func circle(_ r: CGFloat) -> CGPath { UIBezierPath(ovalIn: .init(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r)).cgPath }
      let mask = CAShapeLayer()
      mask.frame = bounds; mask.path = circle(opening ? radius : 0.01); front.layer.mask = mask
      let anim = CABasicAnimation(keyPath: "path")
      anim.fromValue = circle(opening ? 0.01 : radius); anim.toValue = mask.path; anim.duration = duration
      anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      mask.add(anim, forKey: "PiliCircle")
    }
    func apply(frontHidden: Bool) {
      front.transform = frontHidden ? f.concatenating(f0) : f0
      front.alpha = frontHidden ? alpha * a0 : a0
      back.transform = frontHidden ? b0 : b.concatenating(b0)
    }
    apply(frontHidden: opening)
    let finish: (Bool) -> Void = { _ in
      front.transform = f0; back.transform = b0; front.alpha = a0; back.alpha = bAlpha
      if self.mode == .circle { front.layer.mask = previousMask }
      if ctx.transitionWasCancelled { new.removeFromSuperview() }
      ctx.completeTransition(!ctx.transitionWasCancelled)
    }
    if duration == 0 { finish(true) }
    else { UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: { apply(frontHidden: !self.opening) }, completion: finish) }
  }
}
