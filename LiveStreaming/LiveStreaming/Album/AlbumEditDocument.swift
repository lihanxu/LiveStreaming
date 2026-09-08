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
    /// 播放倍速，必须 > 0
    var speed: Double
}

/// 时间线占位；阶段 1 固定整段 1x，不接 UI。空 segments 表示整段保留、speed=1。
struct AlbumTimelineEdit: Equatable {
    /// 有序不相交的保留段；空 = 整段 1x
    var segments: [AlbumTimelineSegment] = []
}

/// 一份资源的剪辑文档；会话持有，UI 只改这份再触发重跑。
struct AlbumEditDocument: Equatable {
    /// 画幅
    var geometry = AlbumGeometryEdit()
    /// 时间线；阶段 1 保持默认
    var timeline = AlbumTimelineEdit()
}
