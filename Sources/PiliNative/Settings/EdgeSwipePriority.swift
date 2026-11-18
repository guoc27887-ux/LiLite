import SwiftUI
import UIKit

/// Horizontal pagers (page-style TabView) otherwise capture the swipes that pop the navigation
/// stack. This probe makes the enclosing pager's pan wait for the system pop gestures to fail.
/// `contentPop` decides whether iOS 26's swipe-from-anywhere back gesture is active: on the first
/// page a rightward swipe means "go back"; on later pages it must page back instead, so the
/// content gesture is switched off there while the screen-edge gesture keeps working.
/// As a child view controller it restores the gesture whenever its page is covered or removed.
private struct EdgeSwipePriorityProbe: UIViewControllerRepresentable {
  let contentPop: Bool
  func makeUIViewController(context: Context) -> Probe { Probe() }
  func updateUIViewController(_ controller: Probe, context: Context) {
    controller.contentPop = contentPop
    controller.install()
  }
  static func dismantleUIViewController(_ controller: Probe, coordinator: ()) { controller.restore() }
  final class Probe: UIViewController {
    var contentPop = true
    private weak var linkedPager: UIScrollView?
    private weak var linkedNavigation: UINavigationController?
    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
      view.accessibilityElementsHidden = true
    }
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      install()
    }
    override func didMove(toParent parent: UIViewController?) {
      super.didMove(toParent: parent)
      install()
    }
    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      if linkedPager == nil { install() }
    }
    override func viewWillDisappear(_ animated: Bool) {
      super.viewWillDisappear(animated)
      restore()
    }
    func install() {
      guard view.window != nil else { return }
      DispatchQueue.main.async { [weak self] in self?.link() }
    }
    func restore() {
      linkedNavigation?.piliContentPopGesture?.isEnabled = true
    }
    private func link() {
      guard view.window != nil, let nav = navigationController ?? findNavigation() else { return }
      // Root pages (home channels) never pop, so leave the shared back gestures alone there.
      guard let owner = owningController(in: nav) else { return }
      guard owner !== nav.viewControllers.first, owner === nav.topViewController else { return }
      linkedNavigation = nav
      nav.piliContentPopGesture?.isEnabled = contentPop
      guard let pager = enclosingPager() else { return }
      guard pager !== linkedPager else { return }
      if let edge = nav.interactivePopGestureRecognizer {
        pager.panGestureRecognizer.require(toFail: edge)
      }
      if let content = nav.piliContentPopGesture {
        // A disabled recognizer fails at once, so later pages still page normally.
        pager.panGestureRecognizer.require(toFail: content)
      }
      linkedPager = pager
    }
    private func findNavigation() -> UINavigationController? {
      var responder: UIResponder? = view
      while let r = responder {
        if let c = r as? UIViewController, let nav = c.navigationController { return nav }
        responder = r.next
      }
      return nil
    }
    private func enclosingPager() -> UIScrollView? {
      var current = view.superview
      while let v = current {
        if let scroll = v as? UIScrollView,
          scroll.isPagingEnabled || scroll.contentSize.width > scroll.bounds.width + 1
        {
          return scroll
        }
        current = v.superview
      }
      return nil
    }
    private func owningController(in nav: UINavigationController) -> UIViewController? {
      var c: UIViewController? = parent ?? findOwnerByResponder()
      while let current = c {
        if nav.viewControllers.contains(where: { $0 === current }) { return current }
        c = current.parent
      }
      return nil
    }
    private func findOwnerByResponder() -> UIViewController? {
      var responder: UIResponder? = view.superview
      while let r = responder {
        if let c = r as? UIViewController { return c }
        responder = r.next
      }
      return nil
    }
  }
}

extension View {
  /// Apply to the first page of a horizontal pager inside a pushed screen. Pass whether that first
  /// page is currently selected, so swiping back from anywhere only applies there.
  func edgeSwipeBackPriority(firstPageSelected: Bool = true) -> some View {
    background {
      EdgeSwipePriorityProbe(contentPop: firstPageSelected).frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}

