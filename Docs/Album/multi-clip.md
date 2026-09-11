# 多视频剪辑与转场

本文规划「两段（或多段）视频接到一条播放轴上，接缝可加转场」。单资源画幅 / 裁切 / 变速仍以 [`album-edit.md`](album-edit.md) 为准；本文只回答：**工程比单片多了什么、时钟怎么扩、像素在哪混、为什么不接美摄 SDK。**

交互图：[`multi-clip-architecture.html`](multi-clip-architecture.html)。

对照实现：**阶段 6a / 6b 已落地**；**阶段 7 淡入 / 闪黑 / 闪白已落地**（预览双 Player + 导出双 Reader）。`push` 未做。

---

## 0. 结论

**美摄 Streaming SDK 有完整的多段拼接与转场。** iOS / Android / Web 同一套模型：`NvsTimeline` → `NvsVideoTrack.appendClip` → 相邻 clip 无间隙时 `setBuiltinTransition`。内置转场包括 Fade、Turning、Swap、Stretch In、Page Curl、Lens Flare、Star、Dip To Black / White、Push To Right / Top、Upper Left Into；另有 `.videotransition` 素材包和 `setCustomVideoTransition`。导出走 `compileTimeline`。

**本仓库不引入美摄时间线。** 现有原则已经写明：相册是「草稿 + `AlbumTimeMapper` + 几何内核 + OFFilterKit」，不是 `NvsTimeline`。多段拼接应把 **单资源文档嵌进工程**，在工程播放轴上做重叠与混叠，预览/导出仍出 32BGRA 再进现有滤镜图。

| 能力 | 美摄 | 本仓库现状 | 规划 |
|------|------|------------|------|
| 多文件接到一条轴 | `appendClip` 顺序延展轨道 | 一个 `PHAsset`；`AlbumTimeMapper` 只拼**同一** `AVAsset` 的保留段 | `AlbumProject.clips` 有序拼接 |
| 接缝转场 | 轨道级 `NvsVideoTransition`，默认 Fade | `fade` / 闪黑 / 闪白已落地；`push` 未做 | 接缝值类型 + 双路解码 + 画布混叠 |
| 画中画 / 多轨 | 多条 `NvsVideoTrack` | 无 | **不做**（P0–P2 单视频轨） |
| 主题 / 贴纸 / 字幕包 | 扩展包 | 无 | **不做** |
| 滤镜 | 美摄 VideoFx | `OFAuxiliaryTools`（工程级一份） | 混叠**之后**仍走这一份，不接美摄 Fx |

---

## 1. 美摄能力（对照，不接入）

官方模型（iOS 头文件 `NvsVideoTrack.h`、教程 [MeiCam SDK For iOS](https://wap.meishesdk.com/ios/doc_en/html/content/Tutorial_8md.html)、特效名 [FxNameList](https://www.meishesdk.com/ios/doc_en/html/content/FxNameList_8md.html)）：

```
NvsStreamingContext
  └─ NvsTimeline          // 画布分辨率 + fps + 音频采样
       ├─ NvsVideoTrack   // append / insert / addClip；索引从 0
       │    ├─ NvsVideoClip     // filePath 或相册 localIdentifier；trimIn/trimOut 微秒
       │    └─ NvsVideoTransition  // 建在 clip[i] 与 clip[i+1] 之间
       └─ NvsAudioTrack   // 可独立；音频转场对称
```

要点：

1. **拼接是轨道语义，不是文件 concat。** `appendClip:` 把下一段接到轨道尾；`appendClip:trimIn:trimOut:` 可裁入出点。图片当 clip 时用 trim 表达「静帧时长」。
2. **转场只能加在相邻且无间隙的两段之间。** 有 gap 不能设转场。`setBuiltinTransition:srcClipIndex:withName:` 作用在「该索引 clip 的出点」。空字符串删除转场。
3. **时长会重叠。** 转场持续时间从两侧各「吃掉」一段重叠；工程总时长 &lt; 各 clip 播放时长之和。`NvsVideoTransition.setVideoTransitionDuration` 可改。
4. **自定义转场**走 `setCustomVideoTransition:withCustomRender:`，等于把 GPU 混叠让给宿主。若接美摄只为了自定义渲染，等于买一套引擎再把像素路径绕回 OFFilterKit，双倍复杂度。
5. **授权与体积。** Streaming SDK 是商业库；主题/转场包需商务素材。本 App 滤镜已在 OFFilterKit，再嵌一套 Live Window 会与 `SCGLView` / Metal 门面争预览。

若将来产品强制「美摄同款转场包」，唯一可接受的接法是：**草稿仍是 `AlbumProject`，只在导出或预览适配层把值编译成 `NvsTimeline`**，UI 与几何内核不依赖 `Nvs*` 类型。P0–P2 **不走这条路**。

---

## 2. 现状缺口

当前会话是 **1 资源 = 1 文档**：

```
AlbumEditorViewController.init(asset: PHAsset)
  → AlbumEditDocument { geometry, timeline }
  → AlbumTimeMapper(timeline, sourceDuration)  // 单一 AVAsset
```

`needsComposition` 只处理「同一文件的多保留段 / 变速」。两个 `.mp4` 接在一起、接缝淡入淡出，现有类型表达不了：

- 没有第二份 `AVAsset` / `PHAsset`
- 没有「接缝」对象
- Player 只有一路 `AVPlayerItemVideoOutput`
- Exporter 只有一个 `exportSource`

单文件多段硬切 **继续用** 现有 `AlbumTimelineEdit`；工程级多文件是上一层。

---

## 3. 目标心智模型

把编辑页想成 **工程轴套着若干单片草稿**：

```
用户选 N 个视频
  → AlbumProject.clips[i] = 现有 AlbumEditDocument（各片自己的画幅/裁切/变速）
  → clips[i] 与 clips[i+1] 之间 = AlbumTransition（cut 或有时长的重叠）
  → AlbumProjectMapper 把「每片源轴」映到「无缺口工程播放轴」
  → 每一帧：解 1 路（硬切）或 2 路（转场重叠）→ 各做几何 → 混叠 → OFAuxiliaryTools
```

三条不变：

1. **草稿为真相。** 工程与各 clip 文档都是值类型；VC 唯一写入 `session`。
2. **几何在滤镜之前，且按 clip。** 不能先在 `AVMutableComposition` 里混成一路再套一份画幅，否则第二段的旋转/比例会错。
3. **滤镜仍是工程级一份。** 设置页 LUT/美颜与现在一样作用在成片像素上，不做每 clip 一份 `OFAuxiliaryTools`（需要时再开阶段）。

单资源编辑是 `clips.count == 1` 的退化：Mapper / Player / Exporter 行为与今天一致。

---

## 4. 类型模型（规划）

全部 `struct` + `Equatable`，嵌在 `AlbumEditSession`，**不持久化**。

```
AlbumProject
  ├─ canvas: AlbumProjectCanvas          // 成片画布；默认取 clips[0] 几何后尺寸
  ├─ clips: [AlbumProjectClip]           // 1…6，有序
  └─ transitions: [AlbumTransition]      // count == max(0, clips.count - 1)

AlbumProjectClip
  ├─ localIdentifier: String             // PHAsset.localIdentifier
  ├─ mediaType: photo | video
  └─ document: AlbumEditDocument         // 复用现有 geometry + timeline

AlbumTransition
  ├─ kind: cut | fade | dipToBlack | dipToWhite | push(direction)
  └─ duration: CMTime                    // cut 必须 0；其余夹紧

AlbumProjectCanvas
  └─ size: CGSize                        // 像素；各 clip 几何输出 cover/letterbox 进此画布
```

### 4.1 约束

| 常量 | 建议值 | 原因 |
|------|--------|------|
| `maximumClipCount` | 6 | 与单片 `maximumSegmentCount` 同量级，条带放得下 |
| `minimumClipPlayDuration` | 0.1s | 与单段下限一致 |
| `minimumTransition` | 0.1s（非 cut） | 短于一帧无意义 |
| `maximumTransition` | min(0.8s, 两侧 clip 播放时长的 40%) | 避免一段被转场吃光 |

写入时规范化：

- `transitions.count` 与接缝数对齐；增删 clip 时插入/删除对应 `cut`
- `duration` 超过任一侧可重叠预算则夹紧
- 照片 clip：P2 再做；P0 只允许 `mediaType == video`

### 4.2 与美摄字段对照（便于读文档，不是 API）

| 美摄 | 本模型 |
|------|--------|
| `NvsVideoClip` + trimIn/Out | `AlbumProjectClip.document.timeline`（源 CMTime + speed） |
| `NvsVideoTrack` 顺序 | `clips` 数组序 |
| `setBuiltinTransition(i, name)` | `transitions[i].kind` |
| `setVideoTransitionDuration` | `transitions[i].duration` |
| Timeline 分辨率 | `AlbumProjectCanvas` |
| `compileTimeline` | `AlbumVideoExporter` 读工程轴 |

速度、画幅仍在 clip 文档里，不把美摄 clip 级 VideoFx 映射过来。

---

## 5. 三套时钟

单片已经有「源轴 / 播放轴」。工程再加一根 **工程轴**。

```
clip0 源轴 --TimeMapper--> clip0 播放轴 [========]
clip1 源轴 --TimeMapper--> clip1 播放轴          [========]
转场重叠 duration T 时：两段在工程轴上交叠 T

工程轴:  [======重叠 T======][=======]
         clip0            clip1
playDuration = Σ clip.playDuration − Σ overlap
```

`AlbumProjectMapper`（无状态 struct）：

| API | 语义 |
|-----|------|
| `playDuration` | 上式 |
| `contributions(at playTime)` | 1 或 2 条：`clipIndex` + 该 clip 的 **clip 播放时间** + 转场进度 `t∈[0,1]` |
| `sourceTime(clipIndex:clipPlayTime:)` | 委托该 clip 的 `AlbumTimeMapper` |
| `needsDualDecode(at:)` | 当前是否落在某段 overlap |

面板打开时：

- **剪辑/变速某 clip**：该条带仍是该 clip 的**源轴**（现契约不变）；工程 Player 不要在此时绑「已重叠的工程 Composition」。
- **转场面板**：条带切到**工程轴**，只显示接缝窗口。

导出 Reader 的时间戳一律是工程轴，**不得**再乘 clip speed（speed 已在 clip Mapper 里）。

硬切（全部 `kind == .cut`）：overlap=0，工程轴等于各 clip 播放轴首尾相接。可用 **一个** `AVMutableComposition` 顺序 `insertTimeRange` 多份 `AVAsset`，Player 仍一路输出；几何按 `contributions` 选当前 clip 的 `document.geometry`。

---

## 6. 像素路径

### 6.1 为什么不用「合成后再几何」

`AVMutableComposition` + `AVVideoComposition` 能在系统里做淡入淡出，但输出已是一路像素。现有 `AlbumGeometryKernel` 是 **每 clip 一份** 朝向/旋转/比例。两段比例不同时，必须先各自几何到 `AlbumProjectCanvas`，再混叠。

因此转场混叠放在几何之后、滤镜之前：

```
解码 clip A 当前源帧 ──► GeometryKernel(A) ──► canvas
解码 clip B 当前源帧 ──► GeometryKernel(B) ──► canvas
                         └─ overlap 时 AlbumTransitionKernel(A,B,t,kind)
                         └─ 硬切时只取一路
                                    │
                                    ▼
                           OFAuxiliaryTools.inputFrame
                                    │
                                    ▼
                              SCGLView / Writer
```

### 6.2 预览解码

| 阶段 | 策略 |
|------|------|
| P0 硬切 | 一路 `AlbumVideoPlayer` 绑多 asset Composition；`contributions` 恒为 1 |
| P1 淡入淡出 | 主 Player + **副 Player**（仅 overlap 前后预热 incoming clip）；DisplayLink 上取 1 或 2 个 BGRA |
| 不采用 | 把混叠交给 `AVVideoCompositing` 再送滤镜（会丢掉 per-clip 几何） |

副 Player 只在 `needsDualDecode` 为真时 `play`；离开 overlap 立即 pause，避免双倍解码常开。

### 6.3 导出

`AlbumVideoExporter` 按工程轴推进。硬切：可仍用一个 `AVAssetReader` 读顺序 Composition，但每帧查 `clipIndex` 换几何。有转场：overlap 区间需要第二路 Reader（或随机访问 `AVAssetReader` 起止点切段）。两路都经几何再 `AlbumTransitionKernel`，然后 `inputFrame`，Writer PTS = 工程时间。

`isExporting` 仍停预览、独占 `processingQueue`。

### 6.4 转场内核

`AlbumTransitionKernel`：无实例 enum，输入两张已贴合 canvas 的 32BGRA + `t` + `kind`。

| kind | 算法（P1/P2） |
|------|----------------|
| `cut` | 不调用；Mapper 不会给双路 |
| `fade` | `mix = A*(1-t) + B*t` |
| `dipToBlack` / `dipToWhite` | t&lt;0.5 时 A→纯色，否则纯色→B |
| `push` | 按方向平移两路（P2） |

实现放在 OFFilterKit Metal compute（与现有 Auxiliary kernel 一样走 `OFFilterContext`），避免在 CI 与滤镜图之间再拷一次。音频：P1 用 `AVMutableAudioMix` 在 overlap 做对称音量斜坡；两路都无音则静音。

P0 **不**做 Page Curl / Lens Flare 等美摄内置特效；那些依赖网格与素材包，与「自研混叠」成本不对称。若产品点名某几个，再单独立项做 shader，而不是链美摄包。

### 6.5 不同分辨率如何接到同一画布

两个文件不能按编码尺寸直接 `concat`。H.264 序列参数集（SPS）里宽高是一条码流一份；`AVMutableComposition` 把 4K 轨和 1080p 轨插进同一 composition，**解码出来仍是各自的 `naturalSize`**，Writer / 滤镜图却只能吃一种输出尺寸。拼接的本质是：**先定工程画布，每帧解完后贴合到这块画布，再写同一份 mp4。**

先算「显示尺寸」，再贴合。竖拍 `1920×1080` + `preferredTransform` 旋转 90°，显示是 `1080×1920`，不要拿编码宽高去比。

```
clip A 解码 BGRA（编码朝向）
  → GeometryKernel(A.geometry, A.preferredTransform)   // 正放、用户画幅
  → fit(canvas)                                         // cover 或 letterbox
clip B 同上
  → 硬切：只取当前 clip 的 canvas 帧
  → 转场：两路都已是 canvas 尺寸，才能 mix
  → OFAuxiliaryTools → Writer（canvas，长边再夹到导出上限、偶数）
```

**画布从哪来（P0）：** `AlbumProjectCanvas.size` = clip0 几何输出尺寸（`AlbumGeometryKernel.outputPixelSize`）。clip1 不改工程宽高，只往这块布上贴。用户改 clip0 比例时同步 canvas；改 clip1 比例只影响它自己被 cover 时裁掉哪一圈。

**贴合策略（P0 用 cover，与现比例裁切一致）：**

| 策略 | 行为 | 何时用 |
|------|------|--------|
| **cover（P0）** | 等比放大铺满 canvas，裁掉多出来的边 | 成片无黑边，滤镜/人脸不吃到黑边 |
| letterbox | 等比缩小完整放入，两侧或上下填色 | 以后若产品要「看全片、允许黑边」再开；填色不要进 MediaPipe 前的默认路径 |
| stretch | 非等比拉满 | **不用**，人物会变形 |

cover 计算（已几何、已正放的 clip 输出 `srcW×srcH`，画布 `dstW×dstH`）：

```
scale = max(dstW/srcW, dstH/srcH)
drawW = srcW * scale
drawH = srcH * scale
origin = ((dstW - drawW)/2, (dstH - drawH)/2)   // 居中，超出部分裁掉
```

落到偶数像素，与现导出「长边 1920、宽高偶数」对齐：canvas 先按 clip0 几何算，再 `AlbumMediaConverter` 那套导出缩放，**两段共用这一次缩放**，不要每段先缩到 1920 再拼（否则 4K+1080 会和 1080+4K 清晰度策略不一致）。预览仍按屏长边缩，但是 **同一 canvas 宽高比**。

**例子：** clip0 横屏 3840×2160（16:9），clip1 竖屏显示 1080×1920（9:16）。

1. canvas = clip0 几何后，例如仍 16:9（再按导出夹到 1920×1080）。
2. clip0 cover 到 1920×1080：几乎铺满（已是同一比例则只缩放）。
3. clip1 9:16 cover 进 16:9：按高度撑满 1080，宽度放大后左右裁掉，成片始终 1920×1080。
4. 硬切接缝处尺寸不变，Player / Writer 不必换 session。

**不要做的：**

- 在 `AVMutableCompositionTrack` 上指望系统自动统一分辨率。Composition 只负责时间轴；像素尺寸以几何+fit 为准。
- 用 clip1 的 `naturalSize` 去建 Writer，播到第二段再改 `AVAssetWriter` 尺寸（写不了）。
- 两段都 `copyPixelBuffer` 跳过几何：朝向不同时第二段会横竖颠倒，且尺寸对不上池。

转场比硬切更需要这张画布：fade 是逐像素 `A*(1-t)+B*t`，两张 buffer 宽高必须相同。

---

## 7. UI 与写入

```
主编辑页底部「拼接」（对齐「剪辑」）
  → AlbumJoinPanelView 二级卡片
       ├─ 横向片段格 + 末尾「添加」→ 再 push AlbumViewController 只选视频
       ├─ 删除当前段（至少留一段）
       └─ 接缝：硬切 / 淡入 / 闪黑 / 闪白 + 重叠时长（关闭面板后播放可预览；导出同样混叠）
```

- 增删段、转场都在二级页，主页不再放 clip 切换器。
- 面板仍只持有值拷贝，经委托回 VC。
- 画布：用户改 clip0 比例时，可选择「同步工程 canvas」或「只改该 clip、导出时 cover」。P0：**工程 canvas 锁定为 clip0 几何输出尺寸**，其余 clip cover 进去（与现比例「居中 cover」一致）。

相册网格：P0 可先「编辑页内再选第二个视频」，不必一上来改成多选进编辑。少改 `AlbumViewController` 导航。

---

## 8. 运行时分层（相对现状的增量）

| 类型 | 状态 | 职责 |
|------|------|------|
| `AlbumProject` | 新增 | 工程草稿 |
| `AlbumProjectClip` / `AlbumTransition` | 新增 | clip 与接缝 |
| `AlbumProjectMapper` | 新增 | 工程轴；内部复用每 clip 的 `AlbumTimeMapper` |
| `AlbumTransitionKernel` | 新增 | 双路混叠 |
| `AlbumEditDocument` / `AlbumTimeMapper` | 保持 | 仍描述**一片** |
| `AlbumEditSession` | 扩展 | `document` 升级为 `project`；单 clip 时对外可保留 `document` 计算属性以免一次改光 VC |
| `AlbumEditorViewController` | 扩展 | `init(assets:)`；转场面板；双 Player 生命周期 |
| `AlbumVideoPlayer` | 扩展 | 可绑多 asset Composition；可选第二实例 |
| `AlbumVideoExporter` | 扩展 | 工程轴 + 可选双 Reader |
| `AlbumGeometryKernel` | 保持 | 增加「输出贴合 canvas」的 cover 步骤（或导出前一次 CI） |

设计模式：Project 是 Document 的聚合；Mapper 仍是快照；Kernel 仍是无状态 enum。

---

## 9. 分期

| 阶段 | 内容 | 验收 |
|------|------|------|
| **6a** | `AlbumProject` + Mapper + 两视频硬切；canvas=clip0；全局滤镜；导出 | **已落地** |
| **6b** | 「拼接」二级页添加/删除 clip；单 clip 退化与今天一致 | **已落地**（无重排） |
| **7** | `fade` / `dipToBlack` / `dipToWhite`；双 Player + 双 Reader；音频斜坡 | **已落地** |
| **8** | `push`；转场面板 duration 手柄 | 方向与 duration 夹紧符合 §4.1 |
| 以后 | 静图当 clip、每 clip 独立滤镜、多轨画中画 | 单独立项；画中画才接近美摄第二视频轨 |

阶段 5 截图仍按 [`album-edit.md`](album-edit.md)：实况窗口用**工程播放时间** ±1.5s。

---

## 10. 风险

- **双解码发热**：只在 overlap ±预热窗口开副路。
- **不同帧率/HDR**：统一在几何后变成 canvas 上的 32BGRA；HDR 先当 SDR 夹紧（与现状相册路径一致）。
- **音频时钟**：视频 overlap 时音频也必须斜坡，否则会听到双重对白。
- **面板时钟再次分叉**：工程条带用工程轴，clip 条带用源轴；转场 duration 手柄不要画在源轴 filmstrip 上。
- **Composition 时间戳**：多 asset `insertTimeRange` 后轨 `preferredTransform` 仍按 clip 传给几何内核，不要在 Composition 上 bake 朝向。

---

## 11. 不做什么（本方案边界）

- 不引入 `NvStreamingSdk` / `NvsTimeline` / `compileTimeline`
- 不做美摄素材包转场、主题、贴纸、字幕
- 不做第二条视频轨（画中画）
- 不把转场做成 `OFProcessGraph` 常驻节点（它是双输入、只在 overlap 存在，不是「对当前一帧原地着色」）
- 不持久化工程文件
