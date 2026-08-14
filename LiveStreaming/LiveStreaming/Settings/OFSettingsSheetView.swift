//
//  OFSettingsSheetView.swift
//  LiveStreaming
//
//  底部毛玻璃设置卡片：4 列网格，单击改值，复杂项 push 二级页。
//  适配 iOS 11：FlowLayout + UIBlurEffect.dark，不用 SF Symbol / compositional layout。
//

import UIKit

/// 从底部弹出的设置面板。
class OFSettingsSheetView: UIView {
    /// 每行列数，与参考图一致
    private let columns = 4
    /// 单个格子高度
    private let cellHeight: CGFloat = 76
    /// 调色滑杆行高
    private let sliderCellHeight: CGFloat = 56
    /// 滑杆页最多同时露出的行数，超出可滚动
    private let maxVisibleSliderRows = 6
    /// 卡片相对屏幕左右边距
    private let cardInset: CGFloat = 12
    /// 顶栏高度（标题 / 返回）
    private let headerHeight: CGFloat = 48
    
    /// 提供页面数据和点击处理
    private let controller: OFSettingsController
    /// 导航栈，末尾为当前页
    private var pageStack: [OFSettingsPageID] = [.root]
    
    /// 点击空白关闭
    private let dimmingView = UIButton(type: .custom)
    /// 圆角卡片容器
    private let cardView = UIView()
    /// 深色毛玻璃
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// 顶栏
    private let headerView = UIView()
    /// 二级页返回
    private let backButton = UIButton(type: .system)
    /// 当前页标题
    private let titleLabel = UILabel()
    /// 调色页复位全部滑杆
    private let resetButton = UIButton(type: .system)
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
    
    /// 蒙层 + 卡片 + 网格
    private func setupViews() {
        backgroundColor = .clear
        isHidden = true
        
        dimmingView.backgroundColor = UIColor(white: 0, alpha: 0.32)
        dimmingView.addTarget(self, action: #selector(handleDimmingTap), for: .touchUpInside)
        addSubview(dimmingView)
        
        cardView.backgroundColor = .clear
        cardView.layer.cornerRadius = 28
        cardView.clipsToBounds = true
        addSubview(cardView)
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
        collectionView.register(OFColorSliderCell.self, forCellWithReuseIdentifier: OFColorSliderCell.reuseID)
        cardView.addSubview(collectionView)
        
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
        
        let cardHeight = cardHeightConstraint(forRowCount: 2)
        cardHeightConstraint = cardHeight
        let cardBottom = cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 400)
        cardBottomConstraint = cardBottom
        
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cardInset),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -cardInset),
            cardBottom,
            cardHeight,
            
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
        dimmingView.alpha = 0
        cardBottomConstraint?.constant = -8
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut], animations: {
            self.dimmingView.alpha = 1
            self.layoutIfNeeded()
        })
    }
    
    /// 收起卡片
    func dismiss() {
        cardBottomConstraint?.constant = 420
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn], animations: {
            self.dimmingView.alpha = 0
            self.layoutIfNeeded()
        }, completion: { _ in
            self.isHidden = true
            self.pageStack = [.root]
        })
    }
    
    /// 点击蒙层关闭
    @objc private func handleDimmingTap() {
        dismiss()
    }
    
    /// 调色页全部滑杆归零
    @objc private func handleReset() {
        controller.resetColorAdjust()
        reloadCurrentPage()
    }
    
    /// 二级页返回上一级
    @objc private func handleBack() {
        guard pageStack.count > 1 else {
            return
        }
        pageStack.removeLast()
        reloadCurrentPage()
    }
    
    /// 下拉超过阈值则关闭
    /// - Parameter gesture: 卡片上的拖动手势
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .changed:
            cardBottomConstraint?.constant = max(-8, -8 + translation.y)
        case .ended, .cancelled:
            if translation.y > 80 {
                dismiss()
            } else {
                cardBottomConstraint?.constant = -8
                UIView.animate(withDuration: 0.2) {
                    self.layoutIfNeeded()
                }
            }
        default:
            break
        }
    }
    
    /// 按导航栈顶刷新标题、返回按钮、网格或滑杆高度
    private func reloadCurrentPage() {
        let page = controller.page(for: pageStack.last ?? .root)
        titleLabel.text = page.title
        backButton.isHidden = pageStack.count <= 1
        resetButton.isHidden = page.id != .colorAdjust
        collectionView.isScrollEnabled = page.usesSliders
        if page.usesSliders {
            let visibleRows = min(page.sliders.count, maxVisibleSliderRows)
            cardHeightConstraint?.constant = cardHeightValue(forSliderRows: visibleRows)
        } else {
            let rows = max(1, Int(ceil(Double(page.items.count) / Double(columns))))
            cardHeightConstraint?.constant = cardHeightValue(forRowCount: rows)
        }
        layoutIfNeeded()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
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
    
    /// 顶栏 + 可见滑杆行 + 底部指示条
    /// - Parameter sliderRows: 露出的滑杆行数
    /// - Returns: 卡片总高度
    private func cardHeightValue(forSliderRows sliderRows: Int) -> CGFloat {
        let bottomSafe: CGFloat = 18
        return 8 + headerHeight + CGFloat(sliderRows) * sliderCellHeight + 12 + 5 + 10 + bottomSafe
    }
    
    /// 当前页快照
    /// - Returns: 栈顶对应的 page
    private func currentPage() -> OFSettingsPage {
        return controller.page(for: pageStack.last ?? .root)
    }
}

extension OFSettingsSheetView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 格子数或滑杆行数
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        let page = currentPage()
        if page.usesSliders {
            return page.sliders.count
        }
        return page.items.count
    }
    
    /// 绑定网格格子或调色滑杆
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let page = currentPage()
        if page.usesSliders {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFColorSliderCell.reuseID, for: indexPath) as! OFColorSliderCell
            let row = page.sliders[indexPath.item]
            cell.bind(row: row) { [weak self] key, value in
                self?.controller.updateColorAdjust(key: key, value: value)
            }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFSettingsGridCell.reuseID, for: indexPath) as! OFSettingsGridCell
        let items = page.items
        let item = items[indexPath.item]
        let isLastColumn = (indexPath.item % columns) == columns - 1
        let rowCount = Int(ceil(Double(items.count) / Double(columns)))
        let currentRow = indexPath.item / columns
        cell.bind(item: item, showRightSeparator: !isLastColumn, showBottomSeparator: currentRow < rowCount - 1)
        return cell
    }
    
    /// 网格等分 4 列；滑杆占满一行
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if currentPage().usesSliders {
            return CGSize(width: collectionView.bounds.width, height: sliderCellHeight)
        }
        let width = floor(collectionView.bounds.width / CGFloat(columns))
        return CGSize(width: width, height: cellHeight)
    }
    
    /// 单击：开关 / 循环 / 进入二级页；滑杆页不响应点按
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        let page = currentPage()
        guard !page.usesSliders else {
            return
        }
        let item = page.items[indexPath.item]
        let result = controller.performTap(item.id)
        switch result {
        case .reload:
            reloadCurrentPage()
        case .push(let pageID):
            pageStack.append(pageID)
            reloadCurrentPage()
        }
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

/// 调色页一行：标题、数值、滑杆。拖动时只回调，不刷新整个列表。
class OFColorSliderCell: UICollectionViewCell {
    /// 复用标识
    static let reuseID = "OFColorSliderCell"
    
    /// 参数名
    private let titleLabel = UILabel()
    /// 当前整数值
    private let valueLabel = UILabel()
    /// 强度滑杆
    private let slider = UISlider()
    /// 当前绑定的参数
    private var key: OFColorAdjustKey?
    /// 拖动回调；复用前会覆盖
    private var onChange: ((OFColorAdjustKey, Float) -> Void)?
    
    /// 创建标题、数值和滑杆
    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = UIColor(white: 1, alpha: 0.7)
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textAlignment = .right
        slider.minimumTrackTintColor = UIColor(white: 1, alpha: 0.9)
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.22)
        slider.addTarget(self, action: #selector(handleSlider), for: .valueChanged)
        
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        contentView.addSubview(slider)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            
            slider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 绑定一行滑杆；回调在拖动过程中连续触发
    /// - Parameters:
    ///   - row: 展示数据
    ///   - onChange: 新值写回处理图
    func bind(row: OFColorSliderRow, onChange: @escaping (OFColorAdjustKey, Float) -> Void) {
        key = row.key
        self.onChange = onChange
        titleLabel.text = row.title
        slider.minimumValue = row.minimum
        slider.maximumValue = row.maximum
        slider.value = row.value
        valueLabel.text = formattedValue(row.value)
    }
    
    /// 拖动滑杆：更新数字并通知控制器
    @objc private func handleSlider() {
        let value = slider.value
        valueLabel.text = formattedValue(value)
        guard let key = key else {
            return
        }
        onChange?(key, value)
    }
    
    /// 显示为整数，避免拖动时抖动
    /// - Parameter value: 滑杆值
    /// - Returns: 整数字符串
    private func formattedValue(_ value: Float) -> String {
        return String(Int(round(value)))
    }
}
