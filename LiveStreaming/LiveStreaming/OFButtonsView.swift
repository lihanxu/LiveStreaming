//
//  OFButtonsView.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import UIKit

protocol OFButtonsViewDelegate: NSObjectProtocol {
    func buttonDidSelect(_ view: OFButtonsView, index: Int)
}

class OFButtonsCollectionViewCell: UICollectionViewCell {
    var textLabel :UILabel!
    override var isSelected: Bool {
        didSet {
            textLabel.textColor = isSelected ? .white : .black
            textLabel.backgroundColor = isSelected ? .black : .white
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUI()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let att = super.preferredLayoutAttributesFitting(layoutAttributes);
        var newFrame = self.bounds
        newFrame.size.width = 68
        newFrame.size.height = newFrame.height
        att.frame = newFrame
        return att
    }

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

class OFButtonsView: UIView {
    weak var delegate: OFButtonsViewDelegate?
    private var collectionView: UICollectionView!
    private var items: Array<String>!
    
    init(withItems items: Array<String>) {
        super.init(frame: .zero)
        self.items = items
        initUI()
    }

    init(withItems items: Array<String>, selectedIndex index: Int = 0) {
        super.init(frame: .zero)
        self.items = items
        initUI()
        collectionView.selectItem(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .centeredHorizontally)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
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
    
    func scrollToItem(atIndex index: Int) {
        guard items.count > index else {
            return
        }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredHorizontally, animated: true)
    }
    
    func selectItem(atIndex index: Int) {
        collectionView.selectItem(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .centeredHorizontally)
    }
}

extension OFButtonsView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        delegate?.buttonDidSelect(self, index: indexPath.row)
    }
}

extension OFButtonsView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "OFButtonsCollectionViewCell", for: indexPath) as! OFButtonsCollectionViewCell
        guard items.count > indexPath.row else {
            return cell
        }
        cell.textLabel.text = items[indexPath.row]
        return cell
    }
}

