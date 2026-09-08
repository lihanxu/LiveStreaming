//
//  OFSettingsSheetView.swift
//  LiveStreaming
//
//  底部毛玻璃设置面板：根页和二级页共用，贴底铺满全宽。
//  适配 iOS 11：FlowLayout + UIBlurEffect.dark，不用 SF Symbol / compositional layout。
//

import UIKit
import OFFilterKit

/// 从底部弹出的设置面板。
class OFSettingsSheetView: UIView {
    /// 每行列数，与参考图一致
    private let columns = 4
    /// 单个格子高度
    private let cellHeight: CGFloat = 76
    /// 顶栏高度（标题 / 返回）
    private let headerHeight: CGFloat = 48
    
    /// 提供页面数据和点击处理
    private let controller: OFSettingsController
    /// 导航栈，末尾为当前页
    private var pageStack: [OFSettingsPageID] = [.root]
    
    /// 卡片外的透明点击区，用来关闭；不加暗色，避免挡住预览
    private let dimmingView = UIButton(type: .custom)
    /// 贴底全宽面板
    private let cardView = UIView()
    /// 深色毛玻璃；alpha 压低，避免糊死预览
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 顶栏
    private let headerView = UIView()
    /// 二级页返回
    private let backButton = UIButton(type: .system)
    /// 当前页标题
    private let titleLabel = UILabel()
    /// 调色页右侧复位
    private let resetButton = UIButton(type: .system)
    /// 调色内容，放在同一张卡片里
    private let colorEditor = OFColorAdjustEditorView()
    /// 面部重塑：对比 + 图标 + 滑杆
    private let reshapeEditor = OFFaceReshapeEditorView()
    /// 美颜着色：横向图标 + 滑杆
    private let beautyEditor = OFBeautyEditorView()
    /// LUT / 美肤滤镜：互斥选项 + 灵敏度
    private let optionEditor = OFOptionSliderEditorView()
    /// 对比原图；放在卡片上方，不挡预览也不挤占栏内空间
    private let compareButton = UIButton(type: .custom)
    /// 对比按钮边长
    private let compareSize: CGFloat = 36
    /// 参数网格
    private var collectionView: UICollectionView!
    /// 底部横条，提示可下拉关闭
    private let homeIndicator = UIView()
    /// 卡片高度约束，随行数变化
    private var cardHeightConstraint: NSLayoutConstraint?
    /// 卡片贴底约束，动画时改 constant
    private var cardBottomConstraint: NSLayoutConstraint?
    
    /// - Parameter controller: 设置数据源
    init(controller: OFSettingsController) {
        self.controller = controller
        super.init(frame: .zero)
        setupViews()
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 调色 / 重塑 / 美颜页时空白交给预览；对比按钮在卡片外仍要能点
    /// - Parameters:
    ///   - point: 本视图坐标
    ///   - event: 触摸事件
    /// - Returns: 实际接收者；空白处为 nil
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isHidden {
            return nil
        }
        if !compareButton.isHidden {
            let compareLocal = convert(point, to: compareButton)
            if let hit = compareButton.hitTest(compareLocal, with: event) {
                return hit
            }
        }
        if !colorEditor.isHidden || !reshapeEditor.isHidden || !beautyEditor.isHidden || !optionEditor.isHidden {
            let cardLocal = convert(point, to: cardView)
            return cardView.hitTest(cardLocal, with: event)
        }
        return super.hitTest(point, with: event)
    }
    
    /// 透明点击区 + 卡片 + 网格
    private func setupViews() {
        backgroundColor = .clear
        isHidden = true
        
        dimmingView.backgroundColor = .clear
        dimmingView.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        addSubview(dimmingView)
        
        cardView.backgroundColor = .clear
        cardView.layer.cornerRadius = 20
        cardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        cardView.clipsToBounds = true
        addSubview(cardView)
        blurView.alpha = 0.55
        cardView.addSubview(blurView)
        
        backButton.setTitle("返回", for: .normal)
        backButton.setTitleColor(.white, for: .normal)
        backButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        backButton.isHidden = true
        
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        
        resetButton.setTitle("复位", for: .normal)
        resetButton.setTitleColor(.white, for: .normal)
        resetButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        resetButton.addTarget(self, action: #selector(handleReset), for: .touchUpInside)
        resetButton.isHidden = true
        
        headerView.addSubview(backButton)
        headerView.addSubview(titleLabel)
        headerView.addSubview(resetButton)
        cardView.addSubview(headerView)
        
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.scrollDirection = .vertical
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.isScrollEnabled = false
        collectionView.delaysContentTouches = false
        collectionView.register(OFSettingsGridCell.self, forCellWithReuseIdentifier: OFSettingsGridCell.reuseID)
        cardView.addSubview(collectionView)
        
        colorEditor.delegate = self
        colorEditor.isHidden = true
        cardView.addSubview(colorEditor)
        
        reshapeEditor.delegate = self
        reshapeEditor.isHidden = true
        cardView.addSubview(reshapeEditor)
        
        beautyEditor.delegate = self
        beautyEditor.isHidden = true
        cardView.addSubview(beautyEditor)
        
        optionEditor.delegate = self
        optionEditor.isHidden = true
        cardView.addSubview(optionEditor)
        
        compareButton.setImage(OFColorAdjustIconDrawer.compareImage(size: compareSize), for: .normal)
        compareButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        compareButton.layer.cornerRadius = compareSize / 2
        compareButton.addTarget(self, action: #selector(handleCompareDown), for: .touchDown)
        compareButton.addTarget(self, action: #selector(handleCompareUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        compareButton.isHidden = true
        addSubview(compareButton)
        
        homeIndicator.backgroundColor = UIColor(white: 1, alpha: 0.85)
        homeIndicator.layer.cornerRadius = 2.5
        cardView.addSubview(homeIndicator)
        
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        blurView.translatesAutoresizingMaskIntoConstraints = false
        headerView.translatesAutoresizingMaskIntoConstraints = false
        backButton.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        homeIndicator.translatesAutoresizingMaskIntoConstraints = false
        colorEditor.translatesAutoresizingMaskIntoConstraints = false
        reshapeEditor.translatesAutoresizingMaskIntoConstraints = false
        beautyEditor.translatesAutoresizingMaskIntoConstraints = false
        optionEditor.translatesAutoresizingMaskIntoConstraints = false
        compareButton.translatesAutoresizingMaskIntoConstraints = false
        
        let cardHeight = cardHeightConstraint(forRowCount: 2)
        cardHeightConstraint = cardHeight
        let cardBottom = cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 400)
        cardBottomConstraint = cardBottom
        
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardBottom,
            cardHeight,
            
            compareButton.bottomAnchor.constraint(equalTo: cardView.topAnchor, constant: -12),
            compareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            compareButton.widthAnchor.constraint(equalToConstant: compareSize),
            compareButton.heightAnchor.constraint(equalToConstant: compareSize),
            
            blurView.topAnchor.constraint(equalTo: cardView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            
            headerView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 8),
            headerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight),
            
            backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            
            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            
            resetButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            resetButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            
            collectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: homeIndicator.topAnchor, constant: -12),
            
            colorEditor.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            colorEditor.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            colorEditor.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            colorEditor.bottomAnchor.constraint(equalTo: homeIndicator.topAnchor, constant: -12),
            
            reshapeEditor.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            reshapeEditor.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            reshapeEditor.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            reshapeEditor.bottomAnchor.constraint(equalTo: homeIndicator.topAnchor, constant: -12),
            
            beautyEditor.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            beautyEditor.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            beautyEditor.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            beautyEditor.bottomAnchor.constraint(equalTo: homeIndicator.topAnchor, constant: -12),
            
            optionEditor.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            optionEditor.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            optionEditor.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            optionEditor.bottomAnchor.constraint(equalTo: homeIndicator.topAnchor, constant: -12),
            
            homeIndicator.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            homeIndicator.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
            homeIndicator.widthAnchor.constraint(equalToConstant: 36),
            homeIndicator.heightAnchor.constraint(equalToConstant: 5),
        ])
        
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        headerView.addGestureRecognizer(pan)
    }
    
    /// 弹出卡片并重置到根页
    func present() {
        pageStack = [.root]
        reloadCurrentPage()
        isHidden = false
        layoutIfNeeded()
        cardBottomConstraint?.constant = 0
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut], animations: {
            self.layoutIfNeeded()
        })
    }
    
    /// 收起卡片
    func dismiss() {
        if pageStack.last == .colorAdjust {
            controller.confirmColorAdjustEditing()
        }
        releaseCompareHolding()
        cardBottomConstraint?.constant = 420
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn], animations: {
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
            self.pageStack = [.root]
        })
    }
    
    /// 点击卡片外关闭
    @objc private func handleDimmingTap() {
        dismiss()
    }
    
    /// 调色或重塑页全部滑杆归零
    @objc private func handleReset() {
        if pageStack.last == .colorAdjust {
            controller.resetColorAdjust()
        } else if pageStack.last == .faceReshape {
            controller.resetFaceReshape()
        } else if pageStack.last == .beauty {
            controller.resetBeautyTone()
        } else if pageStack.last == .lut {
            controller.resetLUTIntensity()
        } else if pageStack.last == .transition {
            controller.resetTransitionDuration()
        } else if pageStack.last == .whiteningStyle {
            controller.resetWhiteningIntensity()
        }
        reloadCurrentPage()
    }
    
    /// 二级页返回上一级；调色页保留当前参数，与 LUT 一样即时生效
    @objc private func handleBack() {
        guard pageStack.count > 1 else {
            return
        }
        if pageStack.last == .colorAdjust {
            controller.confirmColorAdjustEditing()
        }
        releaseCompareHolding()
        pageStack.removeLast()
        reloadCurrentPage()
    }
    
    /// 下拉超过阈值则关闭
    /// - Parameter gesture: 卡片上的拖动手势
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .changed:
            cardBottomConstraint?.constant = max(0, translation.y)
        case .ended, .cancelled:
            if translation.y > 80 {
                dismiss()
            } else {
                cardBottomConstraint?.constant = 0
                UIView.animate(withDuration: 0.2) {
                    self.layoutIfNeeded()
                }
            }
        default:
            break
        }
    }
    
    /// 按导航栈顶刷新：根页和二级页都用同一张卡片
    private func reloadCurrentPage() {
        let page = controller.page(for: pageStack.last ?? .root)
        let isColor = page.id == .colorAdjust
        let isReshape = page.id == .faceReshape
        let isBeauty = page.id == .beauty
        let isOption = page.optionSlider != nil
        titleLabel.text = page.title
        backButton.isHidden = pageStack.count <= 1
        resetButton.isHidden = !(isColor || isReshape || isBeauty || isOption)
        collectionView.isScrollEnabled = false
        collectionView.isHidden = isColor || isReshape || isBeauty || isOption
        colorEditor.isHidden = !isColor
        reshapeEditor.isHidden = !isReshape
        beautyEditor.isHidden = !isBeauty
        optionEditor.isHidden = !isOption
        compareButton.isHidden = !showsCompareButton
        cardView.isHidden = false
        dimmingView.isUserInteractionEnabled = true
        if isColor {
            cardHeightConstraint?.constant = cardHeightValue(forColorEditor: colorEditor.contentHeight())
            colorEditor.reload(rows: page.sliders)
        } else if isReshape {
            cardHeightConstraint?.constant = cardHeightValue(forColorEditor: reshapeEditor.contentHeight())
            reshapeEditor.reload(rows: page.reshapeSliders)
        } else if isBeauty {
            cardHeightConstraint?.constant = cardHeightValue(forColorEditor: beautyEditor.contentHeight())
            beautyEditor.reload(
                rows: page.beautySliders,
                meshOn: controller.isFaceMeshOverlayEnabled,
                oneClickOn: controller.isBeautyOneClickEnabled
            )
        } else if isOption, let option = page.optionSlider {
            cardHeightConstraint?.constant = cardHeightValue(forColorEditor: optionEditor.contentHeight())
            optionEditor.reload(page: option)
        } else {
            let rows = max(1, Int(ceil(Double(page.items.count) / Double(columns))))
            cardHeightConstraint?.constant = cardHeightValue(forRowCount: rows)
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.reloadData()
        }
        layoutIfNeeded()
    }
    
    /// 计算卡片高度约束
    /// - Parameter rowCount: 网格行数
    /// - Returns: 已激活的高度约束（仅创建时使用）
    private func cardHeightConstraint(forRowCount rowCount: Int) -> NSLayoutConstraint {
        return cardView.heightAnchor.constraint(equalToConstant: cardHeightValue(forRowCount: rowCount))
    }
    
    /// 顶栏 + 网格 + 底部指示条
    /// - Parameter rowCount: 行数
    /// - Returns: 卡片总高度
    private func cardHeightValue(forRowCount rowCount: Int) -> CGFloat {
        let bottomSafe: CGFloat = 18
        return 8 + headerHeight + CGFloat(rowCount) * cellHeight + 12 + 5 + 10 + bottomSafe
    }
    
    /// 顶栏 + 调色内容 + 底部指示条
    /// - Parameter editorHeight: 调色内容高度
    /// - Returns: 卡片总高度
    private func cardHeightValue(forColorEditor editorHeight: CGFloat) -> CGFloat {
        let bottomSafe: CGFloat = 18
        return 8 + headerHeight + editorHeight + 12 + 5 + 10 + bottomSafe
    }
    
    /// 美颜 / 美肤滤镜 / 重塑 / 调色页在卡片上方放对比
    private var showsCompareButton: Bool {
        switch pageStack.last ?? .root {
        case .beauty, .whiteningStyle, .faceReshape, .colorAdjust, .lut:
            return true
        case .root, .cartoon, .transition:
            return false
        }
    }
    
    /// 松开关闭对比，避免离开页面后还旁路
    private func releaseCompareHolding() {
        controller.setBeautyToneCompareHolding(false)
        controller.setFaceReshapeCompareHolding(false)
        controller.setColorAdjustCompareHolding(false)
        controller.setLUTBypassed(false)
    }
    
    /// 按住对比看未处理画面
    @objc private func handleCompareDown() {
        switch pageStack.last ?? .root {
        case .beauty, .whiteningStyle:
            controller.setBeautyToneCompareHolding(true)
        case .faceReshape:
            controller.setFaceReshapeCompareHolding(true)
        case .colorAdjust:
            controller.setColorAdjustCompareHolding(true)
        case .lut:
            controller.setLUTBypassed(true)
        case .root, .cartoon, .transition:
            break
        }
    }
    
    /// 松开对比
    @objc private func handleCompareUp() {
        releaseCompareHolding()
    }
    
    /// 当前页快照
    /// - Returns: 栈顶对应的 page
    private func currentPage() -> OFSettingsPage {
        return controller.page(for: pageStack.last ?? .root)
    }
}

extension OFSettingsSheetView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 格子数
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return currentPage().items.count
    }
    
    /// 绑定标题和当前值
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFSettingsGridCell.reuseID, for: indexPath) as! OFSettingsGridCell
        let items = currentPage().items
        let item = items[indexPath.item]
        let isLastColumn = (indexPath.item % columns) == columns - 1
        let rowCount = Int(ceil(Double(items.count) / Double(columns)))
        let currentRow = indexPath.item / columns
        cell.bind(item: item, showRightSeparator: !isLastColumn, showBottomSeparator: currentRow < rowCount - 1)
        return cell
    }
    
    /// 等分 4 列
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = floor(collectionView.bounds.width / CGFloat(columns))
        return CGSize(width: width, height: cellHeight)
    }
    
    /// 单击：开关 / 循环 / 进入二级页
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let items = currentPage().items
        guard indexPath.item < items.count else {
            return
        }
        let item = items[indexPath.item]
        let result = controller.performTap(item.id)
        switch result {
        case .reload:
            reloadCurrentPage()
        case .push(let pageID):
            pageStack.append(pageID)
            if pageID == .colorAdjust {
                controller.beginColorAdjustEditing()
            }
            reloadCurrentPage()
        }
    }
}

extension OFSettingsSheetView: OFOptionSliderEditorViewDelegate {
    /// 点 LUT 预设或美肤滤镜
    func optionSliderEditor(_ editor: OFOptionSliderEditorView, didSelect id: Int) {
        if pageStack.last == .lut {
            controller.selectLUTOption(id)
        } else if pageStack.last == .whiteningStyle {
            controller.selectWhiteningOption(id)
        } else if pageStack.last == .transition {
            controller.selectTransitionOption(id)
        }
        reloadCurrentPage()
    }
    
    /// 拖动灵敏度
    func optionSliderEditor(_ editor: OFOptionSliderEditorView, didChangeIntensity value: Float) {
        if pageStack.last == .lut {
            controller.updateLUTIntensity(value)
        } else if pageStack.last == .whiteningStyle {
            controller.updateWhiteningIntensity(value)
        } else if pageStack.last == .transition {
            controller.updateTransitionDuration(value)
        }
    }
}

extension OFSettingsSheetView: OFColorAdjustEditorViewDelegate {
    /// 拖动当前项
    func colorAdjustEditor(_ editor: OFColorAdjustEditorView, didChange key: OFColorAdjustKey, value: Float) {
        controller.updateColorAdjust(key: key, value: value)
    }
}

extension OFSettingsSheetView: OFFaceReshapeEditorViewDelegate {
    /// 拖动当前项灵敏度
    func faceReshapeEditor(_ editor: OFFaceReshapeEditorView, didChange key: OFFaceReshapeKey, value: Float) {
        controller.updateFaceReshape(key: key, value: value)
    }
}

extension OFSettingsSheetView: OFBeautyEditorViewDelegate {
    /// 拖动着色滑杆
    func beautyEditor(_ editor: OFBeautyEditorView, didChange key: OFBeautyToneKey, value: Float) {
        controller.updateBeautyTone(key: key, value: value)
    }
    
    /// 进入美肤滤镜页
    func beautyEditorDidTapWhiteningStyle(_ editor: OFBeautyEditorView) {
        pageStack.append(.whiteningStyle)
        reloadCurrentPage()
    }
    
    /// 开关人脸网格
    func beautyEditorDidToggleMesh(_ editor: OFBeautyEditorView) {
        _ = controller.performTap(.faceMeshOverlay)
        reloadCurrentPage()
    }
    
    /// 进入面部重塑页
    func beautyEditorDidTapReshape(_ editor: OFBeautyEditorView) {
        pageStack.append(.faceReshape)
        reloadCurrentPage()
    }
    
    /// 开关一键美颜
    func beautyEditorDidToggleOneClick(_ editor: OFBeautyEditorView) {
        controller.toggleBeautyOneClick()
        reloadCurrentPage()
    }
    
    /// 点子项后退出一键，保留预设数值给手动调
    func beautyEditorDidLeaveOneClick(_ editor: OFBeautyEditorView) {
        controller.leaveBeautyOneClick()
        reloadCurrentPage()
    }
}

/// 设置网格格子：上标题、下当前值，细分割线。
class OFSettingsGridCell: UICollectionViewCell {
    /// 复用标识
    static let reuseID = "OFSettingsGridCell"
    
    /// 参数名
    private let titleLabel = UILabel()
    /// 当前值
    private let valueLabel = UILabel()
    /// 右侧竖线
    private let rightLine = UIView()
    /// 底部分割线
    private let bottomLine = UIView()
    
    /// 创建标签和分割线
    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.textAlignment = .center
        valueLabel.textColor = UIColor(white: 1, alpha: 0.55)
        valueLabel.font = UIFont.systemFont(ofSize: 13)
        valueLabel.textAlignment = .center
        let lineColor = UIColor(white: 1, alpha: 0.18)
        rightLine.backgroundColor = lineColor
        bottomLine.backgroundColor = lineColor
        
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        contentView.addSubview(rightLine)
        contentView.addSubview(bottomLine)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        rightLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        let hairline = 1.0 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -10),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            valueLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            
            rightLine.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rightLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightLine.widthAnchor.constraint(equalToConstant: hairline),
            
            bottomLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: hairline),
        ])
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 填充文案并控制分割线是否画出
    /// - Parameters:
    ///   - item: 设置项
    ///   - showRightSeparator: 最后一列不画竖线
    ///   - showBottomSeparator: 最后一行不画横线
    func bind(item: OFSettingItem, showRightSeparator: Bool, showBottomSeparator: Bool) {
        titleLabel.text = item.title
        valueLabel.text = item.valueText
        rightLine.isHidden = !showRightSeparator
        bottomLine.isHidden = !showBottomSeparator
    }
}

