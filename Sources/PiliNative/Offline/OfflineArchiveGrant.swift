import Foundation

extension BiliAPI {
  func offlineArchiveDetails(_ bvid: String, owner: String) async throws -> ArchiveCacheDetails {
    let bytes = try await fetch(
      "/x/web-interface/wbi/view", try await sign(["bvid": bvid]), host: "api.bilibili.com",
      expectedAccount: owner, cacheVideoIdentity: true)
    struct Header: Decodable { let code: Int, message: String?, data: ArchiveCacheDetails? }
    let h = try JSONDecoder().decode(Header.self, from: bytes)
    guard h.code == 0, let body = h.data else { throw ServiceError(h.message ?? "未取得稿件缓存许可") }
    guard body.bvid == bvid else { throw ServiceError("稿件已变化，请刷新") }
    return body
  }
  func offlineArchivePermission(_ bvid: String, cid: Int64, owner: String) async throws {
    try await offlineArchiveDetails(bvid, owner: owner).authorize(bvid, cid: cid)
  }
  struct ArchiveCacheMenu {
    let archive: ArchiveCacheDetails, video: [Int], audio: [Int], singleFile: Bool
  }
  func offlineArchiveMenu(_ bvid: String, cid: Int64, owner: String) async throws
    -> ArchiveCacheMenu
  {
    let metadata = try await offlineArchiveDetails(bvid, owner: owner)
    try metadata.authorize(bvid, cid: cid)
    do {
      let f = try await formats(bvid, cid: cid, expectedAccount: owner, forCache: true)
      let qualities = Set(f.video.filter(PlaybackOption.supportsOfflineVideo).map(\.id)).sorted(
        by: >)
      guard !qualities.isEmpty else { throw ServiceError("没有可缓存的画质") }
      return .init(
        archive: metadata, video: qualities,
        audio: Set((f.audio ?? []).filter(PlaybackOption.supportsAudio).map(\.id)).sorted(by: >),
        singleFile: false)
    } catch let error as ServiceError where error.message == "这个视频没有分轨播放地址" {
      let legacy = try await legacyPlayback(bvid, cid: cid, expectedAccount: owner, forCache: true)
      var qualitySet = Set(legacy.body.accept_quality ?? [])
      if let current = legacy.body.quality { qualitySet.insert(current) }
      let qualities = qualitySet.filter { $0 > 0 }.sorted(by: >)
      return .init(archive: metadata, video: qualities, audio: [], singleFile: false)
    }
  }
}
