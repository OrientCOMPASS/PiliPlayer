<div align="center">
    <img width="180" height="180" src="assets/images/logo/logo.png" alt="piliplayer logo">
    <h1>piliplayer</h1>
    <p>面向 <b>Android</b> 的 BiliBili 第三方客户端，专注于 <b>VR / 全景播放</b> 与 <b>本地 / 局域网媒体</b>。</p>
    <p><sub>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 的 <code>piliplayer</code> 分支独立维护；Flutter 包名仍为 <code>PiliPlus</code>。</sub></p>
</div>

<div align="center">

<img src="assets/screenshots/home.png" width="30%" alt="home" />
<img src="assets/screenshots/media.png" width="30%" alt="local media" />
<img src="assets/screenshots/main_screen.png" width="30%" alt="player" />

</div>

<br/>

## 这是什么

piliplayer 在完整的 PiliPlus（B 站）客户端之上，重点打磨了两块能力，并为此维护了一份**自编译的 VR 补丁版 libmpv**：

- **VR / 全景播放** —— 等距柱状 360° / 180°，单目 / 左右（SBS）/ 上下（TB）双目片源。
- **本地 & 局域网播放** —— 播放本机存储与局域网（SMB / WebDAV / HTTP / FTP）里的视频。

> 仅针对 **Android（arm64-v8a）**。设计与取舍、逐轮真机验证记录详见 **[docs/piliplayer.md](docs/piliplayer.md)**；VR 需求边界见 **[REQUIREMENTS.md](REQUIREMENTS.md)**。

<br/>

## 适配平台

- [x] Android（arm64-v8a）
- [ ] iOS / Windows / Linux / macOS —— 不再维护：对应平台工程、CI，以及 Dart 侧桌面专用代码与依赖（`window_manager` / `tray_manager` / `win32` / `screen_retriever` / `desktop_webview_window`）均已移除，`lib/` 仅保留 Android 路径

<br/>

## 核心能力

### VR / 全景播放

- 格式矩阵：**水平 360° / 180° × 立体布局 单目 / 左右(SBS) / 上下(TB)**，另有「自动（按片源元数据）」与「强制平面（普通 2D）」。
- 由 mpv 的 **GPU 用户着色器在渲染管线内单次重投影**（零拷贝；输出尺寸只与屏幕分辨率相关，与 4K/8K 片源无关）。
- 操作：单指拖拽环视、双指缩放视场角、**陀螺仪环视**、「视角摆正」；180° 片源手动偏航在覆盖边界收敛。
- 双目片源只取一只眼渲染，**眼位（左 / 右）可切换**；播放中切换格式 / 眼位**保留当前进度原位生效**。
- **文件名自动识别**（默认开、可关）：按关键词识别布局，并**防误判**（`360p` / `1080p` 等清晰度写法不会被当成全景）。
- 环视状态下 HUD 显示偏航 / 俯仰 / 视场读数；VR 控制层随播放器控件**自动隐藏**（手势唤醒）。
- 若运行时引擎不具备 VR 改造能力，界面会**明确提示**，不静默失效。
- 范围外（明确不做）：Cardboard 双眼分屏输出、cubemap 片源。

### 本地 & 局域网播放

- 单页「本地」板块：**设备存储 / 快捷方式 / 局域网**，无多余 Tab、无全盘扫描。
- 快捷方式只展示**用户收藏**的来源（设备内路径亦可收藏）；局域网自动发现的主机会**显示主机名**（匿名 SMB2 握手取名）。
- 目录浏览 → 点文件播放，同目录视频自动组成播放列表，支持**续播记忆（只存本机）**。
- 协议：**SMB（自研纯 Dart 实现）/ WebDAV / HTTP / FTP**。
- 播放本地内容时**不向 B 站上报任何数据**（历史心跳、预览图、弹幕、评论等一律不走）。
- 入口：「我的」→ 本地视频，或「离线缓存」页右上角。

### 手柄 / 外设

- D-pad 左右 = 快退 / 快进（用户设定时长，默认 10s），上下 = 音量。
- 肩键 **R1 = +60s，L1 = −60s**。

### 继承自 PiliPlus 的 B 站能力

推荐 / 热门 / 番剧 / 直播 / 动态 / 搜索 / 评论 / 私信 / 收藏夹 / 稍后再看 / 离线缓存 / DLNA 投屏 / 弹幕 / 字幕 / 超分辨率 / 多账号 / SponsorBlock 等，完整清单见上游 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)。

<br/>

## 自编译 libmpv（VR 补丁版）

VR 重投影依赖一份打了补丁的 libmpv，构建脚本与补丁都在仓库内：

- `tool/libmpv-vr/buildscripts/` —— 构建脚本（源自 `My-Responsitories/libmpv-android-video-build`）。
- `tool/libmpv-vr/buildscripts/patches/mpv/` —— mpv 补丁（`vr_vo_gpu` / `vr_metadata` / `lavc_set_java_vm`）。
- `tool/libmpv-vr/buildscripts/patches/ffmpeg/libsmb2.patch` —— 为 ffmpeg 增加 `smb://` 协议（libsmb2）。
- `third_party/media_kit_libs_android_video/` —— vendored 的 media_kit Android 库，gradle 时拉取 CI 构建的 VR 版 `libmpv.so`。

CI（`.github/workflows/libmpv_vr.yml`）构建 arm64-v8a 的 `libmpv.so` 并发布到滚动 release `libmpv-vr`；应用 CI（`.github/workflows/piliplayer_ci.yml`）随后自动取用。

<br/>

## 从源码构建（Android）

```bash
# 1. 安装 Flutter（版本见 .fvmrc / pubspec.yaml：3.47.4）
#    并对 Flutter SDK 应用仓库内补丁（material / cupertino 等）
pwsh lib/scripts/patch.ps1 android

# 2. 拉取依赖
flutter pub get

# 3. 构建 release APK（仅 arm64-v8a）
flutter build apk --release --target-platform android-arm64
```

> 签名：release 签名从环境变量或 `android/key.properties` 读取（`KEYSTORE_*` / `KEY_ALIAS` / `KEY_PASSWORD`）。
> 若使用 PKCS12 keystore，key 密码即 store 密码。

<br/>

## 项目结构

```
android/                 Android 工程（唯一保留的平台）
lib/                     Dart 应用代码
  plugin/pl_player/      播放器控制器 / VR 控制层
  pages/local_media/     「本地」板块
  services/smb/          纯 Dart SMB 实现
  services/local_media_service.dart
  scripts/               构建期应用到 Flutter SDK 的补丁（CI 亦使用）
tool/libmpv-vr/          VR 补丁版 libmpv 的构建脚本与补丁
third_party/             vendored media_kit Android 库
test/                    单元测试
docs/piliplayer.md       设计说明 + 逐轮真机验证记录
.github/workflows/       piliplayer_ci.yml（应用）/ libmpv_vr.yml（libmpv）
```

<br/>

## 声明

此项目仅用于学习和测试，请于下载后 24 小时内删除。所用 API 皆从官方网站收集，不提供任何破解内容。

致敬开源上游（本仓库在其基础上做了更激进的修改）：

- [guozhigq/pilipala](https://github.com/guozhigq/pilipala)
- [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)

## 致谢

- [media-kit](https://github.com/media-kit/media-kit)
- [My-Responsitories/libmpv-android-video-build](https://github.com/My-Responsitories/libmpv-android-video-build)
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [mpv](https://mpv.io/) / [FFmpeg](https://ffmpeg.org/)

## License

见 [LICENSE](LICENSE)。
