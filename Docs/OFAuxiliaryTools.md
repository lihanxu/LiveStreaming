# OFAuxiliaryTools 架构

本文只讲滤镜门面 [`OFAuxiliaryTools`](../OFFilterKit/Sources/Metal/OFAuxiliaryTools.swift) 及其调度图。App 级模块划分见 [`architecture.md`](architecture.md)。

## 0. 模块边界与 Pod

滤镜内核是仓库根目录的开发源 Pod [`OFFilterKit/`](../OFFilterKit/)，不发 spec 仓库。App [`LiveStreaming/Podfile`](../LiveStreaming/Podfile) 用：

```ruby
pod 'OFFilterKit', :path => '../OFFilterKit'
```

`static_framework = true`：MediaPipe 以静态 xcframework 提供，动态库无法传递该依赖。

| 在 OFFilterKit | 留在 App |
|----------------|----------|
| 门面 `OFAuxiliaryTools`、`OFProcessGraph`、全部滤镜节点 | 采集、编码、音频 |
| `OFFilterContext`（Metal + 像素池） | `SCGLView`、`FrameBuffer`（`#import <OFFilterKit/Frame.h>`） |
| `VideoFrame`（`Frame.h` / `Frame.m`） | Settings UI、`OFMetalFuntions`（摄像头按钮枚举） |
| LUT PNG、`*.mlmodel`、`face_landmarker.task`、`AuxiliaryTool.metal` | `Album/*`（只调 `inputFrame` 与 `session.tools.pixelBufferPool`） |
| `OFBeautySettings` / `OFWhiteningStyle` / `OFColorAdjustParams` | `OFColorAdjustEditorView` 等编辑器视图 |

对外产品 API 保持：`OFAuxiliaryTools` + `inputFrame` + 参数 DTO。Swift 调用处 `import OFFilterKit`。

**资源 Bundle**：`s.resource_bundles` → App 内 `OFFilterKit.bundle`。LUT / `face_landmarker.task` / 编译后的 `mlmodelc` / `default.metallib` 都从这里读（[`OFFilterResources`](../OFFilterKit/Sources/Metal/OFFilterResources.swift)）。静态库不会把 metallib 带进 App，Pod 在编译后把它拷进该 bundle。

**`OFFilterContext` 生命周期**：每个 `OFAuxiliaryTools` 构造时新建一份 Metal 设备封装 + `OFPixelBufferTool`，再注入各 `*Computer`。直播与相册各持一门面，像素池按实例隔离；仍不要同时对同一 GPU 设备 `inputFrame`。

## 1. 定位

`OFAuxiliaryTools` 是滤镜子系统的**唯一业务入口**。直播页、相册会话、设置页都不直接操作 Metal kernel 或 MediaPipe 任务。

职责：

1. 构造默认处理图（节点 + 边）
2. 把设置页开关/滑杆写成各节点参数
3. 提供 `inputFrame(_:)`：一帧进图，按拓扑序原地处理
4. 协调跨节点共享状态（人脸关键点是否推理、对比原图旁路）

不负责：采集、OpenGL 预览、H.264 编码、相册读写。像素源和去向由宿主决定。

宿主有两份独立实例，参数互不串扰：

| 宿主 | 实例持有者 | 调用线程约束 |
|------|------------|--------------|
| 实时流 | `ViewController.auxiliaryTools` | 采集回调线程 `inputFrame` |
| 相册 | `AlbumEditSession.tools` | 会话串行 GPU 队列 `inputFrame` |

设置页通过 `OFSettingsController(tools:context:)` 绑定同一实例；相册在滤镜变更后靠 `onPipelineChanged` 从 source 重跑。

## 2. 分层

```
设置 UI / 直播 VC / 相册 Session
              │  只调门面方法
              ▼
        OFAuxiliaryTools          ← 构图、参数、跨节点开关
              │
              ▼
        OFProcessGraph            ← ID 图 + processor 表 + 拓扑序缓存
              │
              ▼
     OFProcessNode 实现           ← LUT / Beauty / Cartoon / …
              │
    ┌─────────┼──────────┐
    ▼         ▼          ▼
  Metal    MediaPipe   Core ML
 Compute   Landmarker  AnimeGANv3
```

| 层 | 文件（均在 `OFFilterKit/Sources/`） | 做什么 |
|----|------|--------|
| 门面 | `Metal/OFAuxiliaryTools.swift` | 持有全部节点、连边、UI API |
| 调度 | `Process/OFProcessGraph.swift` | `SCListGraph<OFProcessNodeID>`，按拓扑序调用 `process` |
| 约定 | `Process/OFProcessNode.swift` | `isEnabled` + 原地改 `VideoFrame` |
| 图结构 | `Graph/SCListGraph.swift` | 邻接表有向图 + Kahn 拓扑排序 |
| 节点 | `Face/` `LUT/` `ColorAdjust/` `Cartoon/` `Transition/` `Metal/` | 各自编译 pipeline、读写参数 |
| 实例资源 | `OFFilterContext` → `OFDefalutMetal` + `OFPixelBufferTool` | 每门面一份设备/队列与输出池 |

图结构只存 **ID 与边**。真正做 GPU 的对象挂在 `processors` 字典里。`source` / `sink` 是占位顶点，没有 processor。

## 3. 默认链路

构图在 `setupProcessGraph()`，当前是一条有向链（DAG 的退化形式）：

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

顺序约束是产品语义，不是随意排列：

- **Landmarker 最先**：美颜、重塑、漫画风共用同一组点；必须先有（或沿用上一帧的）结果。
- **Beauty 在 Reshape 前**：先磨皮着色，再几何形变，避免形变后面部区域和关键点错位。
- **ColorAdjust / LUT 在脸部处理之后**：全局调色不要干扰关键点所在像素语义。
- **Cartoon 在 LUT 后**：风格化覆盖写实调色。
- **Transition 最后**：切镜混合的是「已经滤好」的画面。

加贴纸、分割等后续节点：新 `OFProcessNodeID` + `addNode` + `addEdge`，不必改调度器。

## 4. 一帧怎么走

```
VideoFrame（pixelBuffer + texture）
        │
        ▼
OFAuxiliaryTools.inputFrame
        │
        ▼
OFProcessGraph.process
  1. 构图未变则复用 cachedOrder（避免每帧 Kahn）
  2. 按序遍历；无 processor 或 isEnabled == false → 跳过（透传）
  3. isEnabled 的节点原地改 frame.pixelBuffer / texture
        │
        ▼
faceLandmarker.applyDebugOverlayIfNeeded   ← 网格调试画在处理后的帧上
        │
        ▼
宿主：SCGLView.inputFrame 或导出 Writer
```

**透传**是架构关键：关闭的 LUT/模糊/漫画风不跑 GPU，也不拷贝一帧。代价是节点必须能在「没人改过 buffer」时安全跳过。

**原地改帧**让预览路径零额外 blit，但相册照片必须从 `sourceBuffer` 拷贝后再进图，否则第二次滤镜叠在已处理结果上。

## 5. 节点约定

```swift
protocol OFProcessNode: AnyObject {
    var isEnabled: Bool { get }
    func process(_ frame: VideoFrame)
}
```

各节点自己决定 `isEnabled`，门面不在调度层写 if-else 滤镜列表。典型条件：

| 节点 | 开启条件（摘要） |
|------|------------------|
| FaceLandmarker | 美颜开、网格开、或漫画风开（要脸遮罩） |
| Beauty / FaceReshape | 总开关 + 档位非零，且未 bypass |
| LUT / ColorAdjust | 选了预设/滑杆非零，且未 bypass |
| Cartoon | 选了风格预设 |
| GaussianBlur / Peak / SingleColor | 对应开关 |
| Transition | 已武装且正在播放时段 |

「按住对比原图」走各节点 `setBypassed`，把 `isEnabled` 打成 false，图调度自然跳过，不必另建一条原片图。

人脸是**注入共享**，不是每节点各跑一次推理：

```
faceLandmarker ──► beauty.landmarker
               ├──► faceReshape.landmarker
               └──► cartoon.landmarker
```

`updateFaceLandmarkerFlags()` 把「谁需要点」收成一次 `inferenceEnabled`。Landmarker 用 MediaPipe live stream，推理异步、不阻塞采集；忙时丢帧，美颜继续用上一帧点。

## 6. 当前架构的优势

相对「一个巨型 Filter 类里顺序调 kernel」或「每层 UI 直接碰 Metal」，这套分层有这些好处：

**1. 宿主与 GPU 解耦**  
直播采集、相册 Reader、设置页只认门面。换像素源不必改节点；换节点不必改 VC。相册复用同一套 LUT/美颜，没有第二份实现。

**2. 开关即调度**  
`isEnabled` 把产品开关、bypass、资源是否就绪合成「跑或不跑」。实时路径上关闭的重节点（Core ML 漫画风、高斯）直接 continue，比先渲染再丢结果更省。

**3. 构图与执行分离**  
图用 ID 描述依赖，拓扑序缓存。默认虽是链，调度器已按 DAG 写：以后要分支（例如人脸遮罩走旁路再复合）只需加边，不必重写 `process`。

**4. 跨节点状态集中在门面**  
Landmarker 开关、美颜总开关、对比 bypass 若散落在 VC，很容易漏开推理或漏关。门面把「谁依赖谁」收在 `updateFaceLandmarkerFlags`。

**5. 节点可独立演进**  
LUT 换四面体插值、Beauty 加亮眼，只要守协议。设置页只加格子和 `tools.apply…`，不碰图调度。

**6. 适合实时预览的性能模型**  
- 拓扑序不每帧重算  
- 关闭节点零 GPU  
- 输出走 `CVPixelBufferPool`（Metal + GLES 兼容），避免每帧 malloc  
- Landmarker 异步 + in-flight 丢帧，避免推理拖死采集

**7. 实例隔离**  
直播与相册各持一份门面和一份 `OFFilterContext`，滑杆与 `CVPixelBufferPool` 互不污染。仍不要两路同时 `inputFrame` 抢同一 GPU 设备；相册内部靠串行队列。

## 7. 和其他常用架构对比

### 7.1 单体顺序管线（一个类里 if 调 kernel）

很多 Demo / 早期美颜 SDK 把磨皮、LUT、模糊写在同一个 `processFrame` 里。

| | 单体管线 | 本项目（门面 + 图） |
|--|----------|---------------------|
| 优点 | 实现快、调用栈浅、容易看清当前顺序 | 节点独立、可跳过、可复用到相册 |
| 缺点 | 加滤镜要改中枢；关闭也容易仍占分支；难测单节点 | 门面 API 会随参数变胖；默认链仍要人维护顺序 |

本项目若继续把全部 `apply*` 堆在门面上，会滑向「门面变单体」。图调度已经把执行拆开，参数层仍是集中式——这是有意的：UI 只有一个对手。

### 7.2 GPUImage / GPUImage3 式 Filter Chain

每层是 `GPUImageFilter`，用 target 链表串起来，帧在 ping-pong FBO/纹理间传递。

| | GPUImage 链 | 本项目 |
|--|-------------|--------|
| 优点 | 生态大；每滤镜输入输出清晰；易插预览 sink | 关闭节点不经过 FBO；共享 Landmarker 比「每滤镜一份检测」便宜 |
| 缺点 | 每级 blit 有带宽成本；链是线性的，分支/复合要 Group；ObjC 年代 API 重 | 原地改同一 `VideoFrame`，中间结果不好分叉；照片必须拷贝 source |
| 数据模型 | 新输出纹理 | 原地 pixelBuffer |

实时美颜里「多数滤镜关闭」时，透传跳过比 GPUImage 每级都 bind FBO 更合适。若以后要「同一帧出预览 + 小窗 + 编码三种不同效果」，GPUImage 的多 target 更自然，本图目前只有一个 sink。

### 7.3 Core Image（`CIFilter` + `CIContext`）

系统滤镜图，懒求值，末尾一次 `render`。

| | Core Image | 本项目 |
|--|------------|--------|
| 优点 | 系统优化、色彩管理、部分 kernel 能合成；实现量小 | 自定义 Metal / MediaPipe / Core ML 可进同一拓扑；延迟和缓冲策略自己控 |
| 缺点 | 自定义检测+形变不好塞进 CI 图；实时 1080p 多级 CI 有中间图开销；iOS 版本能力差 | 要自己管池、格式、线程 |
| 适用 | 相册调色、系统滤镜 | 直播级自研美颜 + 第三方推理 |

本项目相册导出若只做 LUT，CI 足够；但要和直播同一套瘦脸/漫画风，继续走 `OFProcessNode` 更一致。几何裁切（规划中的剪辑层）用 CI 做、滤镜仍走本图，是合理的混合，不要把旋转做成 DAG 节点。

### 7.4 AVVideoComposition / 自定义 Compositor

导出用 `AVAssetExportSession` + `AVVideoComposition`，在 compositor 里逐帧处理。

| | AVVideoComposition | 本项目 |
|--|--------------------|--------|
| 优点 | 和 AVFoundation 时间轴、音画对齐原生；系统管 Reader/Writer | 预览和导出可跑同一 `inputFrame`，朝向/滤镜一致 |
| 缺点 | 预览要另接 `AVPlayer` + compositor，调试重；难塞异步 Landmarker | 导出时钟、变速、多段要自己写 Exporter（相册已走 Reader/Writer） |

滤镜图不应承担时间线。剪辑规划把几何/时间放在图外，正是避免把本架构变成「伪 compositor」。

### 7.5 完整节点编辑器（Nuke / Fusion / 部分直播 SDK 的 Node Graph）

任意分支、多输入混合、每节点缓存中间纹理、可序列化工程文件。

| | 全功能节点图 | 本项目 |
|--|-------------|--------|
| 优点 | 能做复杂合成、A/B 分支、复用子图 | 实现量和每帧开销小；产品滤镜是固定顺序 |
| 缺点 | 调度、缓存失效、色彩空间都很重；移动端实时难扛 | 当前构图没用上多入边；中间结果不能分发给两个下游 |

本图的 `SCListGraph` 已是有向图，但执行时忽略边、只按拓扑序依次原地写同一帧——等价于「线性合成器」。这是针对「一条美颜链路」的正确简化。真正的多输出/旁路混合需要：中间 buffer、按边传纹理，而不是继续原地写。

### 7.6 MPS / Metal 显式 CommandBuffer 录制

宿主每帧自己 `encode` 一串 compute encoder，参数用 argument buffer。

| | 手写 CommandBuffer | 本项目 |
|--|---------------------|--------|
| 优点 | 最少抽象、最好把控 encoder 合并与内存 | 节点可测、可关；产品同学改开关不必碰 encoder |
| 缺点 | 与 UI 绑定后无法复用到相册；合并 encoder 的收益要专门做 | 每节点可能各自提交（取决于实现），少了跨节点 encoder 合并 |

性能热点若在「多次 commit」，可在 `OFProcessGraph` 里改为同一 `MTLCommandBuffer` 多 encoder，而不必拆掉节点协议。

### 7.7 对比小结

```
灵活度/合成能力
        ▲
        │  全功能 Node Graph
        │  GPUImage 多 target
        │  Core Image 图
        │  ★ 本项目：门面 + DAG 调度 + 原地透传
        │  AVVideoComposition
        │  单体 processFrame
        └────────────────────────►  实时成本 / 实现量  （越右越重）
```

本项目选在「固定产品链路 + 实时可关节点 + 多宿主复用」这一点。优势不是图灵完备的合成器，而是：

- 比单体好拆、好比对、好比对原图
- 比 GPUImage 链少一次「关闭也过 FBO」
- 比 Core Image 容易接入 MediaPipe / 自研 kernel
- 比完整节点编辑器轻一个数量级，适合 iOS 12 直播预览

## 8. 约束与演进边界

这些不是实现细节，是架构取舍：

1. **执行模型是线性原地写**。要做「LUT 与漫画风并行再混合」，必须引入按边传递的中间纹理，不能只加一条边。
2. **像素池按门面实例隔离**。两套门面不再抢同一 `CVPixelBufferPool`，但仍不要同时 `inputFrame` 抢同一 GPU。相册用串行队列；直播与相册页面互斥。
3. **线程安全在图外**。图本身无锁。直播约定采集线程；相册约定 `processingQueue`。设置页改参数与 `process` 并发时，节点需自保（多数只写几个标量）。
4. **门面会变胖**。长期应避免把每个滑杆都变成 `tools.setXxx`。可按域拆成 `BeautyFacade` / `ColorFacade`，仍由 `OFAuxiliaryTools` 持有并构图。
5. **Landmarker 异步**。美颜形变用的是上一帧点，快速转头会有一帧滞后。这是实时性换精度，不要改成同步推理堵采集。
6. **剪辑（旋转/裁切/变速）不要进 DAG**。它们改坐标系和时间轴，应在 `inputFrame` 之前由会话层处理，否则关键点与导出时钟绑死在已变形帧上。

## 9. 和主文档的关系

- App 导航、相册会话、导出：[`architecture.md`](architecture.md)
- 滤镜在 OFFilterKit：主文档第 5 节；拓扑与节点表与本文第 3 节一致
- 相册剪辑规划：主文档第 8 节；剪辑层在本门面之外
