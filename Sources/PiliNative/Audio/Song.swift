import SwiftUI

struct AudioSong: Decodable {
  var uid: Int64? = nil
  let id: Int64, title: String, author: String?, cover: String?, intro: String?, lyric: String?,
    duration: Int?, bvid: String?
}
extension BiliAPI {
  func song(_ id: Int64) async throws -> AudioSong {
    try await read(
      "/audio/music-service-c/web/song/info", ["sid": "\(id)"], host: "www.bilibili.com",
      as: AudioSong.self)
  }

}
struct SongView: View {
  let id: Int64
  var origin: ListenOrigin? = nil, autoplay = false
  @State private var launched = false
  @State private var song: AudioSong?
  @State private var sharingMoment: MediaMomentSelection?
  @State private var issue: String?
  @State private var retry = 0
  @State private var listen = false
  var body: some View {
    List {
      if let s = song {
        Section {
          HStack(alignment: .top, spacing: 14) {
            SiteThumbnail(url: s.cover.flatMap(httpsURL)) {
              $0.resizable().scaledToFill()
            } placeholder: {
              Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.tertiary)
            }
            .frame(width: 112, height: 112).background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 6) {
              Text(s.title).piliFont(.headline).lineLimit(3)
              if let author = s.author, !author.isEmpty {
                Label(author, systemImage: "person").piliFont(.subheadline).foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              if let d = s.duration, d > 0 {
                Text(clockText(Double(d))).piliFont(.caption).monospacedDigit().foregroundStyle(.secondary)
              }
            }
          }
          .padding(.vertical, 6)
          HStack(spacing: 10) {
            Button {
              ListenQueue.shared.start(ListenTrack(s, origin: origin))
              listen = true
            } label: {
              Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .piliButtonStyle(.glassProminent)
            Button {
              ListenQueue.shared.add(ListenTrack(s, origin: origin))
              listen = true
            } label: {
              Label("加入待播", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
            }
            .piliButtonStyle(.glass)
          }
          .font(.subheadline.weight(.semibold)).controlSize(.large)
          .listRowSeparator(.hidden)
          if let intro = s.intro, !intro.isEmpty {
            Text(intro).piliFont(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Section {
          if let lyric = s.lyric.flatMap(httpsURL) {
            NavigationLink { SongLyric(url: lyric, songID: s.id) } label: {
              SettingsRowLabel(title: "歌词", symbol: "quote.bubble", color: .pink)
            }
          }
          NavigationLink { Discussion(oid: id, type: 14) } label: {
            SettingsRowLabel(title: "评论", symbol: "text.bubble", color: .blue)
          }
          MediaMomentButton(resource: .song(s), selection: $sharingMoment)
        }
        if let bv = s.bvid, !bv.isEmpty {
          Section("相关视频") {
            VideoLink(video: .preview(id: bv, title: s.title, cover: s.cover ?? "", author: s.author))
          }
        }
      } else if let issue {
        ContentUnavailableView {
          Label("音频未能载入", systemImage: "music.note")
        } description: { Text(issue) } actions: { Button("重试") { retry += 1 } }
          .listRowBackground(Color.clear)
      } else {
        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
      }
    }.navigationTitle("音频").navigationBarTitleDisplayMode(.inline).task(id: retry) {
      do {
        let result = try await BiliAPI.shared.song(id)
        try Task.checkCancellation()
        song = result
        issue = nil
        if autoplay && !launched {
          launched = true
          ListenQueue.shared.start(ListenTrack(result, origin: origin))
          listen = true
        }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    .mediaMomentSheet($sharingMoment)
    .navigationDestination(isPresented: $listen) { ListenView() }
  }
}
