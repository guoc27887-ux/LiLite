import SwiftUI
import WebKit

extension WebLoginIdentity {
  static func verify(_ input: [String: String]) async throws -> (
    cookies: [String: String], name: String
  ) {
    let result = try await inspect(input)
    return (result.cookies, result.name)
  }
  static func inspect(_ input: [String: String]) async throws -> WebLoginInspection {
    var values = input.filter { keys.contains($0.key) }
    guard values.values.allSatisfy(valid), values["SESSDATA"] != nil, values["bili_jct"] != nil
    else {
      throw ServiceError("尚未取得完整的登录信息，请先完成网页登录")
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    let proxy = APIProxy.current()
    proxy.apply(to: config)
    let session = URLSession(
      configuration: config, delegate: APIRedirectPolicy(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var req = URLRequest(
      url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!, timeoutInterval: 15)
    req.setValue(
      values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "; "),
      forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (data, http, responseCookies) = try await BiliServiceSession(native: session, proxy: proxy).response(for: req)
    struct Response: Decodable {
      let code: Int
      struct User: Decodable { let isLogin: Bool?, mid: Int64?, uname: String? }
      let data: User?
    }
    let r = try JSONDecoder().decode(Response.self, from: data)
    if (http as? HTTPURLResponse)?.statusCode == 200,
      r.code == -101 || (r.code == 0 && r.data?.isLogin == false) {
      throw ServiceError("账号未登录，请重新登录", code: -101)
    }
    guard (http as? HTTPURLResponse)?.statusCode == 200, r.code == 0, r.data?.isLogin == true,
      let mid = r.data?.mid, mid > 0
    else { throw ServiceError("登录已失效，请重新登录") }
    if let uid = values["DedeUserID"], uid != String(mid) { throw ServiceError("账号信息不匹配") }
    values["DedeUserID"] = String(mid)
    try Task.checkCancellation()
    let updated = try WebCookieJar.update(legacy: values, stored: [], cookies: responseCookies, from: req.url!, owner: String(mid))
    return .init(cookies: WebCookieJar.root(updated.legacy, updated.stored), name: r.data?.uname ?? "", responseCookies: responseCookies)
  }
}
@MainActor private final class WebLoginFlow: NSObject, ObservableObject, WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { ServerCertificatePolicy.respond(to: challenge, completion: completionHandler) }
  let browser: WKWebView
  @Published var host = "passport.bilibili.com"
  @Published var issue: String?
  private static let start = URL(string: "https://passport.bilibili.com/login")!
  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    browser = WKWebView(frame: .zero, configuration: config)
    super.init()
    browser.navigationDelegate = self
    browser.allowsBackForwardNavigationGestures = true
    browser.load(URLRequest(url: Self.start))
  }
  private func allowed(_ u: URL?) -> Bool {
    guard let u, u.scheme?.lowercased() == "https", u.user == nil, u.password == nil,
      u.port == nil || u.port == 443, let h = u.host?.lowercased()
    else { return false }
    return [
      "passport.bilibili.com", "www.bilibili.com", "m.bilibili.com", "account.bilibili.com",
      "security.bilibili.com", "bilibili.com",
    ].contains(h)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let frame = action.targetFrame, !frame.isMainFrame {
      let u = action.request.url
      decisionHandler(u?.scheme == "https" || u?.absoluteString == "about:blank" ? .allow : .cancel)
      return
    }
    guard allowed(action.request.url) else {
      decisionHandler(.cancel)
      return
    }
    if action.targetFrame == nil {
      decisionHandler(.cancel)
      if action.request.httpMethod == "GET" { webView.load(action.request) }
    } else {
      decisionHandler(.allow)
    }
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if allowed(webView.url) {
      host = webView.url?.host ?? host
      issue = nil
    }
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if (error as NSError).code != NSURLErrorCancelled { issue = "登录页未能打开" }
  }
  func grant() async throws -> (cookies: [String: String], name: String) {
    guard allowed(browser.url) else { throw ServiceError("请在哔哩哔哩登录页完成登录") }
    let jar = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
    return try await WebLoginIdentity.verify(WebLoginIdentity.values(jar))
  }
}
private struct LoginWebPage: UIViewRepresentable {
  let browser: WKWebView
  func makeUIView(context: Context) -> WKWebView { browser }
  func updateUIView(_ view: WKWebView, context: Context) {}
}
struct WebsiteLogin: View {
  @StateObject private var flow = WebLoginFlow()
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var busy = false
  @State private var request: Task<Void, Never>?
  var body: some View {
    LoginWebPage(browser: flow.browser).ignoresSafeArea(edges: .bottom)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Label(flow.host, systemImage: "lock.fill").font(.footnote.weight(.medium))
            .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .primaryAction) {
          Button { flow.browser.reload() } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("刷新登录页")
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          if let error = flow.issue {
            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
          }
          Text("在网页中完成登录后，点击下方按钮保存此账号").font(.caption).foregroundStyle(.secondary)
          LoginSubmit(title: "使用此账号登录", busy: busy) { submit() }.disabled(busy)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity)
        .piliGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 4)
      }
      .onDisappear {
        request?.cancel()
        flow.browser.stopLoading()
      }
  }
  private func submit() {
        guard !busy else { return }
        busy = true
        request = Task {
          defer { busy = false }
          do {
            let generation = try await AccountJar.shared.packStamp().generation
            let login = try await flow.grant()
            try Task.checkCancellation()
            try await AccountJar.shared.add(login.cookies, label: login.name, expectedGeneration: generation)
            await accounts.refresh()
            if !Task.isCancelled { dismiss() }
          } catch { if !Task.isCancelled { flow.issue = error.localizedDescription } }
        }
  }
}
