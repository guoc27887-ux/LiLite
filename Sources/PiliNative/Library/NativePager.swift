import SwiftUI
import UIKit

/// UIKit owns every intermediate offset. SwiftUI sees only a settled page, and each page
/// keeps its hosting controller (including list position, reply state and navigation context).
struct NativePager<Page: View>: View {
  let count: Int
  @Binding var page: Int
  @ViewBuilder let content: (Int) -> Page
  var body: some View {
    NativePagerHost(count: count, page: $page, content: content)
      .accessibilityAction(named: "上一页") { if page > 0 { page -= 1 } }
      .accessibilityAction(named: "下一页") { if page + 1 < count { page += 1 } }
  }
}

private struct NativePagerHost<Page: View>: UIViewControllerRepresentable {
  let count: Int
  @Binding var page: Int
  @ViewBuilder let content: (Int) -> Page
  func makeUIViewController(context: Context) -> NativePagingController { NativePagingController() }
  func updateUIViewController(_ controller: NativePagingController, context: Context) {
    let environment = context.environment
    let selection = $page
    controller.update(count: count, page: page, reduced: environment.accessibilityReduceMotion,
      select: { if selection.wrappedValue != $0 { selection.wrappedValue = $0 } }) { i in
      AnyView(content(i).environment(\.self, environment))
    }
  }
  static func dismantleUIViewController(_ controller: NativePagingController, coordinator: ()) { controller.close() }
}

@MainActor final class NativePagingController: UIViewController, UIScrollViewDelegate {
  private final class PagingScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { !(view is UITextField) && !(view is UITextView) }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === panGestureRecognizer {
        let velocity = panGestureRecognizer.velocity(in: self)
        if abs(velocity.y) > abs(velocity.x) { return false }
      }
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
  }
  private let scroll = PagingScrollView()
  private var hosts: [UIHostingController<AnyView>] = []
  private var size = CGSize.zero
  private var selection = NativePagingSelection()
  private var animating = false
  private var pending: (() -> Void)?
  private var select: ((Int) -> Void)?
  private weak var linkedNavigation: UINavigationController?
  private var closed = false
  private var moving: Bool { scroll.isTracking || scroll.isDragging || scroll.isDecelerating || animating }
  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
    scroll.backgroundColor = .clear
    scroll.delegate = self
    scroll.isPagingEnabled = true
    scroll.isDirectionalLockEnabled = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.delaysContentTouches = true
    scroll.canCancelContentTouches = true
    scroll.panGestureRecognizer.addTarget(self, action: #selector(panStateChanged(_:)))
    view.addSubview(scroll)
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    linkBackGestures()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    linkBackGestures()
    let next = view.bounds.size
    guard next != size, next.width > 0, next.height > 0 else { return }
    if size != .zero { scroll.stopScrollingAndZooming() }
    animating = false
    size = next
    layoutPages()
    scroll.setContentOffset(CGPoint(x: CGFloat(selection.selected) * size.width, y: 0), animated: false)
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed, !self.moving else { return }
      self.flush()
    }
  }
  private func layoutPages() {
    scroll.frame = view.bounds
    scroll.contentSize = CGSize(width: size.width * CGFloat(hosts.count), height: size.height)
    for (i, host) in hosts.enumerated() {
      host.view.frame = CGRect(x: CGFloat(i) * size.width, y: 0, width: size.width, height: size.height)
    }
  }
  func update(count: Int, page: Int, reduced: Bool, select: @escaping (Int) -> Void, content: @escaping (Int) -> AnyView) {
    guard !closed else { return }
    loadViewIfNeeded()
    self.select = select
    selection.update(count: count, page: page, moving: moving)
    // A decoder/metadata update may arrive during a pan. Keep only its latest root update,
    // without evaluating page builders or touching host.rootView until motion has finished.
    pending = { [weak self] in self?.apply(count: count, reduced: reduced, content: content) }
    if !moving { flush() }
  }
  private func flush() {
    let work = pending
    pending = nil
    work?()
  }
  private func apply(count: Int, reduced: Bool, content: (Int) -> AnyView) {
    let count = max(0, count)
    while hosts.count > count {
      let host = hosts.removeLast()
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }
    for i in 0..<count {
      let root = content(i)
      if i < hosts.count { hosts[i].rootView = root }
      else {
        let host = UIHostingController(rootView: root)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addChild(host)
        scroll.addSubview(host.view)
        host.didMove(toParent: self)
        hosts.append(host)
      }
    }
    scroll.isScrollEnabled = count > 1
    layoutPages()
    selection.applied()
    accessibilityPage(selection.selected)
    let target = CGPoint(x: CGFloat(selection.selected) * size.width, y: 0)
    if size.width > 0, abs(scroll.contentOffset.x - target.x) > 0.5 {
      animating = view.window != nil && !reduced
      scroll.setContentOffset(target, animated: animating)
    }
  }
  private func accessibilityPage(_ page: Int) {
    for (i, host) in hosts.enumerated() { host.view.accessibilityElementsHidden = i != page }
  }
  private func settled() {
    guard !closed, size.width > 0, !hosts.isEmpty else { return }
    animating = false
    let page = min(max(0, Int((scroll.contentOffset.x / size.width).rounded())), hosts.count - 1)
    let publish = selection.settle(at: page)
    accessibilityPage(page)
    // Do not re-enter SwiftUI while UIKit is invoking a delegate/layout callback.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed, !self.moving else { return }
      if let publish, self.selection.canPublish(publish) { self.select?(publish) }
      self.flush()
    }
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { animating = false }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settled() } }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled() }
  @objc private func panStateChanged(_ gesture: UIPanGestureRecognizer) {
    if gesture.state == .cancelled || gesture.state == .failed {
      DispatchQueue.main.async { [weak self] in self?.settled() }
    }
  }
  private func linkBackGestures() {
    guard let nav = navigationController, nav !== linkedNavigation else { return }
    linkedNavigation = nav
    if let edge = nav.interactivePopGestureRecognizer { scroll.panGestureRecognizer.require(toFail: edge) }
    if let content = nav.piliContentPopGesture { scroll.panGestureRecognizer.require(toFail: content) }
  }
  func close() {
    closed = true
    pending = nil
    select = nil
    scroll.delegate = nil
  }
}
