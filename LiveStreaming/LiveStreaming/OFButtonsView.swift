//
//  OFButtonsView.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  底部横向功能按钮。LUT 切换后可通过 updateItem 改文案。
//

import UIKit

/// 底部按钮点击回调。
protocol OFButtonsViewDelegate: NSObjectProtocol {
    /// 用户点中某个功能
    /// - Parameters:
    ///   - view: 按钮条
    ///   - index: 按钮下标
    func buttonDidSelect(_ view: OFButtonsView, index: Int)
}

/// 单个功能按钮 cell。
class OFButtonsCollectionViewCell: UICollectionViewCell {
    /// 按钮文案
    var textLabel :UILabel!
    /// 选中时白字黑底，未选中黑字白底
    override var isSelected: Bool {
        didSet {
            textLabel.textColor = isSelected ? .white : .black
            textLabel.backgroundColor = isSelected ? .black : .white
        }
    }
    
    /// 创建 cell 并搭 UI
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUI()
    }
    
    /// 不支持 Storyboard
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// self-sizing：固定宽 68，高度沿用 layout
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let att = super.preferredLayoutAttributesFitting(layoutAttributes);
        var newFrame = self.bounds
        newFrame.size.width = 68
        newFrame.size.height = newFrame.height
        att.frame = newFrame
        return att
    }

    /// 圆角 + 铺满的居中 Label
    func setUI() {
        clipsToBounds = true
        layer.cornerRadius = 8
        backgroundColor = .clear
        textLabel = UILabel()
        textLabel.textColor = .black
        textLabel.font = UIFont.systemFont(ofSize: 14)
        textLabel.backgroundColor = .white
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 2
        contentView.addSubview(textLabel)
        
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            textLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            textLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
}

/// 底部横向功能按钮条。
class OFButtonsView: UIView {
    /// 点击回调
    weak var delegate: OFButtonsViewDelegate?
    /// 横向 collection
    private var collectionView: UICollectionView!
    /// 按钮文案列表
    private var items: Array<String>!
    
    /// 用文案列表创建，默认不预选
    /// - Parameter items: 按钮标题
    init(withItems items: Array<String>) {
        super.init(frame: .zero)
        self.items = items
        initUI()
    }

    /// 用文案列表创建并选中指定下标
    /// - Parameters:
    ///   - items: 按钮标题
    ///   - index: 初始选中项
    init(withItems items: Array<String>, selectedIndex index: Int = 0) {
        super.init(frame: .zero)
        self.items = items
        initUI()
        collectionView.selectItem(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .centeredHorizontally)
    }
    
    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 创建横向 collection 并铺满自身
    private func initUI() {
        backgroundColor = .clear
        
        let layout = UICollectionViewFlowLayout()
        layout.estimatedItemSize = CGSize(width: 68, height: 36)
        layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        layout.scrollDirection = .horizontal
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.bounces = false
        collectionView.backgroundColor = .clear
        collectionView.register(OFButtonsCollectionViewCell.self, forCellWithReuseIdentifier: "OFButtonsCollectionViewCell")
        addSubview(collectionView)
        
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: self.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        ])
    }
    
    /// 滚到指定按钮居中
    /// - Parameter index: 下标
    func scrollToItem(atIndex index: Int) {
        guard items.count > index else {
            return
        }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredHorizontally, animated: true)
    }
    
    /// 选中指定按钮
    /// - Parameter index: 下标
    func selectItem(atIndex index: Int) {
        collectionView.selectItem(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .centeredHorizontally)
    }
    
    /// 更新某个按钮文案（LUT 切换预设时用）。
    func updateItem(at index: Int, text: String) {
        guard items.indices.contains(index) else {
            return
        }
        items[index] = text
        collectionView.reloadItems(at: [IndexPath(row: index, section: 0)])
    }
}

extension OFButtonsView: UICollectionViewDelegate {
    /// 点击后居中滚动并通知 delegate
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        delegate?.buttonDidSelect(self, index: indexPath.row)
    }
}

extension OFButtonsView: UICollectionViewDataSource {
    /// 按钮个数
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }
    
    /// 绑定文案
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "OFButtonsCollectionViewCell", for: indexPath) as! OFButtonsCollectionViewCell
        guard items.count > indexPath.row else {
            return cell
        }
        cell.textLabel.text = items[indexPath.row]
        return cell
    }
}

