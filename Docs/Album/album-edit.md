# 相册编辑模块架构

本文是相册编辑（`LiveStreaming/LiveStreaming/Album/`）的设计文档。应用级滤镜 DAG、直播采集见 [`../architecture.md`](../architecture.md)。交互图：

| 图 | 内容 |
|----|------|
| [`clip-architecture.html`](clip-architecture.html) | 剪辑架构：画幅 / 裁切 / 变速写入草稿，时间线类型，Mapper 与导出 |
| [`clip-dataflow.html`](clip-dataflow.html) | `AlbumTimeMapper` 时钟契约（裁切与变速共用） |

对照实现：阶段 1–3 已落地；阶段 4 变速仅方案；阶段 5 截图未做。

## 1. 原则

1. **草稿为真相**。预览、导出、截图只读 `AlbumEditSession.document`（`AlbumEditDocument`）。滤镜参数不在文档内，只在 `OFAuxiliaryTools`。
2. **几何与时间线正交**。`AlbumGeometryEdit` 改坐标系；`AlbumTimelineEdit` 决定解哪一段源时间。二者都不是 `OFProcessGraph` 节点。
3. **几何在滤镜之前**。`AlbumGeometryKernel` 一次 CI 合成朝向与用户画幅，输出正放铺满画面，再 `inputFrame`。黑边不得进 MediaPipe。
4. **UI 不持有草稿引用**。面板只持有值类型**本地副本**；经委托把新值交给 `AlbumEditorViewController`，由 VC 赋值 `session.document`。
5. **TimeMapper 无状态**。`AlbumTimeMapper` 是 `struct` 快照：`init(timeline:sourceDuration:)`。Player / Exporter 按需构造，不反向持有文档。
6. **不引入美摄时间线**。不抄 `NvsTimeline` / `compileTimeline`；Composition 只表达「播放轴无缺口」。

## 2. 能力与分期

| 资源 | 画幅 | 剪辑 | 变速 | 截图 |
|------|------|------|------|------|
| 照片 | 90° / 翻转 / 自由角 / 比例（居中 cover） | 无 | 无 | 阶段 5：几何+滤镜静图 |
| 视频 | 同照片 | 单段收尾（阶段 2）/ 多段（阶段 3） | 整段再分段（阶段 4） | 静图；实况为播放头 ±1.5s **播放时间** |

| 阶段 | 内容 | 状态 |
|------|------|------|
| 1 | 文档 + 几何内核 + 照片预览/导出 | 已落地 |
| 2 | 视频并入几何；单段收尾 | 已落地（裁切拖框未做） |
| 3 | 多段 Composition；预览/导出读合成轴 | 已落地 |
| 4 | 整段变速，再分段变速 | 方案（本文 §7） |
| 5 | 静图截图，再实况截图 | 未做 |

约束：最短段 `AlbumTimelineEdit.minimumDuration` = 0.1s；最多 `maximumSegmentCount` = 6 段。`speed > 0`，建议夹紧 `[0.25, 4]`。

## 3. 类型模型

全部为值类型（`struct`），嵌在会话的一份草稿里，不单独持久化。

```
AlbumEditDocument
  ├─ geometry: AlbumGeometryEdit
  │     quarterTurns, flipHorizontal, flipVertical
  │     freeAngleDegrees, aspect: AlbumAspectMode
  └─ timeline: AlbumTimelineEdit
        segments: [AlbumTimelineSegment]   // 0…6，有序不相交
              sourceStart: CMTime          // 源媒体时间
              sourceEnd:   CMTime
              speed:       Double          // 播放倍率，必须 > 0
```

### 3.1 AlbumEditDocument

一份资源的剪辑草稿。`AlbumEditSession` 持有；VC 只通过赋值字段更新。

### 3.2 AlbumGeometryEdit

用户画幅，与片源 `preferredTransform` 分开存，由 `AlbumGeometryKernel` 按固定顺序合成：片源朝向 → 正交旋转 + 翻转 → 自由角（cover 放大）→ 按比例居中裁切。

### 3.3 AlbumTimelineEdit

保留段集合。**空 `segments` 表示整段保留且 speed=1**（未剪辑语义）。

阶段 3 的 `resolvedSegments` **把 speed 写死为 1**，阶段 4 必须改为保留并夹紧 speed。`applyingSegments` 仅当「一段、几乎覆盖片源、且 speed≈1」时清空；否则整段 2x 会被当成未剪辑丢掉。

突变（均返回新值，不原地改共享引用）：

| 方法 | 作用 |
|------|------|
| `applyingSingleTrim` / `applyingSegments` | 写入保留段 |
| `insertingSegment` / `addingSegment` | 空隙插入（仅剪辑） |
| `removingSegment` | 删除；删光变空文档 |
| `splittingSegment` | 源时间一分为二；阶段 4 须**继承**原段 speed |

### 3.4 AlbumTimelineSegment

一条保留区间。时间一律是**源媒体时间**，不是成片播放时间。

- 段源时长 = `sourceEnd − sourceStart`
- 段播放时长 = 源时长 / `speed`（阶段 3 实现为 1）
- 整段变速 = 当前所有保留段同一 `speed`
- 分段变速 = `splittingSegment` 后各段 `speed` 可不同
- **不**新增独立 SpeedRamp / 速度层；删除空隙只由剪辑产生

### 3.5 AlbumTimeMapper

```swift
init(timeline: AlbumTimelineEdit, sourceDuration: CMTime)
```

对 `resolvedSegments` 的只读视图。职责：

| API | 语义 |
|-----|------|
| `playDuration` | Σ 段播放时长；阶段 4 起为 Σ(源时长/speed) |
| `needsComposition` | 阶段 3：`count ≥ 2`；阶段 4：再或任一 `\|speed−1\| > ε` |
| `playTime(sourceTime:in:playOffset:)` | 源 PTS → 播放轴（阶段 4 须除以 speed） |
| `makeComposition(from:)` | `insertTimeRange`；阶段 4 后再 `scaleTimeRange` |
| `exportSource` / `exportTimeRange` | Reader 用：合成轴 `[0, playDuration]` 或单段源区间 |

逆映射（阶段 4 补齐）：`source = start + (play − playOffset) × speed`。

## 4. 写入路径（UI 与草稿）

面板**不**引用 `session.document` 里的时间线/几何。值类型决定「present 进去的是拷贝，改完必须交回」。

```
AlbumGeometryPanelView.geometry          ──didChange──► VC ──► session.document.geometry
AlbumTrimPanelView 本地 timeline         ──didChange──► VC ──► session.document.timeline
AlbumSpeedPanelView 本地 timeline（拟）  ──didChange──► VC ──► session.document.timeline
```

`AlbumEditorViewController`：

- 持有 `session`、`videoPlayer`、`geometryPanel`、`trimPanel`（及拟新增 `speedPanel`）
- 是**唯一**把面板结果写进 `session.document` 的类型
- `configureVideoPlayer()`：用 `AlbumTimeMapper(timeline: session.document.timeline, …)` 决定绑 Composition 还是原片入出点；Player **不**接收 `AlbumTimelineEdit`

剪辑/变速面板打开期间：Player 改绑**原片整段**（条带是源轴）。`didChange` 只写文档并 `scrub` 源时间，不重建 Composition。`didDismiss` 后再 `configureVideoPlayer()`。

## 5. 运行时分层

| 类型 | 种类 | 职责 |
|------|------|------|
| `AlbumEditorViewController` | class | 门面：持有会话/播放器/面板；写 document；构造 Mapper 配 Player |
| `AlbumGeometryPanelView` | class | 画幅交互；本地 `AlbumGeometryEdit`；委托提交 |
| `AlbumTrimPanelView` | class | 首尾/多段裁切；本地 `AlbumTimelineEdit`；委托提交 |
| `AlbumSpeedPanelView` | class（拟） | 整段/分段倍速；本地 `AlbumTimelineEdit`；委托提交 |
| `AlbumTrimFilmstripView` | class | 源轴条带；剪辑可插空隙；变速模式只 `splittingSegment` |
| `AlbumEditSession` | class | 持有 `document` 与 `OFAuxiliaryTools`；`processingQueue` 串行 GPU；导出独占 |
| `AlbumVideoPlayer` | class | `AVPlayer` + `VideoOutput` 出 BGRA；单段入出点循环；多段播 Composition |
| `AlbumGeometryKernel` | enum | 单帧 CI：朝向 + 用户画幅 |
| `OFAuxiliaryTools` | class | 滤镜图；相册独立实例 |
| `SCGLView` | class | GLES 预览；只 letterbox |
| `AlbumVideoExporter` | enum | Reader → 几何 → 滤镜 → Writer；在 session 队列同步调用 |
| `AlbumTimeMapper` | struct | 见 §3.5 |
| `AlbumMediaConverter` | enum | 尺寸、像素拷贝、UIImage |

像素路径（视频预览）：

```
VideoOutput BGRA
  → GeometryKernel.apply(document.geometry, preferredTransform)
  → tools.inputFrame
  → 主线程 SCGLView
```

导出视频：几何 bake 进像素后 `writer.transform = identity`。预览长边 = 屏 `nativeBounds` 长边；视频导出长边 1920（偶数）；照片导出长边 4096。

## 6. 剪辑（已落地）

| 模式 | 行为 |
|------|------|
| 首尾 | 单段入出点；切到此模式若已有多段，收成「首段入点～末段出点」 |
| 多段 | 源轴可滚动 + 居中剪刀；空隙确认插入；段内显示手柄；列表点选/删除 |

条带抽帧：`AVAssetImageGenerator`，源文件时间。拖动手柄不重抽。

## 7. 变速（阶段 4 方案）

与剪辑**同一条** `AlbumTimelineEdit`，只改 `AlbumTimelineSegment.speed`。

| | 整段剪辑 | 分段剪辑 | 整段变速 | 分段变速 |
|--|--|--|--|--|
| UI | 首尾手柄 | 源轴 + 剪刀 | SpeedPanel「整段」滑杆/档位 | 「分段」复用条带，选中段改 speed |
| 文档 | 单段入出点 | 多段保留 | 各段 speed 相同 | 各段 speed 可不同 |
| 面板打开 | 原片源轴 | 原片源轴 | 原片 **1x** 源轴 | 同左 |
| 关闭后预览 | 原片+入出点 | Composition 1x | 见 needsComposition | Composition + `scaleTimeRange` |

文档语义（相对阶段 3 必须改）：

- `resolvedSegments` 保留 speed
- `applyingSegments` 仅「整段且 1x」清空
- `splittingSegment` / 拖动手柄继承 speed；空隙新段默认 1
- `isImplicitFullRange` 增加 `speed≈1`

`needsComposition = 段数≥2 \|\| 任一非 1x`。单段 1x 仍走原片 `CMTimeRange`。合成：`insertTimeRange` 后按 `1/speed` `scaleTimeRange`；音视频同一缩放（第一期变调）。导出若已读合成轴，Reader/Writer **不得再乘 speed**。

UI：底部工具条增加「变速」。`AlbumSpeedPanelView` 委托对齐 TrimPanel。分段页禁用空隙插入。`AVPlayer.rate` 仅可作整段页试听，正式预览/导出走 Mapper。

**不采用**：独立速度层与剪辑层求交；单段只改 `rate`、导出另写 PTS。

## 8. 截图（阶段 5）

吃合成结果，不抓 `SCGLView`。与导出共用 GPU 独占队列。静图按导出分辨率从该时刻源帧重跑几何+滤镜。实况：封面=该静图；视频=播放头 ±1.5s **播放时间**，夹在 `[0, playDuration]`。

## 9. 设置 UI

底部「设置」只绑 `session.tools`（`OFSettingsController(context: .album)`）。画幅 / 剪辑 / 变速入口并列，不进设置栈。`onPipelineChanged`：照片从 source 重跑；视频 `refreshCurrentFrame`。

## 10. 风险

- 自由角必须 cover，否则黑边进人脸检测
- 分段变速 + AAC 时间戳累积
- iOS 12 实况写入需 JPEG/MOV 配对 identifier，失败降级为静图+短视频
