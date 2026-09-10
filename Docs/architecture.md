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

内核是仓库根目录开发源 Pod [`OFFilterKit/`](../OFFilterKit/)，不发 spec。App 只负责采集、预览、相册和设置 UI。专文见 [`FilterKit/OFAuxiliaryTools.md`](FilterKit/OFAuxiliaryTools.md)。

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

- 几何（含片源朝向）bake 进像素后 `writer.transform = identity`；输出尺寸是几何后偶数宽高，长边仍 1920
- Reader `timeRange` 限在单段收尾区间；导出前 `videoPlayer.teardown()`，避免与 `AVAssetReader` 争用同一 `AVAsset`
- 缩放用 CoreGraphics，不在后台调 UIKit 绘图
- 音频：PCM 读出再编 AAC

设置：`OFSettingsController(context: .album)`，隐藏摄像头与转场；`onPipelineChanged` 驱动照片从 source 重算、视频刷新当前帧。

## 8. 相册编辑模块

剪辑改坐标系与时间轴，滤镜改逐帧着色；几何必须在滤镜之前，二者都不是 `OFProcessGraph` 节点。专文与剪辑架构图见 [`Album/album-edit.md`](Album/album-edit.md)。

要点：`AlbumEditSession.document` 为草稿真相；面板只提交值拷贝，由 `AlbumEditorViewController` 赋值；`AlbumTimeMapper` 无状态，预览/导出按需构造。阶段 1–3 已落地，变速（阶段 4）与截图（阶段 5）见该文档 §7 / §8。

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
  Album/                    网格、编辑会话、画幅/时间线文档、几何内核、转换、播放、收尾面板、导出
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
- 视频预览与导出都经 `AlbumGeometryKernel` bake `preferredTransform` 与用户画幅；Writer 置 identity。不再用编码尺寸 + `writer.transform` 分裂朝向。

## 14. 扩展建议

- 新滤镜：在 OFFilterKit 实现 `OFProcessNode`，在 `OFAuxiliaryTools.setupProcessGraph` 加顶点与边，并在 App 设置页加项。
- 新采集源：继承 `OFInputDevice`，输出 32BGRA `CMSampleBuffer`。
- 推流：在直播 `LivePreviewViewController` 编码出口接封装/网络，不必改处理图。
