import SwiftUI
import WebKit

struct SitePage: View {
  let url: URL
  var noteOID: Int64? = nil
  var role:AccountRole = .main
  @EnvironmentObject private var accounts:AccountContext
  @AppStorage("web.external") private var external = false
  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss
  @State private var inside = false
  @State private var attempted: URL?
  @State private var issue: String?
  var body: some View {
    if !external || inside || noteOID != nil || role != .main {
      EmbeddedSitePage(url:url,noteOID:noteOID,role:role).id("\(role.rawValue):\(accounts.state.owner(.role(role)) ?? "")")
    } else {
      VStack(spacing: 16) {
        Image(systemName: "safari").font(.system(size: 48)).foregroundStyle(.tint)
        Text(url.host ?? "网页").piliFont(.headline)
        if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
        VStack(spacing: 10) {
          Button { launch() } label: { Text("用浏览器打开").frame(maxWidth: 240) }
            .piliButtonStyle(.glassProminent)
          Button { inside = true } label: { Text("在应用内打开").frame(maxWidth: 240) }
            .piliButtonStyle(.glass)
        }
        .controlSize(.large)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("网页").navigationBarTitleDisplayMode(.inline)
      .task(id: url) { if attempted != url { launch() } }
    }
  }
  private func launch() {
    attempted = url
    guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil else { issue = "无法打开这个链接"; return }
    openURL(url) { ok in
      if ok { dismiss() } else { issue = "未能打开浏览器" }
    }
  }
}

private struct EmbeddedSitePage: View {
  let url: URL
  var noteOID: Int64? = nil
  let role:AccountRole
  @StateObject private var browser = SiteBrowser()
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var route: IncomingRoute?
  @State private var clearing = false
  var body: some View {
    VStack(spacing: 0) {
      if browser.loading { ProgressView(value: browser.progress).progressViewStyle(.linear) }
      if let error = browser.issue {
        HStack {
          Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
          Spacer()
          Button("重试") { browser.reload() }.font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
      }
      NativeWebSurface(browser: browser).id(ObjectIdentifier(browser.web))
    }.navigationTitle(browser.title.isEmpty ? (url.host ?? "网页") : browser.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if noteOID != nil && browser.noteFinishTapped {
          ToolbarItem(placement: .confirmationAction) { Button("返回笔记列表") { dismiss() } }
        }
        ToolbarItemGroup(placement: .bottomBar) {
          Button {
            if browser.back { browser.web.goBack() } else { dismiss() }
          } label: {
            Image(systemName: "chevron.backward").accessibilityLabel("后退")
          }
          Button {
            browser.web.goForward()
          } label: {
            Image(systemName: "chevron.forward").accessibilityLabel("前进")
          }.disabled(!browser.forward)
          Spacer()
          Menu {
            Button("刷新") { browser.reload() }
            let current = browser.current ?? url
            Group {
              Button("复制链接") { UIPasteboard.general.url = current }
              ShareLink(item: current)
              Button("用浏览器打开") { openURL(current) }
              if SiteBrowser.bili(current), let uid = accounts.state.owner(.role(role)) {
                Button("同步当前账号") { Task { await browser.sync(uid) } }
              }
            }
            Button("清除网页缓存", role: .destructive) { clearing = true }
          } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("网页操作")
          }
        }
      }.confirmationDialog("清除网页缓存并重新载入？", isPresented: $clearing) {
        Button("清除缓存", role: .destructive) { Task { await browser.clearCache() } }
      }
      .alert("打开外部应用？",isPresented:.init(get:{browser.externalLink != nil},set:{if !$0 {browser.externalLink=nil}}),presenting:browser.externalLink){ target in
        Button("打开"){openURL(target){ok in if !ok {browser.issue="未能打开链接"}}}
        Button("取消",role:.cancel){}
      } message:{ target in Text(target.absoluteString) }
      .task(id:"\(url.absoluteString):\(role.rawValue):\(accounts.state.owner(.role(role)) ?? "")") {
        browser.openNative = { r in route = IncomingRoute(link: r) }
        browser.closePage = {dismiss()}
        browser.noteEditor(noteOID)
        await browser.start(url,account:accounts.state.owner(.role(role)),role:role)
      }
      .piliSheet(item: $route) { r in
        PiliNavigationStack { LinkDestination(item: r.link).toolbar { Button("关闭") { route = nil } } }
      }
  }
}
@MainActor
private final class SiteBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { ServerCertificatePolicy.respond(to: challenge, completion: completionHandler) }
  @Published private(set) var web: WKWebView
  @Published var externalLink:URL?
  @Published var title = ""
  @Published var loading = false
  @Published var progress = 0.0
  @Published var back = false
  @Published var forward = false
  @Published var current: URL?
  @Published var issue: String?
  @Published var noteFinishTapped = false
  private var bridge: NoteEditorBridge?
  func noteEditor(_ aid: Int64?) {
    guard aid != bridge?.oid else { return }
    let controller = web.configuration.userContentController
    if bridge != nil {
      controller.removeScriptMessageHandler(
        forName: NoteEditorBridge.name, contentWorld: .defaultClient)
      controller.removeAllUserScripts()
    }
    bridge = nil
    noteFinishTapped = false
    if let aid {
      let hook = NoteEditorBridge(oid: aid) { [weak self] finish in
        if finish { self?.noteFinishTapped = true } else { self?.openNative?(.archive(aid, 1)) }
      }
      bridge = hook
      hook.install(controller)
    }
  }
  var openNative: ((SharedLink) -> Void)?
  private var watches: [NSKeyValueObservation] = []
  private var invalidationObserver: NSObjectProtocol?
  private var startURL: URL?
  private var owner: String?
  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    web = WKWebView(frame: .zero, configuration: config)
    super.init()
    invalidationObserver = NotificationCenter.default.addObserver(forName: InvalidWebSession.notification, object: nil, queue: .main) { [weak self] notification in
      guard let uid = notification.object as? String else { return }
      Task { @MainActor [weak self] in await self?.expired(uid) }
    }
    observeWeb()
  }
  deinit { if let invalidationObserver { NotificationCenter.default.removeObserver(invalidationObserver) } }
  private func expired(_ uid: String) async {
    guard owner == uid else { return }
    web.stopLoading(); owner = nil; startURL = nil
    await web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    issue = "登录已失效，请重新登录"
  }
  private func observeWeb(){
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsBackForwardNavigationGestures = true
    watches = [
      web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.state() }
      },
      web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.state() }
      },
      web.observe(\.title, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.state() }
      },
      web.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.state() }
      },
    ]
  }
  static func bili(_ u: URL) -> Bool {
    let h = u.host?.lowercased() ?? ""
    return u.scheme == "https" && u.user == nil && u.password == nil && (u.port == nil || u.port == 443)
      && (h == "bilibili.com" || h.hasSuffix(".bilibili.com"))
  }
  private func state() {
    title = web.title ?? ""
    current = web.url
    loading = web.isLoading
    progress = web.estimatedProgress
    back = web.canGoBack
    forward = web.canGoForward
  }
  private var role = AccountRole.main
  func start(_ u: URL, account:String?,role:AccountRole) async {
    guard let safe = httpsURL(u.absoluteString), safe.user == nil, safe.password == nil else {
      issue = "网页地址无效"
      return
    }
    if safe == startURL && owner == account && self.role == role { return }
    self.role=role
    web.stopLoading()
    let store = web.configuration.websiteDataStore
    if owner != account {
      await store.removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    guard !Task.isCancelled else { return }
    owner = account
    startURL = safe
    issue = nil
    if let account, Self.bili(safe) { await putCookies(account) }
    guard !Task.isCancelled else { return }
    web.load(URLRequest(url: safe))
  }
  private func putCookies(_ uid: String) async {
    guard owner == uid, let user = try? await AccountJar.shared.current(.role(role)), user.id == uid,
      !Task.isCancelled
    else { return }
    let store = web.configuration.websiteDataStore.httpCookieStore
    for cookie in user.webCookies {
      if Task.isCancelled || owner != uid { return }
      await store.setCookie(cookie)
    }
  }
  func sync(_ uid: String) async {
    guard let u = web.url, Self.bili(u), owner == uid else { return }
    await putCookies(uid)
    if owner == uid { reload() }
  }
  func clearCache() async {
    let types = Set([
      WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
      WKWebsiteDataTypeOfflineWebApplicationCache,
    ])
    let old=web,place=web.url ?? startURL
    await old.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    guard old === web,let place else{return}
    old.stopLoading();old.navigationDelegate=nil;old.uiDelegate=nil;watches=[]
    web=WKWebView(frame:.zero,configuration:old.configuration)
    observeWeb();issue=nil;state();web.load(URLRequest(url:place))
  }
  func reload() {
    issue = nil
    if web.url != nil { web.reload() } else if let startURL { web.load(URLRequest(url: startURL)) }
  }
  func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,preferences:WKWebpagePreferences,
    decisionHandler:@escaping(WKNavigationActionPolicy,WKWebpagePreferences)->Void) {
    if let url=action.request.url,SiteBrowser.bili(url) {
      if url.host == "passport.bilibili.com",url.path == "/pc/passport/findPassword" {preferences.preferredContentMode = .desktop}
      else if (url.host == "www.bilibili.com" && url.path == "/h5/match/data/home") || (url.host == "passport.bilibili.com" && url.path.hasPrefix("/h5-app/")) {preferences.preferredContentMode = .mobile}
    }
    decide(action) { decisionHandler($0,preferences) }
  }
  private func decide(_ action:WKNavigationAction,_ decisionHandler:(WKNavigationActionPolicy)->Void) {
    guard let url = action.request.url else {
      decisionHandler(.cancel)
      return
    }
    let host=url.host?.lowercased() ?? ""
    if (host=="bilibili.com" || host.hasSuffix(".bilibili.com")),let port=url.port,
      port != (url.scheme == "https" ? 443:80) {decisionHandler(.cancel);return}
    let main = action.targetFrame?.isMainFrame != false
    if main, let route = SharedLink.parse(url.absoluteString), url != startURL,
      url.scheme == "piliplus" || url.scheme == "bilibili"
        || action.navigationType == .linkActivated
    {
      decisionHandler(.cancel)
      openNative?(route)
      return
    }
    if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil,
      url.password == nil
    {
      decisionHandler(.allow)
    } else if !main && ["about", "blob", "data"].contains(url.scheme ?? "") {
      decisionHandler(.allow)
    } else {
      if main,action.navigationType == .linkActivated,let scheme=url.scheme?.lowercased(),
        url.user == nil,url.password == nil,!["about","blob","data","file","javascript","webkit","x-apple.systempreferences","prefs","app-prefs","itms-services","piliplus"].contains(scheme),
        ["tel","sms","mailto","facetime","facetime-audio"].contains(scheme) || url.absoluteString.hasPrefix(scheme+"://") {externalLink=url}
      decisionHandler(.cancel)
    }
  }
  func webViewDidClose(_ webView:WKWebView) { closePage?() }
  var closePage:(()->Void)?
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if action.targetFrame == nil, let url = action.request.url,
      ["https", "http"].contains(url.scheme ?? "")
    {
      web.load(action.request)
    }
    return nil
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    issue = nil
    state()
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { failed(error) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(error)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    issue = "网页已停止响应"
    state()
  }
  private func failed(_ e: Error) {
    if (e as NSError).code != NSURLErrorCancelled { issue = e.localizedDescription }
    state()
  }
}
private struct NativeWebSurface: UIViewRepresentable {
  let browser: SiteBrowser
  func makeUIView(context: Context) -> WKWebView { browser.web }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}
