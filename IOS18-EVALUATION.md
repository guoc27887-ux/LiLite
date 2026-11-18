# LiLite 降级 iOS 18 评估（2026-11-18）

源码基线：liuliuya2333/LiLite v1.0.1（56e4c67），600 个 Swift 文件、约 8.9 万行。

## 已确认的坑（静态审计）

1. **最低版本写死 26**：Package.swift 的 `platforms: [.iOS("26.0")]`，外加链接参数
   `-platform_version ios 26.0 <sdk>`（靠环境变量 PILI_IOS_SDK_VERSION 注入）。
   改 18.0 是两行事，但改完编译器才会开始报真正的错。
2. **Liquid Glass 按钮样式（量最大、最好修）**：`.buttonStyle(.glass)` 84 处 / 50 文件，
   `.glassProminent` 40 处 / 37 文件。iOS 18 SDK 里没有这两个符号，调用点会逐个报错。
   修法与 cilicili 相同：加一层兼容修饰符，26 用玻璃、18 回退 bordered/borderedProminent，
   再脚本化批量替换调用点。机械活，风险低。
3. **glassEffect 材质**：8 处 / 8 文件，另 GlassEffectContainer 1 处。
   同样包一层兼容修饰符，18 回退 ultraThinMaterial。
4. **SwiftUI WebView / WebPage（iOS 26 新 API）**：WebView( 5 处 / 4 文件，WebPage 2 处 / 1 文件。
   要换回 WKWebView 的 UIViewRepresentable 包装，工作量中等，点位少。
5. **作者已自带防护 1 处**：DeviceSceneDelegate 的 preferredWindowingControlStyle 已标
   @available(iOS 26)，不用动。
6. **没用到的 26 独占功能**（好消息）：FoundationModels、tabViewBottomAccessory、
   ConcentricRectangle、scrollEdgeEffectStyle 等均为 0。

## 未知数（只有真编译才见底）

- 其他 iOS 26 独占的 SwiftUI/UIKit 细碎 API（新初始化器、新修饰符），grep 数不全。
  把部署目标改到 18.0 后拿 iOS 18 SDK 编译，错误清单就是第二波坑，按 cilicili 的经验
  通常是几十处量级、逐个加 #available 或换等价写法。
- 运行时差异：低目标版本的应用在 iOS 26 上会走旧外观兼容模式，反过来在 iOS 18 上
  玻璃质感全无，但功能不受影响。

## 构建路线（真正的长杆）

- 官方构建是 WSL/Linux + xtool + Swift Darwin SDK，且 build.sh 每次从源码编译
  FFmpeg（MediaKit/build-ffmpeg.sh）和 mpv（build-mpv.py），首构很慢。
- Darwin SDK 要从 Xcode 里抽，下载 Xcode 需要 Apple ID 登录，这是用户本人的步骤；
  或者走 GitHub Actions 的 macOS  runner（自带 Xcode，可选 iOS 18 SDK），
  但 build.sh 是 Linux 导向的脚本，搬到 macOS 要适配一轮。
- 本机磁盘只有 7.5G，本地全量构建（工具链 + SDK + FFmpeg/mpv 源码编译）空间不够，
  倾向 GitHub Actions 路线，与 cilicili 出包方式一致。

## 结论

能降。已确认的坑以玻璃样式为主（约 130 处调用点、集中在一种修法），WebView 替换是
唯一的点状开发活；剩余风险在编译后暴露的第二波错误和构建链适配，不在业务代码。
下一步：建 fork + Actions 工作流，把目标改 18.0 跑首轮编译，拿到完整错误清单再逐项修。
