# 相册示波器 P0 架构

本文只覆盖 **P0**：直方图 RGB（可选 Y）、波形图 Y（可选 Colorize）。**已在相册编辑页落地。**

交互图：[`scopes-p0.html`](scopes-p0.html)。相册编辑总览见 [`album-edit.md`](album-edit.md)。

---

## 0. 心智模型

示波器是 **测量旁路**，不是第三条像素管道。预览像素路径不变：

```
几何 → OFAuxiliaryTools.inputFrame（原地着色）→ SCGLView
                              │
                              └─ 仅面板打开时 → AlbumScopeAnalyzer → 快照 → 示波器 UI
```

- 和达芬奇一样：读 **当前 Viewer 信号**（几何 + 滤镜之后），不读显示器、不读 `SCGLView`（有 letterbox）。
- **不进** `OFProcessGraph`：不改像素、直播不付钱、导出不跑。
- 不写入 `AlbumEditDocument`：不是剪辑草稿。

---

## 1. P0 范围

| 面板 | 模式 | 轴 | 用户能开关 |
|------|------|----|------------|
| 直方图 | RGB 叠画；可选再画 Y | X = 电平 0…100%，Y = 像素计数（Gain 归一化） | Y 通道 |
| 波形 | 仅 Y | X = 画面水平位置，Y = 电平 0…100% | Colorize |

刻度固定 **百分比 0…100**（full-range BGRA，0 和 255 对应 0% 和 100%）。P0 不做 legal range、10-bit、nits。

亮度：`Y = 0.2126 R + 0.7152 G + 0.0722 B`（Rec.709，与 sRGB 显示预览一致）。

---

## 2. 原则

1. **取样在滤镜之后。** `AlbumEditSession` 在 `tools.inputFrame` 返回后、回主线程送预览之前调用 Analyzer。几何未完成或滤镜未跑的帧不得进示波器。
2. **旁路，不是节点。** 禁止往 `OFProcessNode` 加 histogram/waveform。处理图保持「对 BGRA 着色」。Analyzer 复用 `session.tools.context` 的同一 `MTLDevice` / texture cache，禁止第二套 GPU 设备。
3. **关闭即跳过。** `isEnabled == false` 时 `analyze` 立即 return，不 dispatch kernel、不 wait、不改 completion 形态以外的热路径成本。
4. **导出零成本。** `processVideoFrameSync` / `exportPhoto` 不调用 Analyzer。`beginExport` 已丢弃预览；示波器面板随导出关掉即可。
5. **UI 不持有 GPU。** 面板只吃值类型 `AlbumScopeSnapshot`（直方图 4×256 计数 + 波形 256×256 密度/上色）。绘制用 UIKit。
6. **分析分辨率封顶。** 预览长边可达屏 nativeBounds。P0 分析前把纹理缩到 **长边 ≤ 512**（偶数），再跑 atomic。预览仍用全分辨率送 `SCGLView`。
7. **同步提交、跟 peak 同一契约。** 仍在 `processingQueue` 上 `commit + waitUntilCompleted`，避免帧已交给 GL 后异步读正在显示的 buffer。靠降采样把附加延迟压住。

---

## 3. 类型

全部新建在 `LiveStreaming/LiveStreaming/Album/`，不改 `Pods/`，不改处理图枚举。

```
AlbumScopeAnalyzer          class    Metal 累加；仅 Session 持有
AlbumScopeSnapshot          struct   一帧的直方图 + 波形；Equatable 不要求
AlbumScopePanelView         class    叠在预览上；本地 mode / 开关；委托只报 UI 状态
AlbumScopeKind              enum    histogram | waveform
```

### 3.1 AlbumScopeSnapshot

| 字段 | 含义 |
|------|------|
| `histogramR/G/B/Y` | 各 256 个 `UInt32`；bin `i` 对应电平 `i/255` |
| `waveformWidth` / `waveformHeight` | 固定 256×256 |
| `waveformLuma` | 256×256 行优先 `UInt16` 密度（该列该电平的像素计数） |
| `waveformColor` | Colorize 关则为空；否则 256×256 预乘过的 RGB 展示色（`UInt8`×4 或打包） |

Y 直方图即使 UI 关掉也建议 kernel 一并累加（一次遍历四个 atomic），避免为开关再编一条 pipeline。

### 3.2 Analyzer 状态（不是文档）

| 属性 | 生命周期 |
|------|---------|
| `isEnabled` | 面板 visible；VC 在 present/dismiss 时写 |
| `colorize` | 波形 Colorize；只影响第二通道是否写 `waveformColor` |
| `analysisMaxLongEdge` | 常量 512 |

直方图 RGB/YRGB 是 **显示开关**，不需要重跑 GPU（Y 已在快照里）。

---

## 4. 运行时分层

| 类型 | 职责 |
|------|------|
| `AlbumEditorViewController` | 底部「示波器」入口；打开时 `session.scopesEnabled = true`；把 snapshot 交给 panel；导出/消失时关掉 |
| `AlbumScopePanelView` | 直方图/波形切换、Y、Colorize；用 snapshot 画图；**不**引用 document / tools |
| `AlbumEditSession` | 预览路径：`inputFrame` 后若 enabled 则 `analyzer.analyze`；completion 带上 snapshot |
| `AlbumScopeAnalyzer` | 缩放 → hist kernel + wave kernel → 读回 shared buffer → `AlbumScopeSnapshot` |
| `OFAuxiliaryTools` | 不变；示波器不是它的节点 |
| `SCGLView` | 仍只收处理后的 `VideoFrame` |

### 4.1 Session 热路径（预览）

```
processingQueue:
  1. GeometryKernel.apply
  2. tools.inputFrame(frame)          // 原地改像素
  3. snapshot = analyzer.analyze(frame)  if isEnabled  else nil
  4. 主线程: previewView.inputFrame + panel.apply(snapshot)
```

照片 `reprocessPhotoPreview`、视频 `processVideoPreviewFrame` 走同一插入点。滤镜 `onPipelineChanged` 已会重跑预览，示波器自动跟上。

**不要**把 snapshot 塞进 `VideoFrame`。预览类型保持像素帧；示波器是平行回调或 completion 元组：

```swift
completion: (VideoFrame, AlbumScopeSnapshot?) -> Void
```

### 4.2 为何不挂 DAG 尾节点

| 若做成 `OFProcessNode` | 问题 |
|------------------------|------|
| 直播同一份 `OFAuxiliaryTools` | 采集也会 atomic |
| `isEnabled` 关仍可能被图调度 | 要改图拓扑或每帧空跑 |
| 节点约定改像素 | 示波器只读，语义相反 |
| 导出逐帧 | 离线编码无谓等 GPU |

Session 插入点已经串行、导出可跳过，足够。

---

## 5. GPU 内核

两个 compute kernel，同一 command buffer（一次 wait）。

### 5.1 直方图 `albumScopeHistogram`

输入：降采样 BGRA 纹理。输出：`MTLBuffer`，`uint hist[4][256]`（R,G,B,Y）。

每像素：线性化不必做（预览已是显示编码）；`bin = round(c * 255)`，`atomic_fetch_add`。

Y 用上述 Rec.709 系数。每帧 encode 前 `fill(0)` 该 buffer。

读回：`MTLResourceStorageModeShared`（Apple GPU）。256×4×4 = 4KB，主线程画面积图。

### 5.2 波形 `albumScopeWaveform`

列映射：`col = x * 256 / width`。电平 bin 同直方图。  
输出密度：`uint16 dens[256][256]`（或 uint32，P0 512² 图最多约 26 万像素，UInt16 够用）。

Colorize 开：另写 `uint rgbSum[256][256][3]` + `dens`，读回后 `display = rgbSum / dens`（dens=0 则透明）。为少一条 buffer，可用 `uint32 packed` 或第四个通道只存 dens、RGB 用独立 buffer。

显示：256×256 `CGImage` / `UIImage`，纵轴 **底 = 0%、顶 = 100%**（注意 Metal 纹理原点，读回时翻转 Y）。

### 5.3 降采样

`MPSImageBilinearScale` 或现成 `AlbumMediaConverter.scaledPixelBuffer` 到长边 512。优先 Converter：已在相册 GPU 队列使用、iOS 12 无 MPS 版本顾虑更少。分析用副本，**不得**缩小送去 `SCGLView` 的那一帧。

---

## 6. UI

- 入口：底部工具条「示波器」（照片/视频都有），与画幅并列；**不进设置栈**（设置只绑滤镜）。
- 形态：预览 **左侧或底部浮层**（约 1/3 宽），不要再占一整块底部 Sheet，避免和画幅/剪辑互斥到无法对照画面。
- 打开示波器 **不关闭** 画幅/剪辑；剪辑期间预览仍走几何+滤镜，统计仍然有效。
- 控件：`直方图 | 波形`；直方图「Y」开关；波形「上色」。
- 直方图绘制：三（或四）条半透明面积；Gain = `max(count)` 归一化到视图高度，避免死黑图把峰压没。
- 波形：灰度密度图；Colorize 用 `waveformColor`，无样本像素处透明。叠加 0/50/100% 刻度线。

`AlbumScopePanelView` 只通过委托通知 VC：`didChangeEnabled` / `didChangeColorize`。VC 写 Analyzer 标志并在静图时 `reprocessPhotoPreview()`。

---

## 7. 文件

| 文件 | 职责 |
|------|------|
| `AlbumScopeAnalyzer.swift` | 缩放、encode、读回、组装 Snapshot |
| `AlbumScopeSnapshot.swift` | 值类型 + 直方图/波形常量（256） |
| `AlbumScope.metal` | 两个 kernel |
| `AlbumScopePanelView.swift` | 浮层 UI 与绘制 |
| `AlbumEditSession.swift` | `scopesEnabled`；预览 completion 带 snapshot；导出不调用 |
| `AlbumEditorViewController.swift` | 入口按钮、开关 Analyzer、把 snapshot 交给 panel |

Metal 编进 App target（与相册源码同 target），或并入现有 `OFFilterKit` shader library **仅当** 不想维护第二份 `.metallib`。推荐 **App target 独立 `AlbumScope.metal`**，Analyzer 用 `device.makeDefaultLibrary()`，避免把测量 shader 泄漏进直播 kit。

---

## 8. 明确不做（P0）

- RGB Parade / YRGB 波形 / YCbCr
- 矢量、CIE、Qualifier、Low Pass、Extents、HDR
- 示波器结果进导出或烧进成片
- 统计未滤镜的「Input」直方图（曲线 Input/Output）
- 直播页

P1 若做 Parade：同一波形 kernel，按通道拆三栏视口，Analyzer 接口加 `layout: overlay | parade` 即可。

---

## 9. 风险

- **`waitUntilCompleted` 拉长预览。** 必须降采样；若仍掉帧，再对视频隔帧分析（静图仍每张都跑）。
- **滤镜原地改 buffer。** 必须在 `inputFrame` **之后** 分析；之前是未着色像素。
- **iOS 12 atomic。** 只用 `device` buffer 上的 `atomic_fetch_add`，不要依赖 imageatomic（部分像素格式/系统更晚才稳）。
- **Colorize 读回量。** 256×256×12 字节量级可接受；不要按原图宽度做列累加。
- **主线程绘制。** 直方图 256 点 Bezier 无压力；波形用一次 `CGContext` 填像素，不要逐点 `UIView`。
