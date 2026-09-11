# 相册编辑模块架构

本文是相册编辑（`LiveStreaming/LiveStreaming/Album/`）的设计文档。应用级滤镜 DAG、直播采集见 [`../architecture.md`](../architecture.md)。

**本文解决什么：** 用户从系统相册点进一张图或一段视频之后，画幅、裁切、变速、滤镜预览、导出是怎么串起来的。读完应能回答：草稿存在哪、谁允许改它、源时间和播放轴差在哪、为什么几何不能做成滤镜节点。

交互图（打开 HTML，不必先读完本文）：

| 图 | 内容 |
|----|------|
| [`clip-architecture.html`](clip-architecture.html) | 画幅 / 裁切 / 变速写入草稿，时间线类型，Mapper 与导出 |
| [`clip-dataflow.html`](clip-dataflow.html) | `AlbumTimeMapper` 时钟契约（裁切与变速共用） |
| [`class-diagram.html`](class-diagram.html) | 类型关系 |
| [`scopes-p0.md`](scopes-p0.md) / [`scopes-p0.html`](scopes-p0.html) | 示波器 P0：直方图 / 波形旁路（已落地） |
| [`multi-clip.md`](multi-clip.md) / [`multi-clip-architecture.html`](multi-clip-architecture.html) | 多视频拼接与转场（规划；不引入美摄时间线） |

对照实现：阶段 1–4 已落地（含整段/分段变速）；阶段 5 截图未做；示波器 P0 已落地；多视频工程未做。

---

## 0. 五分钟心智模型

把编辑页想成三条平行管道，只在「当前这一帧」汇合：

```
                    ┌─ 滤镜参数 ──► OFAuxiliaryTools（处理图，原地改像素）
用户操作 ─┬─ 画幅 ──► document.geometry ──► AlbumGeometryKernel（CI，滤镜之前）
          └─ 裁切/变速 ► document.timeline ──► AlbumTimeMapper ──► Player / Exporter
```

- **滤镜**回答「像素怎么着色」，和直播共用 OFFilterKit，相册单独持有一份门面。
- **几何**回答「坐标系：朝向、旋转、翻转、自由角、比例」。必须在滤镜前做完，输出正放铺满，黑边不得进 MediaPipe。
- **时间线**回答「源媒体上保留哪些区间、每段几倍速」。时间一律是**源时间**；播放器和导出器按需映射到**无缺口播放轴**。

这不是 NLE：没有轨道层、没有独立速度层、没有持久化工程文件。会话结束文档即丢。Composition 只在「多段或非 1x」时出现，用来让播放轴连续。

建议读代码顺序：`AlbumEditDocument` → `AlbumTimeMapper` → `AlbumEditSession` → `AlbumEditorViewController` 的 `configureVideoPlayer` / 三个 Panel Delegate → `AlbumGeometryKernel` → `AlbumVideoExporter`。

---

## 1. 原则（以及为什么）

1. **草稿为真相。** 预览、导出、（规划中的）截图只读 `AlbumEditSession.document`（`AlbumEditDocument`）。滤镜参数不在文档内，只在 `OFAuxiliaryTools`。这样改 LUT 不必碰时间线；改入出点不必重跑整张滤镜图的参数对象。
2. **几何与时间线正交。** `AlbumGeometryEdit` 改坐标系；`AlbumTimelineEdit` 决定解哪一段源时间、倍速多少。二者都不是 `OFProcessGraph` 节点。处理图保持「对正放 BGRA 着色」，直播/相册滤镜实现仍是一份。
3. **几何在滤镜之前。** `AlbumGeometryKernel` 一次 CI 合成片源朝向与用户画幅，再 `inputFrame`。人脸检测、美颜都假设画面正放、无大块黑边。
4. **UI 不持有草稿引用。** 面板只持有值类型**本地副本**；经委托把新值交给 `AlbumEditorViewController`，由 VC 赋值 `session.document`。值类型保证 `present` 进去的是拷贝，改完必须交回，避免面板与会话各改一半。
5. **TimeMapper 无状态。** `AlbumTimeMapper` 是 `struct` 快照：`init(timeline:sourceDuration:)`。Player / Exporter 按需构造，不反向持有文档，也不缓存过期 Composition。
6. **不引入美摄时间线。** 不抄 `NvsTimeline` / `compileTimeline`。`AVMutableComposition` 只表达「播放轴无缺口」。单段且 1x 仍用原片 + 入出点，少一次合成、少一份时间戳误差。

另外两条工程约定：

- **方案 B：不复制滤镜。** GPU 全部走 `AlbumEditSession.processingQueue`；导出时 `isExporting` 丢弃预览帧，并 `teardown` Player，避免与 `AVAssetReader` 争用同一 `AVAsset`。
- **裁切与变速同一条时间线。** 只改 `AlbumTimelineSegment.speed`，不新增 SpeedRamp、不与剪辑层求交。空隙只由剪辑插入/删除产生。

---

## 2. 能力与分期

| 资源 | 画幅 | 剪辑 | 变速 | 截图 |
|------|------|------|------|------|
| 照片 | 90° / 翻转 / 自由角 / 比例（居中 cover） | 无 | 无 | 阶段 5：几何+滤镜静图 |
| 视频 | 同照片 | 首尾单段 / 多段保留 | 整段同一 speed，或分段各 speed | 静图；实况为播放头 ±1.5s **播放时间** |

| 阶段 | 内容 | 状态 |
|------|------|------|
| 1 | 文档 + 几何内核 + 照片预览/导出 | 已落地 |
| 2 | 视频并入几何；单段收尾 | 已落地（画幅无自由拖框，比例居中 cover） |
| 3 | 多段 Composition；预览/导出读合成轴 | 已落地 |
| 4 | 整段变速，再分段变速 | **已落地**（`AlbumSpeedPanelView` + Mapper `scaleTimeRange`） |
| 5 | 静图截图，再实况截图 | 未做 |

约束写在 `AlbumTimelineEdit`：

| 常量 | 值 | 原因 |
|------|-----|------|
| `minimumDuration` | 0.1s | 过短则 Reader / Player 起不来 |
| `maximumSegmentCount` | 6 | 条带手柄与列表放不下更多 |
| `minimumSpeed` / `maximumSpeed` | 0.25 / 4.0 | 夹紧非法或非有限 speed |
| `speedEpsilon` | 0.001 | 判断是否 1x，决定能否清空为「未剪辑」 |

---

## 3. 类型模型

全部为值类型（`struct`，`Equatable`），嵌在会话的一份草稿里，**不单独持久化**。突变方法返回新值，不原地改调用方未持有的引用。

```
AlbumEditDocument
  ├─ geometry: AlbumGeometryEdit
  │     quarterTurns          正交顺时针 90° 次数，对 4 取模
  │     flipHorizontal / flipVertical
  │     freeAngleDegrees      自由角（度）；内核 cover 放大后再裁回
  │     aspect: AlbumAspectMode   original | ratio(w,h)
  └─ timeline: AlbumTimelineEdit
        segments: [AlbumTimelineSegment]   // 0…6，有序不相交
              sourceStart: CMTime          // 源媒体时间
              sourceEnd:   CMTime
              speed:       Double          // 播放倍率，写入时夹紧
```

### 3.1 AlbumEditDocument

一份资源的剪辑草稿。`AlbumEditSession` 持有；**只有** `AlbumEditorViewController` 通过赋值字段更新。滤镜强度、LUT 选择等不在此。

### 3.2 AlbumGeometryEdit

用户画幅，与片源 `preferredTransform` **分开存**。内核按固定顺序合成（见 §5.1）。`isIdentity` 只表示用户没改画幅，视频仍可能要因轨朝向做一次 orient。

照片加载时 `AlbumMediaConverter` 已把 EXIF 朝向 bake 进预览/导出 buffer，几何内核对照片传 `preferredTransform = .identity`。视频 `VideoOutput` 出的是**编码朝向**像素，必须把轨 transform 传进内核。

### 3.3 AlbumTimelineEdit

保留段集合。**空 `segments` 表示整段保留且 speed=1**（未剪辑语义），不是「导出 0 秒」。

所有读取先走 `resolvedSegments(sourceDuration:)`：按起点排序、与已写入段截断重叠、夹紧到 `[0, duration]`、丢掉短于 0.1s 的段、夹紧 speed、最多 6 段。若结果为空则回退为整段 1x。

`applyingSegments` 写入时：仅当「一段、几乎覆盖片源（±0.05s）、且 speed≈1」才清空数组。整段 2x **必须留下一段**，否则变速会被当成未剪辑丢掉。

| 方法 | 谁调用 | 作用 |
|------|--------|------|
| `applyingSingleTrim` | 首尾模式 | 写成一段；尽量继承当前统一 speed |
| `applyingSegments` | 规范化入口 | 排序截断后写回 |
| `insertingSegment` | 多段空隙确认 | 整段未切时变成该区间；否则插入且禁止重叠 |
| `addingSegment` | （辅助） | 在最大空隙居中插约 1s |
| `removingSegment` | 删除按钮 | 删光 → 空文档（整段未切） |
| `splittingSegment` | 变速分段剪刀（能力位 `splitOnly`） | 一分为二，**继承**原段 speed |
| `applyingSpeed` | 变速面板 | `index == nil` 时当前所有保留段同一 speed |

条带 `AlbumTrimFilmstripCapability`：`none`（首尾无剪刀）、`gapInsert`（空隙确认插入）、`splitOnly`（段内切开、禁止插空隙）。剪辑多段用 `gapInsert`。变速分段面板目前同样传 `gapInsert`（与剪辑共用条带交互）；设计意图上分段变速更适合 `splitOnly`，以免变速面板改保留区间。

### 3.4 AlbumTimelineSegment

一条保留区间。时间一律是**源媒体时间**，不是成片播放时间。

- 段源时长 = `sourceEnd − sourceStart`
- 段播放时长 = 源时长 / `speed`
- 整段变速 = 当前所有保留段同一 `speed`
- 分段变速 = 切开（或已有多段）后各段 `speed` 可不同
- **不**新增独立速度层；删除空隙只由剪辑产生；变速新插的空隙段默认 1x

### 3.5 AlbumTimeMapper

```swift
init(timeline: AlbumTimelineEdit, sourceDuration: CMTime)
```

对 `resolvedSegments` 的只读视图。Player / Exporter 各构造一次，用完即丢。

| API | 语义 |
|-----|------|
| `playDuration` | Σ(段源时长 / speed) |
| `needsComposition` | 段数 ≥ 2 **或** 任一 `\|speed−1\| > ε` |
| `playTime(sourceTime:in:playOffset:)` | 源 PTS → 播放轴：`offset + (source − start) / speed` |
| `sourceTime(playTime:in:playOffset:)` | 逆映射：`start + (play − offset) × speed` |
| `makeComposition(from:)` | 按段 `insertTimeRange`，非 1x 再 `scaleTimeRange`；音视频同一倍率 |
| `exportSource` / `exportTimeRange` | Reader：合成轴 `[0, playDuration]`，或单段 1x 的源区间 |

`needsComposition == false` 时 `makeComposition` 返回 nil，调用方应绑原片。合成失败时 `exportSource` 回退原片。

---

## 4. 两套时钟

这是新人最容易写错的地方。文档和条带只认**源轴**；关掉面板后的预览和导出认**播放轴**。

```
源轴（片源 PTS）          播放轴（成片时间，从 0 连续）
[====保留====]  删除   [==保留 2x==]
     │                      │
     └─ Mapper 按段拼接并 /speed ──► [====][========]   ← 无缺口
```

| 场景 | 用哪根轴 |
|------|----------|
| `AlbumTimelineSegment`、条带滚动、剪刀、手柄 | 源时间 |
| 剪辑/变速面板打开时 `videoPlayer.scrub` | 源时间（Player 已改绑原片整段） |
| 面板关闭后 `configureVideoPlayer` | 单段 1x：原片入出点（仍是源时间）；否则 Composition 从 0 到 `playDuration` |
| 导出 Reader | 与上相同：`exportTimeRange()` |
| 规划中的实况截图 ±1.5s | **播放时间**，夹在 `[0, playDuration]` |

面板打开期间 **不要** 重建 Composition：条带是源轴，合成轴对不齐剪刀。`isTimelinePanelOpen` 挡住 `configureVideoPlayer`。`didChange` 只写文档并 seek；`didDismiss` 再按 Mapper 配 Player。

导出若已经在读 Composition，Writer 时间戳就是播放轴，**不得再乘 speed**。

---

## 5. 写入路径（UI 与草稿）

面板**不**引用 `session.document` 里的时间线/几何。

```
AlbumGeometryPanelView.geometry     ──didChange──► VC ──► session.document.geometry
AlbumTrimPanelView 本地 timeline    ──didChange──► VC ──► session.document.timeline
AlbumSpeedPanelView 本地 timeline   ──didChange──► VC ──► session.document.timeline
```

`AlbumEditorViewController`：

- 持有 `session`、`videoPlayer`、`geometryPanel`、`trimPanel`、`speedPanel`
- 是**唯一**把面板结果写进 `session.document` 的类型
- `configureVideoPlayer()`：`AlbumTimeMapper(...)` 决定绑 Composition 还是原片入出点；Player **不**接收 `AlbumTimelineEdit`
- 底部工具条：照片仅「画幅」；视频为「画幅 / 播放 / 剪辑 / 变速」。右上「设置」只绑滤镜

画幅 `didChange` 立刻重跑：照片从 `photoSourceBuffer` 走 session；视频 `refreshCurrentFrame`（几何在 GPU 队列上读最新 `document.geometry`）。

变速整段页可用 `AVPlayer.rate` **试听**；正式预览和导出走 Mapper / Composition。不要把试听 rate 当成导出契约。

---

## 6. 运行时分层

| 类型 | 种类 | 职责 |
|------|------|------|
| `AlbumEditorViewController` | class | 门面：持有会话/播放器/面板；写 document；构造 Mapper 配 Player；导出独占 UI |
| `AlbumGeometryPanelView` | class | 画幅交互；本地 `AlbumGeometryEdit`；委托提交 |
| `AlbumTrimPanelView` | class | 首尾/多段裁切；本地 `AlbumTimelineEdit`；委托提交 |
| `AlbumSpeedPanelView` | class | 整段/分段倍速；本地同一套 timeline；委托对齐 TrimPanel |
| `AlbumTrimFilmstripView` | class | 源轴条带；能力位决定剪刀 |
| `AlbumTrimThumbnailLoader` | class | `AVAssetImageGenerator` 按源时间抽小图；`generation` token 丢弃过期回调 |
| `AlbumEditSession` | class | 持有 document 与 tools；串行 GPU；导出独占 |
| `AlbumVideoPlayer` | class | `AVPlayer` + `VideoOutput` 出 BGRA；入出点循环；scrub 合并 pending seek |
| `AlbumGeometryKernel` | enum | 无实例；单帧 CI |
| `OFAuxiliaryTools` | class | 滤镜图；相册独立实例 |
| `SCGLView` | class | GLES 预览；相册 letterbox + `holdsLastFrame` |
| `AlbumVideoExporter` | enum | Reader → 几何 → 滤镜 → Writer；必须在 session 队列同步调用 |
| `AlbumTimeMapper` | struct | §3.5 |
| `AlbumMediaConverter` | enum | 尺寸、像素拷贝、朝向、Photos 加载 |

设计模式对照（便于和对外部件类比）：

| 模式 | 落点 |
|------|------|
| Facade | 编辑 VC |
| Session / 工作单元 | `AlbumEditSession` |
| Document / Value Object | `AlbumEditDocument` 及嵌套 struct |
| Snapshot Mapper | `AlbumTimeMapper` |
| Strategy | 条带 `capability` |
| Delegate | 面板 → VC；Player → VC |
| Namespace enum | Kernel / Converter / Exporter（无状态工具） |
| 逻辑独占 | `beginExport` / `endExport` + 停预览 |

### 6.1 几何内核顺序

`AlbumGeometryKernel.apply`（后台队列，不用 UIKit 绘图；复用静态 `CIContext`）：

1. 片源朝向（与 Converter 同一套 orientation 映射；对不齐则直接乘 `preferredTransform`）
2. 正交旋转（顺时针 90° × n；CI 坐标 y 向上，用负弧度）
3. 左右 / 上下翻转
4. 自由角：先转再 cover 放大，裁回旋转前尺寸，避免黑角
5. 比例：居中裁成目标宽高比
6. `extent` 原点归零后 render 到池里的 32BGRA

`outputPixelSize` 必须与上述裁切顺序一致，供 Writer 先定画布。用户几何为 identity 且轨已正放时，走 `copyPixelBuffer`，避免无谓 CI。

### 6.2 像素路径

视频预览（DisplayLink 在主线程取帧，处理进 GPU 队列）：

```
AVPlayerItemVideoOutput  32BGRA（编码朝向，尺寸按 naturalSize 缩放）
  → AlbumGeometryKernel.apply(document.geometry, preferredTransform)
  → tools.inputFrame
  → 主线程 SCGLView.inputFrame
```

照片预览/导出：几何（transform = identity）→ `inputFrame`。滤镜原地改 buffer，故预览始终从 `photoSourceBuffer` 经 Kernel 产出**新** buffer 再进图。

导出视频：几何 bake 进像素后 `writer.transform = identity`。目标尺寸 = 几何输出 → 长边 1920 → 偶数。音频 PCM → AAC。

分辨率：预览长边 = 屏 `nativeBounds` 长边；视频导出 1920；照片导出 4096。

### 6.3 播放器细节

- `VideoOutput` 必须按轨 `naturalSize` 要 buffer。若用 transform 后的竖屏尺寸，横图会被拉成竖图。
- 单段：`forwardPlaybackEndTime` + 循环回 `trimStart`（不是 0）。
- 多段/变速：Item 绑 Composition，播放轴无缺口，禁止在 DisplayLink 里逐帧跳过删除段。
- 拖动手柄：`scrub` 只保留最新 pending seek，避免连跳被取消后松手才出一帧。
- 暂停拖出点时不要把 `forwardPlaybackEndTime` 写到拖动中的 end 上，否则顶在出点取不到帧。

---

## 7. 剪辑 UI（已落地）

| 模式 | 行为 |
|------|------|
| 首尾 | 单段入出点；可平移整段窗口；切到此模式若已有多段，收成「首段入点～末段出点」 |
| 多段 | 源轴可滚动 + 居中剪刀；空隙确认插入；段内显示手柄；列表点选/删除 |

条带抽帧：`AVAssetImageGenerator`，源文件时间，格子取窗口**中点**（避免第一格永远是黑场片头）。拖动手柄不重抽。片段列表另有 loader，避免和条带 `cancel` 互踢。

---

## 8. 变速（已落地）

与剪辑**同一条** `AlbumTimelineEdit`，只改 `AlbumTimelineSegment.speed`。

| | 整段剪辑 | 分段剪辑 | 整段变速 | 分段变速 |
|--|--|--|--|--|
| UI | 首尾手柄 | 源轴 + 剪刀 | SpeedPanel 滑杆/档位 | 「分段」复用条带，选中段改 speed |
| 文档 | 单段入出点 | 多段保留 | 各段 speed 相同 | 各段 speed 可不同 |
| 面板打开 | 原片源轴 | 原片源轴 | 原片 **1x** 源轴 | 同左 |
| 关闭后预览 | 原片+入出点 | Composition（1x 多段） | `needsComposition` 则 scale | Composition + `scaleTimeRange` |

文档语义（已实现）：

- `resolvedSegments` 保留并夹紧 speed
- `applyingSegments` 仅「整段且 1x」清空
- `splittingSegment` / 拖动手柄继承 speed；空隙新段默认 1
- `isImplicitFullRange` 要求 `speed≈1`

**不采用：** 独立速度层与剪辑层求交；单段只改 `AVPlayer.rate`、导出另写 PTS。

---

## 9. 截图（阶段 5，未做）

吃合成结果，不抓 `SCGLView`。与导出共用 GPU 独占队列。静图按导出分辨率从该时刻源帧重跑几何+滤镜。实况：封面=该静图；视频=播放头 ±1.5s **播放时间**，夹在 `[0, playDuration]`。

---

## 10. 设置 UI

底部「设置」只绑 `session.tools`（`OFSettingsController(context: .album)`），隐藏摄像头切换与转场。画幅 / 剪辑 / 变速入口并列，不进设置栈。`onPipelineChanged`：照片从 source 重跑；视频 `refreshCurrentFrame`。

---

## 11. 文件对照

| 文件 | 读它之前先知道 |
|------|----------------|
| `AlbumEditDocument.swift` | 草稿与时间线规范化 |
| `AlbumTimeMapper.swift` | 两套时钟、Composition |
| `AlbumEditSession.swift` | GPU 队列、导出独占、几何后再滤镜 |
| `AlbumEditorViewController.swift` | 谁写 document、面板开关与 Player 换绑 |
| `AlbumGeometryKernel.swift` | 单帧 CI 顺序 |
| `AlbumMediaConverter.swift` | 加载、拷贝、偶数尺寸 |
| `AlbumVideoPlayer.swift` | 出帧、循环、scrub |
| `AlbumVideoExporter.swift` | 离线读写 |
| `AlbumTrimPanelView.swift` / `AlbumSpeedPanelView.swift` | 本地副本 + 委托 |
| `AlbumTrimFilmstripView.swift` | 源轴交互 |
| `AlbumTrimThumbnailLoader.swift` | 抽帧与过期回调 |
| `AlbumGeometryPanelView.swift` | 画幅控件 |
| `AlbumScopeAnalyzer.swift` | 滤镜后旁路累加 |
| `AlbumScopePanelView.swift` | 预览浮层直方图 / 波形 |

---

## 12. 常见坑

- 改滤镜却在已处理的照片 buffer 上再 `inputFrame` → 效果叠两次。必须从 `photoSourceBuffer` 重跑。
- 面板打开时按播放轴 seek → 和剪刀对不齐。打开期间绑原片、用源时间。
- 导出已读 Composition 再按 speed 改 PTS → 速度乘两次。
- 自由角只旋转不 cover → 黑三角进 FaceLandmarker。
- Writer 仍设 `preferredTransform`、像素未 bake → 和预览朝向不一致。
- `VideoOutput` 按竖屏显示尺寸要帧 → 横源被拉伸。
- 导出时 Player 还握着同一 `AVAsset` → Reader 失败或卡死；先 `teardown`。
- 整段 2x 写成空 `segments` → 下次打开变回 1x。
- 后台用 UIKit 绘图缩放 → 线程警告/随机坏图；走 Converter 的 CG 路径。
- `inputFrame` 在 `SCGLView.start()` 之前 → 帧被丢掉；静图要在 `viewDidAppear` 之后再送。

---

## 13. 风险

- 自由角必须 cover，否则黑边进人脸检测
- 分段变速 + AAC 时间戳累积（合成轴缩放后音画对齐要靠同一 `scaleTimeRange`）
- iOS 12 实况写入需 JPEG/MOV 配对 identifier，失败应降级为静图+短视频（截图阶段）
