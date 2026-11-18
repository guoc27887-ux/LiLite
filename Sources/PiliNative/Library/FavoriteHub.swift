import SwiftUI

struct FavoriteHub: View {
  enum Tab: String, CaseIterable, Identifiable {
    case video, bangumi, cinema, article, note, topic, cheese
    var id: Self { self }
    var title: String {
      switch self {
      case .video: "视频"
      case .bangumi: "追番"
      case .cinema: "追剧"
      case .article: "专栏"
      case .note: "笔记"
      case .topic: "话题"
      case .cheese: "课堂"
      }
    }
  }
  let uid: String
  @State private var tab: Tab
  @State private var top = 0
  init(uid: String, initial: String = "video") {
    self.uid = uid
    _tab = State(initialValue: Tab(rawValue: initial) ?? .video)
  }
  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch tab {
        case .video: FolderList(uid: uid)
        case .bangumi, .cinema: FollowedSeasons(uid: uid, initialType: tab == .bangumi ? 1 : 2, fixedType: true)
        case .article: SavedReadings(uid: uid, hub: .article)
        case .note: SavedReadings(uid: uid, initialShelf: .drafts, hub: .note)
        case .topic: SavedReadings(uid: uid, initialShelf: .topics, hub: .topic)
        case .cheese: CoursesView(mid: uid, favorites: true)
        }
      }.id(tab).environment(\.libraryScrollToTop, top)
        .transition(.opacity)
    }
    .animation(.easeOut(duration: 0.2), value: tab)
    .piliSafeAreaBar(edge: .top, spacing: 0) {
      ChipBar(items: Tab.allCases, selection: $tab, title: \.title, reselect: { top &+= 1 })
        .padding(.vertical, 6)
    }
    .navigationTitle("我的收藏")
  }
}
private struct LibraryScrollKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
  var libraryScrollToTop: Int {
    get { self[LibraryScrollKey.self] }
    set { self[LibraryScrollKey.self] = newValue }
  }
}
