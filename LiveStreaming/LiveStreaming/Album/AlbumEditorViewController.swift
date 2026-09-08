//
//  AlbumEditorViewController.swift
//  LiveStreaming
//
//  相册编辑页 UI；滤镜/预览/导出经 AlbumEditSession 串行 GPU 队列。
//

import UIKit
import Photos
import AVFoundation
import CocoaLumberjack
import OFFilterKit

/// 相册单资源编辑：OpenGL 预览 + 设置卡片 + 导出。
class AlbumEditorViewController: UIViewController {
    /// 当前编辑的相册资源
    private let asset: PHAsset
    /// 编辑会话（方案 B）
    private let session = AlbumEditSession()
    /// 设置数据源（相册模式）
    private lazy var settingsController: OFSettingsController = {
        let controller = OFSettingsController(tools: session.tools, context: .album)
        controller.onPipelineChanged = { [weak self] in
            self?.handlePipelineChanged()
        }
        return controller
    }()
    /// 底部设置卡片
    private var settingsSheet: OFSettingsSheetView!
    /// OpenGL 预览
    private let previewView = SCGLView()
    /// 照片原始 BGRA；滤镜必须从该副本重跑
    private var photoSourceBuffer: CVPixelBuffer?
    /// 视频播放器
    private let videoPlayer = AlbumVideoPlayer()
    /// 导出用 AVAsset；预览加载后缓存
    private var videoAsset: AVAsset?
    /// 是否正在导出（UI 态）
    private var isExporting = false

    /// 右上设置
    private let settingsButton = UIButton(type: .system)
    /// 右上导出
    private let exportButton = UIButton(type: .system)
    /// 视频播放/暂停
    private let playButton = UIButton(type: .system)
    /// 照片画幅入口；视频隐藏
    private let geometryButton = UIButton(type: .system)
    /// 画幅底部面板
    private let geometryPanel = AlbumGeometryPanelView()
    /// 加载中
    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .whiteLarge)
        return indicator
    }()
    /// 导出进度条
    private let exportProgressView = UIProgressView(progressViewStyle: .default)
    /// 导出进度文案
    private let exportProgressLabel = UILabel()

    /// - Parameter asset: 用户点中的 PHAsset
    init(asset: PHAsset) {
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
    }

    /// 不支持 Storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 搭 UI 并加载媒体
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = asset.mediaType == .video ? "视频编辑" : "照片编辑"
        videoPlayer.delegate = self
        initUI()
        initLayout()
        loadMedia()
    }

    /// 可见后开 GL 预览；静图必须在 start 之后再入帧，否则会被丢掉
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        previewView.start()
        if asset.mediaType == .image {
            reprocessPhotoPreview()
        }
        if asset.mediaType == .video, videoAsset != nil, !isExporting {
            videoPlayer.play()
            updatePlayButtonTitle()
        }
    }

    /// 离开页停预览与视频
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewView.stop()
        videoPlayer.pause()
    }

    /// 释放视频资源
    deinit {
        videoPlayer.teardown()
    }

    /// 预览 + 按钮 + 设置卡片
    private func initUI() {
        previewView.holdsLastFrame = true
        previewView.isAspectFitEnabled = true
        view.addSubview(previewView)

        configureTopButton(settingsButton, title: "设置")
        settingsButton.addTarget(self, action: #selector(handleSettingsTap), for: .touchUpInside)
        view.addSubview(settingsButton)

        configureTopButton(exportButton, title: "导出")
        exportButton.addTarget(self, action: #selector(handleExportTap), for: .touchUpInside)
        view.addSubview(exportButton)

        playButton.setTitle("播放", for: .normal)
        playButton.setTitleColor(.white, for: .normal)
        playButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        playButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        playButton.layer.cornerRadius = 18
        playButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        playButton.addTarget(self, action: #selector(handlePlayTap), for: .touchUpInside)
        playButton.isHidden = asset.mediaType != .video
        view.addSubview(playButton)

        geometryButton.setTitle("画幅", for: .normal)
        geometryButton.setTitleColor(.white, for: .normal)
        geometryButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        geometryButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        geometryButton.layer.cornerRadius = 18
        geometryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        geometryButton.addTarget(self, action: #selector(handleGeometryTap), for: .touchUpInside)
        geometryButton.isHidden = asset.mediaType != .image
        view.addSubview(geometryButton)

        geometryPanel.delegate = self
        geometryPanel.isHidden = true
        view.addSubview(geometryPanel)

        activityIndicator.color = .white
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        exportProgressView.progressTintColor = UIColor(red: 0.2, green: 0.65, blue: 1, alpha: 1)
        exportProgressView.isHidden = true
        view.addSubview(exportProgressView)

        exportProgressLabel.font = UIFont.systemFont(ofSize: 13)
        exportProgressLabel.textColor = .white
        exportProgressLabel.textAlignment = .center
        exportProgressLabel.isHidden = true
        view.addSubview(exportProgressLabel)

        settingsSheet = OFSettingsSheetView(controller: settingsController)
        view.addSubview(settingsSheet)
        view.bringSubviewToFront(geometryPanel)
    }

    /// 统一顶部按钮样式
    private func configureTopButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = UIColor(white: 0, alpha: 0.35)
        button.layer.cornerRadius = 16
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
    }

    /// Auto Layout
    private func initLayout() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.translatesAutoresizingMaskIntoConstraints = false
        geometryButton.translatesAutoresizingMaskIntoConstraints = false
        geometryPanel.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        exportProgressView.translatesAutoresizingMaskIntoConstraints = false
        exportProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsSheet.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),

            exportButton.topAnchor.constraint(equalTo: settingsButton.topAnchor),
            exportButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),

            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            geometryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            geometryButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            geometryPanel.topAnchor.constraint(equalTo: view.topAnchor),
            geometryPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            geometryPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geometryPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            exportProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            exportProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            exportProgressView.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: -16),

            exportProgressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            exportProgressLabel.bottomAnchor.constraint(equalTo: exportProgressView.topAnchor, constant: -8),

            settingsSheet.topAnchor.constraint(equalTo: view.topAnchor),
            settingsSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            settingsSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// 按类型加载照片或视频
    private func loadMedia() {
        activityIndicator.startAnimating()
        exportButton.isEnabled = false
        if asset.mediaType == .video {
            AlbumMediaConverter.loadVideoAsset(asset: asset) { [weak self] avAsset in
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()
                guard let avAsset = avAsset else {
                    self.showAlert(title: "加载失败", message: "无法读取视频资源")
                    return
                }
                self.videoAsset = avAsset
                self.videoPlayer.configure(with: avAsset)
                self.exportButton.isEnabled = true
                if self.isViewLoaded && self.view.window != nil && !self.isExporting {
                    self.videoPlayer.play()
                    self.updatePlayButtonTitle()
                }
            }
        } else {
            AlbumMediaConverter.loadPhotoBuffer(
                asset: asset,
                maxLongEdge: AlbumMediaConverter.previewMaxLongEdge,
                pool: session.tools.pixelBufferPool
            ) { [weak self] buffer in
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()
                guard let buffer = buffer else {
                    self.showAlert(title: "加载失败", message: "无法读取照片")
                    return
                }
                self.photoSourceBuffer = buffer
                self.reprocessPhotoPreview()
                self.exportButton.isEnabled = true
            }
        }
    }

    /// 设置变更：照片重跑 source
    private func handlePipelineChanged() {
        if asset.mediaType == .image {
            reprocessPhotoPreview()
        }
    }

    /// 经 session GPU 队列重跑照片预览
    private func reprocessPhotoPreview() {
        guard let source = photoSourceBuffer else { return }
        session.reprocessPhotoPreview(source: source) { [weak self] frame in
            self?.previewView.inputFrame(frame)
        }
    }

    /// 进入导出独占：停播放器（释放 AVAsset，避免和 Reader 抢同一份资源）
    /// - Parameter work: 主线程；在 session 标记 isExporting 后执行
    private func enterExportMode(work: @escaping () -> Void) {
        geometryPanel.dismiss()
        videoPlayer.teardown()
        updatePlayButtonTitle()
        previewView.stop()
        session.beginExport {
            work()
        }
    }

    /// 退出导出独占并恢复预览
    /// - Parameter resumeVideo: 是否恢复视频播放
    private func leaveExportMode(resumeVideo: Bool, completion: (() -> Void)? = nil) {
        session.endExport { [weak self] in
            guard let self = self else { return }
            self.previewView.start()
            if resumeVideo, self.asset.mediaType == .video, let videoAsset = self.videoAsset {
                self.videoPlayer.configure(with: videoAsset)
                self.videoPlayer.play()
                self.updatePlayButtonTitle()
            }
            completion?()
        }
    }

    /// 弹出设置
    @objc private func handleSettingsTap() {
        geometryPanel.dismiss()
        view.bringSubviewToFront(settingsSheet)
        settingsSheet.present()
    }

    /// 弹出画幅面板
    @objc private func handleGeometryTap() {
        guard !isExporting, asset.mediaType == .image else { return }
        geometryPanel.geometry = session.document.geometry
        view.bringSubviewToFront(geometryPanel)
        geometryPanel.present()
    }

    /// 播放/暂停视频
    @objc private func handlePlayTap() {
        guard !isExporting else { return }
        videoPlayer.togglePlayback()
        updatePlayButtonTitle()
    }

    /// 同步播放按钮文案
    private func updatePlayButtonTitle() {
        playButton.setTitle(videoPlayer.isPlaying() ? "暂停" : "播放", for: .normal)
    }

    /// 导出到相册
    @objc private func handleExportTap() {
        guard !isExporting else { return }
        if asset.mediaType == .video {
            exportVideo()
        } else {
            exportPhoto()
        }
    }

    /// 照片导出
    private func exportPhoto() {
        isExporting = true
        setExportUI(visible: true, progress: 0, text: "准备导出…")
        exportButton.isEnabled = false
        geometryButton.isEnabled = false

        enterExportMode { [weak self] in
            guard let self = self else { return }
            AlbumMediaConverter.loadPhotoBuffer(
                asset: self.asset,
                maxLongEdge: AlbumMediaConverter.photoExportMaxLongEdge,
                pool: self.session.tools.pixelBufferPool
            ) { buffer in
                guard let buffer = buffer else {
                    self.finishExport(success: false, message: "无法读取原图", resumeVideo: false)
                    return
                }
                self.session.exportPhoto(from: buffer) { result in
                    switch result {
                    case .success(let image):
                        self.setExportUI(visible: true, progress: 0.9, text: "写入相册…")
                        AlbumVideoExporter.savePhotoToPhotoLibrary(image: image) { saveResult in
                            switch saveResult {
                            case .success:
                                self.finishExport(success: true, message: "已保存到相册", resumeVideo: false)
                            case .failure(let error):
                                self.finishExport(success: false, message: error.localizedDescription, resumeVideo: false)
                            }
                        }
                    case .failure(let error):
                        self.finishExport(success: false, message: error.localizedDescription, resumeVideo: false)
                    }
                }
            }
        }
    }

    /// 视频导出
    private func exportVideo() {
        guard let videoAsset = videoAsset else {
            showAlert(title: "导出失败", message: "视频尚未加载完成")
            return
        }
        isExporting = true
        setExportUI(visible: true, progress: 0, text: "导出中 0%")
        exportButton.isEnabled = false
        playButton.isEnabled = false

        enterExportMode { [weak self] in
            guard let self = self else { return }
            DDLogInfo("album export video tapped")
            self.session.exportVideo(asset: videoAsset, progress: { [weak self] value in
                self?.setExportUI(
                    visible: true,
                    progress: value,
                    text: String(format: "导出中 %d%%", Int(value * 100))
                )
            }, completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let url):
                    self.setExportUI(visible: true, progress: 0.95, text: "写入相册…")
                    AlbumVideoExporter.saveVideoToPhotoLibrary(fileURL: url) { saveResult in
                        switch saveResult {
                        case .success:
                            self.finishExport(success: true, message: "已保存到相册", resumeVideo: true)
                        case .failure(let error):
                            self.finishExport(success: false, message: error.localizedDescription, resumeVideo: true)
                        }
                    }
                case .failure(let error):
                    self.finishExport(success: false, message: error.localizedDescription, resumeVideo: true)
                }
            })
        }
    }

    /// 更新导出进度 UI
    private func setExportUI(visible: Bool, progress: Float, text: String) {
        exportProgressView.isHidden = !visible
        exportProgressLabel.isHidden = !visible
        exportProgressView.progress = progress
        exportProgressLabel.text = text
    }

    /// 导出结束
    private func finishExport(success: Bool, message: String, resumeVideo: Bool) {
        leaveExportMode(resumeVideo: resumeVideo) { [weak self] in
            guard let self = self else { return }
            self.isExporting = false
            self.exportButton.isEnabled = true
            self.playButton.isEnabled = true
            self.geometryButton.isEnabled = true
            self.setExportUI(visible: false, progress: 0, text: "")
            self.showAlert(title: success ? "导出成功" : "导出失败", message: message)
        }
    }

    /// 简单弹窗
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

extension AlbumEditorViewController: AlbumVideoPlayerDelegate {
    /// DisplayLink 在主线程触发，处理交给 session GPU 队列
    func videoPlayer(_ player: AlbumVideoPlayer, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isExporting else { return }
        session.processVideoPreviewFrame(pixelBuffer, preferredTransform: player.preferredTransform) { [weak self] frame in
            self?.previewView.inputFrame(frame)
        }
    }
}

extension AlbumEditorViewController: AlbumGeometryPanelViewDelegate {
    /// 画幅文档变更：从 source 重跑几何 + 滤镜
    func geometryPanel(_ panel: AlbumGeometryPanelView, didChange geometry: AlbumGeometryEdit) {
        session.document.geometry = geometry
        reprocessPhotoPreview()
    }
}
