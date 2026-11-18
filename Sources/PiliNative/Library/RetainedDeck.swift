import SwiftUI

private struct ActiveCatalogPageKey:EnvironmentKey {static let defaultValue=true}
private struct PreparedCatalogPageKey:EnvironmentKey {static let defaultValue=true}
extension EnvironmentValues {
  var activeCatalogPage:Bool {
    get{self[ActiveCatalogPageKey.self]} set{self[ActiveCatalogPageKey.self]=newValue}
  }
  /// True for the selected page and its mounted neighbours: they may fetch their first page so
  /// a swipe slides onto real content instead of a spinner. Only the active page auto-pages.
  var preparedCatalogPage:Bool {
    get{self[PreparedCatalogPageKey.self]} set{self[PreparedCatalogPageKey.self]=newValue}
  }
}
private struct CatalogNavigationTitle: ViewModifier {
  let title: String, embedded: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if embedded { content }
    else { content.navigationTitle(title) }
  }
}
extension View {
  func piliCatalogTitle(_ title: String, embedded: Bool) -> some View {
    modifier(CatalogNavigationTitle(title: title, embedded: embedded))
  }
}

/// Keep each visited page's list, scroll position and controls until its owning identity changes.
/// Only the first page carries the edge-swipe probe (see `edgeSwipeBackPriority`).
private struct DeckEdgePriority: ViewModifier {
  let first: Bool, selectedFirst: Bool
  func body(content: Content) -> some View {
    if first { content.edgeSwipeBackPriority(firstPageSelected: selectedFirst) } else { content }
  }
}
struct RetainedDeck<Choice:Hashable,Content:View>:View {
  let choices:[Choice]
  @Binding var selection:Choice
  var swipe=true
  /// Fractional page position while the pager moves (0 = first page), for tab indicators that
  /// follow the finger like the original client's TabBar.
  let onProgress:((CGFloat)->Void)?
  @ViewBuilder let content:(Choice)->Content
  @Environment(\.activeCatalogPage) private var parentActive
  @State private var visited=Set<Choice>()
  @State private var scrolled:Choice?
  init(choices:[Choice], selection:Binding<Choice>, swipe:Bool=true, progress:Binding<CGFloat>?=nil,
       onProgress:((CGFloat)->Void)?=nil,
       @ViewBuilder content:@escaping (Choice)->Content) {
    self.choices=choices; _selection=selection; self.swipe=swipe; self.content=content
    // A write-only callback lets an indicator observe motion without subscribing the page.
    self.onProgress = onProgress ?? progress.map { binding in { binding.wrappedValue = $0 } }
  }
  @ViewBuilder private func page(_ key:Choice)->some View {
    Group {
      // Neighbours are mounted too, so a swipe reveals a real page instead of a blank one.
      if selection == key || visited.contains(key) || adjacent(key) {
        content(key).environment(\.activeCatalogPage,parentActive && selection==key)
          .environment(\.preparedCatalogPage,parentActive && (selection==key || adjacent(key)))
      } else {Color.clear}
    }.accessibilityHidden(selection != key).allowsHitTesting(selection == key)
  }
  private func adjacent(_ key:Choice)->Bool {
    guard swipe, let i=choices.firstIndex(of:selection), let j=choices.firstIndex(of:key) else{return false}
    return abs(i-j)==1
  }
  var body:some View {
    Group {
      if swipe {
        // A paging ScrollView instead of a page TabView: it reports a continuous offset (the
        // TabView only changed selection after the swipe settled, so the chips jumped), and
        // a tapped channel slides across instead of cutting.
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
              page(choice).containerRelativeFrame([.horizontal, .vertical])
                // DIAG5: DeckEdgePriority probe removed
                .id(choice)
            }
          }.scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollPosition(id: $scrolled)
        .onScrollGeometryChange(for: CGFloat.self) { g in
          g.containerSize.width > 0 ? g.contentOffset.x / g.containerSize.width : 0
        } action: { _, _ in
          // DIAG5: progress write-back disabled
        }
        .onAppear { if scrolled == nil { scrolled = selection } }
        // Commit only once the pager rests, so a tapped jump across several pages does not
        // feed intermediate pages back into the selection mid-animation.
        .onScrollPhaseChange { _, phase in
          if phase == .idle, let value = scrolled, value != selection { selection = value }
        }
        .onChange(of: selection) { _, value in
          guard scrolled != value else { return }
          withAnimation(.smooth(duration: 0.32)) { scrolled = value }
        }
      } else {
        ZStack {
          ForEach(choices,id:\.self){choice in page(choice).opacity(choice==selection ? 1:0)}
        }.animation(.easeInOut(duration: 0.2), value: selection)
      }
    }.onChange(of:selection,initial:true){_,v in visited.insert(v)}
      .onChange(of:choices){_,ids in visited.formIntersection(ids)}
  }
}
