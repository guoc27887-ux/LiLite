<p align="center">
  <img src="Resources/Brand/banner.png" alt="轻哩 LiLite" width="100%">
</p>

<p align="center">
  <b>轻哩 LiLite</b> · 轻盈顺滑的原生 iOS 视频客户端<br>
  SwiftUI / UIKit 编写，支持 iOS 17+
</p>

<p align="center">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-3F8DF5?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/License-PolyForm%20Noncommercial-14C8F5?style=flat-square">
  <img alt="QQ 群 1136576646" src="https://img.shields.io/badge/QQ%E7%BE%A4-1136576646-12B7F5?style=flat-square&logo=qq&logoColor=white">
  <a href="https://t.me/Lilitexxx"><img alt="Telegram" src="https://img.shields.io/badge/Telegram-Lilitexxx-26A5E4?style=flat-square&logo=telegram&logoColor=white"></a></p>

---

## 简介

轻哩是一个第三方哔哩哔哩 iOS 客户端，用 Swift 从头编写：界面完全原生，跟随系统的 Liquid Glass 材质、导航手势、画中画和辅助功能。

名字里的"轻"是目标：启动快、滑动跟手、播放不卡、界面不打扰内容。

## 功能

| 模块 | 内容 |
|---|---|
| 浏览 | 推荐、热门、排行、分区、番剧影视、直播、专栏、搜索与历史 |
| 播放 | **mpv / AVPlayer 双内核**（设置中可切换，默认 mpv）、多画质与音轨、倍速与长按加速、手势调节亮度音量进度、平滑全屏进出与横屏 |
| 画面 | Anime4K 超分、画面比例与缩放、截图与动图 |
| 弹幕 | 实时弹幕、ASS 字幕渲染（libass）、弹幕屏蔽与样式设置、发送弹幕 |
| 互动 | 评论楼中楼、表情与图片评论、点赞投币收藏、动态、私信 |
| 系统 | 画中画、DLNA 投屏、后台听视频与歌词、离线缓存 |
| 账号 | 扫码 / 网页 / Cookie 登录、多账号切换 |
| 数据 | WebDAV 备份、数据包导入导出 |

轻哩使用 Firebase Analytics 统计活跃用户、会话和主导航页面访问，使用 Crashlytics 收集崩溃堆栈、应用版本和崩溃时的主标签页。页面事件只记录「发现」「搜索」「动态」「我的」四个固定分类

## 截图

<p align="center">
  <img src="Resources/Screenshots/showcase.png" alt="轻哩界面截图" width="100%">
</p>

## 安装

在 [Releases](https://github.com/liuliuya2333/LiLite/releases/latest) 下载最新的未签名 IPA（`LiLite-版本号-unsigned.ipa`），再用以下任一工具签名安装：

| 工具 | 说明 |
|---|---|
| [AltStore](https://altstore.io) / [SideStore](https://sidestore.io) | 免费 Apple ID 即可，7 天后需刷新签名 |
| [Sideloadly](https://sideloadly.io) | 电脑端签名安装，支持免费或付费开发者账号 |
| [TrollStore](https://github.com/opa334/TrollStore) | 支持的系统版本可永久安装 |

- 支持 iOS 17+。
- 未签名包不含组播权限，DLNA 投屏改用 Bonjour 和指定 IP 发现设备。
- 不提供 App Store 或 TestFlight 版本；也可以按下方说明自行构建。
- 在「设置 → 版本与更新」打开「提醒新版本」，有新的 Release 时会收到提示。

## 交流

| 渠道 | 地址 |
|---|---|
| QQ 群 | 1136576646 |
| Telegram 群 | [t.me/Lilitexxx](https://t.me/Lilitexxx) |

## 构建

在 macOS 上用 Xcode 原生构建：

- Xcode 27 与 iPhoneOS SDK
- 用于编译 FFmpeg、libass、mpv 的 Meson、Ninja 和 pkg-config（需在 `PATH` 或 `~/.local/bin` 中），libplacebo 还需要 Python 的 jinja2

在仓库根目录运行：

| 命令 | 作用 |
|---|---|
| `./build.sh --sim` | 为 iOS 模拟器构建调试版，安装到已启动的模拟器并打开（可用 `PILI_SIM` 指定设备） |
| `./build.sh --prepare` | 编译真机与模拟器两套媒体依赖并准备 Firebase SDK，之后可直接用 Xcode 打开 `LiLite.xcodeproj` 运行 |
| `./build.sh` | 调试构建，输出 `dist/PiliNative.ipa` |
| `./build.sh --release-personal` | 使用个人签名权限的 Release 未签名 IPA |
| `./build.sh --sign-personal` | 用 Xcode 中登录的开发者账号签名（需设置 `PILI_TEAM`） |
| `./build.sh --release` | 带 SSDP 组播能力的 Release 未签名 IPA |

首次构建会编译 FFmpeg、libass、mpv 等依赖，耗时较长；之后为增量构建。Apple 账号、令牌、证书和描述文件都不会进入仓库。

构建脚本会下载并校验 Firebase Apple SDK。自行维护分支时，可用 `LILITE_FIREBASE_PLIST` 指定自己的 Apple 应用配置。Release 和签名构建会在 `dist/` 生成对应的 `.dSYM.zip`，可上传至 Firebase 控制台 Crashlytics 的 dSYM 页面

## 目录

| 位置 | 内容 |
|---|---|
| [Sources/PiliNative](Sources/PiliNative) | 应用源码，按账号、播放、社区、直播、离线、设置等模块组织 |
| [MediaKit](MediaKit) | FFmpeg / mpv / libass 的 iOS 构建脚本与 C 桥接 |
| [ArchiveKit](ArchiveKit) | 数据包格式、ZIP 兼容性与账号迁移 |
| [ColorKit](ColorKit) | 动态配色 |
| [Wire](Wire/README.md) | 协议生成的 Swift 消息 |
| [Resources/Brand](Resources/Brand) | 图标与品牌素材 |

## 品牌

| | |
|---|---|
| 名称 | 轻哩（中文）· LiLite（英文） |
| 形象 | 戴着播放键发卡、眯眼笑的白发看板娘，头顶跃起一枚水晶播放键 |
| 主色 | 水晶青 `#14C8F5` → 晴空蓝 `#1E7BF5` → 深海蓝 `#0A55E8` |
| 底色 | 云雾蓝 `#E4F1FB`、发色白 `#FFFFFF`、腮红粉 `#F7A8B8` |

图标原图在 [Resources/Brand/icon.png](Resources/Brand/icon.png)（1024×1024，直角满版，由系统裁切圆角）。

## 许可证

本项目以 [PolyForm Noncommercial License 1.0.0](LICENSE) 发布。使用的第三方组件（mpv、FFmpeg、libass、SwiftProtobuf 等）各自遵循其原有许可证，详见应用内"开源许可"页面。

## 致谢

- [mpv](https://mpv.io)、[FFmpeg](https://ffmpeg.org)、[libass](https://github.com/libass/libass)、[Anime4K](https://github.com/bloc97/Anime4K)
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)

## 声明

- 本项目与哔哩哔哩（bilibili）官方无任何关联，所有视频、图片、弹幕和评论内容的版权归原作者及哔哩哔哩所有。
- 本项目仅供学习交流使用，请勿用于任何违反法律法规或哔哩哔哩用户协议的用途。
- 使用本项目产生的一切后果由使用者自行承担。
