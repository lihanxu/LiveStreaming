//
//  AlbumTrimFilmstripView.swift
//  LiveStreaming
//
//  美摄式首尾裁剪条：源时间铺砖缩略图 + 橙色选区手柄 + 框外遮罩。
//

import AVFoundation
import UIKit

/// 条带入出点变化
protocol AlbumTrimFilmstripViewDelegate: AnyObject {
    /// 拖动手柄或平移选区后回调；`previewTime` 供大预览 seek
    /// - Parameters:
    ///   - filmstrip: 条带
    ///   - start: 入点
    ///   - end: 出点
    ///   - previewTime: 应显示的源时间
    func filmstrip(
        _ filmstrip: AlbumTrimFilmstripView,
        didChangeStart start: CMTime,
        end: CMTime,
        previewTime: CMTime
    )
}

/// 当前拖动手势落在哪一端；平移选区时两端一起动
private enum AlbumTrimFilmstripDrag {
    /// 未拖
    case none
    /// 入点
    case start
    /// 出点
    case end
    /// 平移整段选区
    case window
}

/// 一行缩略图尺子；拖手柄只改遮罩，不重抽帧。
class AlbumTrimFilmstripView: UIView {
    /// 入出点变化
    weak var delegate: AlbumTrimFilmstripViewDelegate?
    /// 源时长
    private var sourceDuration = CMTime.zero
    /// 入点
    private var startTime = CMTime.zero
    /// 出点
    private var endTime = CMTime.zero
    /// 当前预览头，画白色指示针
    private var previewTime = CMTime.zero
    /// 正在抽帧的资源；换片才重抽
    private var asset: AVAsset?
    /// 上次抽帧时的条宽，旋转或首次布局后差 2pt 才重抽
    private var loadedWidth: CGFloat = 0
    /// 抽帧器
    private let loader = AlbumTrimThumbnailLoader()
    /// 当前拖的类型
    private var drag: AlbumTrimFilmstripDrag = .none
    /// 平移选区开始时的入点
    private var windowDragStart = CMTime.zero
    /// 平移选区开始时的出点
    private var windowDragEnd = CMTime.zero
    /// 平移手势起点的 x
    private var windowDragOriginX: CGFloat = 0

    /// 手柄视觉宽
    private let handleWidth: CGFloat = 16
    /// 手柄命中外扩
    private let handleSlop: CGFloat = 14
    /// 选区橙色
    private let accentColor = UIColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1)

    /// 缩略图行
    private let thumbsStack = UIStackView()
    /// 格子；按宽度重铺
    private var thumbViews: [UIImageView] = []
    /// 入点左侧变暗
    private let leftMask = UIView()
    /// 出点右侧变暗
    private let rightMask = UIView()
    /// 选区顶底描边
    private let selectionBorder = UIView()
    /// 入点手柄
    private let leftHandle = UIView()
    /// 出点手柄
    private let rightHandle = UIView()
    /// 播放头
    private let playhead = UIView()

    /// 搭条带；默认不接收外部约束以外的尺寸
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 关面板时停掉抽帧
    deinit {
        loader.cancel()
    }

    /// 绑定资源并套上当前收尾；同宽同资源不重抽
    /// - Parameters:
    ///   - asset: 源视频
    ///   - duration: 源时长
    ///   - start: 入点
    ///   - end: 出点
    func configure(asset: AVAsset, duration: CMTime, start: CMTime, end: CMTime) {
        let assetChanged = self.asset !== asset
        self.asset = asset
        sourceDuration = duration
        applyTimes(start: start, end: end, preview: start, emit: false)
        if assetChanged {
            loadedWidth = 0
            loader.cancel()
            clearThumbnails()
        }
        setNeedsLayout()
        layoutIfNeeded()
        reloadThumbnailsIfNeeded()
    }

    /// 只改入出点（复位 / 外部写入），不重抽
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - preview: 指示针
    func updateSelection(start: CMTime, end: CMTime, preview: CMTime) {
        applyTimes(start: start, end: end, preview: preview, emit: false)
        layoutSelection()
    }

    /// 取消抽帧
    func cancelLoading() {
        loader.cancel()
    }

    /// 子视图尺寸变化后重铺手柄，必要时补抽
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSelection()
        reloadThumbnailsIfNeeded()
    }

    /// 子视图与手势
    private func setupViews() {
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        layer.cornerRadius = 6
        clipsToBounds = true

        thumbsStack.axis = .horizontal
        thumbsStack.alignment = .fill
        thumbsStack.distribution = .fillEqually
        thumbsStack.spacing = 0
        thumbsStack.isUserInteractionEnabled = false
        addSubview(thumbsStack)

        leftMask.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        leftMask.isUserInteractionEnabled = false
        addSubview(leftMask)
        rightMask.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        rightMask.isUserInteractionEnabled = false
        addSubview(rightMask)

        selectionBorder.isUserInteractionEnabled = false
        selectionBorder.layer.borderColor = accentColor.cgColor
        selectionBorder.layer.borderWidth = 2
        addSubview(selectionBorder)

        configureHandle(leftHandle, roundedLeft: true)
        configureHandle(rightHandle, roundedLeft: false)
        addSubview(leftHandle)
        addSubview(rightHandle)

        playhead.backgroundColor = .white
        playhead.layer.cornerRadius = 1
        playhead.isUserInteractionEnabled = false
        addSubview(playhead)

        thumbsStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    /// 橙色手柄 + 中间白条
    /// - Parameters:
    ///   - handle: 手柄
    ///   - roundedLeft: 左侧手柄圆左角，右侧圆右角
    private func configureHandle(_ handle: UIView, roundedLeft: Bool) {
        handle.backgroundColor = accentColor
        handle.layer.cornerRadius = 6
        if #available(iOS 11.0, *) {
            handle.layer.maskedCorners = roundedLeft
                ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
        let grip = UIView()
        grip.backgroundColor = .white
        grip.layer.cornerRadius = 1.5
        grip.isUserInteractionEnabled = false
        handle.addSubview(grip)
        grip.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.equalTo(3)
            make.height.equalTo(16)
        }
    }

    /// 写入时间并可选通知会话
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - preview: 指示针
    ///   - emit: 是否回调
    private func applyTimes(start: CMTime, end: CMTime, preview: CMTime, emit: Bool) {
        let clamped = AlbumTimelineEdit().applyingSingleTrim(
            start: start,
            end: end,
            sourceDuration: sourceDuration
        ).resolvedSegment(sourceDuration: sourceDuration)
        startTime = clamped.sourceStart
        endTime = clamped.sourceEnd
        var seek = preview
        if CMTimeCompare(seek, startTime) < 0 {
            seek = startTime
        } else if CMTimeCompare(seek, endTime) > 0 {
            seek = endTime
        }
        previewTime = seek
        if emit {
            delegate?.filmstrip(self, didChangeStart: startTime, end: endTime, previewTime: previewTime)
        }
    }

    /// 按当前入出点摆手柄、遮罩、描边
    private func layoutSelection() {
        let width = bounds.width
        let height = bounds.height
        guard width > 1, height > 1 else { return }
        let startX = x(for: startTime)
        let endX = x(for: endTime)
        leftMask.frame = CGRect(x: 0, y: 0, width: max(0, startX), height: height)
        rightMask.frame = CGRect(x: endX, y: 0, width: max(0, width - endX), height: height)
        selectionBorder.frame = CGRect(x: startX, y: 0, width: max(handleWidth * 2, endX - startX), height: height)
        leftHandle.frame = CGRect(x: startX, y: 0, width: handleWidth, height: height)
        rightHandle.frame = CGRect(x: endX - handleWidth, y: 0, width: handleWidth, height: height)
        let playX = x(for: previewTime)
        playhead.frame = CGRect(x: playX - 1, y: 0, width: 2, height: height)
    }

    /// 源时间 → 条带 x
    /// - Parameter time: 源时间
    /// - Returns: 点坐标
    private func x(for time: CMTime) -> CGFloat {
        let durationSeconds = max(CMTimeGetSeconds(sourceDuration), 0.001)
        let ratio = CGFloat(max(0, min(1, CMTimeGetSeconds(time) / durationSeconds)))
        return ratio * bounds.width
    }

    /// 条带 x → 源时间
    /// - Parameter position: 点坐标
    /// - Returns: 源 CMTime
    private func time(at position: CGFloat) -> CMTime {
        let durationSeconds = max(CMTimeGetSeconds(sourceDuration), 0)
        let ratio = Double(max(0, min(1, position / max(bounds.width, 1))))
        let timescale = sourceDuration.timescale > 0 ? sourceDuration.timescale : 600
        return CMTime(seconds: ratio * durationSeconds, preferredTimescale: timescale)
    }

    /// 清空格子图，留下底色
    private func clearThumbnails() {
        thumbViews.forEach { $0.image = nil }
    }

    /// 宽度够了且格数变了才抽；拖手柄不进这里
    private func reloadThumbnailsIfNeeded() {
        guard let asset = asset, bounds.width > 8, bounds.height > 8 else { return }
        let cellWidth = bounds.height
        let count = min(20, max(4, Int(ceil(bounds.width / cellWidth))))
        if thumbViews.count != count {
            rebuildThumbViews(count: count)
            loadedWidth = 0
        }
        if abs(loadedWidth - bounds.width) < 2 { return }
        loadedWidth = bounds.width
        let maxPixel = min(160, bounds.height * UIScreen.main.scale)
        loader.load(asset: asset, count: count, duration: sourceDuration, maxPixel: maxPixel) { [weak self] index, image in
            guard let self = self, index < self.thumbViews.count else { return }
            self.thumbViews[index].image = image
        }
    }

    /// 按格数重建 UIImageView
    /// - Parameter count: 格子数
    private func rebuildThumbViews(count: Int) {
        thumbViews.forEach { $0.removeFromSuperview() }
        thumbsStack.arrangedSubviews.forEach { thumbsStack.removeArrangedSubview($0) }
        thumbViews.removeAll()
        for _ in 0..<count {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = UIColor(white: 0.18, alpha: 1)
            imageView.isUserInteractionEnabled = false
            thumbsStack.addArrangedSubview(imageView)
            thumbViews.append(imageView)
        }
    }

    /// 命中测试：先两端手柄，再选区内部
    /// - Parameter point: 条带坐标
    /// - Returns: 拖的类型
    private func dragKind(at point: CGPoint) -> AlbumTrimFilmstripDrag {
        let startX = x(for: startTime)
        let endX = x(for: endTime)
        let leftHit = CGRect(
            x: startX - handleSlop,
            y: -handleSlop,
            width: handleWidth + handleSlop * 2,
            height: bounds.height + handleSlop * 2
        )
        let rightHit = CGRect(
            x: endX - handleWidth - handleSlop,
            y: -handleSlop,
            width: handleWidth + handleSlop * 2,
            height: bounds.height + handleSlop * 2
        )
        let inLeft = leftHit.contains(point)
        let inRight = rightHit.contains(point)
        if inLeft && inRight {
            return abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
        }
        if inLeft { return .start }
        if inRight { return .end }
        if point.x > startX && point.x < endX {
            return .window
        }
        return .none
    }

    /// 拖入点 / 出点 / 整段
    /// - Parameter gesture: 平移
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            drag = dragKind(at: point)
            windowDragStart = startTime
            windowDragEnd = endTime
            windowDragOriginX = point.x
        case .changed:
            switch drag {
            case .none:
                break
            case .start:
                applyTimes(start: time(at: point.x), end: endTime, preview: time(at: point.x), emit: true)
                layoutSelection()
            case .end:
                applyTimes(start: startTime, end: time(at: point.x), preview: time(at: point.x), emit: true)
                layoutSelection()
            case .window:
                // 整段平移时保持选区长度，撞到片头/片尾再顶住
                let shift = CMTimeSubtract(time(at: point.x), time(at: windowDragOriginX))
                let kept = CMTimeSubtract(windowDragEnd, windowDragStart)
                var newStart = CMTimeAdd(windowDragStart, shift)
                newStart = CMTimeMaximum(newStart, .zero)
                var newEnd = CMTimeAdd(newStart, kept)
                if CMTimeCompare(newEnd, sourceDuration) > 0 {
                    newEnd = sourceDuration
                    newStart = CMTimeMaximum(CMTimeSubtract(newEnd, kept), .zero)
                }
                applyTimes(start: newStart, end: newEnd, preview: newStart, emit: true)
                layoutSelection()
            }
        default:
            drag = .none
        }
    }
}
