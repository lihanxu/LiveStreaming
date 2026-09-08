# LiveStreaming 应用架构

本文描述当前 App 的模块划分、数据流与关键约束，对应仓库 `LiveStreaming/` 工程（iOS 12+，UIKit）。

## 1. 产品形态

App 启动后进入首页，两个入口：

| 入口 | 页面 | 职责 |
|------|------|------|
| 实时流预览 | `LivePreviewViewController`（Storyboard id 同名） | 摄像头采集 → 滤镜处理图 → OpenGL 预览；顺带 H.264 编码与耳返 |
| 相册 | `AlbumViewController` → `AlbumEditorViewController` | 浏览系统相册；对照片/视频套同一套 LUT/美颜，预览并可导出回相册 |

滤镜实现只维护一份，在开发源 Pod **OFFilterKit**（`OFAuxiliaryTools` + `OFProcessGraph`）。直播与相册各自持有独立门面实例，参数互不串扰。

## 2. 技术栈与依赖

- 语言：Swift + 少量 Objective-C（`VideoFrame` 在 OFFilterKit；`FrameBuffer` 在 App）
- UI：UIKit，无 SceneDelegate；`AppDelegate.window` + `Main.storyboard`
- 采集：AVFoundation `AVCaptureSession`（32BGRA + PCM）
- GPU：滤镜走 Metal Compute（OFFilterKit）；预览走 OpenGL ES 3（`SCGLView`），通过 IOSurface / `CVPixelBuffer` 共享像素
- 人脸：MediaPipe Tasks Vision（由 OFFilterKit 引入；`face_landmarker.task` 在 Pod resource bundle）
- 漫画风：Core ML `AnimeGANv3_*.mlmodel`（同样在 Pod bundle，编成 `mlmodelc`）
- 日志：CocoaLumberjack（TTY stderr + os_log + 按天文件）
- 最低系统：iOS 12.0。App `Podfile` 依赖 `OFFilterKit`（`:path => '../OFFilterKit'`）与 Lumberjack；MediaPipe 由内核 Pod 带入。

权限（`Info.plist`）：相机、麦克风、相册读写、写入相册。

## 3. 导航与进程入口

```
AppDelegate
  ├─ OFLogger.setup()
  └─ AVAudioSession playAndRecord
Main.storyboard
  └─ UINavigationController
       └─ HomeViewController
            ├─ push LivePreviewViewController（实时流）
            └─ push AlbumViewController
                 └─ push AlbumEditorViewController
```

- 首页不持有摄像头/相册资源。
- 实时流页从 Storyboard 实例化，以保证 `SCGLView` 的 IBOutlet；进入后才 `startSession`，返回首页时停止采集与预览。
- 相册网格申请 Photos `readWrite`；点选资源进入编辑页。

## 4. 总体数据流

```
                    ┌─────────────────────────────────────┐
                    │         OFFilterKit                 │
                    │         OFAuxiliaryTools            │
                    │              │                      │
  像素源 ──────────►│         OFProcessGraph              │──► VideoFrame.pixelBuffer
                    │  (Metal / MediaPipe / Core ML)      │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
                                 SCGLView
                              (GLES 预览)
```

像素源有两类：

1. **直播**：`OFiPhoneInputDevice` 采集线程回调 `CMSampleBuffer` → 封装 `VideoFrame` → `inputFrame`；同时把原始 sample 送给 `VideoEncoder`（裸 Annex-B H.264 写临时文件，尚未封装推流）。
2. **相册**：`AlbumEditSession` 在串行 GPU 队列上对照片拷贝或视频帧做同样的 `inputFrame`。

音频直播走 `AudioManager` / `AudioPlayer` 耳返；相册视频预览音频由 `AVPlayer` 播放，导出时 PCM 转 AAC 写入 mp4。

## 5. 滤镜在 OFFilterKit

内核是仓库根目录开发源 Pod [`OFFilterKit/`](../OFFilterKit/)，不发 spec。App 只负责采集、预览、相册和设置 UI。专文见 [`OFAuxiliaryTools.md`](OFAuxiliaryTools.md)。

- 门面：`OFFilterKit/Sources/Metal/OFAuxiliaryTools.swift`
- 调度：`OFProcessGraph`（拓扑序缓存，未启用的节点透传）
- 节点协议：`OFProcessNode`（`isEnabled` + 原地改 `pixelBuffer` / `texture`）
- GPU 资源：每门面一份 `OFFilterContext`（`OFDefalutMetal` + `OFPixelBufferTool`）
- 资源：`OFFilterKit.bundle`（LUT PNG、`face_landmarker.task`、`mlmodelc`、`default.metallib`）
- App 引用：`import OFFilterKit`；`FrameBuffer.h` 使用 `#import <OFFilterKit/Frame.h>`

默认链路（与代码注释一致）：

```
Source
  → FaceLandmarker
  → Beauty
  → FaceReshape
  → ColorAdjust
  → LUT
  → Cartoon
  → SingleColor
  → GaussianBlur
  → Peak
  → Transition
  → Sink
```

| 节点 | 类型 | 说明 |
|------|------|------|
| FaceLandmarker | MediaPipe | 关键点；美颜/重塑/漫画风共用 |
| Beauty | Metal | 磨皮、美肤 LUT、亮眼、白牙 |
| FaceReshape | Metal | 瘦脸、大眼、瘦鼻等 |
| ColorAdjust | Metal | 曝光、对比、色温等 |
| LUT | Metal | 3D LUT 预设 + 混合强度 |
| Cartoon | Core ML | 宫崎骏 / 新海诚风 |
| SingleColor / GaussianBlur / Peak | Metal | 单色、模糊、描边 |
| Transition | Metal | 切镜冻结帧混合；**仅直播设置页露出** |

节点会原地替换 `CVPixelBuffer`。因此相册**照片**必须从原始 `sourceBuffer` 拷贝后再跑图，不能在已滤镜的结果上叠第二次。拷贝走 `AlbumMediaConverter` 传入的 `session.tools.pixelBufferPool`。

像素池按 `OFFilterContext` 实例隔离，不再用进程单例。直播与相册仍不要同时 `inputFrame` 抢同一 GPU；相册内部靠 `AlbumEditSession` 串行队列。

## 6. 实时流模块

| 文件 | 职责 |
|------|------|
| `OFiPhoneInputDevice` | 前后摄 + 麦克风，`hd1920x1080`，前置镜像 |
| `LivePreviewViewController` | 协调采集、处理图、`SCGLView`、设置卡片、编码器 |
| `VideoEncoder` | VideoToolbox H.264，写 `temp.h264`（非相册导出） |
| `AudioManager` / `AudioPlayer` | 耳返 |

设置：`OFSettingsController(context: .live)`，根页含摄像头切换与转场。

## 7. 相册模块（会话层）

目录：`LiveStreaming/LiveStreaming/Album/`

设计目标（方案 B）：**不复制滤镜**，补像素源、预览循环、导出，并用会话串行化 GPU。

```
AlbumEditorViewController（UI）
        │
        ▼
AlbumEditSession
  ├─ OFAuxiliaryTools（独立实例）
  ├─ processingQueue（所有 inputFrame）
  ├─ 预览：照片重跑 source / 视频逐帧
  └─ 导出独占：isExporting，停 SCGLView 与 AVPlayer
        │
        ├─ AlbumMediaConverter（方向烘焙、尺寸、拷贝）
        ├─ AlbumVideoPlayer（AVPlayer + VideoOutput）
        └─ AlbumVideoExporter（Reader/Writer → mp4 → 相册）
```

分辨率约定：

- 预览长边：屏幕 `nativeBounds` 长边（避免 3x 屏发糊）
- 照片导出长边上限：4096
- 视频导出长边上限：1920，且宽高收成偶数（H.264）

预览：`SCGLView.holdsLastFrame` + `isAspectFitEnabled`（静图不被 DisplayLink 弹出后变黑；按比例 letterbox）。

导出视频注意：

- 使用轨道 **编码尺寸** + `writer.transform = preferredTransform`，避免显示尺寸与 transform 叠两次
- 导出前 `videoPlayer.teardown()`，避免与 `AVAssetReader` 争用同一 `AVAsset`
- 缩放用 CoreGraphics，不在后台调 UIKit 绘图
- 音频：PCM 读出再编 AAC

设置：`OFSettingsController(context: .album)`，隐藏摄像头与转场；`onPipelineChanged` 驱动照片从 source 重算。

## 8. 相册剪辑层

剪辑改坐标系和时间轴，滤镜改逐帧着色；二者分开，滤镜 DAG 拓扑不改。`OFAuxiliaryTools` 只吃已经正放且铺满的画面，人脸关键点才与预览/导出一致。没有美摄 `NvsTimeline`：用 `AlbumEditDocument` + TimeMapper + `AlbumGeometryKernel` 表达同一套语义。

**落地进度**：阶段 1 已接入照片画幅（文档 + 几何内核 + 预览/导出）。视频画幅、剪辑、变速、截图仍按第 7 节现状，见 8.8。

### 8.1 两层并行，不是上下游

时间线不处理像素，只决定解哪一帧。几何挂在每一帧像素上。

```
EditDocument
  ├─ Geometry ──► GeometryKernel ──► AlbumEditSession → OFAuxiliaryTools
  └─ Timeline ──► TimeMapper（仅视频）
时钟 / Reader ──► TimeMapper ──► 源帧 ──► GeometryKernel
                                                      ├─ SCGLView
                                                      ├─ Exporter
                                                      └─ Snapshot
```

几何必须在滤镜之前。不把旋转、裁切、变速做成 `OFProcessGraph` 节点。

`GeometryKernel` 第一次变换是片源 `preferredTransform`（照片加载时已 bake，等价 identity），再叠用户 90° / 翻转 / 自由角 / 比例，**一次** CI render。cover 铺满裁切框，黑边不得进 MediaPipe。确认后的输出尺寸即会话画布；视频导出 `writer.transform = identity`（阶段 2）。`SCGLView` 只对屏幕 letterbox，不再裁一次。

### 8.2 能力边界

| 资源 | 画幅 | 剪辑 | 变速 | 截图 |
|------|------|------|------|------|
| 照片 | 阶段 1：90° / 翻转 / 角度 / 比例（居中 cover） | 无 | 无 | 阶段 5：画幅 + 滤镜后静图 |
| 视频 | 阶段 2 | 收尾（阶段 2）/ 多段（阶段 3） | 整段再分段（阶段 4） | 静图；实况为播放头 ±1.5s 播放时间 + 封面（阶段 5） |

滤镜参数只存在于 `OFAuxiliaryTools`。预览 / 导出 / 截图只读同一份 `AlbumEditDocument`。

时间一律用源媒体时间。段播放时长 = 段源时长 / speed；播放头落在某段时，源时间 = 段起点 + (播放时间 − 段播放起点) × speed。收尾改单段起止；多段按序拼接、播放轴无缺口；整段变速即各段同一 speed；speed > 0。

### 8.3 运行时分层

| 层 | 职责 | 落点 |
|----|------|------|
| Document | 画幅 + 时间线纯数据 | `AlbumEditDocument` |
| TimeMapper | 播放头 ↔ 源时间、导出 PTS、生成 Composition | 阶段 3 |
| GeometryKernel | 单帧 BGRA：朝向 + 旋转/翻转/仿射/裁切 | `AlbumGeometryKernel`（CI；后台禁用 UIKit 绘图） |
| Session | 串行 GPU：几何 → 滤镜；导出独占 | `AlbumEditSession` |
| PreviewClock | 按播放时间取源帧 | 阶段 2 起演进 `AlbumVideoPlayer` |
| Exporter | 按段读源、几何、滤镜、写盘 | 阶段 2 起演进 `AlbumVideoExporter` |
| Snapshot | 合成结果出静图 / 实况 | 阶段 5 |
| UI | 画幅入口与设置卡片并列 | `AlbumEditorViewController` + `AlbumGeometryPanelView` |

几何参数分解存储、内核按固定顺序合成：片源朝向 → 正交旋转 + 翻转 → 自由角（cover 放大）→ 按比例居中裁切。

### 8.4 预览

**照片（阶段 1）**：source buffer → 几何 → 滤镜 → `SCGLView`。改画幅或滤镜都从 source 重跑。几何已产出独立 buffer，不必再拷一次。

**视频（阶段 2+）**：单段收尾 + 整段变速用 `AVPlayer` + `VideoOutput`（`seek` / `forwardPlaybackEndTime` / `rate`）。多段 / 分段变速由 TimeMapper 生成 `AVMutableComposition`，Player 对合成轴线性播放。禁止靠逐帧 seek 跳删除段。剪辑 UI 在 1x 源时间下编辑，进出时卸掉/打回变速。

### 8.5 导出

**照片（阶段 1）**：高分辨率 source → 几何 → 滤镜 → `UIImage` 入库；长边上限仍 4096。

**视频（阶段 2+）**：按保留段循环 Reader；PTS 经 mapper 从 0 单调递增；几何后偶数宽高、transform 为 identity。第一期变速同时变调；音频按段重采样。

### 8.6 截图（阶段 5）

吃合成结果，不抓预览 View。与导出共用 GPU 独占队列。

| 类型 | 做法 |
|------|------|
| 静图 | 导出分辨率从 source / 该时刻源帧重跑几何 + 滤镜 |
| 实况 | 封面 = 该静图；视频 = 播放头 ±1.5s **播放时间**，夹在 `[0, playDuration]` |

播放轴上删除段已不存在，短片可跨保留段但观感连续。Live Photo 写入需 JPEG/MOV 配对 content identifier；失败则降级为静图 + 短视频两条资源。

### 8.7 与设置 UI 的关系

底部「设置」只管滤镜。剪辑入口另开，不进 `OFSettingsController`。阶段 1 照片只显示画幅；视频画幅入口隐藏。编辑页只绑文档变更 → session 重跑，不在 VC 里算矩阵。

### 8.8 分期与风险

| 阶段 | 内容 | 状态 |
|------|------|------|
| 1 | 文档 + 几何内核 + 照片画幅预览/导出（居中 cover，无拖框） | 已落地 |
| 2 | 视频并入几何（修朝向分裂）；单段收尾；可补裁切拖框 | 未做 |
| 3 | 多段 Composition；导出按段 Reader | 未做 |
| 4 | 整段变速，再分段变速 | 未做 |
| 5 | 静图截图，再实况截图 | 未做 |

风险：自由角必须 cover，否则黑边进人脸检测；分段变速 + AAC 时间戳累积误差；iOS 12 实况写入必须有降级路径。

美摄对照（Momenta）：学「草稿为真相、几何在滤镜前、多段播放轴无缺口、截图吃合成时间线」。不抄 `NvsTimeline` / `compileTimeline`。

## 9. 设置 UI

| 类型 | 职责 |
|------|------|
| `OFSettingsController` | 数据源与参数写入处理图 |
| `OFSettingsSheetView` | 底部毛玻璃卡片、导航栈、对比原图 |
| 各 `*EditorView` | LUT/美肤选项滑杆、美颜、重塑、调色 |

`OFSettingsContext`：`.live` / `.album`。

## 10. 预览（SCGLView）

- Layer：`CAEAGLLayer`，`contentsScale` 对齐屏幕，布局变化时重建 FBO
- 环形队列：`FrameBuffer`（ObjC），直播持续入帧；相册静图需 `holdsLastFrame`
- `inputFrame` 在未 `start()` 时丢弃
- 直播铺满；相册等比留边

## 11. 目录对照

```
OFFilterKit/                          滤镜内核开发源 Pod
  OFFilterKit.podspec
  Sources/
    Metal/                            门面、Context、像素池、部分滤镜、AuxiliaryTool.metal
    Process/ Face/ LUT/ ColorAdjust/ Cartoon/ Transition/
    Frame/                            VideoFrame（public header）
    Graph/                            SCListGraph / SCQueue
  Resources/                          LUT PNG、mlmodel、face_landmarker.task

LiveStreaming/LiveStreaming/          App
  AppDelegate.swift / HomeViewController.swift / OFLogger.swift
  Live/                     LivePreviewViewController
  Capture/                  OFInputDevice / OFiPhoneInputDevice
  Preview/                  SCGLView、FrameBuffer、GLES shader
  Album/                    网格、编辑会话、画幅文档、几何内核、转换、播放、导出
  Settings/                 设置数据、底部面板、各 EditorView
  Audio/ Video/             耳返、H.264 编码
```

App 工程用 Xcode 文件夹自动同步（`PBXFileSystemSynchronizedRootGroup`）引用 `LiveStreaming/`，在该目录新增/移动源码不必再改 `project.pbxproj`。`Info.plist` 与 bridging header 走 membership exception；GLES `.vsh/.fsh` 经 Copy Files 拷进 bundle 的 `Preview/Shader/`（避免 CocoaPods 无法解析 Resources 阶段 exception）。

## 12. 日志

`OFLogger.setup()`：

1. `DDTTYLogger` → stderr（Xcode Debug Console 可见）
2. `DDOSLogger` → 系统统一日志（Console.app）
3. `DDFileLogger` → 按天文件，保留 7 天

相册导出关键字：`album export`。Cursor 终端不会出现真机运行日志，需在 Xcode 控制台查看。

## 13. 已知边界

- `VideoEncoder` 只写裸 H.264，不能直接存相册；相册视频必须走 `AlbumVideoExporter`。
- 漫画风 + 人脸在接近屏像素时较重；导出长视频会逐帧跑检测，耗时属预期。
- 像素池按门面实例隔离；直播与相册仍不要同时 `inputFrame` 抢同一 GPU，相册内部靠串行队列。
- 视频预览（`AVPlayerItemVideoOutput`）会 bake `preferredTransform`，导出仍用编码尺寸 + `writer.transform`。阶段 2 把朝向并入 `GeometryKernel` 后，预览/导出都 bake，Writer 置 identity。

## 14. 扩展建议

- 新滤镜：在 OFFilterKit 实现 `OFProcessNode`，在 `OFAuxiliaryTools.setupProcessGraph` 加顶点与边，并在 App 设置页加项。
- 新采集源：继承 `OFInputDevice`，输出 32BGRA `CMSampleBuffer`。
- 推流：在直播 `LivePreviewViewController` 编码出口接封装/网络，不必改处理图。
