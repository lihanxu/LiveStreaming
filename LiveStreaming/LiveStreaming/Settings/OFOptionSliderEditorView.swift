//
//  OFOptionSliderEditorView.swift
//  LiveStreaming
//
//  LUT / 美肤滤镜：横向互斥选项 + 一条灵敏度滑杆，布局对齐调色页。
//

import UIKit
import SnapKit

/// 互斥选项 + 灵敏度回调。
protocol OFOptionSliderEditorViewDelegate: AnyObject {
    /// 点了某个预设 / 风格
    func optionSliderEditor(_ editor: OFOptionSliderEditorView, didSelect id: Int)
    /// 拖动灵敏度
    func optionSliderEditor(_ editor: OFOptionSliderEditorView, didChangeIntensity value: Float)
}

/// 调色同款：图标行 + 底部滑杆。
class OFOptionSliderEditorView: UIView {
    /// 图标区高度
    private let iconRowHeight: CGFloat = 72
    /// 单个图标格子宽
    private let iconItemWidth: CGFloat = 56
    /// 滑杆区高度
    private let sliderRowHeight: CGFloat = 44
    /// 滑杆强调色
    private let accentColor = UIColor(red: 1.0, green: 0.42, blue: 0.18, alpha: 1.0)
    
    /// 事件回设置页
    weak var delegate: OFOptionSliderEditorViewDelegate?
    /// 当前页数据
    private var page = OFOptionSliderPage(options: [], selectedID: 0, intensity: 0, intensityEnabled: false)
    
    /// 横向图标列表
    private var iconCollection: UICollectionView!
    /// 灵敏度
    private let slider = UISlider()
    
    /// 组装图标和滑杆
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 卡片内内容高度
    /// - Returns: 不含顶栏和指示条
    func contentHeight() -> CGFloat {
        return 8 + iconRowHeight + sliderRowHeight
    }
    
    /// 刷新选项和滑杆
    /// - Parameter page: 当前页
    func reload(page: OFOptionSliderPage) {
        self.page = page
        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = page.intensity
        slider.isEnabled = page.intensityEnabled
        slider.alpha = page.intensityEnabled ? 1 : 0.35
        iconCollection.reloadData()
        if let index = page.options.firstIndex(where: { $0.id == page.selectedID }) {
            iconCollection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
        }
    }
    
    /// 横向列表、滑杆
    private func setupViews() {
        backgroundColor = .clear
        
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 4
        layout.minimumInteritemSpacing = 0
        iconCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        iconCollection.backgroundColor = .clear
        iconCollection.showsHorizontalScrollIndicator = false
        iconCollection.delegate = self
        iconCollection.dataSource = self
        iconCollection.register(OFOptionSliderIconCell.self, forCellWithReuseIdentifier: OFOptionSliderIconCell.reuseID)
        addSubview(iconCollection)
        
        slider.minimumTrackTintColor = UIColor(white: 0.92, alpha: 1)
        slider.maximumTrackTintColor = UIColor(white: 0.55, alpha: 1)
        slider.setThumbImage(OFColorAdjustIconDrawer.thumbImage(color: accentColor, diameter: 16), for: .normal)
        slider.addTarget(self, action: #selector(handleSlider), for: .valueChanged)
        addSubview(slider)
        
        iconCollection.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(iconRowHeight)
        }
        slider.snp.makeConstraints { make in
            make.top.equalTo(iconCollection.snp.bottom)
            make.leading.trailing.equalToSuperview().inset(20)
            make.height.equalTo(sliderRowHeight)
        }
    }
    
    /// 拖动立刻写回
    @objc private func handleSlider() {
        guard page.intensityEnabled else {
            return
        }
        delegate?.optionSliderEditor(self, didChangeIntensity: slider.value)
    }
}

extension OFOptionSliderEditorView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 选项数量
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return page.options.count
    }
    
    /// 绑定标题和选中态
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFOptionSliderIconCell.reuseID, for: indexPath) as! OFOptionSliderIconCell
        let row = page.options[indexPath.item]
        cell.bind(title: row.title, selected: row.id == page.selectedID)
        return cell
    }
    
    /// 固定图标格子尺寸
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: iconItemWidth, height: iconRowHeight)
    }
    
    /// 点选项切换预设 / 风格
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let id = page.options[indexPath.item].id
        delegate?.optionSliderEditor(self, didSelect: id)
    }
}

/// 圆形线框 + 标题。
class OFOptionSliderIconCell: UICollectionViewCell {
    /// 复用标识
    static let reuseID = "OFOptionSliderIconCell"
    
    /// 线框图标
    private let iconView = UIImageView()
    /// 参数名
    private let titleLabel = UILabel()
    
    /// 创建图标和标题
    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .center
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 10)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        iconView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(8)
            make.centerX.equalToSuperview()
            make.size.equalTo(36)
        }
        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(iconView.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview().inset(2)
        }
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 选中实心底 + 加粗白圈
    /// - Parameters:
    ///   - title: 选项名
    ///   - selected: 当前项
    func bind(title: String, selected: Bool) {
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        titleLabel.alpha = selected ? 1 : 0.42
        iconView.image = OFOptionSliderIconDrawer.ringImage(size: 36, selected: selected)
    }
}

/// 只有圆环，避免为每个 LUT 预设单独画 glyph。
enum OFOptionSliderIconDrawer {
    /// 圆形线框
    /// - Parameters:
    ///   - size: 边长
    ///   - selected: 选中填浅底
    /// - Returns: 图标
    static func ringImage(size: CGFloat, selected: Bool) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let ring = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 2, dy: 2)
            let ringPath = UIBezierPath(ovalIn: ring)
            if selected {
                UIColor(white: 1, alpha: 0.28).setFill()
                ringPath.fill()
                ringPath.lineWidth = 2.2
                UIColor.white.setStroke()
            } else {
                ringPath.lineWidth = 1
                UIColor(white: 1, alpha: 0.38).setStroke()
            }
            ringPath.stroke()
        }
    }
}
