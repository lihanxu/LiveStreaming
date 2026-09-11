//
//  AlbumViewController.swift
//  LiveStreaming
//
//  读取系统相册并网格展示；未授权时引导去设置。
//

import UIKit
import SnapKit
import Photos

/// 相册网格页：浏览或挑选视频片段。
class AlbumViewController: UIViewController {

    /// 为 true 时只列出视频，供编辑页追加片段
    private let videoOnly: Bool
    /// 非空则点选后回调并 pop，不进入编辑页
    private let pickHandler: ((PHAsset) -> Void)?

    /// 按拍摄时间倒序的资源结果；未授权或为空时为 nil
    private var fetchResult: PHFetchResult<PHAsset>?
    /// 异步出缩略图，避免卡主线程
    private let imageManager = PHCachingImageManager()
    /// 当前格子对应的请求像素尺寸（随列宽变化）
    private var thumbnailSize = CGSize(width: 120, height: 120)
    /// 无权限 / 空相册提示
    private let statusLabel = UILabel()
    /// 去系统设置或补充受限相册
    private let actionButton = UIButton(type: .system)
    /// 相册格子
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .white
        view.register(AlbumPhotoCell.self, forCellWithReuseIdentifier: AlbumPhotoCell.reuseId)
        view.dataSource = self
        view.delegate = self
        return view
    }()

    /// 浏览系统相册
    init() {
        videoOnly = false
        pickHandler = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// 挑选一段视频追加到工程
    /// - Parameters:
    ///   - videoOnly: 是否只显示视频
    ///   - pickHandler: 选中后回调
    init(videoOnly: Bool, pickHandler: @escaping (PHAsset) -> Void) {
        self.videoOnly = videoOnly
        self.pickHandler = pickHandler
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 搭 UI，注册相册变更，再按权限拉资源
    override func viewDidLoad() {
        super.viewDidLoad()
        title = pickHandler == nil ? "相册" : "选择视频"
        view.backgroundColor = .white
        PHPhotoLibrary.shared().register(self)
        initUI()
        initLayout()
        requestAccessAndReload()
    }

    /// 按当前列宽重算缩略图像素，减少糊图或浪费
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let columns: CGFloat = 4
        let spacing: CGFloat = 2
        let width = floor((collectionView.bounds.width - spacing * (columns - 1)) / columns)
        guard width > 0 else { return }
        let scale = UIScreen.main.scale
        thumbnailSize = CGSize(width: width * scale, height: width * scale)
    }

    /// 注销相册观察，避免页面销毁后仍回调
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    /// 网格铺满，提示叠在中间
    private func initUI() {
        view.addSubview(collectionView)

        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.textColor = UIColor(white: 0.4, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        actionButton.setTitle("去设置", for: .normal)
        actionButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        actionButton.addTarget(self, action: #selector(handleActionTap), for: .touchUpInside)
        actionButton.isHidden = true
        view.addSubview(actionButton)
    }

    /// 集合视图贴安全区，提示居中
    private func initLayout() {
        collectionView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.bottom.equalToSuperview()
        }
        statusLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
            make.leading.trailing.equalToSuperview().inset(32)
        }
        actionButton.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(12)
            make.centerX.equalToSuperview()
        }
    }

    /// 按系统版本申请读相册权限，再刷新列表
    private func requestAccessAndReload() {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            handleAuthorization(status)
        } else {
            handleAuthorization(PHPhotoLibrary.authorizationStatus())
        }
    }

    /// 已授权则拉资源；未决定则弹系统框；拒绝则引导设置
    /// - Parameter status: 当前 Photos 授权状态
    private func handleAuthorization(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            reloadAssets()
        case .notDetermined:
            requestAuthorization()
        case .denied, .restricted:
            showEmptyState(message: "没有相册访问权限，请在系统设置中允许访问。", actionTitle: "去设置")
        @unknown default:
            showEmptyState(message: "无法访问相册。", actionTitle: "去设置")
        }
    }

    /// iOS 14+ 用 readWrite，旧系统走无级别接口
    private func requestAuthorization() {
        let handler: (PHAuthorizationStatus) -> Void = { [weak self] status in
            DispatchQueue.main.async {
                self?.handleAuthorization(status)
            }
        }
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handler)
        } else {
            PHPhotoLibrary.requestAuthorization(handler)
        }
    }

    /// 倒序拉取图/视频，刷新网格
    private func reloadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result: PHFetchResult<PHAsset>
        if videoOnly {
            result = PHAsset.fetchAssets(with: .video, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        fetchResult = result
        if result.count == 0 {
            let limited: Bool
            if #available(iOS 14, *) {
                limited = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
            } else {
                limited = false
            }
            if limited {
                showEmptyState(message: "当前仅可访问部分照片，可在系统设置中调整权限。", actionTitle: "去设置")
            } else {
                showEmptyState(message: "相册里还没有内容。", actionTitle: nil)
            }
        } else {
            statusLabel.isHidden = true
            actionButton.isHidden = true
            collectionView.isHidden = false
            collectionView.reloadData()
        }
    }

    /// 隐藏网格并展示说明；无操作按钮时只留文案
    /// - Parameters:
    ///   - message: 中间提示
    ///   - actionTitle: 按钮文案；nil 表示不显示按钮
    private func showEmptyState(message: String, actionTitle: String?) {
        collectionView.isHidden = true
        statusLabel.isHidden = false
        statusLabel.text = message
        if let actionTitle = actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    /// 打开系统设置，让用户改相册权限
    @objc private func handleActionTap() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

extension AlbumViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    /// 相册资源数
    /// - Parameters:
    ///   - collectionView: 网格
    ///   - section: 分区，目前只有一组
    /// - Returns: PHAsset 数量
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return fetchResult?.count ?? 0
    }

    /// 绑定缩略图和视频角标
    /// - Parameters:
    ///   - collectionView: 网格
    ///   - indexPath: 格子位置
    /// - Returns: 复用后的格子
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AlbumPhotoCell.reuseId, for: indexPath) as! AlbumPhotoCell
        guard let asset = fetchResult?.object(at: indexPath.item) else {
            return cell
        }
        cell.representedAssetIdentifier = asset.localIdentifier
        cell.showsVideoBadge = asset.mediaType == .video
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: options) { image, _ in
            // 复用后 identifier 对不上则丢弃，避免闪错图
            if cell.representedAssetIdentifier == asset.localIdentifier {
                cell.imageView.image = image
            }
        }
        return cell
    }

    /// 四列等宽正方形
    /// - Parameters:
    ///   - collectionView: 网格
    ///   - collectionViewLayout: 流式布局
    ///   - indexPath: 格子位置
    /// - Returns: 单格尺寸
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = 4
        let spacing: CGFloat = 2
        let width = floor((collectionView.bounds.width - spacing * (columns - 1)) / columns)
        return CGSize(width: width, height: width)
    }

    /// 进入编辑页（LUT / 美颜 / 导出）
    /// - Parameters:
    ///   - collectionView: 网格
    ///   - indexPath: 点中的格子
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let asset = fetchResult?.object(at: indexPath.item) else { return }
        if let pickHandler = pickHandler {
            guard asset.mediaType == .video else { return }
            pickHandler(asset)
            navigationController?.popViewController(animated: true)
            return
        }
        let editor = AlbumEditorViewController(asset: asset)
        navigationController?.pushViewController(editor, animated: true)
    }
}

extension AlbumViewController: PHPhotoLibraryChangeObserver {
    /// 用户增删照片或改受限范围后重拉列表
    /// - Parameter changeInstance: 系统变更描述
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            self?.reloadAssets()
        }
    }
}

/// 相册缩略图格子：图片 + 可选视频标记。
class AlbumPhotoCell: UICollectionViewCell {
    /// 复用标识
    static let reuseId = "AlbumPhotoCell"
    /// 当前格子对应的 PHAsset.localIdentifier，用来丢掉过期回调
    var representedAssetIdentifier: String?
    /// 缩略图
    let imageView = UIImageView()
    /// 视频资源时显示「视频」角标
    private let badgeLabel = UILabel()
    /// 是否显示视频角标
    var showsVideoBadge: Bool = false {
        didSet {
            badgeLabel.isHidden = !showsVideoBadge
        }
    }

    /// 铺满裁剪，角标贴右下
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = UIColor(white: 0.92, alpha: 1)
        contentView.addSubview(imageView)

        badgeLabel.text = "视频"
        badgeLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = UIColor(white: 0, alpha: 0.45)
        badgeLabel.textAlignment = .center
        badgeLabel.isHidden = true
        contentView.addSubview(badgeLabel)

        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        badgeLabel.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(4)
            make.size.equalTo(CGSize(width: 32, height: 16))
        }
        badgeLabel.layer.cornerRadius = 3
        badgeLabel.clipsToBounds = true
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 复用前清图，避免残影
    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        representedAssetIdentifier = nil
        showsVideoBadge = false
    }
}
