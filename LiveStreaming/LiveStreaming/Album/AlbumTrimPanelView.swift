//
//  AlbumTrimPanelView.swift
//  LiveStreaming
//
//  视频单段收尾面板：缩略图条 + 入出点手柄。只改时间线文档，不碰像素。
//

import UIKit
import SnapKit
import AVFoundation
import CoreMedia

/// 收尾面板回调
protocol AlbumTrimPanelViewDelegate: AnyObject {
    /// 入出点变化；`previewTime` 是当前拖的那一端，供播放器 seek
    /// - Parameters:
    ///   - panel: 面板
    ///   - start: 入点
    ///   - end: 出点
    ///   - previewTime: 应显示的源时间
    func trimPanel(
        _ panel: AlbumTrimPanelView,
        didChangeStart start: CMTime,
        end: CMTime,
        previewTime: CMTime
    )
}

/// 从底部弹出的剪辑卡片；点空白关闭。
class AlbumTrimPanelView: UIView {
    /// 改时间线时通知编辑页
    weak var delegate: AlbumTrimPanelViewDelegate?
    /// 源时长；present 前写入
    private var sourceDuration = CMTime.zero
    /// 当前入点
    private var startTime = CMTime.zero
    /// 当前出点
    private var endTime = CMTime.zero

    /// 卡片外透明点击区
    private let dimmingView = UIButton(type: .custom)
    /// 贴底面板
    private let cardView = UIView()
    /// 深色毛玻璃
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 标题
    private let titleLabel = UILabel()
    /// 关闭
    private let closeButton = UIButton(type: .system)
    /// 复位整段
    private let resetButton = UIButton(type: .system)
    /// 入点
    private let startLabel = UILabel()
    /// 出点
    private let endLabel = UILabel()
    /// 保留时长
    private let durationLabel = UILabel()
    /// 美摄式缩略图条
    private let filmstrip = AlbumTrimFilmstripView()
    /// 卡片贴底约束，弹出/收起时改 offset
    private var cardBottomConstraint: Constraint?
    /// 卡片高度，与收起位移一致
    private let cardHeight: CGFloat = 220

    /// 搭建子视图；默认隐藏
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        isHidden = true
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 弹出面板并抽源视频缩略图
    /// - Parameters:
    ///   - asset: 源视频，条带从该文件抽帧
    ///   - start: 入点
    ///   - end: 出点
    func present(asset: AVAsset, start: CMTime, end: CMTime) {
        sourceDuration = asset.duration
        startTime = start
        endTime = end
        refreshLabels()
        filmstrip.configure(asset: asset, duration: asset.duration, start: start, end: end)
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
        }
    }

    /// 收起面板并停抽帧
    func dismiss() {
        filmstrip.cancelLoading()
        cardBottomConstraint?.update(offset: cardHeight + 20)
        UIView.animate(withDuration: 0.22, animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
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

        titleLabel.text = "首尾裁剪"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        cardView.addSubview(titleLabel)

        closeButton.setTitle("完成", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        cardView.addSubview(closeButton)

        resetButton.setTitle("复位", for: .normal)
        resetButton.setTitleColor(UIColor(white: 1, alpha: 0.85), for: .normal)
        resetButton.addTarget(self, action: #selector(handleReset), for: .touchUpInside)
        cardView.addSubview(resetButton)

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
            make.centerX.equalToSuperview()
        }
        closeButton.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-16)
        }
        resetButton.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.leading.equalToSuperview().offset(16)
        }
        startLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(14)
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
            make.top.equalTo(startLabel.snp.bottom).offset(12)
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

    /// 刷新入出点与时长文案
    private func refreshLabels() {
        startLabel.text = "入点 \(formatTime(startTime))"
        endLabel.text = "出点 \(formatTime(endTime))"
        let kept = max(0, CMTimeGetSeconds(CMTimeSubtract(endTime, startTime)))
        durationLabel.text = String(format: "时长 %.1f 秒", kept)
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

    /// 恢复整段；条带不重抽
    @objc private func handleReset() {
        startTime = .zero
        endTime = sourceDuration
        refreshLabels()
        filmstrip.updateSelection(start: startTime, end: endTime, preview: startTime)
        delegate?.trimPanel(self, didChangeStart: startTime, end: endTime, previewTime: startTime)
    }
}

extension AlbumTrimPanelView: AlbumTrimFilmstripViewDelegate {
    /// 条带拖动手柄：写标签并转给编辑页
    func filmstrip(
        _ filmstrip: AlbumTrimFilmstripView,
        didChangeStart start: CMTime,
        end: CMTime,
        previewTime: CMTime
    ) {
        startTime = start
        endTime = end
        refreshLabels()
        delegate?.trimPanel(self, didChangeStart: start, end: end, previewTime: previewTime)
    }
}
