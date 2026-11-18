import PhotosUI

import SwiftUI

extension BiliAPI {
  func messageForm(
    _ path: String, fields: [String: String], query: [String: String], account: Identity
  ) async throws -> [String: Any] {
    guard let csrf = account.csrf, (try await AccountJar.shared.current())?.id == account.id else {
      throw ServiceError("请重新登录")
    }
    var c = URLComponents()
    c.scheme = "https"
    c.host = "api.vc.bilibili.com"
    c.path = path
    c.queryItems = query.map(URLQueryItem.init)
    guard let url = c.url else { throw URLError(.badURL) }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = "POST"
    let form = fields.merging(["csrf": csrf, "csrf_token": csrf, "mobi_app": "web", "build": "0"]) {
      $1
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func encoded(_ s: String) -> String {
      s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    req.httpBody = Data(
      form.sorted { $0.key < $1.key }.map { encoded($0.key) + "=" + encoded($0.value) }.joined(
        separator: "&"
      ).utf8)
    req.setValue(
      "application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.setValue(account.header, forHTTPHeaderField: "Cookie")
    req.setValue("https://message.bilibili.com/", forHTTPHeaderField: "Referer")
    let (d, h) = try await webResponse(req, identity: account)
    guard let r = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
      throw URLError(.cannotParseResponse)
    }
    guard (h as? HTTPURLResponse)?.statusCode == 200, r["code"] as? Int == 0 else {
      throw ServiceError(r["message"] as? String ?? "消息操作失败")
    }
    return r["data"] as? [String: Any] ?? [:]
  }
  func sendDirect(
    to target: Int64, text: String?, image: IMOutgoingPicture?, withdraw: String? = nil,
    share: IMShareCard? = nil, forwardPhoto: IMForwardPhoto? = nil, expectedUser: String
  )
    async throws
  {
    guard let user = try await AccountJar.shared.current(credentials:.both), user.id != String(target), target > 0
    else { throw ServiceError("请选择私信对象") }
    if expectedUser != user.id { throw ServiceError("账号已切换") }
    let hasText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    guard
      [hasText, image != nil, share != nil, withdraw != nil, forwardPhoto != nil].filter({ $0 })
        .count == 1
    else { throw ServiceError("请选择一种消息内容") }
    let kind: Int
    let content: String
    if let withdraw {
      guard IMHistoryPolicy.key(withdraw) != nil else { throw ServiceError("消息编号无效") }
      kind = 5
      content = withdraw
    } else {
      let body: [String: Any]
      if let share {
        kind = share.messageType
        body = share.body
      } else if let forwardPhoto {
        kind = 2
        body = forwardPhoto.fields
      } else if let image {
        let p = try await upload(image.bytes, account: user, biz: "im", format: image.format)
        kind = 2
        body = [
          "url": p.image_url, "height": p.image_height, "width": p.image_width,
          "imageType": image.format.rawValue,
          "original": 1, "size": p.img_size ?? Double(image.bytes.count) / 1024,
        ]
      } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        kind = 1
        body = ["content": text]
      } else {
        throw ServiceError("请输入消息")
      }
      content = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }
    try Task.checkCancellation()
    guard let fresh = try await AccountJar.shared.current(credentials:.both), fresh.id == expectedUser,
      fresh.mobileToken == user.mobileToken
    else { throw ServiceError("账号授权已变更") }
    if user.mobileToken?.isEmpty == false, let sender = Int64(user.id) {
      try await instantMessaging(for: user.id).sendCardOrNote(
        sender: sender, to: target, kind: Int32(kind), content: content)
      return
    }
    let device = UUID().uuidString
    let q = try await sign([
      "w_sender_uid": user.id, "w_receiver_id": "\(target)", "w_dev_id": device,
    ])
    let data = try await messageForm(
      "/web_im/v1/web_im/send_msg",
      fields: [
        "msg[sender_uid]": user.id, "msg[receiver_id]": "\(target)", "msg[receiver_type]": "1",
        "msg[msg_type]": "\(kind)", "msg[msg_status]": "0", "msg[dev_id]": device,
        "msg[timestamp]": "\(Int(Date().timeIntervalSince1970))", "msg[new_face_version]": "1",
        "msg[content]": content, "from_firework": "0",
      ], query: q, account: user)
    let key = (data["msg_key"] as? String) ?? (data["msg_key"] as? NSNumber)?.stringValue
    if IMHistoryPolicy.key(key) != nil || ((data["seqno"] as? NSNumber)?.int64Value ?? 0) > 0 {
      return
    }
    throw ServiceError("服务未返回消息编号，请刷新会话查看")
  }
  func acknowledge(_ conversation: Conversation, _ seq: Int64, expectedUser: String) async throws {
    guard let user = try await AccountJar.shared.current(), user.id == expectedUser else {
      throw ServiceError("账号已切换")
    }
    guard seq > 0, conversation.talker_id > 0, [1, 2].contains(conversation.session_type),
      let csrf = user.csrf
    else { throw ServiceError("无效的会话") }
    let fields = try await sign([
      "talker_id": String(conversation.talker_id),
      "session_type": String(conversation.session_type), "ack_seqno": String(seq), "build": "0",
      "mobi_app": "web", "csrf": csrf, "csrf_token": csrf,
    ])
    let raw = try await fetch(
      "/session_svr/v1/session_svr/update_ack", fields, host: "api.vc.bilibili.com",
      expectedAccount: expectedUser)
    struct Ack: Decodable { let code: Int, message: String? }
    let reply = try JSONDecoder().decode(Ack.self, from: raw)
    guard reply.code == 0 else { throw ServiceError(reply.message ?? "未能标记已读") }
    await MainActor.run {
      NotificationCenter.default.post(name: .piliUnreadChanged, object: nil)
      NotificationCenter.default.post(name: .piliIMChanged, object: expectedUser)
    }
  }
}
struct MessageComposer: View {
  let target: Int64, uid: String, sent: () -> Void
  @State private var text = ""
  @State private var selection: PhotosPickerItem?
  @State private var busy = false
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if selection != nil {
        HStack(spacing: 6) {
          Label("已选择一张图片", systemImage: "photo").foregroundStyle(.secondary)
          Button { selection = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            .buttonStyle(.plain).accessibilityLabel("移除图片")
        }
        .piliFont(.caption)
      }
      HStack(alignment: .bottom, spacing: 10) {
        PhotosPicker(selection: $selection, matching: .images) {
          Image(systemName: "photo").font(.title3).foregroundStyle(.secondary).frame(width: 34, height: 38)
        }
        .accessibilityLabel("图片").disabled(!text.isEmpty)
        EmoteInput(text: $text, prompt: "发个消息聊聊呗~", compact: true).disabled(selection != nil)
          .padding(.horizontal, 12)
          .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        Button { Task { await send() } } label: {
          if busy { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
        }
        .piliButtonStyle(.glassProminent).buttonBorderShape(.circle)
        .accessibilityLabel("发送")
        .disabled(selection == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let issue { Text(issue).piliFont(.caption).foregroundStyle(.red) }
    }
    .padding(.horizontal, 12).padding(.vertical, 8).background(.bar).disabled(busy)
  }
  private func send() async {
    guard let finished = try? SleepExitFence.shared.enter() else { return }; defer { finished() }
    guard !busy else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    do {
      var data: IMOutgoingPicture?
      if let selection {
        guard let bytes = try await selection.loadTransferable(type: Data.self) else {
          throw ServiceError("无法读取图片")
        }
        data = try await Task.detached(priority: .userInitiated) { try IMOutgoingPicture(bytes) }
          .value
      }
      try Task.checkCancellation()
      try await BiliAPI.shared.sendDirect(to: target, text: text, image: data, expectedUser: uid)
      text = ""
      selection = nil
      issue = nil
      sent()
    } catch { issue = error.localizedDescription }
  }
}
struct MessageKey: Decodable {
  let value: String
  init(_ value: String) { self.value = value }
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) {
      value = s
    } else if let n = try? c.decode(UInt64.self) {
      value = String(n)
    } else {
      value = String(try c.decode(Int64.self))
    }
  }
}
