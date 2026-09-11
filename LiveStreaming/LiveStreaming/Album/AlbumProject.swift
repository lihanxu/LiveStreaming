//
//  AlbumProject.swift
//  LiveStreaming
//
//  多视频工程草稿：有序 clip 列表与接缝转场。
//

import CoreMedia

/// 接缝转场类型；非 cut 时预览双解码、导出拉两路后混叠。
enum AlbumTransitionKind: Int, Equatable {
    /// 硬切，无重叠
    case cut = 0
    /// 交叉淡化
    case fade = 1
    /// 闪黑
    case dipToBlack = 2
    /// 闪白
    case dipToWhite = 3

    /// 面板分段标题
    var title: String {
        switch self {
        case .cut: return "硬切"
        case .fade: return "淡入"
        case .dipToBlack: return "闪黑"
        case .dipToWhite: return "闪白"
        }
    }

    /// 面板上的顺序
    static let presets: [AlbumTransitionKind] = [.cut, .fade, .dipToBlack, .dipToWhite]
}

/// 相邻两段之间的接缝；`cut` 时 duration 必须为 0。
struct AlbumTransition: Equatable {
    /// 效果
    var kind: AlbumTransitionKind = .cut
    /// 重叠时长；硬切为 0
    var duration: CMTime = .zero

    /// 硬切接缝
    static let cut = AlbumTransition()

    /// 非硬切默认重叠
    static let defaultOverlap = CMTime(seconds: 0.35, preferredTimescale: 600)
    /// 最短重叠
    static let minimumOverlap = CMTime(seconds: 0.1, preferredTimescale: 600)
    /// 最长重叠
    static let maximumOverlap = CMTime(seconds: 0.8, preferredTimescale: 600)

    /// 按类型夹紧 duration
    /// - Returns: 可写入的接缝
    func normalized() -> AlbumTransition {
        if kind == .cut {
            return AlbumTransition(kind: .cut, duration: .zero)
        }
        let seconds = CMTimeGetSeconds(duration)
        let minS = CMTimeGetSeconds(Self.minimumOverlap)
        let maxS = CMTimeGetSeconds(Self.maximumOverlap)
        let clamped = min(max(seconds.isFinite ? seconds : 0.35, minS), maxS)
        return AlbumTransition(kind: kind, duration: CMTime(seconds: clamped, preferredTimescale: 600))
    }
}

/// 工程里的一段成片来源；画幅与剪辑仍用单片 `AlbumEditDocument`。
struct AlbumProjectClip: Equatable {
    /// 系统相册 `PHAsset.localIdentifier`，用来再次请求 AVAsset
    var localIdentifier: String
    /// 该片自己的画幅 + 时间线
    var document = AlbumEditDocument()
}

/// 多段视频工程；单资源编辑是 `clips.count == 1`。
struct AlbumProject: Equatable {
    /// 条带与切换器放得下的上限
    static let maximumClipCount = 6
    /// 有序片段；空表示尚未载入
    var clips: [AlbumProjectClip] = []
    /// 接缝，数量为 `max(0, clips.count - 1)`
    var transitions: [AlbumTransition] = []
    /// 画幅 / 剪辑 / 变速 / 拼接面板作用的下标
    var selectedIndex: Int = 0

    /// 当前选中的单片文档；无 clip 时为空文档
    var selectedDocument: AlbumEditDocument {
        get {
            guard clips.indices.contains(selectedIndex) else { return AlbumEditDocument() }
            return clips[selectedIndex].document
        }
        set {
            guard clips.indices.contains(selectedIndex) else { return }
            clips[selectedIndex].document = newValue
        }
    }

    /// 是否多于一段，预览要按段切换解码、导出要拼合成轴
    var isMultiClip: Bool {
        return clips.count >= 2
    }

    /// 夹紧选中下标
    mutating func normalizeSelection() {
        if clips.isEmpty {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex), clips.count - 1)
    }

    /// 接缝数与 clip 对齐；缺的补硬切，多的丢掉
    mutating func syncTransitions() {
        let needed = max(0, clips.count - 1)
        while transitions.count < needed {
            transitions.append(.cut)
        }
        if transitions.count > needed {
            transitions.removeLast(transitions.count - needed)
        }
        for index in transitions.indices {
            transitions[index] = transitions[index].normalized()
        }
    }

    /// 写入一条接缝
    /// - Parameters:
    ///   - transition: 新接缝
    ///   - index: clip[i] 与 clip[i+1] 之间
    mutating func applyingTransition(_ transition: AlbumTransition, at index: Int) {
        syncTransitions()
        guard transitions.indices.contains(index) else { return }
        transitions[index] = transition.normalized()
    }

    /// 追加一段；已满或 identifier 空则失败
    /// - Parameter localIdentifier: 新片 PHAsset 标识
    /// - Returns: 是否写入
    mutating func appendingClip(localIdentifier: String) -> Bool {
        guard !localIdentifier.isEmpty, clips.count < Self.maximumClipCount else { return false }
        clips.append(AlbumProjectClip(localIdentifier: localIdentifier))
        selectedIndex = clips.count - 1
        syncTransitions()
        return true
    }

    /// 删掉选中段；至少留 1 段
    /// - Returns: 是否删除
    mutating func removingSelectedClip() -> Bool {
        guard clips.count >= 2, clips.indices.contains(selectedIndex) else { return false }
        if selectedIndex < transitions.count {
            transitions.remove(at: selectedIndex)
        } else if selectedIndex > 0 {
            transitions.remove(at: selectedIndex - 1)
        }
        clips.remove(at: selectedIndex)
        normalizeSelection()
        syncTransitions()
        return true
    }
}
