import SwiftUI

/// Notes, summary and chapters, shown as chips in the detail page's tool row.
struct VideoExtraChips: View {
  let video: Video, cid: Int64, jump: (Double) -> Void
  let model: PlayerModel
  @ObservedObject var story: InteractiveStory
  @AppStorage("detail.summary") private var allowSummary = false
  @AppStorage("detail.chapters") private var showChapters = true
  @State private var showSummary = false
  var body: some View {
    if let aid = video.aid {
      NavigationLink {
        ArchiveNotes(aid: aid, interactive: video.rights?.is_stein_gate == 1, model: model, cid: cid, videoTitle: video.title)
      } label: { ArchiveToolChip(title: "笔记", symbol: "note.text") }
    }
    if showChapters, let chapters = story.positions?.chapters, !chapters.isEmpty {
      NavigationLink {
        ArchiveChapterPanel(model: model, bvid: video.bvid, cid: cid, initial: chapters)
      } label: { ArchiveToolChip(title: "分段 \(chapters.count)", symbol: "list.bullet.rectangle") }
    }
    if allowSummary {
      Button { showSummary = true } label: { ArchiveToolChip(title: "视频总结", symbol: "text.quote") }
        .piliSheet(isPresented: $showSummary) {
          PiliNavigationStack {
            VideoSummaryView(video: video, cid: cid, jump: jump).toolbar {
              Button("关闭") { showSummary = false }
            }
          }
        }
    }
  }
}

/// Interactive story choices, the collection card, co-creators and tags.
struct VideoExtras: View {
  let video: Video, cid: Int64, jump: (Double) -> Void, choose: (Int64) -> Void
  let model: PlayerModel
  @ObservedObject var story: InteractiveStory
  @Binding var reversedSections: Set<Int64>
  let canReverseCollection: Bool, playCollection: (Video,Int64?) -> Void
  var showOwner: (() -> Void)? = nil
  @State private var collectionOpen = false
  @EnvironmentObject private var accounts: AccountContext
  @State private var tags: [ArchiveTag] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let node = story.node {
        VStack(alignment: .leading, spacing: 10) {
          Label(node.title ?? "互动视频", systemImage: "arrow.triangle.branch").font(.headline)
          if let prompt = node.question?.title, !prompt.isEmpty {
            Text(prompt).font(.subheadline).foregroundStyle(.secondary)
          }
          ForEach(node.options) { c in
            Button { story.choose(c, navigate: choose) } label: {
              Text(c.option ?? "继续").frame(maxWidth: .infinity)
            }.piliButtonStyle(.glass)
          }
          if story.canRestart {
            Button("回到故事开头") { story.restart(choose) }.font(.footnote)
          }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
          in: RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
      }
      if let issue = story.error {
        Button("重新加载互动选项") { story.retry() }.piliButtonStyle(.glass).accessibilityHint(issue)
      }
      if let catalog = video.ugc_season, !(catalog.sections ?? []).isEmpty {
        ArchiveCollectionCard(catalog: catalog, currentBVID: video.bvid) { collectionOpen = true }
          .piliSheet(isPresented: $collectionOpen) {
            ArchiveCollectionPanel(
              catalog: catalog, current: video.bvid,currentCID:cid,owner: video.owner?.name,
              canReverse: canReverseCollection, subscriptionID: video.season_id, reversed: $reversedSections, play: playCollection)
          }
      }
      if let staff = video.staff, !staff.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("联合创作").font(.headline)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
              ForEach(staff.filter{$0.mid>0}) { s in
                StaffCard(staff: s, showOwner: s.mid == video.owner?.mid ? showOwner : nil)
              }
            }.padding(.horizontal, 16)
          }.scrollClipDisabled().padding(.horizontal, -16)
        }
      }
      if !tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(tags) { t in
              if let route = t.route {
                NavigationLink { LinkDestination(item:route) } label: {
                  Text(t.label).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }.buttonStyle(.plain)
                  .contextMenu { Button("复制标签"){ UIPasteboard.general.string = t.tag_name } }
              }
            }
          }.padding(.horizontal, 16)
        }.scrollClipDisabled().padding(.horizontal, -16)
      }
    }
    .task(id:"\(video.bvid):\(cid):\(accounts.state.active ?? "")") {
      tags = []
      let owner = accounts.state.active ?? ""
      let result = try? await BiliAPI.shared.read(
        "/x/web-interface/view/detail/tag", ["bvid": video.bvid, "cid": "\(cid)"], expectedAccount:owner, as:[ArchiveTag].self)
      if !Task.isCancelled, owner == (accounts.state.active ?? "") {
        var seen = Set<String>(); tags = (result ?? []).filter { seen.insert($0.id).inserted }
      }
    }
  }
}

private struct StaffCard: View {
  let staff: VideoStaff
  let showOwner: (() -> Void)?
  var body: some View {
    VStack(spacing: 6) {
      if let showOwner {
        Button { TouchFeedback.light(); showOwner() } label: { identity }.buttonStyle(.plain)
      } else {
        NavigationLink {
          CreatorSpace(mid: staff.mid, name: staff.name ?? "创作者")
        } label: { identity }.buttonStyle(.plain).piliTapFeedback()
      }
      CreatorQuickRelation(mid: staff.mid).controlSize(.mini)
    }
  }
  private var identity: some View {
    VStack(spacing: 4) {
      ProfileAvatar(url: staff.face.flatMap(httpsURL), size: 48)
      Text(staff.name ?? "创作者").font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
      if let title = staff.title, !title.isEmpty {
        Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }.frame(width: 72)
  }
}
