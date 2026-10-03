# libmpv-vr — VR 版 libmpv (arm64-v8a) 构建

本目录为 PiliPlus `piliplayer` 分支构建**带 VR/全景重投影的 libmpv.so**，
产物是 media_kit 安卓端使用的 `default-arm64-v8a.jar`（滚动 release tag
`libmpv-vr`），由 `.github/workflows/libmpv_vr.yml` 在 CI 里构建发布，
应用侧通过 `third_party/media_kit_libs_android_video`（vendored 包）引用。

## 来源与基线

- `buildscripts/` 逐字取自
  [My-Responsitories/libmpv-android-video-build](https://github.com/My-Responsitories/libmpv-android-video-build)
  提交 `8e50ecc` —— 即应用当前锁定的 `20260906` release 的构建状态
  （mpv v0.41.0 / ffmpeg n9.0.1 / libplacebo 7.360.1 / NDK 29，default flavor）。
  只做了两处裁剪：`include/download-deps.sh` 去掉了与本次产物无关的克隆
  （libvpx / libx264 / fftools_ffi / media_kit / media-kit-android-helper /
  shaderc 占位），并移除了 encoders-gpl、full 两个 flavor 的 bundle/patch 脚本。
- `buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch`：上游原有补丁
  （media_kit 需要的 `mpv_lavc_set_java_vm` 导出），原样保留。
- `buildscripts/patches/mpv/vr_vo_gpu.patch`：**本次新增**。给 mpv 的
  `vo=gpu` 加 VR 重投影（在硬解与常规渲染链之后、输出之前，把合成好的
  平面画面投到球面网格上），渲染数学与头部追踪移植自
  [xl_player](https://github.com/xl-player-developers/xl_player)
  （球面网格 / Cardboard 畸变网格 / OrientationEKF 头追，EKF 已转写为 C）。
  新增 mpv 选项（也是运行时属性）：
  `vr`、`vr-layout`(mono/sbs/tb)、`vr-projection`(360/180)、`vr-eye`(left/right)、
  `vr-stereo-output`、`vr-fov`(水平视场角,度)、`vr-yaw`、`vr-pitch`、
  `vr-head-tracking`、`vr-reset-view`(递增计数触发回正)。
  视角参数是"热"参数：变更不触发渲染链重建（见 patch 内
  `only_vr_view_opts_changed`），头追在 native 侧逐帧运行，不经 Dart 往返。
  手动环视（头追关闭）时 `vr_manual_angles()` 还会在 native 侧兜底夹取视角：
  180° 片源的偏航在覆盖边界收敛、俯仰在极点收敛（转出画面见黑不可接受），
  头追开启时不夹取（陀螺仪模式按需求放宽）。
  **第十六轮**：① `VR_FREE_LOOK`——按需求方要求放开手动视角限制：180° 片源
  的覆盖边界夹取与俯仰"视口不越过极点"夹取全部移除（转出覆盖看黑边已被
  明确接受），只留偏航回绕与俯仰 ±90°（等距柱状极点奇异，也是选项值域）；
  ② `vr-fov` 值域 10~150 → **10~180**（`vr-view` 解析同步放宽；
  `vr_fovy_from_hfov` 原有的垂直 fov ≤179° 保护避免了 tan(90°) 退化）。
  注意 fov>~160 时背面剔除（w<=0 整三角形丢弃）在视锥边缘可能出现小块
  空洞——极端放大下的已知边界，常规视场不受影响。③ ffmpeg 协议白名单补
  `--enable-protocol=fd`：系统"用其他应用打开"的 content:// 视频经
  ContentResolver 导出 fd 后以 `fd://N` 交给 mpv 播放。
  **第十五轮（真机"手势卡顿/HUD 与陀螺仪分离"修复）**：
  ① `vr-view` 合并字符串属性（`"yaw=..,pitch=..,fov=.."`，解析后覆盖标量
  字段）：mpv 客户端每次 setProperty 都要一次"客户端→core 同步派发 +
  core→VO 同步 VOCTRL 握手"，拖拽时 9 个属性/批 × ~33 批/s ≈ 300 次跨线程
  往返/s，正是"手势拖动卡顿而陀螺仪（零属性流量）流畅"的根因——合并后
  每批只剩 1 次；② `vr-view-yaw`/`vr-view-pitch` 只读属性（经
  `VOCTRL_VR_VIEW_ANGLES` 读 vr.c 每帧缓存的有效视角中心，含头姿与折叠
  偏置），HUD 从此显示**真实**视线方向而不是只显示手动分量（属性实现在
  vr_metadata.patch，避免两个补丁同时改 command.c 产生重叠 hunk）。
  **VR_GYRO_CONT（第十四轮，真机"陀螺仪开关跳变/背对画面"修复）**：
  开启头追时不再直接使用原始设备姿态——等首个真实陀螺仪样本到达后采样
  参考系 `ref_inv = head⁻¹·B·A⁻¹`（A=on 模式手动部 Ry·Rx，B=off 模式
  Rx·Ry，角度均含折叠偏置），使开启瞬间画面**逐元素连续**（也根治"切入
  陀螺仪背对画面要转 180°"）；关闭头追时把最后一次跟踪模型的中心方向
  分解回 yaw/pitch 折叠进 `bias_yaw/bias_pitch`（滚转分量丢弃），手动模式
  在偏置之上继续，关闭瞬间视角不跳；「视角摆正」(vr-reset-view) 清零偏置
  并以当前姿态为新参考。1.5x 倍速卡顿缓解：头追关闭且视角未变时恢复
  "静止帧 blit 缓存"（此前 VR 一律禁用缓存，暂停/OSD 重绘都全链重渲染），
  VR 视角热更新会精确失效该缓存。数学已用独立 C 程序对随机姿态 5 万组
  数值验证（开启连续性 ~4e-7、折叠中心误差 ~1e-6）。
  **VR_DUMB_FIX（第十三轮，真机"VR 不生效"的根因修复）**：mpv 的 vo=gpu 有
  一个"无高级处理就走 dumb mode 直拷"的自动优化，media_kit 安卓端的默认
  选项（bilinear 缩放、关 dither/downscaling 附加项）恰好满足其条件，导致
  **所有播放都进 dumb mode**——VR 分支（`p->opts.vr && !p->dumb_mode`）永远
  不执行，且 dumb mode 的选项白名单会把 `vr` 清零，画面永远是平面 2D。
  修复：`check_dumb_mode()` 在 `vr=yes` 时返回 false（VR 需要完整渲染链）；
  `vr` 开关翻转不再走热更新而是完整 reinit（dumb 资格随之重算）；被强制
  dumb（无可用 FBO）时打 WARN 日志说明 VR 被禁用。热更新比较基准也从
  `p->opts`（会被 check_gl_features 改写，导致比较恒不等 → 每次拖视角都
  全链重建）改为影子副本 `opts_cache_copy`，并且只回拷 VR 字段。
- `buildscripts/patches/ffmpeg/libsmb2.patch`：**第十四轮新增**（对齐 VLC 的
  SMB 行为）。安卓端打包的 FFmpeg 原本没有任何 smb 协议（libsmbclient 是
  GPLv3+Samba 全家桶，没法用），应用侧此前用"Dart SMB2 客户端 + 回环 HTTP
  代理"喂 mpv——播放泵长期占用会话池导致目录浏览变慢、seek 重连易断流、
  退出后代理泵还有残余传输。本补丁给 ffmpeg 增加 `smb://` URLProtocol
  （`libavformat/libsmb2.c`，基于 **libsmb2**——VLC 安卓 smb access 用的同一
  个库，LGPL、静态链入 libmpv.so）：mpv 直接持有 SMB socket，seek 是同句柄
  定位读（不重连），停播即断开；URL 形如
  `smb://[domain;][user[:pass]@]host[:port]/share/path`（各分量百分号编码，
  密码不落日志），命令级超时默认 10s（`timeout` AVOption）。
  **SMB2_BLANK_PW（第十五轮，真机 `STATUS_INVALID_PARAMETER` 根因）**：
  libsmb2 客户端把 NULL 密码当"匿名登录"（`ntlmssp.c: password == NULL →
  anonymous`），空密码的真实账号会被服务器拒绝——有用户名时必须显式
  `smb2_set_password("")` 走空密码 NTLMv2（Dart 浏览客户端正是这样做的，
  所以浏览正常而直连播放失败）。配套：
  `depinfo.sh`/`download-deps.sh`/`scripts/libsmb2.sh`（cmake 静态+PIC 构建，
  安装后把不自包含的头文件补齐 stddef/stdint/time 前置与 umbrella include，
  ffmpeg configure 的单头探测才能通过）与 `flavors/default.sh` 的
  `--enable-libsmb2`。`patch.sh` 同时改为**按补丁内容哈希跳过重复应用**
  （ffmpeg 树不再因 mpv 补丁迭代而被 clean 全量重编）。
- `buildscripts/patches/mpv/vr_metadata.patch`：**多格式 VR 需求新增**。
  片源元数据识别：`demux_lavf` 解析 lavf 的 spherical（mov `sv3d`/`prji`、
  mkv `Projection`）与 stereo3d（mov `st3d`、mkv `StereoMode`）side data，
  以只读属性暴露给客户端，供应用侧的「自动（按片源元数据）」模式使用：
  `vr-metadata-projection` = none/360/180/cubemap/other、
  `vr-metadata-layout` = none/mono/sbs/tb/other。
  （cubemap 与其他投影为"识别到但不支持"，应用侧必须明确提示而非静默失效。）

## jar 组装策略

不重新构建 media_kit 的 event-loop / android-helper：`bundle_vr_arm64.sh`
下载上游 `20260906` 的 `default-arm64-v8a.jar`（校验 sha256），只把其中
`lib/arm64-v8a/libmpv.so` 换成本次构建产物，其余 `.so` 逐字节保留。
这样应用运行时的唯一变化就是 mpv 本体，风险面最小。

## 本地重建

沙盒（2 vCPU）无法承担全量交叉编译，请在 CI 触发：

- push 到 `piliplayer` 且改动 `tool/libmpv-vr/**` 会自动构建并发布；
- 或手动 `workflow_dispatch`（可选是否发布）。

deps/prefix 有 actions/cache：只改 mpv 补丁时约 5-8 分钟出包，全量约 25-35 分钟。
