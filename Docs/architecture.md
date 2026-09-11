# LiveStreaming 应用架构

本文描述当前 App 的模块划分、数据流与关键约束，对应仓库 `LiveStreaming/` 工程（iOS 12+，UIKit）。

**怎么读：** 先看 §1–4 建立「两种像素源、一份滤镜图」；直播看 §6；相册会话与分辨率看 §7；画幅/剪辑/变速的类型与时钟看 [`Album/album-edit.md`](Album/album-edit.md)。滤镜节点细节看 [`FilterKit/OFAuxiliaryTools.md`](FilterKit/OFAuxiliaryTools.md)。

一句话：App 只做采集、预览、相册编辑和设置 UI；着色逻辑只维护在开发源 Pod **OFFilterKit**。相册剪辑是「草稿 + 时间映射 + 几何内核」，**不是**美摄式 `NvsTimeline`。

## 1. 产品形态

App 启动后进入首页，两个入口：

| 入口 | 页面 | 职责 |
|------|------|------|
| 实时流预览 | `LivePreviewViewController`（Storyboard id 同名） | 摄像头采集 → 滤镜处理图 → OpenGL 预览；顺带 H.264 编码与耳返 |
| 相册 | `AlbumViewController` → `AlbumEditorViewController` | 浏览系统相册；LUT/美颜照片与视频共用；预览并可导出回相册 |

滤镜实现只维护一份，在开发源 Pod **OFFilterKit**（`OFAuxiliaryTools` + `OFProcessGraph`）。直播与相册各自持有独立门面实例，参数互不串扰。

## 2. 技术栈与依赖

- 语言：Swift + 少量 Objective-C（`VideoFrame` 在 OFFilterKit；`FrameBuffer` 在 App）
- UI：UIKit，无 SceneDelegate；`AppDelegate.window` + `Main.storyboard`
- 采集：AVFoundation `AVCaptureSession`（32BGRA + PCM）
- GPU：滤镜走 Metal Compute（OFFilterKit）；预览走 OpenGL ES 3（`SCGLView`），通过 IOSurface / `CVPixelBuffer` 共享像素
- 人脸：MediaPipe Tasks Vision（由 OFFilterKit 引入；`face_landmarker.task` 在 Pod resource bundle）
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
- 资源：`OFFilterKit.bundle`（LUT PNG、`face_landmarker.task`、`default.metallib`）
- App 引用：`import OFFilterKit`；`FrameBuffer.h` 使用 `#import <OFFilterKit/Frame.h>`

默认链路（与代码注释一致）：

```
Source
  → FaceLandmarker
  → Beauty
  → FaceReshape
  → ColorAdjust
  → LUT
  → SingleColor
  → GaussianBlur
  → Peak
  → Transition
  → Sink
```

| 节点 | 类型 | 说明 |
|------|------|------|
| FaceLandmarker | MediaPipe | 关键点；美颜/重塑共用 |
| Beauty | Metal | 磨皮、美肤 LUT、亮眼、白牙 |
| FaceReshape | Metal | 瘦脸、大眼、瘦鼻等 |
| ColorAdjust | Metal | 曝光、对比、色温等 |
| LUT | Metal | 3D LUT 预设 + 混合强度 |
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

**方案 B：** 不复制滤镜实现。相册补三件事——像素从哪来、预览怎么循环、导出怎么写文件——并用会话把 GPU 串行化。直播页与编辑页各持一份 `OFAuxiliaryTools`，参数互不串扰。

心智模型：

```
相册网格（AlbumViewController）
        │ 点选 PHAsset
        ▼
AlbumEditorViewController          唯一写 session.document 的门面
        │
        ▼
AlbumEditSession
  ├─ document                      画幅 + 时间线（滤镜参数不在此）
  ├─ OFAuxiliaryTools              独立滤镜图
  ├─ processingQueue               所有 inputFrame / 导出同步处理
  └─ isExporting                   独占时丢弃预览帧
        │
        ├─ AlbumMediaConverter     方向、尺寸、拷贝、UIImage
        ├─ AlbumGeometryKernel     单帧 CI：朝向 + 用户画幅（滤镜之前）
        ├─ AlbumTimeMapper         源时间 ↔ 播放轴；按需拼 Composition
        ├─ AlbumVideoPlayer        AVPlayer + VideoOutput 出 BGRA
        └─ AlbumVideoExporter      Reader → 几何 → 滤镜 → Writer → 相册
```

照片与视频共用几何 + 滤镜；时间线只对视频有意义。照片必须保留一份未滤镜的 `photoSourceBuffer`：处理图会**原地**替换 `CVPixelBuffer`，改 LUT 时要从 source 重跑，不能在已滤镜结果上叠第二次。

分辨率约定（`AlbumMediaConverter`）：

| 用途 | 长边 | 备注 |
|------|------|------|
| 预览 | 屏 `nativeBounds` 长边 | 避免 3x 屏被放大发糊 |
| 照片导出 | 4096 | 从相册重新 decode，不复用预览 buffer |
| 视频导出 | 1920 | 几何后再 `evenSize`，H.264 要求偶数宽高 |

预览：`SCGLView.holdsLastFrame` + `isAspectFitEnabled`。静图若无 holdsLastFrame，DisplayLink 弹出队列后会变黑；相册按比例 letterbox，直播铺满。

导出视频要点：

- 几何（含轨 `preferredTransform`）bake 进像素后 `writer.transform = identity`。不要再用「编码尺寸 + Writer 旋转」分裂朝向。
- `AlbumTimeMapper.exportSource` / `exportTimeRange`：单段 1x 读原片入出点；多段或非 1x 读 Composition，区间是播放轴 `[0, playDuration]`。已读合成轴时**不要再乘 speed**。
- 导出前 `videoPlayer.teardown()`，避免 `AVPlayer` 与 `AVAssetReader` 争用同一 `AVAsset`。
- 缩放走 CoreGraphics，后台不要调 UIKit 绘图。
- 音频：PCM 读出再编 AAC；Composition 里音视频同一 `scaleTimeRange`（第一期变调）。

设置：`OFSettingsController(context: .album)`，隐藏摄像头与转场。`onPipelineChanged`：照片从 source 重算，视频 `refreshCurrentFrame`。画幅 / 剪辑 / 变速在编辑页底部工具条，**不进**设置导航栈。

## 8. 相册编辑模块（画幅 / 剪辑 / 变速）

滤镜改「这一帧怎么着色」；剪辑改「这一帧从哪来、坐标系是什么」。几何与时间线都**不是** `OFProcessGraph` 节点。完整类型、两套时钟、面板写入路径见 [`Album/album-edit.md`](Album/album-edit.md)；交互图见同目录 `clip-architecture.html` / `clip-dataflow.html`。

新人只需先记住六条：

1. **草稿为真相。** `AlbumEditSession.document`（`AlbumEditDocument`）是预览/导出唯一输入。滤镜滑杆写 `session.tools`，不写 document。
2. **几何 ⊥ 时间线。** `AlbumGeometryEdit` 改坐标系；`AlbumTimelineEdit` 是源时间上的保留段 + 每段 `speed`。空 `segments` = 整段 1x、未剪辑。
3. **几何在滤镜之前。** `AlbumGeometryKernel` 一次 CI 合成朝向与用户画幅，输出正放铺满，再 `inputFrame`。自由角必须 cover，否则黑边进 MediaPipe。
4. **UI 交回值拷贝。** 面板 `present` 时拷贝 document；`didChange` 交给 VC 赋值。面板不持有 `session.document` 引用。
5. **Mapper 无状态。** `AlbumTimeMapper(timeline:sourceDuration:)` 按需构造。Player 只吃 `AVAsset` + 入出点，不吃 `AlbumTimelineEdit`。
6. **不引入美摄时间线。** Composition 只表达「播放轴无缺口」。单段 1x 仍用原片 + `forwardPlaybackEndTime`。

已落地：照片/视频画幅、单段与多段裁切、整段与分段变速。未做：截图（阶段 5）。约束：最短段 0.1s，最多 6 段，speed 夹紧 `[0.25, 4]`。

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
    Process/ Face/ LUT/ ColorAdjust/ Transition/
    Frame/                            VideoFrame（public header）
    Graph/                            SCListGraph / SCQueue
  Resources/                          LUT PNG、face_landmarker.task

LiveStreaming/LiveStreaming/          App
  AppDelegate.swift / HomeViewController.swift / OFLogger.swift
  Live/                     LivePreviewViewController
  Capture/                  OFInputDevice / OFiPhoneInputDevice
  Preview/                  SCGLView、FrameBuffer、GLES shader
  Album/                    网格、会话、文档、几何内核、TimeMapper、转换、播放、画幅/剪辑/变速面板、导出
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
- 像素池按门面实例隔离；直播与相册仍不要同时 `inputFrame` 抢同一 GPU，相册内部靠串行队列。
- 视频预览与导出都经 `AlbumGeometryKernel` bake `preferredTransform` 与用户画幅；Writer 置 identity。不再用编码尺寸 + `writer.transform` 分裂朝向。
- 相册草稿不持久化；退出编辑页即丢。多段/变速预览绑 Composition，剪辑面板打开时改绑原片源轴。

## 14. 扩展建议

- 新滤镜：在 OFFilterKit 实现 `OFProcessNode`，在 `OFAuxiliaryTools.setupProcessGraph` 加顶点与边，并在 App 设置页加项。
- 新采集源：继承 `OFInputDevice`，输出 32BGRA `CMSampleBuffer`。
- 推流：在直播 `LivePreviewViewController` 编码出口接封装/网络，不必改处理图。
- 多视频拼接与转场：见 [`Album/multi-clip.md`](Album/multi-clip.md)。美摄 SDK 有轨道 `appendClip` 与内置转场，本仓库仍不引入 `NvsTimeline`，在现有草稿上叠加 `AlbumProject`。
