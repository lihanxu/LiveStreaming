//
//  AlbumScopePanelView.swift
//  LiveStreaming
//
//  预览浮层示波器：直方图 RGB（可选 Y）与波形 Y（可选 Colorize）。不引用草稿或滤镜。
//

import UIKit
import SnapKit

/// 示波器面板把开关交给编辑页，由 VC 写 Analyzer
protocol AlbumScopePanelViewDelegate: AnyObject {
    /// 浮层显示或关闭
    /// - Parameter enabled: true 时应对当前预览帧跑分析
    func scopePanel(_ panel: AlbumScopePanelView, didChangeEnabled enabled: Bool)
    /// 波形 Colorize 变更；静图需要重跑当前帧
    /// - Parameter colorize: 是否上色
    func scopePanel(_ panel: AlbumScopePanelView, didChangeColorize colorize: Bool)
}

/// 叠在预览上的示波器卡片，可拖动；不与画幅/剪辑互斥
final class AlbumScopePanelView: UIView, UIGestureRecognizerDelegate {
    /// 通知编辑页开关 Analyzer
    weak var delegate: AlbumScopePanelViewDelegate?
    /// 当前种类；本地显示状态
    private(set) var kind: AlbumScopeKind = .histogram
    /// 直方图是否叠 Y
    private var showsLuma = false
    /// 波形是否 Colorize
    private(set) var colorize = false
    /// 波形通道；切模式只重绘，不重跑 GPU
    private(set) var waveformMode: AlbumScopeWaveformMode = .mixed
    /// 最近一帧快照
    private var snapshot: AlbumScopeSnapshot?

    /// 深色卡片
    private let cardView = UIView()
    /// 标题
    private let titleLabel = UILabel()
    /// 直方图 / 波形
    private let kindControl = UISegmentedControl(items: ["直方图", "波形"])
    /// 直方图 Y
    private let lumaSwitch = UISwitch()
    /// 直方图 Y 文案
    private let lumaLabel = UILabel()
    /// 波形上色
    private let colorizeSwitch = UISwitch()
    /// 波形上色文案
    private let colorizeLabel = UILabel()
    /// 直方图 Y 行；与上色共用标题栏右侧
    private let optionStack = UIStackView()
    /// 上色行，放在卡片右上角
    private let colorizeRow = UIStackView()
    /// 波形通道竖排：混合 / R / G / B
    private let channelStack = UIStackView()
    /// 通道按钮，下标对应 `AlbumScopeWaveformMode`
    private var channelButtons: [UIButton] = []
    /// 直方图绘制
    private let histogramView = AlbumScopeHistogramView()
    /// 波形图
    private let waveformView = AlbumScopeWaveformPlotView()
    /// 波形左侧刻度
    private let waveformScale = AlbumScopeWaveformScaleView()
    /// 不透明度文案
    private let opacityLabel = UILabel()
    /// 浮层不透明度 0.4…1.0，默认 1
    private let opacitySlider = UISlider()
    /// 相对父视图 leading
    private var leadingConstraint: Constraint?
    /// 相对父视图 top
    private var topConstraint: Constraint?
    /// 手势开始时的 leading/top 常量
    private var dragStartLeading: CGFloat = 0
    /// 手势开始时的 top 常量
    private var dragStartTop: CGFloat = 0

    /// 搭建浮层；默认隐藏
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        isHidden = true
        isUserInteractionEnabled = false
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 打开浮层并开始测量
    func present() {
        isHidden = false
        isUserInteractionEnabled = true
        delegate?.scopePanel(self, didChangeEnabled: true)
    }

    /// 钉在预览上：固定宽高，之后靠拖动手势改 leading/top
    /// - Parameter host: 编辑页根视图
    func pin(in host: UIView) {
        snp.makeConstraints { make in
            leadingConstraint = make.leading.equalTo(host.safeAreaLayoutGuide).offset(10).constraint
            topConstraint = make.top.equalTo(host.safeAreaLayoutGuide).offset(52).constraint
            make.width.equalTo(252)
            make.height.equalTo(280)
        }
    }

    /// 关闭浮层并停止测量
    func dismiss() {
        guard !isHidden else {
            return
        }
        isHidden = true
        isUserInteractionEnabled = false
        delegate?.scopePanel(self, didChangeEnabled: false)
    }

    /// 主线程写入最新快照并刷新图
    /// - Parameter snapshot: GPU 读回；nil 不改上一帧
    func apply(snapshot: AlbumScopeSnapshot?) {
        guard let snapshot = snapshot else {
            return
        }
        self.snapshot = snapshot
        histogramView.snapshot = snapshot
        histogramView.showsLuma = showsLuma
        histogramView.setNeedsDisplay()
        waveformView.apply(snapshot: snapshot, mode: waveformMode, colorize: colorize)
    }

    /// 子视图与约束
    private func setupViews() {
        backgroundColor = .clear

        cardView.backgroundColor = UIColor(white: 0.14, alpha: 1)
        cardView.layer.cornerRadius = 12
        cardView.layer.masksToBounds = true
        addSubview(cardView)

        titleLabel.text = "示波器"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        cardView.addSubview(titleLabel)

        kindControl.selectedSegmentIndex = 0
        kindControl.addTarget(self, action: #selector(handleKindChange), for: .valueChanged)
        configureSegmentedControl(kindControl)
        cardView.addSubview(kindControl)

        configureSwitch(lumaSwitch)
        lumaSwitch.addTarget(self, action: #selector(handleLumaChange), for: .valueChanged)
        lumaLabel.text = "Y"
        lumaLabel.textColor = .white
        lumaLabel.font = UIFont.systemFont(ofSize: 12)

        configureSwitch(colorizeSwitch)
        colorizeSwitch.addTarget(self, action: #selector(handleColorizeChange), for: .valueChanged)
        colorizeLabel.text = "上色"
        colorizeLabel.textColor = .white
        colorizeLabel.font = UIFont.systemFont(ofSize: 12)

        optionStack.axis = .horizontal
        optionStack.alignment = .center
        optionStack.spacing = 4
        optionStack.addArrangedSubview(lumaLabel)
        optionStack.addArrangedSubview(lumaSwitch)
        cardView.addSubview(optionStack)

        colorizeRow.axis = .horizontal
        colorizeRow.alignment = .center
        colorizeRow.spacing = 4
        colorizeRow.addArrangedSubview(colorizeLabel)
        colorizeRow.addArrangedSubview(colorizeSwitch)
        cardView.addSubview(colorizeRow)

        channelStack.axis = .vertical
        channelStack.alignment = .fill
        channelStack.distribution = .fillEqually
        channelStack.spacing = 4
        let titles = ["Mix", "R", "G", "B"]
        for (index, title) in titles.enumerated() {
            let button = makeChannelButton(title: title, index: index)
            channelButtons.append(button)
            channelStack.addArrangedSubview(button)
        }
        channelStack.isHidden = true
        cardView.addSubview(channelStack)
        refreshChannelButtons()

        histogramView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        histogramView.layer.cornerRadius = 6
        histogramView.layer.masksToBounds = true
        cardView.addSubview(histogramView)

        waveformView.backgroundColor = UIColor(white: 0, alpha: 1)
        waveformView.layer.cornerRadius = 6
        waveformView.layer.masksToBounds = true
        waveformView.isHidden = true
        cardView.addSubview(waveformView)

        waveformScale.isHidden = true
        cardView.addSubview(waveformScale)

        opacityLabel.text = "曲线透明度"
        opacityLabel.textColor = .white
        opacityLabel.font = UIFont.systemFont(ofSize: 11)
        cardView.addSubview(opacityLabel)

        opacitySlider.minimumValue = 0.45
        opacitySlider.maximumValue = 1
        opacitySlider.value = 1
        opacitySlider.minimumTrackTintColor = UIColor(red: 0.35, green: 0.65, blue: 1, alpha: 1)
        opacitySlider.addTarget(self, action: #selector(handleOpacityChange), for: .valueChanged)
        cardView.addSubview(opacitySlider)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        cardView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.leading.equalToSuperview().offset(10)
        }
        colorizeRow.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-8)
        }
        optionStack.snp.makeConstraints { make in
            make.centerY.equalTo(titleLabel)
            make.trailing.equalToSuperview().offset(-8)
        }
        kindControl.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(8)
            make.height.equalTo(28)
        }
        opacityLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(10)
            make.top.equalTo(kindControl.snp.bottom).offset(12)
        }
        opacitySlider.snp.makeConstraints { make in
            make.centerY.equalTo(opacityLabel)
            make.leading.equalTo(opacityLabel.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-10)
        }
        histogramView.snp.makeConstraints { make in
            make.top.equalTo(opacitySlider.snp.bottom).offset(8)
            make.leading.equalToSuperview().offset(8)
            make.trailing.equalToSuperview().offset(-8)
            make.bottom.equalToSuperview().offset(-8)
        }
        waveformScale.snp.makeConstraints { make in
            make.top.bottom.equalTo(histogramView)
            make.leading.equalToSuperview().offset(4)
            make.width.equalTo(22)
        }
        channelStack.snp.makeConstraints { make in
            make.top.bottom.equalTo(histogramView)
            make.trailing.equalToSuperview().offset(-6)
            make.width.equalTo(24)
        }
        waveformView.snp.makeConstraints { make in
            make.top.bottom.equalTo(histogramView)
            make.leading.equalTo(waveformScale.snp.trailing).offset(2)
            make.trailing.equalTo(channelStack.snp.leading).offset(-4)
        }
        refreshOptionVisibility()
    }

    /// 分段控件用不透明底 + 白字，避免半透明叠在预览上看不清
    /// - Parameter control: 直方图/波形或通道切换
    private func configureSegmentedControl(_ control: UISegmentedControl) {
        let title: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 12, weight: .medium)
        ]
        control.setTitleTextAttributes(title, for: .normal)
        control.setTitleTextAttributes(title, for: .selected)
        control.backgroundColor = UIColor(white: 0.26, alpha: 1)
        control.tintColor = .white
        if #available(iOS 13.0, *) {
            control.selectedSegmentTintColor = UIColor(white: 0.42, alpha: 1)
        }
    }

    /// 竖排通道按钮
    /// - Parameters:
    ///   - title: 混合 / R / G / B
    ///   - index: `AlbumScopeWaveformMode` 原始值
    /// - Returns: 可点选的通道按钮
    private func makeChannelButton(title: String, index: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        button.layer.cornerRadius = 6
        button.tag = index
        button.addTarget(self, action: #selector(handleChannelTap(_:)), for: .touchUpInside)
        return button
    }

    /// 按当前模式高亮竖排通道
    private func refreshChannelButtons() {
        for button in channelButtons {
            let selected = button.tag == waveformMode.rawValue
            button.backgroundColor = selected
                ? UIColor(white: 0.42, alpha: 1)
                : UIColor(white: 0.26, alpha: 1)
        }
    }

    /// 缩小开关以塞进窄浮层
    /// - Parameter control: UISwitch
    private func configureSwitch(_ control: UISwitch) {
        control.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        control.onTintColor = UIColor(red: 0.25, green: 0.55, blue: 1, alpha: 1)
    }

    /// 切换直方图 / 波形
    @objc private func handleKindChange() {
        kind = AlbumScopeKind(rawValue: kindControl.selectedSegmentIndex) ?? .histogram
        histogramView.isHidden = kind != .histogram
        waveformView.isHidden = kind != .waveform
        waveformScale.isHidden = kind != .waveform
        channelStack.isHidden = kind != .waveform
        refreshOptionVisibility()
        histogramView.setNeedsDisplay()
        refreshWaveformImage()
    }

    /// 只改直方图绘制，不重跑 GPU
    @objc private func handleLumaChange() {
        showsLuma = lumaSwitch.isOn
        histogramView.showsLuma = showsLuma
        histogramView.setNeedsDisplay()
    }

    /// Colorize 交给 VC 写 Analyzer
    @objc private func handleColorizeChange() {
        colorize = colorizeSwitch.isOn
        refreshWaveformImage()
        delegate?.scopePanel(self, didChangeColorize: colorize)
    }

    /// 竖排通道点选
    /// - Parameter sender: 通道按钮
    @objc private func handleChannelTap(_ sender: UIButton) {
        waveformMode = AlbumScopeWaveformMode(rawValue: sender.tag) ?? .mixed
        refreshChannelButtons()
        refreshWaveformImage()
    }

    /// 用当前模式重画波形
    private func refreshWaveformImage() {
        waveformView.apply(snapshot: snapshot, mode: waveformMode, colorize: colorize)
    }

    /// 只改曲线透明度，标题和按钮保持不透明
    @objc private func handleOpacityChange() {
        let alpha = CGFloat(opacitySlider.value)
        histogramView.alpha = alpha
        waveformView.alpha = alpha
        waveformScale.alpha = alpha
    }

    /// 拖动浮层，夹在父视图安全区内
    /// - Parameter gesture: 单指平移
    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let host = superview else {
            return
        }
        if gesture.state == .began {
            dragStartLeading = leadingConstraint?.layoutConstraints.first?.constant ?? 10
            dragStartTop = topConstraint?.layoutConstraints.first?.constant ?? 52
            return
        }
        guard gesture.state == .changed || gesture.state == .ended else {
            return
        }
        let translation = gesture.translation(in: host)
        let inset: CGFloat = 8
        let safe = host.safeAreaInsets
        let maxLeading = max(inset, host.bounds.width - safe.left - safe.right - bounds.width - inset)
        let maxTop = max(inset, host.bounds.height - safe.top - safe.bottom - bounds.height - inset)
        let leading = min(max(inset, dragStartLeading + translation.x), maxLeading)
        let top = min(max(inset, dragStartTop + translation.y), maxTop)
        leadingConstraint?.update(offset: leading)
        topConstraint?.update(offset: top)
        if gesture.state == .ended {
            dragStartLeading = leading
            dragStartTop = top
        }
    }

    /// 直方图右上角 Y；波形右上角上色，右侧竖排通道
    private func refreshOptionVisibility() {
        let hist = kind == .histogram
        optionStack.isHidden = !hist
        colorizeRow.isHidden = hist
        channelStack.isHidden = hist
    }

    /// 滑杆、开关、通道不要当成拖动手势
    /// - Parameters:
    ///   - gestureRecognizer: 拖动手势
    ///   - touch: 当前触点
    /// - Returns: 落在 UIControl 上则不拖
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var node = touch.view
        while let current = node, current !== self {
            if current is UIControl {
                return false
            }
            node = current.superview
        }
        return true
    }
}

/// 波形绘制：按屏幕像素最近邻取样，关闭插值
private final class AlbumScopeWaveformPlotView: UIView {
    /// 内部按像素对齐的图
    private let imageView = UIImageView()
    /// 当前快照
    private var snapshot: AlbumScopeSnapshot?
    /// 当前通道模式
    private var mode: AlbumScopeWaveformMode = .mixed
    /// 是否上色
    private var colorize = false

    /// 黑底 + 最近邻图层
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .nearest
        imageView.layer.minificationFilter = .nearest
        addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 写入快照并画 256×256；放大由最近邻图层完成
    /// - Parameters:
    ///   - snapshot: 密度；nil 则只改模式
    ///   - mode: 混合 / R / G / B
    ///   - colorize: 上色开关
    func apply(snapshot: AlbumScopeSnapshot?, mode: AlbumScopeWaveformMode, colorize: Bool) {
        if let snapshot = snapshot {
            self.snapshot = snapshot
        }
        self.mode = mode
        self.colorize = colorize
        guard let snapshot = self.snapshot else {
            imageView.image = nil
            return
        }
        imageView.image = snapshot.makeWaveformImage(mode: mode, colorize: colorize)
    }
}

/// 直方图面积图：R/G/B 半透明叠画，可选 Y
private final class AlbumScopeHistogramView: UIView {
    /// 当前帧计数
    var snapshot: AlbumScopeSnapshot?
    /// 是否叠亮度曲线
    var showsLuma = false

    /// 画 RGB（及可选 Y）面积与 0/50/100 刻度
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        UIColor(white: 0.05, alpha: 1).setFill()
        context.fill(rect)
        let plot = rect.insetBy(dx: 4, dy: 8)
        drawGrid(in: plot)
        guard let snapshot = snapshot else {
            return
        }
        let maxCount = visibleMax(snapshot)
        guard maxCount > 0 else {
            return
        }
        fillChannel(snapshot.histogramR, color: UIColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.88), plot: plot, maxCount: maxCount)
        fillChannel(snapshot.histogramG, color: UIColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 0.88), plot: plot, maxCount: maxCount)
        fillChannel(snapshot.histogramB, color: UIColor(red: 0.25, green: 0.45, blue: 1, alpha: 0.88), plot: plot, maxCount: maxCount)
        if showsLuma {
            strokeChannel(snapshot.histogramY, color: UIColor.white, plot: plot, maxCount: maxCount)
        }
    }

    /// 可见通道的峰，用作 Gain 归一化
    /// - Parameter snapshot: 当前快照
    /// - Returns: 最大计数
    private func visibleMax(_ snapshot: AlbumScopeSnapshot) -> UInt32 {
        var peak: UInt32 = 0
        func consider(_ values: [UInt32]) {
            for value in values where value > peak {
                peak = value
            }
        }
        consider(snapshot.histogramR)
        consider(snapshot.histogramG)
        consider(snapshot.histogramB)
        if showsLuma {
            consider(snapshot.histogramY)
        }
        return peak
    }

    /// 0 / 50 / 100% 竖线
    /// - Parameter plot: 绘图区
    private func drawGrid(in plot: CGRect) {
        let color = UIColor(white: 1, alpha: 0.18)
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = 1
        for t in [CGFloat(0), 0.5, 1] {
            let x = plot.minX + plot.width * t
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor(white: 1, alpha: 0.45)
        ]
        ("0%" as NSString).draw(at: CGPoint(x: plot.minX, y: plot.maxY - 10), withAttributes: attrs)
        ("50%" as NSString).draw(at: CGPoint(x: plot.midX - 10, y: plot.maxY - 10), withAttributes: attrs)
        ("100%" as NSString).draw(at: CGPoint(x: plot.maxX - 22, y: plot.maxY - 10), withAttributes: attrs)
    }

    /// 半透明填充
    /// - Parameters:
    ///   - values: 256 档
    ///   - color: 填充色
    ///   - plot: 绘图区
    ///   - maxCount: Gain
    private func fillChannel(_ values: [UInt32], color: UIColor, plot: CGRect, maxCount: UInt32) {
        guard values.count >= AlbumScopeSnapshot.binCount else {
            return
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        let last = AlbumScopeSnapshot.binCount - 1
        for i in 0...last {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(last)
            let y = plot.maxY - plot.height * CGFloat(values[i]) / CGFloat(maxCount)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.close()
        color.setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Y 用描边以免盖住 RGB
    /// - Parameters:
    ///   - values: 256 档
    ///   - color: 描边色
    ///   - plot: 绘图区
    ///   - maxCount: Gain
    private func strokeChannel(_ values: [UInt32], color: UIColor, plot: CGRect, maxCount: UInt32) {
        guard values.count >= AlbumScopeSnapshot.binCount else {
            return
        }
        let path = UIBezierPath()
        path.lineWidth = 1.5
        let last = AlbumScopeSnapshot.binCount - 1
        for i in 0...last {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(last)
            let y = plot.maxY - plot.height * CGFloat(values[i]) / CGFloat(maxCount)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        color.setStroke()
        path.stroke()
    }
}

/// 波形左侧 0 / 50 / 100 电平
private final class AlbumScopeWaveformScaleView: UIView {
    /// 画纵轴百分比
    override func draw(_ rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor(white: 1, alpha: 0.55)
        ]
        ("100" as NSString).draw(at: CGPoint(x: 0, y: 0), withAttributes: attrs)
        ("50" as NSString).draw(at: CGPoint(x: 2, y: rect.midY - 5), withAttributes: attrs)
        ("0" as NSString).draw(at: CGPoint(x: 6, y: rect.maxY - 10), withAttributes: attrs)
    }
}
