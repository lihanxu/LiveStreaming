//
//  AlbumJoinPanelView.swift
//  LiveStreaming
//
//  拼接二级面板：添加/删除片段、选择接缝转场。交互对齐剪辑卡片。
//

import UIKit
import SnapKit
import AVFoundation
import CoreMedia

/// 拼接面板回调
protocol AlbumJoinPanelViewDelegate: AnyObject {
    /// 用户点了添加格子，编辑页去挑视频
    /// - Parameter panel: 面板
    func joinPanelDidRequestAddClip(_ panel: AlbumJoinPanelView)

    /// 选中某段，编辑页改 selectedIndex 并刷新预览
    /// - Parameters:
    ///   - panel: 面板
    ///   - index: clip 下标
    func joinPanel(_ panel: AlbumJoinPanelView, didSelectClip index: Int)

    /// 删除当前选中段
    /// - Parameter panel: 面板
    func joinPanelDidRequestDeleteSelected(_ panel: AlbumJoinPanelView)

    /// 接缝草稿变更
    /// - Parameters:
    ///   - panel: 面板
    ///   - index: 接缝下标
    ///   - transition: 新接缝
    func joinPanel(
        _ panel: AlbumJoinPanelView,
        didChangeTransitionAt index: Int,
        transition: AlbumTransition
    )

    /// 点空白或完成收起
    /// - Parameter panel: 面板
    func joinPanelDidDismiss(_ panel: AlbumJoinPanelView)
}

/// 片段格子
private final class AlbumJoinClipCell: UICollectionViewCell {
    /// 封面
    let imageView = UIImageView()
    /// 序号或「添加」
    let badgeLabel = UILabel()
    /// 选中描边
    private let ring = UIView()

    /// 搭格子
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        contentView.addSubview(imageView)
        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = 10
        ring.isUserInteractionEnabled = false
        contentView.addSubview(ring)
        badgeLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.backgroundColor = UIColor(white: 0, alpha: 0.5)
        badgeLabel.layer.cornerRadius = 3
        badgeLabel.clipsToBounds = true
        contentView.addSubview(badgeLabel)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        ring.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        badgeLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(4)
            make.height.equalTo(16)
        }
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 绑定封面与选中
    /// - Parameters:
    ///   - image: 封面；添加格为 nil
    ///   - title: 角标
    ///   - selected: 当前段
    ///   - isAdd: 是否添加格
    func apply(image: UIImage?, title: String, selected: Bool, isAdd: Bool) {
        imageView.image = image
        imageView.backgroundColor = isAdd ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0.2, alpha: 1)
        badgeLabel.text = title
        ring.layer.borderColor = (selected && !isAdd
            ? UIColor(red: 1, green: 0.48, blue: 0.12, alpha: 1)
            : UIColor(white: 1, alpha: isAdd ? 0.25 : 0)
        ).cgColor
        if isAdd {
            ring.layer.borderWidth = 1
            ring.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        } else {
            ring.layer.borderWidth = 2
        }
    }
}

/// 从底部弹出的拼接卡片；点空白关闭。
class AlbumJoinPanelView: UIView {
    /// 增删改通知编辑页
    weak var delegate: AlbumJoinPanelViewDelegate?
    /// 各段已加载的片源；与工程 clips 对齐
    private var assets: [AVAsset?] = []
    /// 接缝草稿
    private var transitions: [AlbumTransition] = []
    /// 选中 clip
    private var selectedIndex = 0
    /// 封面
    private var clipImages: [Int: UIImage] = [:]
    /// 抽封面
    private let thumbLoader = AlbumTrimThumbnailLoader()

    /// 卡片外透明点击区
    private let dimmingView = UIButton(type: .custom)
    /// 贴底面板
    private let cardView = UIView()
    /// 深色毛玻璃
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 标题
    private let titleLabel = UILabel()
    /// 完成
    private let closeButton = UIButton(type: .system)
    /// 说明
    private let hintLabel = UILabel()
    /// 片段列表（末尾为添加格）
    private let clipsView: UICollectionView
    /// 删除选中段
    private let deleteButton = UIButton(type: .system)
    /// 接缝标题
    private let junctionLabel = UILabel()
    /// 硬切 / 淡入 / 闪黑 / 闪白
    private let kindControl = UISegmentedControl(items: AlbumTransitionKind.presets.map { $0.title })
    /// 重叠时长文案
    private let durationLabel = UILabel()
    /// 重叠滑杆
    private let durationSlider = UISlider()
    /// 预览仍硬切的提示
    private let previewHintLabel = UILabel()
    /// 卡片贴底
    private var cardBottomConstraint: Constraint?
    /// 卡片高度
    private let cardHeight: CGFloat = 332

    /// 搭建子视图；默认隐藏
    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 64, height: 64)
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
    ///   - assets: 与 clips 对齐；未加载为 nil
    ///   - selectedIndex: 当前段
    ///   - transitions: 接缝
    func present(assets: [AVAsset?], selectedIndex: Int, transitions: [AlbumTransition]) {
        self.assets = assets
        self.transitions = transitions
        self.selectedIndex = min(max(0, selectedIndex), max(0, assets.count - 1))
        reloadThumbs()
        refreshTransitionControls()
        clipsView.reloadData()
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
        }
    }

    /// 增删后只刷列表，不重做弹出动画
    /// - Parameters:
    ///   - assets: 片源
    ///   - selectedIndex: 当前段
    ///   - transitions: 接缝
    func reload(assets: [AVAsset?], selectedIndex: Int, transitions: [AlbumTransition]) {
        self.assets = assets
        self.transitions = transitions
        self.selectedIndex = min(max(0, selectedIndex), max(0, assets.count - 1))
        reloadThumbs()
        refreshTransitionControls()
        clipsView.reloadData()
    }

    /// 收起面板
    /// - Parameter notify: 是否回调 dismiss；导出独占时为 false
    func dismiss(notify: Bool = true) {
        if isHidden {
            return
        }
        thumbLoader.cancel()
        cardBottomConstraint?.update(offset: cardHeight + 20)
        UIView.animate(withDuration: 0.22, animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
            if notify {
                self.delegate?.joinPanelDidDismiss(self)
            }
        })
    }

    /// 空白点击关闭，卡片内继续响应
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

        titleLabel.text = "拼接"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        cardView.addSubview(titleLabel)

        closeButton.setTitle("完成", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        cardView.addSubview(closeButton)

        hintLabel.text = "按顺序拼接多段视频，点接缝可选转场"
        hintLabel.textColor = UIColor(white: 1, alpha: 0.7)
        hintLabel.font = UIFont.systemFont(ofSize: 12)
        cardView.addSubview(hintLabel)

        clipsView.backgroundColor = .clear
        clipsView.dataSource = self
        clipsView.delegate = self
        clipsView.showsHorizontalScrollIndicator = false
        clipsView.register(AlbumJoinClipCell.self, forCellWithReuseIdentifier: "clip")
        cardView.addSubview(clipsView)

        deleteButton.setTitle("删除片段", for: .normal)
        deleteButton.setTitleColor(.white, for: .normal)
        deleteButton.backgroundColor = UIColor(white: 1, alpha: 0.16)
        deleteButton.layer.cornerRadius = 8
        deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
        cardView.addSubview(deleteButton)

        junctionLabel.text = "接缝转场"
        junctionLabel.textColor = UIColor(white: 1, alpha: 0.75)
        junctionLabel.font = UIFont.systemFont(ofSize: 13)
        cardView.addSubview(junctionLabel)

        kindControl.addTarget(self, action: #selector(handleKindChanged), for: .valueChanged)
        if #available(iOS 13.0, *) {
            kindControl.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
        }
        kindControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        cardView.addSubview(kindControl)

        durationLabel.textColor = UIColor(white: 1, alpha: 0.85)
        durationLabel.font = UIFont.systemFont(ofSize: 12)
        cardView.addSubview(durationLabel)

        durationSlider.minimumValue = Float(CMTimeGetSeconds(AlbumTransition.minimumOverlap))
        durationSlider.maximumValue = Float(CMTimeGetSeconds(AlbumTransition.maximumOverlap))
        durationSlider.addTarget(self, action: #selector(handleDurationChanged), for: .valueChanged)
        cardView.addSubview(durationSlider)

        previewHintLabel.text = "关闭本页后播放可预览转场，导出同样生效"
        previewHintLabel.textColor = UIColor(white: 1, alpha: 0.45)
        previewHintLabel.font = UIFont.systemFont(ofSize: 11)
        cardView.addSubview(previewHintLabel)

        dimmingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cardView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(cardHeight)
            cardBottomConstraint = make.bottom.equalToSuperview().offset(cardHeight + 20).constraint
        }
        blurView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(14)
            make.leading.equalToSuperview().offset(16)
        }
        closeButton.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-16)
        }
        hintLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(6)
            make.leading.trailing.equalToSuperview().inset(16)
        }
        clipsView.snp.makeConstraints { make in
            make.top.equalTo(hintLabel.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(64)
        }
        deleteButton.snp.makeConstraints { make in
            make.top.equalTo(clipsView.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(32)
        }
        junctionLabel.snp.makeConstraints { make in
            make.top.equalTo(deleteButton.snp.bottom).offset(12)
            make.leading.equalToSuperview().offset(16)
        }
        kindControl.snp.makeConstraints { make in
            make.top.equalTo(junctionLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(28)
        }
        durationLabel.snp.makeConstraints { make in
            make.top.equalTo(kindControl.snp.bottom).offset(10)
            make.leading.equalToSuperview().offset(16)
        }
        durationSlider.snp.makeConstraints { make in
            make.centerY.equalTo(durationLabel)
            make.leading.equalTo(durationLabel.snp.trailing).offset(10)
            make.trailing.equalToSuperview().offset(-16)
        }
        previewHintLabel.snp.makeConstraints { make in
            make.top.equalTo(durationSlider.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(16)
        }
    }

    /// 当前正在编辑的接缝下标；选中末段时改前一条接缝
    private var junctionIndex: Int? {
        let clipCount = assets.count
        guard clipCount >= 2 else { return nil }
        if selectedIndex < clipCount - 1 {
            return selectedIndex
        }
        return clipCount - 2
    }

    /// 按段依次抽封面；同一 loader 同时只能跑一轮
    private func reloadThumbs() {
        thumbLoader.cancel()
        clipImages.removeAll()
        loadThumb(startingAt: 0)
    }

    /// 抽 `index` 段封面，完成后再抽下一段
    /// - Parameter index: clip 下标
    private func loadThumb(startingAt index: Int) {
        guard index < assets.count else { return }
        guard let asset = assets[index] else {
            loadThumb(startingAt: index + 1)
            return
        }
        let seconds = min(0.2, max(0, CMTimeGetSeconds(asset.duration) * 0.1))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let pixel = 64 * UIScreen.main.scale
        thumbLoader.load(asset: asset, times: [time], maxPixel: pixel) { [weak self] _, image in
            guard let self = self else { return }
            self.clipImages[index] = image
            self.clipsView.reloadData()
            self.loadThumb(startingAt: index + 1)
        }
    }

    /// 按选中段刷新转场控件
    private func refreshTransitionControls() {
        let canDelete = assets.count >= 2
        deleteButton.isEnabled = canDelete
        deleteButton.alpha = canDelete ? 1 : 0.4
        if let junction = junctionIndex, transitions.indices.contains(junction) {
            kindControl.isEnabled = true
            let kind = transitions[junction].kind
            kindControl.selectedSegmentIndex = AlbumTransitionKind.presets.firstIndex(of: kind) ?? 0
            let overlap = kind != .cut
            durationSlider.isEnabled = overlap
            durationSlider.alpha = overlap ? 1 : 0.35
            let seconds = overlap
                ? CMTimeGetSeconds(transitions[junction].duration)
                : 0
            durationSlider.value = Float(overlap ? seconds : 0.35)
            durationLabel.text = overlap
                ? String(format: "重叠 %.1f 秒", seconds)
                : "重叠 —"
            junctionLabel.text = "接缝 \(junction + 1)→\(junction + 2)"
        } else {
            kindControl.isEnabled = false
            kindControl.selectedSegmentIndex = 0
            durationSlider.isEnabled = false
            durationSlider.alpha = 0.35
            durationLabel.text = "重叠 —"
            junctionLabel.text = "接缝转场（先添加第二段）"
        }
    }

    /// 把控件写回接缝并通知宿主
    private func commitTransitionFromControls() {
        guard let junction = junctionIndex else { return }
        let kindIndex = max(0, kindControl.selectedSegmentIndex)
        let kind = AlbumTransitionKind.presets[kindIndex]
        var duration = AlbumTransition.defaultOverlap
        if kind != .cut {
            duration = CMTime(seconds: Double(durationSlider.value), preferredTimescale: 600)
        }
        let transition = AlbumTransition(kind: kind, duration: duration).normalized()
        if transitions.indices.contains(junction) {
            transitions[junction] = transition
        }
        refreshTransitionControls()
        delegate?.joinPanel(self, didChangeTransitionAt: junction, transition: transition)
    }

    /// 空白 / 完成
    @objc private func handleDimmingTap() {
        dismiss(notify: true)
    }

    /// 删除选中段
    @objc private func handleDelete() {
        guard assets.count >= 2 else { return }
        delegate?.joinPanelDidRequestDeleteSelected(self)
    }

    /// 改转场类型
    @objc private func handleKindChanged() {
        commitTransitionFromControls()
    }

    /// 改重叠时长
    @objc private func handleDurationChanged() {
        commitTransitionFromControls()
    }
}

extension AlbumJoinPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    /// 片段数 + 添加格
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let extra = assets.count < AlbumProject.maximumClipCount ? 1 : 0
        return assets.count + extra
    }

    /// 绑定封面或添加格
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "clip",
            for: indexPath
        ) as! AlbumJoinClipCell
        if indexPath.item >= assets.count {
            cell.apply(image: nil, title: "添加", selected: false, isAdd: true)
            return cell
        }
        let selected = indexPath.item == selectedIndex
        cell.apply(
            image: clipImages[indexPath.item],
            title: "\(indexPath.item + 1)",
            selected: selected,
            isAdd: false
        )
        return cell
    }

    /// 点添加或选中段
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item >= assets.count {
            delegate?.joinPanelDidRequestAddClip(self)
            return
        }
        selectedIndex = indexPath.item
        collectionView.reloadData()
        refreshTransitionControls()
        delegate?.joinPanel(self, didSelectClip: indexPath.item)
    }
}
