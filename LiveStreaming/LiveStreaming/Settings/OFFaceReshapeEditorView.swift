//
//  OFFaceReshapeEditorView.swift
//  LiveStreaming
//
//  面部重塑卡片内容：横向图标、单滑杆；对比按钮在设置卡片外。
//

import UIKit
import OFFilterKit

/// 面部重塑编辑器回调。
protocol OFFaceReshapeEditorViewDelegate: AnyObject {
    /// 拖动当前项滑杆
    func faceReshapeEditor(_ editor: OFFaceReshapeEditorView, didChange key: OFFaceReshapeKey, value: Float)
}

/// 面部重塑卡片内容：横向图标、单滑杆；对比按钮在设置卡片外。
class OFFaceReshapeEditorView: UIView {
    /// 图标区高度（与调色页一致）
    private let iconRowHeight: CGFloat = 72
    /// 单个图标格子宽
    private let iconItemWidth: CGFloat = 56
    /// 滑杆区高度
    private let sliderRowHeight: CGFloat = 44
    /// 滑杆强调色（与调色页同一橙红圆点）
    private let accentColor = UIColor(red: 1.0, green: 0.42, blue: 0.18, alpha: 1.0)
    
    /// 事件回设置页
    weak var delegate: OFFaceReshapeEditorViewDelegate?
    /// 当前全部滑杆数据
    private var rows: [OFFaceReshapeSliderRow] = []
    /// 当前选中的重塑项
    private var selectedKey: OFFaceReshapeKey = .slimFace
    
    /// 横向图标列表
    private var iconCollection: UICollectionView!
    /// 当前项灵敏度
    private let slider = UISlider()
    
    /// 组装对比按钮、图标、滑杆
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 卡片内内容高度：图标 + 滑杆
    /// - Returns: 不含顶栏和指示条
    func contentHeight() -> CGFloat {
        return 8 + iconRowHeight + sliderRowHeight
    }
    
    /// 用最新参数刷新图标和滑杆；保留当前选中项
    /// - Parameter rows: 全部重塑行
    func reload(rows: [OFFaceReshapeSliderRow]) {
        self.rows = rows
        if !rows.contains(where: { $0.key == selectedKey }), let first = rows.first {
            selectedKey = first.key
        }
        iconCollection.reloadData()
        syncSlider()
        if let index = rows.firstIndex(where: { $0.key == selectedKey }) {
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
        iconCollection.register(OFFaceReshapeIconCell.self, forCellWithReuseIdentifier: OFFaceReshapeIconCell.reuseID)
        addSubview(iconCollection)
        
        slider.minimumTrackTintColor = UIColor(white: 0.92, alpha: 1)
        slider.maximumTrackTintColor = UIColor(white: 0.55, alpha: 1)
        slider.setThumbImage(OFColorAdjustIconDrawer.thumbImage(color: accentColor, diameter: 16), for: .normal)
        slider.addTarget(self, action: #selector(handleSlider), for: .valueChanged)
        addSubview(slider)
        
        iconCollection.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            iconCollection.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconCollection.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconCollection.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconCollection.heightAnchor.constraint(equalToConstant: iconRowHeight),
            
            slider.topAnchor.constraint(equalTo: iconCollection.bottomAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            slider.heightAnchor.constraint(equalToConstant: sliderRowHeight),
        ])
    }
    
    /// 按选中项同步滑杆范围和当前值
    private func syncSlider() {
        guard let row = rows.first(where: { $0.key == selectedKey }) else {
            return
        }
        slider.minimumValue = row.minimum
        slider.maximumValue = row.maximum
        slider.value = row.value
    }
    
    /// 拖动滑杆：立刻写回处理图
    @objc private func handleSlider() {
        delegate?.faceReshapeEditor(self, didChange: selectedKey, value: slider.value)
        if let index = rows.firstIndex(where: { $0.key == selectedKey }) {
            rows[index] = OFFaceReshapeSliderRow(
                key: selectedKey,
                title: rows[index].title,
                value: slider.value,
                minimum: rows[index].minimum,
                maximum: rows[index].maximum
            )
        }
    }
}

extension OFFaceReshapeEditorView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 重塑项数量
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return rows.count
    }
    
    /// 绑定图标和选中态
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFFaceReshapeIconCell.reuseID, for: indexPath) as! OFFaceReshapeIconCell
        let row = rows[indexPath.item]
        cell.bind(row: row, selected: row.key == selectedKey)
        return cell
    }
    
    /// 固定图标格子尺寸
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: iconItemWidth, height: iconRowHeight)
    }
    
    /// 点图标切换当前滑杆
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectedKey = rows[indexPath.item].key
        collectionView.reloadData()
        syncSlider()
    }
}

/// 横向列表里的圆形图标 + 标题。
class OFFaceReshapeIconCell: UICollectionViewCell {
    /// 复用标识
    static let reuseID = "OFFaceReshapeIconCell"
    
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
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 绘制对应线框；选中实心底 + 加粗白圈，未选中半透明细圈
    /// - Parameters:
    ///   - row: 重塑项
    ///   - selected: 是否为当前滑杆
    func bind(row: OFFaceReshapeSliderRow, selected: Bool) {
        titleLabel.text = row.title
        titleLabel.font = UIFont.systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        titleLabel.alpha = selected ? 1 : 0.42
        iconView.image = OFFaceReshapeIconDrawer.parameterImage(key: row.key, size: 36, selected: selected)
    }
}

/// 用 Bezier 画线框图标，避免依赖 SF Symbol（iOS 12）。
enum OFFaceReshapeIconDrawer {
    /// 某一项的圆形线框图标
    /// - Parameters:
    ///   - key: 重塑项
    ///   - size: 画布边长
    ///   - selected: 选中时填浅底并加粗白圈
    /// - Returns: 图标
    static func parameterImage(key: OFFaceReshapeKey, size: CGFloat, selected: Bool) -> UIImage {
        return draw(size: size) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
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
            let glyphColor = selected ? UIColor.white : UIColor(white: 1, alpha: 0.45)
            drawGlyph(key: key, in: ring.insetBy(dx: 7, dy: 7), color: glyphColor)
        }
    }
    
    /// 在圆内画该项的识别图形
    /// - Parameters:
    ///   - key: 重塑项
    ///   - rect: 内接矩形
    ///   - color: 线/填充色
    private static func drawGlyph(key: OFFaceReshapeKey, in rect: CGRect, color: UIColor) {
        color.setStroke()
        color.setFill()
        let path = UIBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch key {
        case .slimFace:
            // 瘦脸：竖向收窄的椭圆脸
            let slim = rect.insetBy(dx: rect.width * 0.22, dy: 0)
            UIBezierPath(ovalIn: slim).stroke()
            return
        case .bigEye:
            let left = CGRect(x: rect.minX, y: rect.midY - 4, width: 8, height: 8)
            let right = CGRect(x: rect.maxX - 8, y: rect.midY - 4, width: 8, height: 8)
            UIBezierPath(ovalIn: left).stroke()
            UIBezierPath(ovalIn: right).stroke()
            UIBezierPath(ovalIn: left.insetBy(dx: 2.5, dy: 2.5)).fill()
            UIBezierPath(ovalIn: right.insetBy(dx: 2.5, dy: 2.5)).fill()
            return
        case .slimNose:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 1))
            path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 1))
            path.close()
        case .mouth:
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
            path.addCurve(
                to: CGPoint(x: rect.maxX - 1, y: rect.midY),
                controlPoint1: CGPoint(x: rect.midX - 2, y: rect.maxY - 1),
                controlPoint2: CGPoint(x: rect.midX + 2, y: rect.maxY - 1)
            )
        case .hairline:
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 5))
            path.addCurve(
                to: CGPoint(x: rect.maxX - 1, y: rect.minY + 5),
                controlPoint1: CGPoint(x: rect.midX - 3, y: rect.minY),
                controlPoint2: CGPoint(x: rect.midX + 3, y: rect.minY)
            )
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 5))
            path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 1))
            path.move(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 5))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 1))
        case .jaw:
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.midY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 1))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY + 2))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 2))
        }
        path.stroke()
    }
    
    /// 在透明画布上描图
    /// - Parameters:
    ///   - size: 边长
    ///   - body: 绘制闭包
    /// - Returns: 位图
    private static func draw(size: CGFloat, body: (CGRect) -> Void) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
        body(CGRect(x: 0, y: 0, width: size, height: size))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
}
