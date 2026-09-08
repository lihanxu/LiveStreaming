//
//  AlbumEditDocument.swift
//  LiveStreaming
//
//  相册剪辑纯数据：画幅 + 时间线。预览/导出/截图只读这份文档；滤镜参数不在此。
//

import CoreMedia
import CoreGraphics

/// 输出画面比例；阶段 1 按居中 cover 裁进该比例。
enum AlbumAspectMode: Equatable {
    /// 保持几何后的宽高比，不再裁切
    case original
    /// 宽:高，例如 16:9
    case ratio(width: Int, height: Int)

    /// 预设在 UI 上的顺序
    static let presets: [AlbumAspectMode] = [
        .original,
        .ratio(width: 1, height: 1),
        .ratio(width: 4, height: 3),
        .ratio(width: 16, height: 9),
        .ratio(width: 9, height: 16),
    ]

    /// 按钮文案
    var title: String {
        switch self {
        case .original:
            return "原图"
        case .ratio(let width, let height):
            return "\(width):\(height)"
        }
    }

    /// 目标宽高比；原图为 nil
    var aspectRatio: CGFloat? {
        switch self {
        case .original:
            return nil
        case .ratio(let width, let height):
            guard width > 0, height > 0 else { return nil }
            return CGFloat(width) / CGFloat(height)
        }
    }
}

/// 用户画幅参数；与片源 `preferredTransform` 分开存，由内核合成。
struct AlbumGeometryEdit: Equatable {
    /// 正交顺时针 90° 次数，对 4 取模
    var quarterTurns: Int = 0
    /// 左右翻转（水平镜像）
    var flipHorizontal: Bool = false
    /// 上下翻转（垂直镜像）
    var flipVertical: Bool = false
    /// 自由角，单位度；阶段 1 建议 ±45
    var freeAngleDegrees: Float = 0
    /// 输出比例；阶段 1 居中 cover，无拖框
    var aspect: AlbumAspectMode = .original

    /// 对 4 取模后的正交次数，保证 0...3
    var normalizedQuarterTurns: Int {
        let turns = quarterTurns % 4
        return turns < 0 ? turns + 4 : turns
    }

    /// 无用户几何（不含片源朝向）
    var isIdentity: Bool {
        return normalizedQuarterTurns == 0
            && !flipHorizontal
            && !flipVertical
            && abs(freeAngleDegrees) < 0.01
            && aspect == .original
    }
}

/// 一条保留段；时间是源媒体时间。
struct AlbumTimelineSegment: Equatable {
    /// 源起点
    var sourceStart: CMTime
    /// 源终点，须大于起点
    var sourceEnd: CMTime
    /// 播放倍速，必须 > 0；阶段 2 固定 1
    var speed: Double
}

/// 时间线；阶段 2 只写单段收尾。空 segments 表示整段保留、speed=1。
struct AlbumTimelineEdit: Equatable {
    /// 有序不相交的保留段；空 = 整段 1x。阶段 2 最多一条。
    var segments: [AlbumTimelineSegment] = []

    /// 单段最短时长，避免空区间让 Reader / Player 起不来
    static let minimumDuration = CMTime(seconds: 0.1, preferredTimescale: 600)

    /// 预览/导出用的单段：空文档视为 `[0, duration]`，speed 强制 1。
    /// - Parameter sourceDuration: 源媒体时长
    /// - Returns: 已夹进合法区间的一段
    func resolvedSegment(sourceDuration: CMTime) -> AlbumTimelineSegment {
        let duration = CMTimeMaximum(sourceDuration, Self.minimumDuration)
        let fallback = AlbumTimelineSegment(sourceStart: .zero, sourceEnd: duration, speed: 1)
        guard let first = segments.first else {
            return fallback
        }
        return Self.clamped(first, sourceDuration: duration)
    }

    /// 写入单段收尾；若几乎是整段则清空，保持「未剪辑」语义。
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线
    func applyingSingleTrim(start: CMTime, end: CMTime, sourceDuration: CMTime) -> AlbumTimelineEdit {
        let clamped = Self.clamped(
            AlbumTimelineSegment(sourceStart: start, sourceEnd: end, speed: 1),
            sourceDuration: sourceDuration
        )
        let epsilon = CMTime(seconds: 0.05, preferredTimescale: 600)
        let startsAtZero = CMTimeCompare(clamped.sourceStart, epsilon) <= 0
        let endsAtDuration = CMTimeCompare(CMTimeSubtract(sourceDuration, clamped.sourceEnd), epsilon) <= 0
        var copy = self
        if startsAtZero && endsAtDuration {
            copy.segments = []
        } else {
            copy.segments = [clamped]
        }
        return copy
    }

    /// 把一段夹进 `[0, duration]`，并保证最短时长。
    /// - Parameters:
    ///   - segment: 原始段
    ///   - sourceDuration: 源时长
    /// - Returns: 合法段，speed=1
    private static func clamped(_ segment: AlbumTimelineSegment, sourceDuration: CMTime) -> AlbumTimelineSegment {
        let duration = CMTimeMaximum(sourceDuration, minimumDuration)
        var start = CMTimeMaximum(segment.sourceStart, .zero)
        var end = CMTimeMinimum(segment.sourceEnd, duration)
        if CMTimeCompare(CMTimeSubtract(end, start), minimumDuration) < 0 {
            end = CMTimeMinimum(CMTimeAdd(start, minimumDuration), duration)
            if CMTimeCompare(CMTimeSubtract(end, start), minimumDuration) < 0 {
                start = CMTimeMaximum(CMTimeSubtract(end, minimumDuration), .zero)
            }
        }
        return AlbumTimelineSegment(sourceStart: start, sourceEnd: end, speed: 1)
    }
}

/// 一份资源的剪辑文档；会话持有，UI 只改这份再触发重跑。
struct AlbumEditDocument: Equatable {
    /// 画幅
    var geometry = AlbumGeometryEdit()
    /// 时间线；视频阶段 2 写单段收尾
    var timeline = AlbumTimelineEdit()
}
