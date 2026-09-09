//
//  AlbumTrimPanelView.swift
//  LiveStreaming
//
//  视频剪辑面板：首尾裁剪 + 多段裁剪。只改时间线文档，不碰像素。
//

import UIKit
import SnapKit
import AVFoundation
import CoreMedia

/// 剪辑面板模式
enum AlbumTrimPanelMode: Int {
    /// 单段入出点
    case headTail = 0
    /// 多段保留，剪刀分割
    case multi = 1
}

/// 收尾面板回调
protocol AlbumTrimPanelViewDelegate: AnyObject {
    /// 时间线变化；`previewTime` 是源时间，供播放器 seek
    /// - Parameters:
    ///   - panel: 面板
    ///   - timeline: 最新时间线
    ///   - previewTime: 应显示的源时间
    func trimPanel(
        _ panel: AlbumTrimPanelView,
        didChange timeline: AlbumTimelineEdit,
        previewTime: CMTime
    )

    /// 面板收起，编辑页可按多段重建 Composition
    /// - Parameter panel: 面板
    func trimPanelDidDismiss(_ panel: AlbumTrimPanelView)

    /// 滚动条带只 seek，不写时间线
    /// - Parameters:
    ///   - panel: 面板
    ///   - previewTime: 视口中心源时间
    func trimPanel(_ panel: AlbumTrimPanelView, didScrub previewTime: CMTime)
}

/// 底部片段格子
private final class AlbumTrimClipCell: UICollectionViewCell {
    /// 封面
    let imageView = UIImageView()
    /// 时长角标
    let durationLabel = UILabel()
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
        durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        durationLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        durationLabel.layer.cornerRadius = 3
        durationLabel.clipsToBounds = true
        contentView.addSubview(durationLabel)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        ring.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        durationLabel.snp.makeConstraints { make in
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

/// 从底部弹出的剪辑卡片；点空白关闭。
class AlbumTrimPanelView: UIView {
    /// 改时间线时通知编辑页
    weak var delegate: AlbumTrimPanelViewDelegate?
    /// 源时长
    private var sourceDuration = CMTime.zero
    /// 当前文档时间线
    private var timeline = AlbumTimelineEdit()
    /// 正在编辑的源
    private var asset: AVAsset?
    /// 选中段
    private var selectedIndex = 0
    /// 当前模式
    private var mode: AlbumTrimPanelMode = .headTail
    /// 片段封面
    private var clipImages: [Int: UIImage] = [:]
    /// 片段封面抽帧，与条带分开以免互取消
    private let clipLoader = AlbumTrimThumbnailLoader()

    /// 卡片外透明点击区
    private let dimmingView = UIButton(type: .custom)
    /// 贴底面板
    private let cardView = UIView()
    /// 深色毛玻璃
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 复位
    private let resetButton = UIButton(type: .system)
    /// 完成
    private let closeButton = UIButton(type: .system)
    /// 首尾 / 多段
    private let modeControl = UISegmentedControl(items: ["首尾裁剪", "多段裁剪"])
    /// 入点
    private let startLabel = UILabel()
    /// 出点
    private let endLabel = UILabel()
    /// 时长
    private let durationLabel = UILabel()
    /// 缩略图条（多段含时间尺）
    private let filmstrip = AlbumTrimFilmstripView()
    /// 删除选中段
    private let deleteButton = UIButton(type: .system)
    /// 片段标题
    private let clipsTitleLabel = UILabel()
    /// 片段列表
    private let clipsView: UICollectionView
    /// 卡片贴底
    private var cardBottomConstraint: Constraint?
    /// 首尾高度
    private let singleCardHeight: CGFloat = 228
    /// 多段高度（含时间尺）
    private let multiCardHeight: CGFloat = 360
    /// 首尾条带高度
    private let singleFilmstripHeight: CGFloat = 56
    /// 多段条带高度（尺 + 缩略图）
    private let multiFilmstripHeight: CGFloat = 80

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
        mode = segments.count > 1 ? .multi : .headTail
        modeControl.selectedSegmentIndex = mode.rawValue
        applyModeLayout()
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
        }
    }

    /// 收起面板并停抽帧
    /// - Parameter notify: 是否回调 `trimPanelDidDismiss`；导出独占时为 false，避免和 teardown 抢播放器
    func dismiss(notify: Bool = true) {
        if isHidden {
            return
        }
        filmstrip.cancelLoading()
        clipLoader.cancel()
        let height = mode == .multi ? multiCardHeight : singleCardHeight
        cardBottomConstraint?.update(offset: height + 20)
        UIView.animate(withDuration: 0.22, animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
            if notify {
                self.delegate?.trimPanelDidDismiss(self)
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
        clipsView.register(AlbumTrimClipCell.self, forCellWithReuseIdentifier: "clip")
        cardView.addSubview(clipsView)

        dimmingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cardView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(singleCardHeight)
            cardBottomConstraint = make.bottom.equalToSuperview().offset(singleCardHeight + 20).constraint
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
            make.width.equalTo(200)
        }
        startLabel.snp.makeConstraints { make in
            make.top.equalTo(resetButton.snp.bottom).offset(12)
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
            make.height.equalTo(singleFilmstripHeight)
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

    /// 按模式改卡片高度与多段控件显隐
    private func applyModeLayout() {
        let multi = mode == .multi
        deleteButton.isHidden = !multi
        clipsTitleLabel.isHidden = !multi
        clipsView.isHidden = !multi
        let height = multi ? multiCardHeight : singleCardHeight
        cardView.snp.updateConstraints { make in
            make.height.equalTo(height)
        }
        filmstrip.snp.updateConstraints { make in
            make.height.equalTo(multi ? multiFilmstripHeight : singleFilmstripHeight)
        }
    }

    /// 用当前时间线刷新条带
    private func reloadFilmstrip() {
        guard let asset = asset else { return }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        selectedIndex = min(selectedIndex, max(0, segments.count - 1))
        filmstrip.configure(
            asset: asset,
            duration: sourceDuration,
            segments: segments,
            selectedIndex: selectedIndex,
            allowsMultiple: mode == .multi,
            showsCutter: mode == .multi
        )
    }

    /// 刷新入出点 / 当前时间文案
    private func refreshLabels() {
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        guard !segments.isEmpty else { return }
        selectedIndex = min(selectedIndex, segments.count - 1)
        if mode == .multi {
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
        } else {
            let segment = segments[selectedIndex]
            startLabel.text = "入点 \(formatTime(segment.sourceStart))"
            endLabel.text = "出点 \(formatTime(segment.sourceEnd))"
            let kept = max(0, CMTimeGetSeconds(CMTimeSubtract(segment.sourceEnd, segment.sourceStart)))
            durationLabel.text = String(format: "时长 %.1f 秒", kept)
        }
        deleteButton.isEnabled = mode == .multi && !timeline.isImplicitFullRange(sourceDuration: sourceDuration)
        deleteButton.alpha = deleteButton.isEnabled ? 1 : 0.4
    }

    /// 刷新片段列表封面
    private func reloadClips() {
        clipImages.removeAll()
        clipsView.reloadData()
        guard mode == .multi, let asset = asset else { return }
        if timeline.isImplicitFullRange(sourceDuration: sourceDuration) { return }
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let times = segments.map { segment -> CMTime in
            let half = CMTimeMultiplyByRatio(CMTimeSubtract(segment.sourceEnd, segment.sourceStart), multiplier: 1, divisor: 2)
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
        refreshLabels()
        delegate?.trimPanel(self, didChange: timeline, previewTime: previewTime)
        if mode == .multi {
            clipsView.reloadData()
        }
    }

    /// m:ss
    /// - Parameter time: 源时间
    /// - Returns: 文案
    private func formatTime(_ time: CMTime) -> String {
        let seconds = max(0, CMTimeGetSeconds(time))
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 点空白或完成
    @objc private func handleDimmingTap() {
        dismiss()
    }

    /// 切模式：首尾把多段收成一段包络
    @objc private func handleModeChanged() {
        let next = AlbumTrimPanelMode(rawValue: modeControl.selectedSegmentIndex) ?? .headTail
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        if next == .headTail, segments.count > 1 {
            timeline = timeline.applyingSingleTrim(
                start: segments.first!.sourceStart,
                end: segments.last!.sourceEnd,
                sourceDuration: sourceDuration
            )
            selectedIndex = 0
        }
        mode = next
        applyModeLayout()
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        let preview = timeline.resolvedSegments(sourceDuration: sourceDuration)[0].sourceStart
        emit(previewTime: preview)
        layoutIfNeeded()
    }

    /// 恢复整段
    @objc private func handleReset() {
        timeline = AlbumTimelineEdit()
        selectedIndex = 0
        reloadFilmstrip()
        refreshLabels()
        reloadClips()
        emit(previewTime: .zero)
    }

    /// 删掉选中段；最后一段删完回到未切整段
    @objc private func handleDelete() {
        let next = timeline.removingSegment(at: selectedIndex, sourceDuration: sourceDuration)
        guard next != timeline else { return }
        timeline = next
        selectedIndex = 0
        reloadFilmstrip()
        reloadClips()
        emit(previewTime: filmstrip.cutterTime)
    }
}

extension AlbumTrimPanelView: AlbumTrimFilmstripViewDelegate {
    /// 条带改段：写文档并 seek
    func filmstrip(
        _ filmstrip: AlbumTrimFilmstripView,
        didChange segments: [AlbumTimelineSegment],
        selectedIndex: Int,
        previewTime: CMTime
    ) {
        self.selectedIndex = selectedIndex
        timeline = timeline.applyingSegments(segments, sourceDuration: sourceDuration)
        emit(previewTime: previewTime)
    }

    /// 滚动只 seek
    func filmstrip(_ filmstrip: AlbumTrimFilmstripView, didScrubTo time: CMTime, selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        refreshLabels()
        if mode == .multi {
            clipsView.reloadData()
        }
        delegate?.trimPanel(self, didScrub: time)
    }

    /// 对勾确认一段
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
        reloadClips()
        emit(previewTime: start)
    }
}

extension AlbumTrimPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    /// 片段数
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if timeline.isImplicitFullRange(sourceDuration: sourceDuration) {
            return 0
        }
        return timeline.resolvedSegments(sourceDuration: sourceDuration).count
    }

    /// 格子
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "clip", for: indexPath) as! AlbumTrimClipCell
        let segments = timeline.resolvedSegments(sourceDuration: sourceDuration)
        let segment = segments[indexPath.item]
        cell.imageView.image = clipImages[indexPath.item]
        let seconds = max(0, CMTimeGetSeconds(CMTimeSubtract(segment.sourceEnd, segment.sourceStart)))
        cell.durationLabel.text = formatTime(CMTime(seconds: seconds, preferredTimescale: 600))
        cell.applySelection(indexPath.item == selectedIndex)
        return cell
    }

    /// 点选一段
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectedIndex = indexPath.item
        let segment = timeline.resolvedSegments(sourceDuration: sourceDuration)[indexPath.item]
        filmstrip.updateSegments(
            timeline.resolvedSegments(sourceDuration: sourceDuration),
            selectedIndex: selectedIndex,
            preview: CMTimeAdd(
                segment.sourceStart,
                CMTimeMultiplyByRatio(CMTimeSubtract(segment.sourceEnd, segment.sourceStart), multiplier: 1, divisor: 2)
            )
        )
        refreshLabels()
        collectionView.reloadData()
        delegate?.trimPanel(self, didScrub: filmstrip.cutterTime)
    }
}
