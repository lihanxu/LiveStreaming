# LiveStreaming 文档

新人建议顺序：应用架构 → 相册模块设计 → 需要时再打开 HTML 图。

## 应用
- [应用架构](architecture.md) — 产品形态、滤镜 DAG、直播/相册会话、目录对照

## 相册编辑
- [模块设计](Album/album-edit.md) — 草稿、两套时钟、几何/剪辑/变速、文件对照与常见坑
- [剪辑架构图](Album/clip-architecture.html)
- [剪辑时钟（TimeMapper）](Album/clip-dataflow.html)
- [类图](Album/class-diagram.html)
- [多视频拼接与转场](Album/multi-clip.md) / [架构图](Album/multi-clip-architecture.html) — 硬切与淡入/闪黑/闪白已落地；不引入 `NvsTimeline`

## 滤镜内核
- [OFAuxiliaryTools](FilterKit/OFAuxiliaryTools.md)

## 运行时
- [进程运行时架构](Runtime/runtime-architecture.html)
