//
//  AlbumTrimFilmstripView.swift
//  LiveStreaming
//
//  剪辑条：首尾模式整段铺满；多段模式可滚动源轴 + 居中剪刀 + 时间尺。
//

import AVFoundation
import SnapKit
import UIKit

/// 条带入出点与滚动预览
protocol AlbumTrimFilmstripViewDelegate: AnyObject {
    /// 保留段被手柄改过
    /// - Parameters:
    ///   - filmstrip: 条带
    ///   - segments: 当前全部保留段
    ///   - selectedIndex: 正在改的段
    ///   - previewTime: 应显示的源时间
    func filmstrip(
        _ filmstrip: AlbumTrimFilmstripView,
        didChange segments: [AlbumTimelineSegment],
        selectedIndex: Int,
        previewTime: CMTime
    )

    /// 滚动或点选导致播放头变化，不改段
    /// - Parameters:
    ///   - filmstrip: 条带
    ///   - time: 居中处的源时间
    ///   - selectedIndex: 播放头所在段；空隙为当前选中
    func filmstrip(_ filmstrip: AlbumTrimFilmstripView, didScrubTo time: CMTime, selectedIndex: Int)

    /// 确认阶段对勾：在空隙（或整段未切）落下一段
    /// - Parameters:
    ///   - filmstrip: 条带
    ///   - start: 待插入入点
    ///   - end: 待插入出点
    func filmstrip(_ filmstrip: AlbumTrimFilmstripView, didConfirmRangeFrom start: CMTime, to end: CMTime)
}

/// 多段条带剪刀行为
enum AlbumTrimFilmstripCapability {
    /// 无剪刀（首尾裁剪）
    case none
    /// 空隙确认插入（剪辑多段）
    case gapInsert
    /// 段内一分为二，禁止插空隙（变速分段）
    case splitOnly
}

/// 当前拖动手势落点
private enum AlbumTrimFilmstripDrag {
    /// 未拖
    case none
    /// 入点
    case start
    /// 出点
    case end
    /// 平移整段选区（仅首尾模式）
    case window
}

/// 一段选区的描边与手柄
private final class AlbumTrimRegionChrome {
    /// 选区顶底描边
    let border = UIView()
    /// 入点手柄
    let leftHandle = UIView()
    /// 出点手柄
    let rightHandle = UIView()
}

/// 多段时间尺：2 秒一个数字，1 秒一个点，随内容滚动。
private final class AlbumTrimRulerView: UIView {
    /// 刻度标签
    private var labels: [UILabel] = []
    /// 小刻度点
    private var dots: [UIView] = []

    /// 按时长重铺刻度
    /// - Parameters:
    ///   - duration: 源时长
    ///   - pointsPerSecond: 每秒对应宽度
    func reload(duration: CMTime, pointsPerSecond: CGFloat) {
        labels.forEach { $0.removeFromSuperview() }
        dots.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        dots.removeAll()
        let seconds = max(CMTimeGetSeconds(duration), 0)
        guard seconds > 0, pointsPerSecond > 1 else { return }
        let height = bounds.height > 1 ? bounds.height : 20
        let major: Double = 2
        var tick = 0.0
        while tick <= seconds + 0.001 {
            let x = CGFloat(tick) * pointsPerSecond
            let isMajor = abs(tick.truncatingRemainder(dividingBy: major)) < 0.001
            if isMajor {
                let label = UILabel()
                label.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                label.textColor = UIColor(white: 1, alpha: 0.85)
                label.textAlignment = .center
                let total = Int(tick.rounded())
                label.text = String(format: "%02d:%02d", total / 60, total % 60)
                label.frame = CGRect(x: x - 22, y: 0, width: 44, height: height)
                addSubview(label)
                labels.append(label)
            } else {
                let dot = UIView()
                dot.backgroundColor = UIColor(white: 1, alpha: 0.45)
                dot.layer.cornerRadius = 1.5
                dot.frame = CGRect(x: x - 1.5, y: (height - 3) / 2, width: 3, height: 3)
                addSubview(dot)
                dots.append(dot)
            }
            tick += 1
        }
    }
}

/// 一行缩略图尺子。多段：内容可滚、剪刀居中；拖手柄只改遮罩，不重抽帧。
class AlbumTrimFilmstripView: UIView, UIScrollViewDelegate {
    /// 入出点 / 滚动 / 确认裁剪
    weak var delegate: AlbumTrimFilmstripViewDelegate?
    /// 源时长
    private var sourceDuration = CMTime.zero
    /// 保留段；至少一段
    private var segments: [AlbumTimelineSegment] = []
    /// 当前选中段
    private var selectedIndex = 0
    /// 多段：可滚源轴 + 居中剪刀
    private var isMultiMode = false
    /// 剪刀：插空隙或只切段
    private var capability: AlbumTrimFilmstripCapability = .none
    /// 当前预览头（多段=视口中心对应的源时间）
    private var previewTime = CMTime.zero
    /// 正在抽帧的资源；换片才重抽
    private var asset: AVAsset?
    /// 上次抽帧时的内容宽，差 2pt 才重抽
    private var loadedWidth: CGFloat = 0
    /// 抽帧器
    private let loader = AlbumTrimThumbnailLoader()
    /// 当前拖的类型
    private var drag: AlbumTrimFilmstripDrag = .none
    /// 多段正在拖入出点；此时禁滚，播放头可离开视口中心
    private var isDraggingHandle: Bool {
        return isMultiMode && (drag == .start || drag == .end)
    }
    /// 平移选区开始时的入点
    private var windowDragStart = CMTime.zero
    /// 平移选区开始时的出点
    private var windowDragEnd = CMTime.zero
    /// 平移手势起点的内容 x
    private var windowDragOriginX: CGFloat = 0
    /// 确认阶段：已记下锚点，滑动另一端
    private var isConfirming = false
    /// 点剪刀时记下的源时间
    private var markAnchor = CMTime.zero
    /// 程序改 offset 时不要当作用户滚动
    private var isProgrammaticScroll = false
    /// 每秒对应点宽；首尾模式 = 视口铺满整段
    private var pointsPerSecond: CGFloat = 1
    /// 每秒点宽缓存，避免每帧重建刻度
    private var laidOutPointsPerSecond: CGFloat = 0
    /// 多段时间尺高度；首尾为 0
    private var rulerHeight: CGFloat {
        return isMultiMode ? 20 : 0
    }

    /// 手柄视觉宽
    private let handleWidth: CGFloat = 16
    /// 手柄命中外扩
    private let handleSlop: CGFloat = 14
    /// 选区橙色
    private let accentColor = UIColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1)
    /// 多段视口大约展示的源秒数
    private let visibleSeconds: CGFloat = 10

    /// 横向滚动；多段开启
    private let scrollView = UIScrollView()
    /// 缩略图 + 尺 + 选区，宽度随源时长
    private let contentView = UIView()
    /// 多段时间尺
    private let rulerView = AlbumTrimRulerView()
    /// 缩略图行
    private let thumbsStack = UIStackView()
    /// 格子
    private var thumbViews: [UIImageView] = []
    /// 删除段遮罩（空隙）
    private var maskViews: [UIView] = []
    /// 每段描边手柄
    private var chromes: [AlbumTrimRegionChrome] = []
    /// 确认阶段待插入区间
    private let pendingBorder = UIView()
    /// 居中播放头，不随内容滚
    private let playhead = UIView()
    /// 居中剪刀 / 确认对勾
    private let cutterButton = UIButton(type: .custom)
    /// 手柄拖动手势；仅首尾模式挂在整条上，多段改挂在左右拉动条
    private var handlePan: UIPanGestureRecognizer!
    /// 首尾点选
    private var headTailTap: UITapGestureRecognizer!

    /// 搭条带
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

    /// 绑定资源并套上保留段；同宽同资源不重抽
    /// - Parameters:
    ///   - asset: 源视频
    ///   - duration: 源时长
    ///   - segments: 已 resolved 的段
    ///   - selectedIndex: 选中段
    ///   - allowsMultiple: 是否多段互不重叠（与 `showsCutter` 一起表示多段模式）
    ///   - showsCutter: 多段可滚条带
    ///   - capability: 剪刀行为；剪辑多段与变速分段均为 `.gapInsert`
    func configure(
        asset: AVAsset,
        duration: CMTime,
        segments: [AlbumTimelineSegment],
        selectedIndex: Int,
        allowsMultiple: Bool,
        showsCutter: Bool,
        capability: AlbumTrimFilmstripCapability = .none
    ) {
        let assetChanged = self.asset !== asset
        self.asset = asset
        sourceDuration = duration
        isMultiMode = showsCutter && allowsMultiple
        self.capability = isMultiMode ? capability : .none
        isConfirming = false
        self.segments = segments.isEmpty
            ? [AlbumTimelineSegment(sourceStart: .zero, sourceEnd: duration, speed: 1)]
            : segments
        self.selectedIndex = min(max(0, selectedIndex), self.segments.count - 1)
        previewTime = isMultiMode ? previewTime : self.segments[self.selectedIndex].sourceStart
        if assetChanged {
            loadedWidth = 0
            loader.cancel()
            clearThumbnails()
            previewTime = .zero
        }
        scrollView.isScrollEnabled = isMultiMode
        handlePan.isEnabled = !isMultiMode
        headTailTap.isEnabled = !isMultiMode
        rulerView.isHidden = !isMultiMode
        rebuildChromeIfNeeded()
        setNeedsLayout()
        layoutIfNeeded()
        reloadThumbnailsIfNeeded()
        if isMultiMode {
            scrollToTime(previewTime, animated: false)
        }
        updateCutterAppearance()
    }

    /// 只改段数据（复位 / 外部写入），不重抽
    /// - Parameters:
    ///   - segments: 保留段
    ///   - selectedIndex: 选中
    ///   - preview: 指示针
    func updateSegments(_ segments: [AlbumTimelineSegment], selectedIndex: Int, preview: CMTime) {
        isConfirming = false
        self.segments = segments.isEmpty
            ? [AlbumTimelineSegment(sourceStart: .zero, sourceEnd: sourceDuration, speed: 1)]
            : segments
        self.selectedIndex = min(max(0, selectedIndex), self.segments.count - 1)
        previewTime = preview
        rebuildChromeIfNeeded()
        layoutSelection()
        updateCutterAppearance()
        if isMultiMode {
            scrollToTime(preview, animated: true)
        }
    }

    /// 把某源时间滚到视口中心
    /// - Parameters:
    ///   - time: 源时间
    ///   - animated: 是否动画
    func scrollToTime(_ time: CMTime, animated: Bool) {
        previewTime = clampTime(time)
        guard isMultiMode, bounds.width > 1 else { return }
        isProgrammaticScroll = true
        let offset = contentX(for: previewTime) - bounds.width / 2
        scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: animated)
        if !animated {
            isProgrammaticScroll = false
        }
        layoutSelection()
        updateCutterAppearance()
    }

    /// 取消抽帧
    func cancelLoading() {
        loader.cancel()
    }

    /// 当前播放头源时间
    var cutterTime: CMTime {
        return previewTime
    }

    /// 当前选中段下标
    var currentSelectedIndex: Int {
        return selectedIndex
    }

    /// 是否正在确认裁剪范围
    var isMarkingRange: Bool {
        return isConfirming
    }

    /// 确认阶段待插入的源区间
    var pendingMarkRange: (CMTime, CMTime)? {
        return pendingRange()
    }

    /// 上次 layout 的宽度，旋转后才重新居中，避免打断手势滚动
    private var lastLayoutWidth: CGFloat = 0

    /// 子视图尺寸变化后重铺
    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateScrollMetrics()
        layoutSelection()
        reloadThumbnailsIfNeeded()
        if isMultiMode, abs(lastLayoutWidth - bounds.width) > 1 {
            lastLayoutWidth = bounds.width
            scrollToTime(previewTime, animated: false)
        }
        lastLayoutWidth = bounds.width
    }

    /// 子视图与手势
    private func setupViews() {
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        layer.cornerRadius = 6
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .fast
        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        scrollView.addSubview(contentView)

        rulerView.isHidden = true
        rulerView.isUserInteractionEnabled = false
        contentView.addSubview(rulerView)

        thumbsStack.axis = .horizontal
        thumbsStack.alignment = .fill
        thumbsStack.distribution = .fillEqually
        thumbsStack.spacing = 0
        thumbsStack.isUserInteractionEnabled = false
        contentView.addSubview(thumbsStack)

        pendingBorder.isUserInteractionEnabled = false
        pendingBorder.layer.borderColor = accentColor.cgColor
        pendingBorder.layer.borderWidth = 2
        pendingBorder.backgroundColor = accentColor.withAlphaComponent(0.18)
        pendingBorder.isHidden = true
        contentView.addSubview(pendingBorder)

        playhead.backgroundColor = UIColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
        playhead.isUserInteractionEnabled = false
        addSubview(playhead)

        cutterButton.setTitle("✂", for: .normal)
        cutterButton.setTitleColor(.white, for: .normal)
        cutterButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        cutterButton.backgroundColor = accentColor
        cutterButton.layer.cornerRadius = 12
        cutterButton.addTarget(self, action: #selector(handleCutterTap), for: .touchUpInside)
        cutterButton.isHidden = true
        addSubview(cutterButton)

        handlePan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(handlePan)
        headTailTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(headTailTap)
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

    /// 多段拉动条自己认拖，避免整条 pan 拦住 ScrollView
    /// - Parameter chrome: 一段的描边手柄
    private func attachHandlePans(to chrome: AlbumTrimRegionChrome) {
        func attach(_ handle: UIView) {
            if handle.gestureRecognizers?.contains(where: { $0 is UIPanGestureRecognizer }) == true {
                return
            }
            handle.isUserInteractionEnabled = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleChromePan(_:)))
            handle.addGestureRecognizer(pan)
            // 只有手势碰到该手柄时才会和滚动竞争；不要把 require 挂到整条 pan 上
            scrollView.panGestureRecognizer.require(toFail: pan)
        }
        attach(chrome.leftHandle)
        attach(chrome.rightHandle)
    }

    /// 段数变化时重建描边/遮罩
    private func rebuildChromeIfNeeded() {
        while chromes.count < segments.count {
            let chrome = AlbumTrimRegionChrome()
            chrome.border.isUserInteractionEnabled = false
            chrome.border.layer.borderColor = UIColor.white.cgColor
            contentView.addSubview(chrome.border)
            configureHandle(chrome.leftHandle, roundedLeft: true)
            configureHandle(chrome.rightHandle, roundedLeft: false)
            attachHandlePans(to: chrome)
            contentView.addSubview(chrome.leftHandle)
            contentView.addSubview(chrome.rightHandle)
            chromes.append(chrome)
        }
        while chromes.count > segments.count {
            let chrome = chromes.removeLast()
            chrome.border.removeFromSuperview()
            chrome.leftHandle.removeFromSuperview()
            chrome.rightHandle.removeFromSuperview()
        }
        let gapCount = segments.count + 1
        while maskViews.count < gapCount {
            let mask = UIView()
            mask.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            mask.isUserInteractionEnabled = false
            contentView.insertSubview(mask, aboveSubview: thumbsStack)
            maskViews.append(mask)
        }
        while maskViews.count > gapCount {
            maskViews.removeLast().removeFromSuperview()
        }
        contentView.bringSubviewToFront(pendingBorder)
        bringSubviewToFront(playhead)
        bringSubviewToFront(cutterButton)
    }

    /// 按时长和模式计算内容宽、pps、inset
    private func updateScrollMetrics() {
        let width = bounds.width
        let height = bounds.height
        guard width > 1, height > 1 else { return }
        let durationSeconds = max(CGFloat(CMTimeGetSeconds(sourceDuration)), 0.001)
        if isMultiMode {
            let window = min(visibleSeconds, durationSeconds)
            pointsPerSecond = width / max(window, 0.001)
        } else {
            // 首尾：缩略图左右各留手柄宽，外侧拉动条仍落在 clipsToBounds 内
            let trackWidth = max(1, width - handleWidth * 2)
            pointsPerSecond = trackWidth / durationSeconds
        }
        let contentWidth = durationSeconds * pointsPerSecond
        let trackY = rulerHeight
        if isMultiMode {
            contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)
            scrollView.contentSize = CGSize(width: contentWidth, height: height)
            let inset = width / 2
            scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        } else {
            contentView.frame = CGRect(x: handleWidth, y: 0, width: contentWidth, height: height)
            scrollView.contentSize = CGSize(width: width, height: height)
            scrollView.contentInset = .zero
            scrollView.contentOffset = .zero
        }
        rulerView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: rulerHeight)
        thumbsStack.frame = CGRect(x: 0, y: trackY, width: contentWidth, height: max(0, height - trackY))
        if isMultiMode, rulerHeight > 0, abs(laidOutPointsPerSecond - pointsPerSecond) > 0.01 {
            laidOutPointsPerSecond = pointsPerSecond
            rulerView.reload(duration: sourceDuration, pointsPerSecond: pointsPerSecond)
        }
    }

    /// 按当前保留段摆手柄、遮罩、描边
    private func layoutSelection() {
        let height = bounds.height
        let trackY = rulerHeight
        let trackHeight = max(0, height - trackY)
        guard height > 1, !segments.isEmpty, pointsPerSecond > 0 else { return }
        let implicitFull = isImplicitFullRange()
        // 1. 空隙遮罩盖在缩略图上
        for index in 0...segments.count {
            let left = index == 0 ? 0 : contentX(for: segments[index - 1].sourceEnd)
            let right = index == segments.count ? contentView.bounds.width : contentX(for: segments[index].sourceStart)
            maskViews[index].frame = CGRect(x: left, y: trackY, width: max(0, right - left), height: trackHeight)
            maskViews[index].isHidden = implicitFull && isMultiMode
        }
        // 2. 已分段白框；仅播放头所在段显示拉动条
        let hovered = indexContaining(previewTime)
        for (index, segment) in segments.enumerated() {
            let startX = contentX(for: segment.sourceStart)
            let endX = contentX(for: segment.sourceEnd)
            let chrome = chromes[index]
            let hideAsUncut = implicitFull && isMultiMode
            chrome.border.isHidden = hideAsUncut
            let showHandles: Bool
            if isMultiMode {
                // 拖动手柄时即使边越过原中心也保持拉动条，避免突然消失
                showHandles = !hideAsUncut && !isConfirming && (hovered == index || (isDraggingHandle && index == selectedIndex))
            } else {
                showHandles = index == selectedIndex
            }
            chrome.leftHandle.isHidden = !showHandles
            chrome.rightHandle.isHidden = !showHandles
            chrome.border.layer.borderWidth = showHandles ? 2 : 1
            chrome.border.layer.borderColor = UIColor.white.cgColor
            // 白框只包片段；拉动条在左右外侧，短片段也不会叠在一起
            chrome.border.frame = CGRect(
                x: startX,
                y: trackY,
                width: max(2, endX - startX),
                height: trackHeight
            )
            chrome.leftHandle.frame = CGRect(
                x: startX - handleWidth,
                y: trackY,
                width: handleWidth,
                height: trackHeight
            )
            chrome.rightHandle.frame = CGRect(
                x: endX,
                y: trackY,
                width: handleWidth,
                height: trackHeight
            )
        }
        // 3. 确认阶段：锚点到当前中心的待选区，夹在当前空隙里
        if isConfirming, let pending = pendingRange() {
            let startX = contentX(for: pending.0)
            let endX = contentX(for: pending.1)
            pendingBorder.isHidden = false
            pendingBorder.frame = CGRect(
                x: startX,
                y: trackY,
                width: max(2, endX - startX),
                height: trackHeight
            )
        } else {
            pendingBorder.isHidden = true
        }
        // 4. 播放头：闲时在视口中心；拖边越过中心时跟手，松手后再滚回中心
        let playX = playheadViewX()
        playhead.frame = CGRect(x: playX - 1, y: 0, width: 2, height: height)
        playhead.isHidden = false
        let cutterSize: CGFloat = 24
        cutterButton.frame = CGRect(
            x: playX - cutterSize / 2,
            y: trackY + (trackHeight - cutterSize) / 2,
            width: cutterSize,
            height: cutterSize
        )
        if !isMultiMode {
            cutterButton.isHidden = true
            playhead.backgroundColor = .white
        } else {
            playhead.backgroundColor = UIColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
        }
        updateCutterAppearance()
    }

    /// 播放头在条带坐标系的 x；多段闲时为视口中心，首尾要加上左侧手柄占位
    /// - Returns: 点坐标
    private func playheadViewX() -> CGFloat {
        if isMultiMode {
            return contentX(for: previewTime) - scrollView.contentOffset.x
        }
        return handleWidth + contentX(for: previewTime)
    }

    /// 剪刀 / 对勾显隐：剪辑在空隙；变速在可切开的段内
    private func updateCutterAppearance() {
        guard isMultiMode else {
            cutterButton.isHidden = true
            return
        }
        if capability == .splitOnly {
            cutterButton.setTitle("✂", for: .normal)
            cutterButton.isHidden = !canSplitAtPlayhead()
            cutterButton.alpha = 1
            return
        }
        cutterButton.setTitle(isConfirming ? "✓" : "✂", for: .normal)
        if isConfirming {
            cutterButton.isHidden = false
            let valid = pendingRange().map { rangeValid($0.0, $0.1) } ?? false
            cutterButton.alpha = valid ? 1 : 0.45
            return
        }
        let insideSegment = (indexContaining(previewTime) != nil || isDraggingHandle) && !isImplicitFullRange()
        let atMax = segments.count >= AlbumTimelineEdit.maximumSegmentCount && !isImplicitFullRange()
        cutterButton.isHidden = insideSegment || atMax
        cutterButton.alpha = 1
    }

    /// 播放头所在段能否一分为二
    /// - Returns: 未达段数上限，且切割点两侧都不短于最短时长
    private func canSplitAtPlayhead() -> Bool {
        guard capability == .splitOnly else { return false }
        guard segments.count < AlbumTimelineEdit.maximumSegmentCount else { return false }
        let index: Int?
        if let hovered = indexContaining(previewTime) {
            index = hovered
        } else if isImplicitFullRange() {
            index = 0
        } else {
            index = nil
        }
        guard let index = index, segments.indices.contains(index) else { return false }
        let segment = segments[index]
        if CMTimeCompare(CMTimeSubtract(previewTime, segment.sourceStart), AlbumTimelineEdit.minimumDuration) < 0 {
            return false
        }
        if CMTimeCompare(CMTimeSubtract(segment.sourceEnd, previewTime), AlbumTimelineEdit.minimumDuration) < 0 {
            return false
        }
        return true
    }

    /// 源时间 → 内容 x
    /// - Parameter time: 源时间
    /// - Returns: 点坐标
    private func contentX(for time: CMTime) -> CGFloat {
        return CGFloat(CMTimeGetSeconds(clampTime(time))) * pointsPerSecond
    }

    /// 内容 x → 源时间
    /// - Parameter position: 内容坐标
    /// - Returns: 源 CMTime
    private func time(atContentX position: CGFloat) -> CMTime {
        let durationSeconds = max(CMTimeGetSeconds(sourceDuration), 0)
        let seconds = Double(max(0, position) / max(pointsPerSecond, 0.001))
        let clamped = min(durationSeconds, max(0, seconds))
        let timescale = sourceDuration.timescale > 0 ? sourceDuration.timescale : 600
        return CMTime(seconds: clamped, preferredTimescale: timescale)
    }

    /// 视口中心对应的源时间
    /// - Returns: 源时间
    private func timeAtCenter() -> CMTime {
        let contentX = scrollView.contentOffset.x + bounds.width / 2
        return time(atContentX: contentX)
    }

    /// 夹进 [0, duration]
    /// - Parameter time: 原时间
    /// - Returns: 合法时间
    private func clampTime(_ time: CMTime) -> CMTime {
        return CMTimeMinimum(CMTimeMaximum(time, .zero), sourceDuration)
    }

    /// 整段尚未切成多段且仍是 1x；变速分段即使覆盖片源也要能切开
    /// - Returns: 剪辑条带里的「未切」语义
    private func isImplicitFullRange() -> Bool {
        guard segments.count == 1 else { return false }
        let only = segments[0]
        let epsilon = CMTime(seconds: 0.05, preferredTimescale: 600)
        let startsAtZero = CMTimeCompare(only.sourceStart, epsilon) <= 0
        let endsAtDuration = CMTimeCompare(CMTimeSubtract(sourceDuration, only.sourceEnd), epsilon) <= 0
        return startsAtZero && endsAtDuration && AlbumTimelineEdit.isUnitySpeed(only.speed)
    }

    /// 播放头落在哪一段里（剪辑未切整段不算；变速分段算）
    /// - Parameter time: 源时间
    /// - Returns: 段下标
    private func indexContaining(_ time: CMTime) -> Int? {
        if isImplicitFullRange() && isMultiMode && capability != .splitOnly { return nil }
        for (index, segment) in segments.enumerated() {
            if CMTimeCompare(time, segment.sourceStart) >= 0 && CMTimeCompare(time, segment.sourceEnd) <= 0 {
                return index
            }
        }
        return nil
    }

    /// 锚点所在空隙；未切整段则整条源
    /// - Parameter time: 锚点
    /// - Returns: 空隙起止
    private func gapContaining(_ time: CMTime) -> (CMTime, CMTime)? {
        if isImplicitFullRange() {
            return (.zero, sourceDuration)
        }
        var cursor = CMTime.zero
        for segment in segments {
            if CMTimeCompare(time, cursor) >= 0 && CMTimeCompare(time, segment.sourceStart) <= 0 {
                return (cursor, segment.sourceStart)
            }
            cursor = segment.sourceEnd
        }
        if CMTimeCompare(time, cursor) >= 0 && CMTimeCompare(time, sourceDuration) <= 0 {
            return (cursor, sourceDuration)
        }
        return nil
    }

    /// 确认阶段待插入区间
    /// - Returns: 入出点
    private func pendingRange() -> (CMTime, CMTime)? {
        guard isConfirming, let gap = gapContaining(markAnchor) else { return nil }
        var start = markAnchor
        var end = previewTime
        if CMTimeCompare(start, end) > 0 {
            swap(&start, &end)
        }
        start = CMTimeMaximum(start, gap.0)
        end = CMTimeMinimum(end, gap.1)
        return (start, end)
    }

    /// 待插入是否够长且不重叠
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    /// - Returns: 可确认
    private func rangeValid(_ start: CMTime, _ end: CMTime) -> Bool {
        return CMTimeCompare(CMTimeSubtract(end, start), AlbumTimelineEdit.minimumDuration) >= 0
            && segments.count < AlbumTimelineEdit.maximumSegmentCount
    }

    /// 邻段夹紧区间，避免重叠
    /// - Parameter index: 段下标
    /// - Returns: 允许的源起止
    private func neighborLimits(for index: Int) -> (CMTime, CMTime) {
        let minStart = index > 0 ? segments[index - 1].sourceEnd : .zero
        let maxEnd = index + 1 < segments.count ? segments[index + 1].sourceStart : sourceDuration
        return (minStart, maxEnd)
    }

    /// 把一段夹进邻段空隙；拖哪一端就钉死另一端，保证最短时长
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - index: 段下标
    ///   - dragging: 正在拖的边；整段平移时保持时长
    /// - Returns: 合法段
    private func clampedSegment(
        start: CMTime,
        end: CMTime,
        index: Int,
        dragging: AlbumTrimFilmstripDrag
    ) -> AlbumTimelineSegment {
        let (minStart, maxEnd) = neighborLimits(for: index)
        let minDur = AlbumTimelineEdit.minimumDuration
        var nextStart = CMTimeMaximum(start, minStart)
        var nextEnd = CMTimeMinimum(end, maxEnd)
        switch dragging {
        case .start:
            // 出点不动，入点不能越过出点 − 最短时长
            let latestStart = CMTimeSubtract(nextEnd, minDur)
            nextStart = CMTimeMinimum(nextStart, latestStart)
            nextStart = CMTimeMaximum(nextStart, minStart)
        case .end:
            // 入点不动，出点不能早于入点 + 最短时长
            let earliestEnd = CMTimeAdd(nextStart, minDur)
            nextEnd = CMTimeMaximum(nextEnd, earliestEnd)
            nextEnd = CMTimeMinimum(nextEnd, maxEnd)
        case .window, .none:
            if CMTimeCompare(CMTimeSubtract(nextEnd, nextStart), minDur) < 0 {
                nextEnd = CMTimeMinimum(CMTimeAdd(nextStart, minDur), maxEnd)
                if CMTimeCompare(CMTimeSubtract(nextEnd, nextStart), minDur) < 0 {
                    nextStart = CMTimeMaximum(CMTimeSubtract(nextEnd, minDur), minStart)
                }
            }
        }
        let inherited = index >= 0 && index < segments.count
            ? AlbumTimelineEdit.clampedSpeed(segments[index].speed)
            : 1
        return AlbumTimelineSegment(sourceStart: nextStart, sourceEnd: nextEnd, speed: inherited)
    }

    /// 写入选中段并回调
    /// - Parameters:
    ///   - start: 入点
    ///   - end: 出点
    ///   - preview: 指示针
    ///   - emit: 是否回调
    private func applySelected(start: CMTime, end: CMTime, preview: CMTime, emit: Bool) {
        guard selectedIndex >= 0, selectedIndex < segments.count else { return }
        segments[selectedIndex] = clampedSegment(
            start: start,
            end: end,
            index: selectedIndex,
            dragging: drag
        )
        let segment = segments[selectedIndex]
        var seek = preview
        if CMTimeCompare(seek, segment.sourceStart) < 0 {
            seek = segment.sourceStart
        } else if CMTimeCompare(seek, segment.sourceEnd) > 0 {
            seek = segment.sourceEnd
        }
        // 多段拖边：入出点越过播放头时播放头跟着走；首尾模式播放头就是被拖的那一端
        if isMultiMode {
            followPlayhead(within: segment)
        } else {
            previewTime = seek
        }
        if emit {
            delegate?.filmstrip(self, didChange: segments, selectedIndex: selectedIndex, previewTime: seek)
        }
    }

    /// 入出点越过当前播放头时，播放头贴在被拖的那一端上
    /// - Parameter segment: 已夹紧的选中段
    private func followPlayhead(within segment: AlbumTimelineSegment) {
        if CMTimeCompare(previewTime, segment.sourceStart) < 0 {
            previewTime = segment.sourceStart
        } else if CMTimeCompare(previewTime, segment.sourceEnd) > 0 {
            previewTime = segment.sourceEnd
        }
    }

    /// 清空格子图，留下底色
    private func clearThumbnails() {
        thumbViews.forEach { $0.image = nil }
    }

    /// 宽度够了且格数变了才抽；拖手柄不进这里
    private func reloadThumbnailsIfNeeded() {
        guard let asset = asset, bounds.width > 8, bounds.height > 8 else { return }
        let trackHeight = max(8, bounds.height - rulerHeight)
        let contentWidth = max(contentView.bounds.width, bounds.width)
        let cellWidth = trackHeight
        let count = min(120, max(4, Int(ceil(contentWidth / cellWidth))))
        if thumbViews.count != count {
            rebuildThumbViews(count: count)
            loadedWidth = 0
        }
        if abs(loadedWidth - contentWidth) < 2 { return }
        loadedWidth = contentWidth
        let maxPixel = min(160, trackHeight * UIScreen.main.scale)
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

    /// 首尾模式命中窗体或手柄
    /// - Parameter point: contentView 坐标
    /// - Returns: 段与拖类型
    private func hitTestHeadTail(atContent point: CGPoint) -> (Int, AlbumTrimFilmstripDrag) {
        func kind(for index: Int) -> AlbumTrimFilmstripDrag {
            let segment = segments[index]
            let startX = contentX(for: segment.sourceStart)
            let endX = contentX(for: segment.sourceEnd)
            let leftHit = CGRect(
                x: startX - handleWidth - handleSlop,
                y: -handleSlop,
                width: handleWidth + handleSlop * 2,
                height: bounds.height + handleSlop * 2
            )
            let rightHit = CGRect(
                x: endX - handleSlop,
                y: -handleSlop,
                width: handleWidth + handleSlop * 2,
                height: bounds.height + handleSlop * 2
            )
            if leftHit.contains(point) && rightHit.contains(point) {
                return abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
            }
            if leftHit.contains(point) { return .start }
            if rightHit.contains(point) { return .end }
            if point.x > startX && point.x < endX { return .window }
            return .none
        }
        let selectedKind = kind(for: selectedIndex)
        if selectedKind != .none {
            return (selectedIndex, selectedKind)
        }
        for index in segments.indices where index != selectedIndex {
            let hit = kind(for: index)
            if hit != .none {
                return (index, hit)
            }
        }
        return (selectedIndex, .none)
    }

    /// 点选一段（首尾）或忽略（多段滚动交给 ScrollView）
    /// - Parameter gesture: 轻点
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard !isMultiMode else { return }
        let point = contentView.convert(gesture.location(in: self), from: self)
        let (index, kind) = hitTestHeadTail(atContent: point)
        guard kind != .none else { return }
        selectedIndex = index
        previewTime = segments[index].sourceStart
        layoutSelection()
        delegate?.filmstrip(self, didChange: segments, selectedIndex: selectedIndex, previewTime: previewTime)
    }

    /// 点居中剪刀：剪辑进入确认；变速则当场切开
    @objc private func handleCutterTap() {
        guard isMultiMode else { return }
        if capability == .splitOnly {
            splitAtPlayhead()
            return
        }
        if isConfirming {
            if let pending = pendingRange(), rangeValid(pending.0, pending.1) {
                delegate?.filmstrip(self, didConfirmRangeFrom: pending.0, to: pending.1)
            }
            isConfirming = false
            updateCutterAppearance()
            layoutSelection()
            return
        }
        guard indexContaining(previewTime) == nil else { return }
        guard gapContaining(previewTime) != nil else { return }
        guard segments.count < AlbumTimelineEdit.maximumSegmentCount || isImplicitFullRange() else { return }
        isConfirming = true
        markAnchor = previewTime
        updateCutterAppearance()
        layoutSelection()
    }

    /// 拖入点 / 出点 / 整段（首尾）
    /// - Parameter gesture: 平移
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = contentView.convert(gesture.location(in: self), from: self)
        switch gesture.state {
        case .began:
            let hit = hitTestHeadTail(atContent: point)
            selectedIndex = hit.0
            drag = hit.1
            let segment = segments[selectedIndex]
            windowDragStart = segment.sourceStart
            windowDragEnd = segment.sourceEnd
            windowDragOriginX = point.x
        case .changed:
            guard selectedIndex >= 0, selectedIndex < segments.count else { return }
            let segment = segments[selectedIndex]
            switch drag {
            case .none:
                break
            case .start:
                applySelected(start: time(atContentX: point.x), end: segment.sourceEnd, preview: time(atContentX: point.x), emit: true)
                layoutSelection()
            case .end:
                applySelected(start: segment.sourceStart, end: time(atContentX: point.x), preview: time(atContentX: point.x), emit: true)
                layoutSelection()
            case .window:
                let (minStart, maxEnd) = neighborLimits(for: selectedIndex)
                let shift = CMTimeSubtract(time(atContentX: point.x), time(atContentX: windowDragOriginX))
                let kept = CMTimeSubtract(windowDragEnd, windowDragStart)
                var newStart = CMTimeAdd(windowDragStart, shift)
                newStart = CMTimeMaximum(newStart, minStart)
                var newEnd = CMTimeAdd(newStart, kept)
                if CMTimeCompare(newEnd, maxEnd) > 0 {
                    newEnd = maxEnd
                    newStart = CMTimeMaximum(CMTimeSubtract(newEnd, kept), minStart)
                }
                applySelected(start: newStart, end: newEnd, preview: newStart, emit: true)
                layoutSelection()
            }
        default:
            drag = .none
        }
    }

    /// 在播放头把当前段一分为二，两侧继承 speed
    private func splitAtPlayhead() {
        guard canSplitAtPlayhead() else { return }
        let index = indexContaining(previewTime) ?? 0
        let segment = segments[index]
        let inherited = AlbumTimelineEdit.clampedSpeed(segment.speed)
        var next = segments
        next.remove(at: index)
        next.insert(
            AlbumTimelineSegment(sourceStart: segment.sourceStart, sourceEnd: previewTime, speed: inherited),
            at: index
        )
        next.insert(
            AlbumTimelineSegment(sourceStart: previewTime, sourceEnd: segment.sourceEnd, speed: inherited),
            at: index + 1
        )
        segments = next
        selectedIndex = index
        rebuildChromeIfNeeded()
        layoutSelection()
        updateCutterAppearance()
        delegate?.filmstrip(self, didChange: segments, selectedIndex: selectedIndex, previewTime: previewTime)
    }

    /// 多段：拖某一端拉动条改入出点
    /// - Parameter gesture: 手柄上的平移
    @objc private func handleChromePan(_ gesture: UIPanGestureRecognizer) {
        guard isMultiMode, let handle = gesture.view else { return }
        // 用 contentView 坐标，避免手柄跟手移动后 location(in: handle) 乱跳
        let point = gesture.location(in: contentView)
        switch gesture.state {
        case .began:
            guard let hit = chromeHit(for: handle) else {
                drag = .none
                return
            }
            selectedIndex = hit.0
            drag = hit.1
            // 拖边时禁止条带跟着滚，否则两端会一起平移
            scrollView.isScrollEnabled = false
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        case .changed:
            guard selectedIndex >= 0, selectedIndex < segments.count else { return }
            let segment = segments[selectedIndex]
            switch drag {
            case .start:
                applySelected(start: time(atContentX: point.x), end: segment.sourceEnd, preview: time(atContentX: point.x), emit: true)
                layoutSelection()
            case .end:
                applySelected(start: segment.sourceStart, end: time(atContentX: point.x), preview: time(atContentX: point.x), emit: true)
                layoutSelection()
            default:
                break
            }
        default:
            drag = .none
            scrollView.isScrollEnabled = true
            // 松手后把当前播放头时间滚回视口中心
            scrollToTime(previewTime, animated: true)
        }
    }

    /// 手柄属于哪一段、入点还是出点
    /// - Parameter handle: 被拖的视图
    /// - Returns: 段下标与拖类型
    private func chromeHit(for handle: UIView) -> (Int, AlbumTrimFilmstripDrag)? {
        for (index, chrome) in chromes.enumerated() {
            if handle === chrome.leftHandle {
                return (index, .start)
            }
            if handle === chrome.rightHandle {
                return (index, .end)
            }
        }
        return nil
    }

    /// 滚动中：中心时间即播放头；确认阶段另一端跟着走
    /// - Parameter scrollView: 条带滚动
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isMultiMode, !isDraggingHandle else { return }
        if isProgrammaticScroll {
            // 松手回中时 offset 在变，必须重铺细线，否则会停在拖动结束时的 x
            layoutSelection()
            return
        }
        previewTime = timeAtCenter()
        if let hovered = indexContaining(previewTime) {
            selectedIndex = hovered
        }
        layoutSelection()
        delegate?.filmstrip(self, didScrubTo: previewTime, selectedIndex: selectedIndex)
    }

    /// 动画 setContentOffset 结束
    /// - Parameter scrollView: 条带滚动
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isProgrammaticScroll = false
        previewTime = timeAtCenter()
        layoutSelection()
        updateCutterAppearance()
    }

    /// 用户接手滚动时取消程序滚动标记
    /// - Parameter scrollView: 条带滚动
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isProgrammaticScroll = false
    }
}
