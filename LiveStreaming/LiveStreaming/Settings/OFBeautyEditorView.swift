//
//  OFBeautyEditorView.swift
//  LiveStreaming
//
//  美颜卡片内容：横向图标、单滑杆。对比按钮在设置卡片外由外壳放置。
//  磨皮 / 美白 / 亮眼 / 白牙用滑杆；点美白进入暖白/冷白/粉白二级页；一键与手动互斥。
//

import UIKit

/// 美颜编辑器回调。
protocol OFBeautyEditorViewDelegate: AnyObject {
    /// 拖动着色滑杆
    func beautyEditor(_ editor: OFBeautyEditorView, didChange key: OFBeautyToneKey, value: Float)
    /// 点人脸网格
    func beautyEditorDidToggleMesh(_ editor: OFBeautyEditorView)
    /// 点面部重塑
    func beautyEditorDidTapReshape(_ editor: OFBeautyEditorView)
    /// 点美白，进入风格二级页
    func beautyEditorDidTapWhiteningStyle(_ editor: OFBeautyEditorView)
    /// 点一键美颜
    func beautyEditorDidToggleOneClick(_ editor: OFBeautyEditorView)
    /// 点了磨皮等子项或进入重塑，退出一键模式并保留当前数值
    func beautyEditorDidLeaveOneClick(_ editor: OFBeautyEditorView)
}

/// 美颜卡片内容：横向图标、单滑杆。
class OFBeautyEditorView: UIView {
    /// 图标区高度
    private let iconRowHeight: CGFloat = 72
    /// 单个图标格子宽
    private let iconItemWidth: CGFloat = 56
    /// 滑杆区高度
    private let sliderRowHeight: CGFloat = 44
    /// 滑杆强调色
    private let accentColor = UIColor(red: 1.0, green: 0.42, blue: 0.18, alpha: 1.0)
    
    /// 事件回设置页
    weak var delegate: OFBeautyEditorViewDelegate?
    /// 当前面板行
    private var rows: [OFBeautySliderRow] = []
    /// 当前选中的滑杆项
    private var selectedKey: OFBeautyPanelKey = .smooth
    /// 人脸网格是否打开，用来画选中圈
    private var meshOn = false
    /// 一键美颜是否打开
    private var oneClickOn = false
    
    /// 横向图标列表
    private var iconCollection: UICollectionView!
    /// 当前项灵敏度
    private let slider = UISlider()
    
    /// 组装图标、滑杆
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
    
    /// 用最新参数刷新；保留当前着色项
    /// - Parameters:
    ///   - rows: 面板行
    ///   - meshOn: 网格是否打开
    ///   - oneClickOn: 一键美颜是否打开
    func reload(rows: [OFBeautySliderRow], meshOn: Bool, oneClickOn: Bool) {
        self.rows = rows
        self.meshOn = meshOn
        self.oneClickOn = oneClickOn
        if oneClickOn {
            selectedKey = .oneClick
            slider.isHidden = true
        } else {
            slider.isHidden = false
            if !selectedKey.usesSlider, let first = rows.first(where: { $0.key.usesSlider }) {
                selectedKey = first.key
            }
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
        iconCollection.register(OFBeautyIconCell.self, forCellWithReuseIdentifier: OFBeautyIconCell.reuseID)
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
    
    /// 按选中着色项同步滑杆
    private func syncSlider() {
        guard selectedKey.usesSlider, let row = rows.first(where: { $0.key == selectedKey }) else {
            return
        }
        slider.minimumValue = row.minimum
        slider.maximumValue = row.maximum
        slider.value = row.value
    }
    
    /// 拖动滑杆立刻写回
    @objc private func handleSlider() {
        guard let tone = selectedKey.toneKey else {
            return
        }
        delegate?.beautyEditor(self, didChange: tone, value: slider.value)
        if let index = rows.firstIndex(where: { $0.key == selectedKey }) {
            rows[index] = OFBeautySliderRow(
                key: selectedKey,
                title: rows[index].title,
                value: slider.value,
                minimum: rows[index].minimum,
                maximum: rows[index].maximum
            )
        }
    }
}

extension OFBeautyEditorView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 图标数量
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return rows.count
    }
    
    /// 绑定图标和选中态
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OFBeautyIconCell.reuseID, for: indexPath) as! OFBeautyIconCell
        let row = rows[indexPath.item]
        let selected: Bool
        switch row.key {
        case .faceMesh:
            selected = meshOn
        case .oneClick:
            selected = oneClickOn
        case .faceReshape:
            selected = false
        default:
            selected = !oneClickOn && row.key == selectedKey
        }
        cell.bind(row: row, selected: selected)
        return cell
    }
    
    /// 固定图标格子尺寸
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return CGSize(width: iconItemWidth, height: iconRowHeight)
    }
    
    /// 点图标：滑杆切换 / 网格开关 / 进入重塑
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let key = rows[indexPath.item].key
        switch key {
        case .oneClick:
            delegate?.beautyEditorDidToggleOneClick(self)
        case .faceMesh:
            delegate?.beautyEditorDidToggleMesh(self)
        case .faceReshape:
            if oneClickOn {
                oneClickOn = false
                delegate?.beautyEditorDidLeaveOneClick(self)
            }
            delegate?.beautyEditorDidTapReshape(self)
        case .whitening:
            selectedKey = key
            if oneClickOn {
                oneClickOn = false
                slider.isHidden = false
                delegate?.beautyEditorDidLeaveOneClick(self)
            }
            delegate?.beautyEditorDidTapWhiteningStyle(self)
        case .smooth, .brightEyes, .whiteTeeth:
            selectedKey = key
            if oneClickOn {
                oneClickOn = false
                slider.isHidden = false
                delegate?.beautyEditorDidLeaveOneClick(self)
            }
            collectionView.reloadData()
            slider.isHidden = false
            syncSlider()
        }
    }
}

/// 横向列表里的圆形图标 + 标题。
class OFBeautyIconCell: UICollectionViewCell {
    /// 复用标识
    static let reuseID = "OFBeautyIconCell"
    
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
    
    /// 选中实心底 + 加粗白圈
    /// - Parameters:
    ///   - row: 面板项
    ///   - selected: 滑杆项为当前项，网格为打开态
    func bind(row: OFBeautySliderRow, selected: Bool) {
        titleLabel.text = row.title
        titleLabel.font = UIFont.systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        titleLabel.alpha = selected ? 1 : 0.42
        iconView.image = OFBeautyIconDrawer.parameterImage(key: row.key, size: 36, selected: selected)
    }
}

/// 用 Bezier 画线框图标，避免依赖 SF Symbol。
enum OFBeautyIconDrawer {
    /// 圆形线框图标
    /// - Parameters:
    ///   - key: 面板项
    ///   - size: 边长
    ///   - selected: 选中填浅底
    /// - Returns: 图标
    static func parameterImage(key: OFBeautyPanelKey, size: CGFloat, selected: Bool) -> UIImage {
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
    
    /// 圆内识别图形
    /// - Parameters:
    ///   - key: 面板项
    ///   - rect: 内接矩形
    ///   - color: 线色
    private static func drawGlyph(key: OFBeautyPanelKey, in rect: CGRect, color: UIColor) {
        color.setStroke()
        color.setFill()
        let path = UIBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch key {
        case .oneClick:
            // 四角星：一键套用
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + 2.2, y: rect.midY - 2.2))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + 2.2, y: rect.midY + 2.2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - 2.2, y: rect.midY + 2.2))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX - 2.2, y: rect.midY - 2.2))
            path.close()
            path.fill()
            return
        case .smooth:
            UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 3)).stroke()
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
            path.addCurve(
                to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 4),
                controlPoint1: CGPoint(x: rect.midX, y: rect.maxY),
                controlPoint2: CGPoint(x: rect.midX + 2, y: rect.maxY - 6)
            )
        case .whitening:
            UIBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).stroke()
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let inner = CGPoint(x: rect.midX + cos(angle) * 7, y: rect.midY + sin(angle) * 7)
                let outer = CGPoint(x: rect.midX + cos(angle) * (rect.width / 2), y: rect.midY + sin(angle) * (rect.height / 2))
                path.move(to: inner)
                path.addLine(to: outer)
            }
        case .brightEyes:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                controlPoint1: CGPoint(x: rect.midX, y: rect.minY + 1),
                controlPoint2: CGPoint(x: rect.midX, y: rect.minY + 1)
            )
            path.addCurve(
                to: CGPoint(x: rect.minX, y: rect.midY),
                controlPoint1: CGPoint(x: rect.midX, y: rect.maxY - 1),
                controlPoint2: CGPoint(x: rect.midX, y: rect.maxY - 1)
            )
            UIBezierPath(ovalIn: CGRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
            return
        case .whiteTeeth:
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY - 2))
            path.addCurve(
                to: CGPoint(x: rect.maxX - 1, y: rect.midY - 2),
                controlPoint1: CGPoint(x: rect.midX, y: rect.maxY),
                controlPoint2: CGPoint(x: rect.midX, y: rect.maxY)
            )
            path.move(to: CGPoint(x: rect.midX - 3, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX - 3, y: rect.midY + 4))
            path.move(to: CGPoint(x: rect.midX + 3, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + 3, y: rect.midY + 4))
        case .faceMesh:
            for row in 0..<3 {
                for col in 0..<3 {
                    let x = rect.minX + 3 + CGFloat(col) * 5
                    let y = rect.minY + 3 + CGFloat(row) * 5
                    UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 2.2, height: 2.2)).fill()
                }
            }
            return
        case .faceReshape:
            UIBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 0)).stroke()
            return
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
