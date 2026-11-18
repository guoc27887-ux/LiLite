/// The standard web player response and its two previous endpoint envelopes use different nesting.

import Foundation

struct EpisodePlayPayload {
  typealias Map = [String: Any]
  struct Info: Decodable {
    var preview: Bool = false
    enum CodingKeys: String, CodingKey { case dash, language, cur_language, volume, clip_info_list, durl, quality, accept_quality, support_formats }
    var dash: DashFormats?
    let language: SpokenCatalog?, cur_language: String?,
      volume: AudioMeasurements?, clip_info_list: [Clip]?
    let durl: [LegacyDURLBody.Part]?, quality: Int?, accept_quality: [Int]?
    struct Quality: Decodable { let quality: Int }
    let support_formats: [Quality]?
    var legacy: LegacyDURLBody {
      .init(durl: durl, quality: quality, accept_quality: accept_quality, language: language,
        cur_language: cur_language, volume: volume)
    }
    struct Clip: Decodable {
      let value: EpisodeClip?
      init(from decoder: Decoder) throws { value = try? EpisodeClip(from: decoder) }
    }
    var clips: [EpisodeClip] { (clip_info_list ?? []).compactMap(\.value).filter(\.usable) }
  }
  enum Route {
    case play(Info)
    case unavailable(String)
  }
  let route: Route
  static func preview(_ bytes: Data) -> Bool {
    guard let packet = try? JSONSerialization.jsonObject(with: bytes) as? Map,
      let data = packet["data"] as? Map ?? packet["result"] as? Map else { return false }
    return [data, data["video_info"] as? Map ?? [:], data["arc"] as? Map ?? [:]].contains(where: EpisodeCachePolicy.previewMedia)
  }
  static func requestsWebFallback(_ bytes: Data) -> Bool {
    guard let packet = try? JSONSerialization.jsonObject(with: bytes) as? Map,
      packet["code"] as? Int == 0, let data = packet["data"] as? Map,
      data["video_info"] as? Map == nil, EpisodeCachePolicy.denial(data) == nil,
      let arc = data["arc"] as? Map, EpisodeCachePolicy.flag(arc["is_drm"]) == true else { return false }
    return true
  }
  init(_ bytes: Data, legacy: Bool = false) throws {
    guard let obj = try JSONSerialization.jsonObject(with: bytes) as? Map,
      let code = obj["code"] as? Int
    else { throw ServiceError("无法识别分集播放信息") }
    if code != 0 {
      route = .unavailable(obj["message"] as? String ?? "当前账号不可播放")
      return
    }
    guard let p = obj["data"] as? Map ?? obj["result"] as? Map else {
      route = .unavailable("未返回播放信息")
      return
    }
    if let reason = EpisodeCachePolicy.denial(p) {
      route = .unavailable(reason)
      return
    }
    var arc = p["arc"] as? Map ?? [:]
    // arc.is_drm is a routing marker in playview, not a media encryption declaration.
    // The fallback and every actual stream still have their own protection checks below.
    arc["is_drm"] = nil
    let info = p["video_info"] as? Map ?? ((legacy || p["dash"] is Map || p["durl"] is [Any]) ? p : [:])
    if let reason = EpisodeCachePolicy.denial(info) {
      route = .unavailable(reason)
      return
    }
    func protected(_ m: Map) -> Bool {
      for key in ["is_drm", "drm_tech_type", "drm_type"]
      where EpisodeCachePolicy.flag(m[key]) == true { return true }
      for k in ["content_protection", "pssh", "drm_info", "license_url"] {
        if let a = m[k] as? String, !a.isEmpty { return true }
        if let a = m[k] as? [Any], !a.isEmpty { return true }
        if let a = m[k] as? Map, !a.isEmpty { return true }
      }
      return false
    }
    let dash = info["dash"] as? Map ?? [:]
    let dolby = (dash["dolby"] as? Map)?["audio"] as? [Map] ?? []
    let flac = (dash["flac"] as? Map)?["audio"] as? Map
    var rows: [Map] = [p, arc, info, dash]
    rows += dash["video"] as? [Map] ?? []
    rows += dash["audio"] as? [Map] ?? []
    rows += dolby
    if let flac { rows.append(flac) }
    rows += info["durl"] as? [Map] ?? []
    guard !rows.contains(where: protected) else {
      route = .unavailable("此分集需要受保护的播放器")
      return
    }
    guard info["dash"] != nil || (info["durl"] as? [Any])?.isEmpty == false else {
      route = .unavailable("当前账号没有可用的播放线路")
      return
    }
    var merged = info
    for k in ["language", "cur_language", "volume"] where merged[k] == nil { merged[k] = p[k] }
    var value = try JSONDecoder().decode(
      Info.self, from: JSONSerialization.data(withJSONObject: merged))
    value.preview = Self.preview(bytes)
    route = .play(value)
  }
}
