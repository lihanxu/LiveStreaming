//
//  AlbumGeometryPanelView.swift
//  LiveStreaming
//
//  画幅底部面板：90°、翻转、角度、比例预设。不在此算矩阵，只改 AlbumGeometryEdit。
//

import UIKit
import SnapKit

/// 画幅面板回调
protocol AlbumGeometryPanelViewDelegate: AnyObject {
    /// 用户改了画幅参数
    /// - Parameter geometry: 最新文档几何
    func geometryPanel(_ panel: AlbumGeometryPanelView, didChange geometry: AlbumGeometryEdit)
}

/// 从底部弹出的画幅卡片；点空白关闭。
class AlbumGeometryPanelView: UIView {
    /// 改几何时通知编辑页
    weak var delegate: AlbumGeometryPanelViewDelegate?
    /// 当前几何；present 前由编辑页写入
    var geometry = AlbumGeometryEdit() {
        didSet {
            if !isUpdatingFromUI {
                refreshControls()
            }
        }
    }

    /// 避免 refresh 时 slider 再回调
    private var isUpdatingFromUI = false
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
    /// 复位
    private let resetButton = UIButton(type: .system)
    /// 90°
    private let rotateButton = UIButton(type: .system)
    /// 左右翻转
    private let flipHButton = UIButton(type: .system)
    /// 上下翻转
    private let flipVButton = UIButton(type: .system)
    /// 角度说明
    private let angleLabel = UILabel()
    /// 自由角滑杆，范围 ±45°
    private let angleSlider = UISlider()
    /// 比例预设
    private let aspectControl = UISegmentedControl(items: AlbumAspectMode.presets.map { $0.title })
    /// 卡片贴底约束，弹出/收起时改 offset
    private var cardBottomConstraint: Constraint?

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

    /// 弹出面板
    func present() {
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.layoutIfNeeded()
        }
    }

    /// 收起面板
    func dismiss() {
        cardBottomConstraint?.update(offset: 280)
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

        titleLabel.text = "画幅"
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

        configureActionButton(rotateButton, title: "旋转90°")
        rotateButton.addTarget(self, action: #selector(handleRotate), for: .touchUpInside)
        configureActionButton(flipHButton, title: "左右翻转")
        flipHButton.addTarget(self, action: #selector(handleFlipH), for: .touchUpInside)
        configureActionButton(flipVButton, title: "上下翻转")
        flipVButton.addTarget(self, action: #selector(handleFlipV), for: .touchUpInside)
        cardView.addSubview(rotateButton)
        cardView.addSubview(flipHButton)
        cardView.addSubview(flipVButton)

        angleLabel.textColor = .white
        angleLabel.font = UIFont.systemFont(ofSize: 13)
        cardView.addSubview(angleLabel)

        angleSlider.minimumValue = -45
        angleSlider.maximumValue = 45
        angleSlider.addTarget(self, action: #selector(handleAngleChanged), for: .valueChanged)
        cardView.addSubview(angleSlider)

        aspectControl.selectedSegmentIndex = 0
        aspectControl.addTarget(self, action: #selector(handleAspectChanged), for: .valueChanged)
        if #available(iOS 13.0, *) {
            aspectControl.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.25)
        }
        aspectControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        cardView.addSubview(aspectControl)

        dimmingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        cardView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(260)
            // 初始藏在屏幕下方，present 时把 offset 改为 0
            cardBottomConstraint = make.bottom.equalToSuperview().offset(280).constraint
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
        rotateButton.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(18)
            make.leading.equalToSuperview().offset(16)
            make.height.equalTo(36)
            make.width.equalTo(flipHButton)
        }
        flipHButton.snp.makeConstraints { make in
            make.top.height.equalTo(rotateButton)
            make.leading.equalTo(rotateButton.snp.trailing).offset(10)
            make.width.equalTo(flipVButton)
        }
        flipVButton.snp.makeConstraints { make in
            make.top.height.equalTo(rotateButton)
            make.leading.equalTo(flipHButton.snp.trailing).offset(10)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }
        angleLabel.snp.makeConstraints { make in
            make.top.equalTo(rotateButton.snp.bottom).offset(16)
            make.leading.equalToSuperview().offset(16)
            make.width.greaterThanOrEqualTo(72)
        }
        angleSlider.snp.makeConstraints { make in
            make.centerY.equalTo(angleLabel)
            make.leading.equalTo(angleLabel.snp.trailing).offset(12)
            make.trailing.equalToSuperview().offset(-16)
        }
        aspectControl.snp.makeConstraints { make in
            make.top.equalTo(angleSlider.snp.bottom).offset(20)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.equalTo(32)
        }

        refreshControls()
    }

    /// 统一三个操作按钮样式
    /// - Parameters:
    ///   - button: 按钮
    ///   - title: 文案
    private func configureActionButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        button.backgroundColor = UIColor(white: 1, alpha: 0.16)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }

    /// 用当前 geometry 刷新控件，不发回调
    private func refreshControls() {
        isUpdatingFromUI = true
        angleSlider.value = geometry.freeAngleDegrees
        angleLabel.text = String(format: "角度 %+d°", Int(geometry.freeAngleDegrees.rounded()))
        if let index = AlbumAspectMode.presets.firstIndex(of: geometry.aspect) {
            aspectControl.selectedSegmentIndex = index
        } else {
            aspectControl.selectedSegmentIndex = 0
        }
        isUpdatingFromUI = false
    }

    /// 通知会话重跑
    private func emitChange() {
        refreshControls()
        delegate?.geometryPanel(self, didChange: geometry)
    }

    /// 点空白或完成
    @objc private func handleDimmingTap() {
        dismiss()
    }

    /// 顺时针 90°
    @objc private func handleRotate() {
        geometry.quarterTurns = (geometry.normalizedQuarterTurns + 1) % 4
        emitChange()
    }

    /// 左右翻转
    @objc private func handleFlipH() {
        geometry.flipHorizontal.toggle()
        emitChange()
    }

    /// 上下翻转
    @objc private func handleFlipV() {
        geometry.flipVertical.toggle()
        emitChange()
    }

    /// 角度滑杆
    @objc private func handleAngleChanged() {
        geometry.freeAngleDegrees = angleSlider.value
        emitChange()
    }

    /// 比例分段
    @objc private func handleAspectChanged() {
        let index = aspectControl.selectedSegmentIndex
        guard index >= 0, index < AlbumAspectMode.presets.count else { return }
        geometry.aspect = AlbumAspectMode.presets[index]
        emitChange()
    }

    /// 全部复位
    @objc private func handleReset() {
        geometry = AlbumGeometryEdit()
        emitChange()
    }
}
