//
//  AlbumSpeedPanelView.swift
//  LiveStreaming
//
//  视频变速面板：整段同一 speed，或分段各改 speed。只改时间线，不碰像素。
//

import UIKit
import SnapKit
import AVFoundation
import CoreMedia

/// 变速面板模式
enum AlbumSpeedPanelMode: Int {
    /// 当前全部保留段同一倍速
    case whole = 0
    /// 选中段独立倍速；条带交互与剪辑多段相同（空隙插入 + 入出点）
    case segmented = 1
}

/// 变速面板回调；对齐 TrimPanel，由 VC 写入 document
protocol AlbumSpeedPanelViewDelegate: AnyObject {
    /// 时间线变化；`previewTime` 是源时间
    /// - Parameters:
    ///   - panel: 面板
    ///   - timeline: 最新时间线
    ///   - previewTime: 应显示的源时间
    func speedPanel(
        _ panel: AlbumSpeedPanelView,
        didChange timeline: AlbumTimelineEdit,
        previewTime: CMTime
    )

    /// 面板收起，编辑页按 Mapper 重建播放器
    /// - Parameter panel: 面板
    func speedPanelDidDismiss(_ panel: AlbumSpeedPanelView)

    /// 滚动条带只 seek
    /// - Parameters:
    ///   - panel: 面板
    ///   - previewTime: 视口中心源时间
    func speedPanel(_ panel: AlbumSpeedPanelView, didScrub previewTime: CMTime)

    /// 整段页试听倍率；分段页为 1。正式预览不走这条。
    /// - Parameters:
    ///   - panel: 面板
    ///   - rate: AVPlayer.rate
    func speedPanel(_ panel: AlbumSpeedPanelView, didChangePreviewRate rate: Float)
}

/// 底部片段格子（倍速角标）
private final class AlbumSpeedClipCell: UICollectionViewCell {
    /// 封面
    let imageView = UIImageView()
    /// 倍速角标
    let speedLabel = UILabel()
    /// 选中描边
    private let ring = UIView()

    /// 搭格子
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        imageView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        contentView.addSubview(imageView)
        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = 8
        ring.isUserInteractionEnabled = false
        contentView.addSubview(ring)
        speedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        speedLabel.textColor = .white
        speedLabel.textAlignment = .center
        speedLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        speedLabel.layer.cornerRadius = 3
        speedLabel.clipsToBounds = true
        contentView.addSubview(speedLabel)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        ring.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        speedLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(3)
            make.height.equalTo(14)
        }
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 选中描边
    /// - Parameter selected: 是否当前段
    func applySelection(_ selected: Bool) {
        ring.layer.borderColor = (selected ? UIColor(red: 1, green: 0.48, blue: 0.12, alpha: 1) : UIColor.clear).cgColor
    }
}

/// 从底部弹出的变速卡片；点空白关闭。
class AlbumSpeedPanelView: UIView {
    /// 改时间线时通知编辑页
    weak var delegate: AlbumSpeedPanelViewDelegate?
    /// 源时长
    private var sourceDuration = CMTime.zero
    /// 当前文档时间线（值拷贝）
    private var timeline = AlbumTimelineEdit()
    /// 正在编辑的源
    private var asset: AVAsset?
    /// 选中段
    private var selectedIndex = 0
    /// 当前模式
    private var mode: AlbumSpeedPanelMode = .whole
    /// 片段封面
    private var clipImages: [Int: UIImage] = [:]
    /// 片段封面抽帧
    private let clipLoader = AlbumTrimThumbnailLoader()
    /// 滑杆回写时不要再 emit
    private var isUpdatingFromUI = false
    /// 档位
    private let presetSpeeds: [Double] = [0.5, 1, 1.5, 2, 3, 4]

    /// 卡片外透明点击区
    private let dimmingView = UIButton(type: .custom)
    /// 贴底面板
    private let cardView = UIView()
    /// 深色毛玻璃
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 复位倍速为 1，保留裁切区间
    private let resetButton = UIButton(type: .system)
    /// 完成
    private let closeButton = UIButton(type: .system)
    /// 整段 / 分段
    private let modeControl = UISegmentedControl(items: ["整段", "分段"])
    /// 当前倍速文案
    private let speedLabel = UILabel()
    /// 连续倍速
    private let speedSlider = UISlider()
    /// 常用档
    private let presetControl = UISegmentedControl(items: ["0.5x", "1x", "1.5x", "2x", "3x", "4x"])
    /// 入点 / 当前时间
    private let startLabel = UILabel()
    /// 出点 / 总长
    private let endLabel = UILabel()
    /// 时长 / 段数
    private let durationLabel = UILabel()
    /// 源轴条带（仅分段）
    private let filmstrip = AlbumTrimFilmstripView()
    /// 删除选中段
    private let deleteButton = UIButton(type: .system)
    /// 片段标题
    private let clipsTitleLabel = UILabel()
    /// 片段列表
    private let clipsView: UICollectionView
    /// 卡片贴底
    private var cardBottomConstraint: Constraint?
    /// 整段高度
    private let wholeCardHeight: CGFloat = 168
    /// 分段高度（倍速控件 + 与剪辑多段相同的条带/删除/列表）
    private let segmentedCardHeight: CGFloat = 448
    /// 分段条带高度
    private let filmstripHeight: CGFloat = 80

    /// 搭建子视图；默认隐藏
    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 56, height: 56)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        clipsView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setupViews()
        isHidden = true
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 弹出面板
    /// - Parameters:
    ///   - asset: 源视频
    ///   - timeline: 当前文档时间线
    func present(asset: AVAsset, timeline: AlbumTimelineEdit) {
        self.asset = asset
        sourceDuration = asset.duration
        self.timeline = timeline
        let segments = timeline.resolvedSegments(sourceDuration: asset.duration)
        selectedIndex = 0
        mode = segments.count > 1 ? .segmented : .whole
        modeControl.selectedSegmentIndex = mode.rawValue
        applyModeLayout()
        syncSpeedControls()
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
        }
        emitPreviewRate()
    }

    /// 收起面板并停抽帧
    /// - Parameter notify: 是否回调 dismiss；导出独占时为 false
    func dismiss(notify: Bool = true) {
        if isHidden {
            return
        }
        filmstrip.cancelLoading()
        clipLoader.cancel()
        let height = mode == .segmented ? segmentedCardHeight : wholeCardHeight
        cardBottomConstraint?.update(offset: height + 20)
        UIView.animate(withDuration: 0.22, animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
            if notify {
                self.delegate?.speedPanelDidDismiss(self)
            }
        })
    }

    /// 空白点击关闭
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isHidden {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    /// 子视图与约束
    private func setupViews() {
        dimmingView.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        addSubview(dimmingView)

        cardView.clipsToBounds = true
        if #available(iOS 11.0, *) {
            cardView.layer.cornerRadius = 16
            cardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        addSubview(cardView)
        cardView.addSubview(blurView)

        resetButton.setTitle("复位", for: .normal)
        resetButton.setTitleColor(UIColor(white: 1, alpha: 0.85), for: .normal)
        resetButton.addTarget(self, action: #selector(handleReset), for: .touchUpInside)
        cardView.addSubview(resetButton)

        closeButton.setTitle("完成", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        cardView.addSubview(closeButton)

        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(handleModeChanged), for: .valueChanged)
        if #available(iOS 13.0, *) {
            modeControl.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
        }
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        cardView.addSubview(modeControl)

        speedLabel.textColor = .white
        speedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        speedLabel.textAlignment = .center
        cardView.addSubview(speedLabel)

        speedSlider.minimumValue = Float(AlbumTimelineEdit.minimumSpeed)
        speedSlider.maximumValue = Float(AlbumTimelineEdit.maximumSpeed)
        speedSlider.minimumTrackTintColor = UIColor(red: 1, green: 0.48, blue: 0.12, alpha: 1)
        speedSlider.addTarget(self, action: #selector(handleSliderChanged), for: .valueChanged)
        cardView.addSubview(speedSlider)

        if #available(iOS 13.0, *) {
            presetControl.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
        }
        presetControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        presetControl.addTarget(self, action: #selector(handlePresetChanged), for: .valueChanged)
        cardView.addSubview(presetControl)

        configureCaption(startLabel)
        configureCaption(endLabel)
        durationLabel.textColor = UIColor(white: 1, alpha: 0.85)
        durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textAlignment = .center
        cardView.addSubview(startLabel)
        cardView.addSubview(endLabel)
        cardView.addSubview(durationLabel)

        filmstrip.delegate = self
        cardView.addSubview(filmstrip)

        deleteButton.setTitle("删除片段", for: .normal)
        deleteButton.setTitleColor(.white, for: .normal)
        deleteButton.backgroundColor = UIColor(white: 1, alpha: 0.16)
        deleteButton.layer.cornerRadius = 8
        deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
        cardView.addSubview(deleteButton)

        clipsTitleLabel.text = "视频片段"
        clipsTitleLabel.textColor = UIColor(white: 1, alpha: 0.75)
        clipsTitleLabel.font = UIFont.systemFont(ofSize: 13)
        cardView.addSubview(clipsTitleLabel)

        clipsView.backgroundColor = .clear
        clipsView.dataSource = self
        clipsView.delegate = self
        clipsView.showsHorizontalScrollIndicator = false
        clipsView.register(AlbumSpeedClipCell.self, forCellWithReuseIdentifier: "clip")
        cardView.addSubview(clipsView)

        dimmingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cardView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(wholeCardHeight)
            cardBottomConstraint = make.bottom.equalToSuperview().offset(wholeCardHeight + 20).constraint
        }
        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        resetButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.equalToSuperview().offset(16)
        }
        closeButton.snp.makeConstraints { make in
            make.centerY.equalTo(resetButton)
            make.trailing.equalToSuperview().offset(-16)
        }
        modeControl.snp.makeConstraints { make in
            make.centerY.equalTo(resetButton)
            make.centerX.equalToSuperview()
            make.width.equalTo(160)
        }
        speedLabel.snp.makeConstraints { make in
            make.top.equalTo(resetButton.snp.bottom).offset(12)
            make.centerX.equalToSuperview()
        }
        speedSlider.snp.makeConstraints { make in
            make.top.equalTo(speedLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(20)
        }
        presetControl.snp.makeConstraints { make in
            make.top.equalTo(speedSlider.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(28)
        }
        startLabel.snp.makeConstraints { make in
            make.top.equalTo(presetControl.snp.bottom).offset(12)
            make.leading.equalToSuperview().offset(16)
        }
        endLabel.snp.makeConstraints { make in
            make.centerY.equalTo(startLabel)
            make.trailing.equalToSuperview().offset(-16)
        }
        durationLabel.snp.makeConstraints { make in
            make.centerY.equalTo(startLabel)
            make.centerX.equalToSuperview()
        }
        filmstrip.snp.makeConstraints { make in
            make.top.equalTo(startLabel.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(filmstripHeight)
        }
        deleteButton.snp.makeConstraints { make in
            make.top.equalTo(filmstrip.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(32)
        }
        clipsTitleLabel.snp.makeConstraints { make in
            make.top.equalTo(deleteButton.snp.bottom).offset(12)
            make.leading.equalToSuperview().offset(16)
        }
        clipsView.snp.makeConstraints { make in
            make.top.equalTo(clipsTitleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(56)
        }
    }

    /// 时间标签样式
    /// - Parameter label: 标签
    private func configureCaption(_ label: UILabel) {
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    }

    /// 按模式改卡片高度与分段控件显隐
    private func applyModeLayout() {
        let segmented = mode == .segmented
        startLabel.isHidden = !segmented
        endLabel.isHidden = !segmented
        durationLabel.isHidden = !segmented
        filmstrip.isHidden = !segmented
        deleteButton.isHidden = !segmented
        clipsTitleLabel.isHidden = !segmented
        clipsView.isHidden = !segmented
        let height = segmented ? segmentedCardHeight : wholeCardHeight
        cardView.snp.updateConstraints { make in
            make.height.equalTo(height)
        }
    }

    /// 当前应显示在滑杆上的倍速
    /// - Returns: 整段为各段公共值（不一致则 1）；分段为选中段
    private func displayedSpeed() -> Double {
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        guard !segments.isEmpty else { return 1 }
        if mode == .segmented {
            selectedIndex = min(selectedIndex, segments.count - 1)
            return AlbumTimelineEdit.clampedSpeed(segments[selectedIndex].speed)
        }
        let first = AlbumTimelineEdit.clampedSpeed(segments[0].speed)
        let same = segments.allSatisfy {
            abs(AlbumTimelineEdit.clampedSpeed($0.speed) - first) <= AlbumTimelineEdit.speedEpsilon
        }
        return same ? first : 1
    }

    /// 同步滑杆、档位、文案，不写文档
    private func syncSpeedControls() {
        isUpdatingFromUI = true
        let speed = displayedSpeed()
        speedSlider.value = Float(speed)
        speedLabel.text = Self.formatSpeed(speed)
        if let presetIndex = presetSpeeds.firstIndex(where: {
            abs($0 - speed) <= AlbumTimelineEdit.speedEpsilon
        }) {
            presetControl.selectedSegmentIndex = presetIndex
        } else {
            presetControl.selectedSegmentIndex = UISegmentedControl.noSegment
        }
        isUpdatingFromUI = false
    }

    /// 用当前时间线刷新条带
    private func reloadFilmstrip() {
        guard mode == .segmented, let asset = asset else { return }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        selectedIndex = min(selectedIndex, max(0, segments.count - 1))
        filmstrip.configure(
            asset: asset,
            duration: sourceDuration,
            segments: segments,
            selectedIndex: selectedIndex,
            allowsMultiple: true,
            showsCutter: true,
            capability: .gapInsert
        )
    }

    /// 刷新入出点 / 当前时间文案（与剪辑多段同一套）
    private func refreshLabels() {
        guard mode == .segmented else { return }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        guard !segments.isEmpty else { return }
        selectedIndex = min(selectedIndex, segments.count - 1)
        if filmstrip.isMarkingRange, let pending = filmstrip.pendingMarkRange {
            startLabel.text = "入点 \(formatTime(pending.0))"
            endLabel.text = "出点 \(formatTime(pending.1))"
            let kept = max(0, CMTimeGetSeconds(CMTimeSubtract(pending.1, pending.0)))
            durationLabel.text = String(format: "确认 %.1f 秒", kept)
        } else {
            startLabel.text = "当前 \(formatTime(filmstrip.cutterTime))"
            endLabel.text = "总长 \(formatTime(sourceDuration))"
            let kept = segments.reduce(0.0) { partial, item in
                if timeline.isImplicitFullRange(sourceDuration: sourceDuration) {
                    return 0
                }
                return partial + max(0, CMTimeGetSeconds(CMTimeSubtract(item.sourceEnd, item.sourceStart)))
            }
            let count = timeline.isImplicitFullRange(sourceDuration: sourceDuration) ? 0 : segments.count
            durationLabel.text = String(format: "%d 段 · %.1f 秒", count, kept)
        }
        deleteButton.isEnabled = !timeline.isImplicitFullRange(sourceDuration: sourceDuration)
        deleteButton.alpha = deleteButton.isEnabled ? 1 : 0.4
    }

    /// m:ss
    /// - Parameter time: 源时间
    /// - Returns: 文案
    private func formatTime(_ time: CMTime) -> String {
        let seconds = max(0, CMTimeGetSeconds(time))
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 刷新片段列表封面
    private func reloadClips() {
        clipImages.removeAll()
        clipsView.reloadData()
        guard mode == .segmented, let asset = asset else { return }
        if timeline.isImplicitFullRange(sourceDuration: sourceDuration) { return }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let times = segments.map { segment -> CMTime in
            let half = CMTimeMultiplyByRatio(
                CMTimeSubtract(segment.sourceEnd, segment.sourceStart),
                multiplier: 1,
                divisor: 2
            )
            return CMTimeAdd(segment.sourceStart, half)
        }
        clipLoader.load(asset: asset, times: times, maxPixel: 120) { [weak self] index, image in
            guard let self = self else { return }
            self.clipImages[index] = image
            guard index < self.clipsView.numberOfItems(inSection: 0) else { return }
            self.clipsView.reloadItems(at: [IndexPath(item: index, section: 0)])
        }
    }

    /// 写回文档并通知预览
    /// - Parameter previewTime: seek 目标
    private func emit(previewTime: CMTime) {
        delegate?.speedPanel(self, didChange: timeline, previewTime: previewTime)
        emitPreviewRate()
        refreshLabels()
        if mode == .segmented {
            clipsView.reloadData()
        }
    }

    /// 整段试听用当前倍速；分段条带是源轴，rate 固定 1
    private func emitPreviewRate() {
        let rate: Float
        if mode == .whole {
            rate = Float(displayedSpeed())
        } else {
            rate = 1
        }
        delegate?.speedPanel(self, didChangePreviewRate: rate)
    }

    /// 1.5x / 2x
    /// - Parameter speed: 倍速
    /// - Returns: 文案
    private static func formatSpeed(_ speed: Double) -> String {
        let value = AlbumTimelineEdit.clampedSpeed(speed)
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "%.0fx", value.rounded())
        }
        return String(format: "%.2fx", value)
    }

    /// 点空白或完成
    @objc private func handleDimmingTap() {
        dismiss()
    }

    /// 切模式：整段把各段 speed 拉齐到当前滑杆
    @objc private func handleModeChanged() {
        let next = AlbumSpeedPanelMode(rawValue: modeControl.selectedSegmentIndex) ?? .whole
        if next == .whole {
            let speed = displayedSpeed()
            timeline = timeline.applyingSpeed(speed, at: nil, sourceDuration: sourceDuration)
            selectedIndex = 0
        }
        mode = next
        applyModeLayout()
        syncSpeedControls()
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        let preview = timeline.resolvedSegments(sourceDuration: sourceDuration)[0].sourceStart
        emit(previewTime: preview)
        layoutIfNeeded()
    }

    /// 各段回到 1x，保留裁切区间
    @objc private func handleReset() {
        timeline = timeline.applyingSpeed(1, at: nil, sourceDuration: sourceDuration)
        selectedIndex = 0
        syncSpeedControls()
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        emit(previewTime: .zero)
    }

    /// 删掉选中段；最后一段删完回到未切整段（倍速复位为 1）
    @objc private func handleDelete() {
        let next = timeline.removingSegment(at: selectedIndex, sourceDuration: sourceDuration)
        guard next != timeline else { return }
        timeline = next
        selectedIndex = 0
        syncSpeedControls()
        reloadFilmstrip()
        reloadClips()
        emit(previewTime: filmstrip.cutterTime)
    }

    /// 滑杆改速
    @objc private func handleSliderChanged() {
        guard !isUpdatingFromUI else { return }
        applySpeed(Double(speedSlider.value), previewTime: currentPreviewTime())
    }

    /// 档位改速
    @objc private func handlePresetChanged() {
        guard !isUpdatingFromUI else { return }
        let index = presetControl.selectedSegmentIndex
        guard presetSpeeds.indices.contains(index) else { return }
        applySpeed(presetSpeeds[index], previewTime: currentPreviewTime())
    }

    /// 写入 speed 并刷新控件
    /// - Parameters:
    ///   - speed: 目标倍速
    ///   - previewTime: seek
    private func applySpeed(_ speed: Double, previewTime: CMTime) {
        let index: Int? = mode == .segmented ? selectedIndex : nil
        timeline = timeline.applyingSpeed(speed, at: index, sourceDuration: sourceDuration)
        syncSpeedControls()
        if mode == .segmented {
            filmstrip.updateSegments(
                timeline.resolvedSegments(sourceDuration: sourceDuration),
                selectedIndex: selectedIndex,
                preview: previewTime
            )
        }
        emit(previewTime: previewTime)
    }

    /// 当前条带播放头；整段为选中段中点
    /// - Returns: 源时间
    private func currentPreviewTime() -> CMTime {
        if mode == .segmented {
            return filmstrip.cutterTime
        }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let segment = segments[min(selectedIndex, segments.count - 1)]
        return CMTimeAdd(
            segment.sourceStart,
            CMTimeMultiplyByRatio(
                CMTimeSubtract(segment.sourceEnd, segment.sourceStart),
                multiplier: 1,
                divisor: 2
            )
        )
    }
}

extension AlbumSpeedPanelView: AlbumTrimFilmstripViewDelegate {
    /// 拖入出点后写文档（speed 由条带继承）
    func filmstrip(
        _ filmstrip: AlbumTrimFilmstripView,
        didChange segments: [AlbumTimelineSegment],
        selectedIndex: Int,
        previewTime: CMTime
    ) {
        self.selectedIndex = selectedIndex
        timeline = timeline.applyingSegments(segments, sourceDuration: sourceDuration)
        syncSpeedControls()
        emit(previewTime: previewTime)
    }

    /// 滚动只 seek，并跟上选中段倍速到滑杆
    func filmstrip(_ filmstrip: AlbumTrimFilmstripView, didScrubTo time: CMTime, selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        syncSpeedControls()
        refreshLabels()
        if mode == .segmented {
            clipsView.reloadData()
        }
        delegate?.speedPanel(self, didScrub: time)
    }

    /// 空隙确认一段，与剪辑多段相同
    func filmstrip(_ filmstrip: AlbumTrimFilmstripView, didConfirmRangeFrom start: CMTime, to end: CMTime) {
        guard let next = timeline.insertingSegment(start: start, end: end, sourceDuration: sourceDuration) else {
            return
        }
        timeline = next
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let mid = CMTimeAdd(
            start,
            CMTimeMultiplyByRatio(CMTimeSubtract(end, start), multiplier: 1, divisor: 2)
        )
        selectedIndex = segments.firstIndex(where: {
            CMTimeCompare(mid, $0.sourceStart) >= 0 && CMTimeCompare(mid, $0.sourceEnd) <= 0
        }) ?? max(0, segments.count - 1)
        filmstrip.updateSegments(segments, selectedIndex: selectedIndex, preview: start)
        syncSpeedControls()
        reloadClips()
        emit(previewTime: start)
    }
}

extension AlbumSpeedPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    /// 片段数
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if timeline.isImplicitFullRange(sourceDuration: sourceDuration) {
            return 0
        }
        return timeline.resolvedSegments(sourceDuration: sourceDuration).count
    }

    /// 格子
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "clip", for: indexPath) as! AlbumSpeedClipCell
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let segment = segments[indexPath.item]
        cell.imageView.image = clipImages[indexPath.item]
        cell.speedLabel.text = Self.formatSpeed(segment.speed)
        cell.applySelection(indexPath.item == selectedIndex)
        return cell
    }

    /// 点选一段，滑杆切到该段 speed
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectedIndex = indexPath.item
        let segment = timeline.resolvedSegments(sourceDuration: sourceDuration)[indexPath.item]
        filmstrip.updateSegments(
            timeline.resolvedSegments(sourceDuration: sourceDuration),
            selectedIndex: selectedIndex,
            preview: CMTimeAdd(
                segment.sourceStart,
                CMTimeMultiplyByRatio(
                    CMTimeSubtract(segment.sourceEnd, segment.sourceStart),
                    multiplier: 1,
                    divisor: 2
                )
            )
        )
        syncSpeedControls()
        refreshLabels()
        collectionView.reloadData()
        delegate?.speedPanel(self, didScrub: filmstrip.cutterTime)
    }
}
