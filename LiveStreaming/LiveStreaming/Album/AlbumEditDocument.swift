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
    /// 播放倍速，必须 > 0；写入时由时间线夹紧到 `[minimumSpeed, maximumSpeed]`
    var speed: Double
}

/// 时间线；空 segments 表示整段保留、speed=1。
struct AlbumTimelineEdit: Equatable {
    /// 有序不相交的保留段；空 = 整段 1x
    var segments: [AlbumTimelineSegment] = []

    /// 单段最短时长，避免空区间让 Reader / Player 起不来
    static let minimumDuration = CMTime(seconds: 0.1, preferredTimescale: 600)
    /// 多段上限，条带放不下太多手柄
    static let maximumSegmentCount = 6
    /// 最慢倍速
    static let minimumSpeed = 0.25
    /// 最快倍速
    static let maximumSpeed = 4.0
    /// 视为 1x 的误差；整段 1x 才允许清空文档
    static let speedEpsilon = 0.001

    /// 把倍速夹进合法区间；非正或非有限当作 1
    /// - Parameter speed: 原始倍速
    /// - Returns: `[minimumSpeed, maximumSpeed]`
    static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 1 }
        return min(max(speed, minimumSpeed), maximumSpeed)
    }

    /// 是否按 1x 处理（可清空为未剪辑）
    /// - Parameter speed: 原始倍速
    /// - Returns: 夹紧后与 1 的差不超过 `speedEpsilon`
    static func isUnitySpeed(_ speed: Double) -> Bool {
        return abs(clampedSpeed(speed) - 1) <= speedEpsilon
    }

    /// 预览/导出用的全部保留段：空文档视为整段 1x；重叠段按起点排序并截断，保留并夹紧 speed。
    /// - Parameter sourceDuration: 源媒体时长
    /// - Returns: 至少一段
    func resolvedSegments(sourceDuration: CMTime) -> [AlbumTimelineSegment] {
        let duration = CMTimeMaximum(sourceDuration, Self.minimumDuration)
        let fallback = [AlbumTimelineSegment(sourceStart: .zero, sourceEnd: duration, speed: 1)]
        if segments.isEmpty {
            return fallback
        }
        let sorted = segments.sorted { CMTimeCompare($0.sourceStart, $1.sourceStart) < 0 }
        var result: [AlbumTimelineSegment] = []
        var cursor = CMTime.zero
        for raw in sorted {
            var start = CMTimeMaximum(raw.sourceStart, cursor)
            start = CMTimeMaximum(start, .zero)
            let end = CMTimeMinimum(raw.sourceEnd, duration)
            if CMTimeCompare(CMTimeSubtract(end, start), Self.minimumDuration) < 0 {
                continue
            }
            result.append(
                AlbumTimelineSegment(
                    sourceStart: start,
                    sourceEnd: end,
                    speed: Self.clampedSpeed(raw.speed)
                )
            )
            cursor = end
            if result.count >= Self.maximumSegmentCount {
                break
            }
        }
        return result.isEmpty ? fallback : result
    }

    /// 阶段 2 兼容：只取第一段
    /// - Parameter sourceDuration: 源媒体时长
    /// - Returns: 已夹进合法区间的一段
    func resolvedSegment(sourceDuration: CMTime) -> AlbumTimelineSegment {
        return resolvedSegments(sourceDuration: sourceDuration)[0]
    }

    /// 写入单段收尾；若几乎是整段则清空，保持「未剪辑」语义。
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线
    func applyingSingleTrim(start: CMTime, end: CMTime, sourceDuration: CMTime) -> AlbumTimelineEdit {
        let current = resolvedSegments(sourceDuration: sourceDuration)
        let first = current.first.map { Self.clampedSpeed($0.speed) } ?? 1
        let sameSpeed = current.allSatisfy { abs(Self.clampedSpeed($0.speed) - first) <= Self.speedEpsilon }
        return applyingSegments(
            [AlbumTimelineSegment(sourceStart: start, sourceEnd: end, speed: sameSpeed ? first : 1)],
            sourceDuration: sourceDuration
        )
    }

    /// 写入多段；一段且几乎整段则清空。
    /// - Parameters:
    ///   - segments: 原始段，可乱序
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线
    func applyingSegments(_ segments: [AlbumTimelineSegment], sourceDuration: CMTime) -> AlbumTimelineEdit {
        var copy = self
        copy.segments = segments
        let resolved = copy.resolvedSegments(sourceDuration: sourceDuration)
        if resolved.count == 1 {
            let only = resolved[0]
            let epsilon = CMTime(seconds: 0.05, preferredTimescale: 600)
            let startsAtZero = CMTimeCompare(only.sourceStart, epsilon) <= 0
            let endsAtDuration = CMTimeCompare(CMTimeSubtract(sourceDuration, only.sourceEnd), epsilon) <= 0
            // 整段且 1x 才清空；整段 2x 必须留下，否则变速会被当成未剪辑丢掉
            let uncut = startsAtZero && endsAtDuration && Self.isUnitySpeed(only.speed)
            copy.segments = uncut ? [] : resolved
        } else {
            copy.segments = resolved
        }
        return copy
    }

    /// 在最大空隙插入一段；空隙不够则返回 nil。
    /// - Parameter sourceDuration: 源时长
    /// - Returns: 新时间线；无法添加为 nil
    func addingSegment(sourceDuration: CMTime) -> AlbumTimelineEdit? {
        let current = resolvedSegments(sourceDuration: sourceDuration)
        guard current.count < Self.maximumSegmentCount else { return nil }
        let duration = CMTimeMaximum(sourceDuration, Self.minimumDuration)
        var gaps: [(CMTime, CMTime)] = []
        var cursor = CMTime.zero
        for segment in current {
            if CMTimeCompare(CMTimeSubtract(segment.sourceStart, cursor), Self.minimumDuration) > 0 {
                gaps.append((cursor, segment.sourceStart))
            }
            cursor = segment.sourceEnd
        }
        if CMTimeCompare(CMTimeSubtract(duration, cursor), Self.minimumDuration) > 0 {
            gaps.append((cursor, duration))
        }
        guard let best = gaps.max(by: { CMTimeCompare(CMTimeSubtract($0.1, $0.0), CMTimeSubtract($1.1, $1.0)) < 0 }) else {
            return nil
        }
        let gap = CMTimeSubtract(best.1, best.0)
        let want = CMTimeMinimum(CMTime(seconds: 1.0, preferredTimescale: 600), CMTimeMultiplyByRatio(gap, multiplier: 1, divisor: 3))
        let length = CMTimeMaximum(want, Self.minimumDuration)
        if CMTimeCompare(gap, length) < 0 {
            return nil
        }
        let extra = CMTimeSubtract(gap, length)
        let start = CMTimeAdd(best.0, CMTimeMultiplyByRatio(extra, multiplier: 1, divisor: 2))
        let end = CMTimeAdd(start, length)
        var next = current
        next.append(AlbumTimelineSegment(sourceStart: start, sourceEnd: end, speed: 1))
        return applyingSegments(next, sourceDuration: sourceDuration)
    }

    /// 删掉指定段；删光后变空文档（整段未切）。
    /// - Parameters:
    ///   - index: 已 resolved 数组下标
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线；无法删除则原样
    func removingSegment(at index: Int, sourceDuration: CMTime) -> AlbumTimelineEdit {
        var current = resolvedSegments(sourceDuration: sourceDuration)
        guard index >= 0, index < current.count else { return self }
        if current.count == 1 {
            var copy = self
            copy.segments = []
            return copy
        }
        current.remove(at: index)
        return applyingSegments(current, sourceDuration: sourceDuration)
    }

    /// 是否尚未真正剪辑：只有一段、几乎覆盖整段源、且 speed≈1。
    /// - Parameter sourceDuration: 源时长
    /// - Returns: 仍是整段 1x
    func isImplicitFullRange(sourceDuration: CMTime) -> Bool {
        let resolved = resolvedSegments(sourceDuration: sourceDuration)
        guard resolved.count == 1 else { return false }
        let only = resolved[0]
        let epsilon = CMTime(seconds: 0.05, preferredTimescale: 600)
        let startsAtZero = CMTimeCompare(only.sourceStart, epsilon) <= 0
        let endsAtDuration = CMTimeCompare(CMTimeSubtract(sourceDuration, only.sourceEnd), epsilon) <= 0
        return startsAtZero && endsAtDuration && Self.isUnitySpeed(only.speed)
    }

    /// 写入倍速：`index == nil` 时当前所有保留段同一 speed（整段变速）。
    /// - Parameters:
    ///   - speed: 目标倍速，内部夹紧
    ///   - index: 已 resolved 下标；nil 表示全部
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线
    func applyingSpeed(_ speed: Double, at index: Int?, sourceDuration: CMTime) -> AlbumTimelineEdit {
        let clamped = Self.clampedSpeed(speed)
        var current = resolvedSegments(sourceDuration: sourceDuration)
        if let index = index {
            guard current.indices.contains(index) else { return self }
            current[index].speed = clamped
        } else {
            for i in current.indices {
                current[i].speed = clamped
            }
        }
        return applyingSegments(current, sourceDuration: sourceDuration)
    }

    /// 空隙里插入一段；若当前是整段单段，则改成该区间作为第一段。
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线；重叠、太短或超上限为 nil
    func insertingSegment(start: CMTime, end: CMTime, sourceDuration: CMTime) -> AlbumTimelineEdit? {
        let duration = CMTimeMaximum(sourceDuration, Self.minimumDuration)
        var nextStart = CMTimeMaximum(start, .zero)
        var nextEnd = CMTimeMinimum(end, duration)
        if CMTimeCompare(nextStart, nextEnd) > 0 {
            swap(&nextStart, &nextEnd)
        }
        if CMTimeCompare(CMTimeSubtract(nextEnd, nextStart), Self.minimumDuration) < 0 {
            return nil
        }
        if isImplicitFullRange(sourceDuration: duration) {
            return applyingSingleTrim(start: nextStart, end: nextEnd, sourceDuration: duration)
        }
        let current = resolvedSegments(sourceDuration: duration)
        guard current.count < Self.maximumSegmentCount else { return nil }
        for segment in current {
            // 开区间相交即重叠；贴边（end == 邻段 start）允许
            if CMTimeCompare(nextStart, segment.sourceEnd) < 0
                && CMTimeCompare(nextEnd, segment.sourceStart) > 0 {
                return nil
            }
        }
        var next = current
        next.append(AlbumTimelineSegment(sourceStart: nextStart, sourceEnd: nextEnd, speed: 1))
        return applyingSegments(next, sourceDuration: duration)
    }

    /// 在选中段内按源时间一分为二；两边都须达到最短时长。
    /// - Parameters:
    ///   - index: 已 resolved 下标
    ///   - time: 切割点（源时间）
    ///   - sourceDuration: 源时长
    /// - Returns: 新时间线；无法切则 nil
    func splittingSegment(at index: Int, time: CMTime, sourceDuration: CMTime) -> AlbumTimelineEdit? {
        var current = resolvedSegments(sourceDuration: sourceDuration)
        guard current.count < Self.maximumSegmentCount else { return nil }
        guard index >= 0, index < current.count else { return nil }
        let segment = current[index]
        if CMTimeCompare(CMTimeSubtract(time, segment.sourceStart), Self.minimumDuration) < 0 {
            return nil
        }
        if CMTimeCompare(CMTimeSubtract(segment.sourceEnd, time), Self.minimumDuration) < 0 {
            return nil
        }
        current.remove(at: index)
        let inherited = Self.clampedSpeed(segment.speed)
        current.insert(
            AlbumTimelineSegment(sourceStart: segment.sourceStart, sourceEnd: time, speed: inherited),
            at: index
        )
        current.insert(
            AlbumTimelineSegment(sourceStart: time, sourceEnd: segment.sourceEnd, speed: inherited),
            at: index + 1
        )
        return applyingSegments(current, sourceDuration: sourceDuration)
    }
}

/// 一份资源的剪辑文档；会话持有，UI 只改这份再触发重跑。
struct AlbumEditDocument: Equatable {
    /// 画幅
    var geometry = AlbumGeometryEdit()
    /// 时间线；视频阶段 3 可写多段
    var timeline = AlbumTimelineEdit()
}
