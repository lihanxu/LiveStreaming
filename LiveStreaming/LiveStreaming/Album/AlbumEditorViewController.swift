//
//  AlbumEditorViewController.swift
//  LiveStreaming
//
//  相册编辑页 UI；滤镜/预览/导出经 AlbumEditSession 串行 GPU 队列。
//

import UIKit
import SnapKit
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
    /// 画幅入口；照片与视频都显示
    private let geometryButton = UIButton(type: .system)
    /// 视频剪辑入口（首尾 / 多段）；照片隐藏
    private let trimButton = UIButton(type: .system)
    /// 视频变速入口；照片隐藏
    private let speedButton = UIButton(type: .system)
    /// 示波器入口；照片与视频都显示
    private let scopeButton = UIButton(type: .system)
    /// 剪辑/变速面板打开时播放器走原片源时间，关掉后再按 Composition 重建
    private var isTimelinePanelOpen = false
    /// 底部工具条容器；视频选项多时分两行，避免示波器被压扁
    private let bottomBar = UIStackView()
    /// 工具条第一行
    private let bottomRow1 = UIStackView()
    /// 工具条第二行（视频：变速 + 示波器）
    private let bottomRow2 = UIStackView()
    /// 画幅底部面板
    private let geometryPanel = AlbumGeometryPanelView()
    /// 视频收尾底部面板
    private let trimPanel = AlbumTrimPanelView()
    /// 视频变速底部面板
    private let speedPanel = AlbumSpeedPanelView()
    /// 预览浮层示波器
    private let scopePanel = AlbumScopePanelView()
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
        scopePanel.dismiss()
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
        configureToolButton(playButton)
        playButton.addTarget(self, action: #selector(handlePlayTap), for: .touchUpInside)

        geometryButton.setTitle("画幅", for: .normal)
        configureToolButton(geometryButton)
        geometryButton.addTarget(self, action: #selector(handleGeometryTap), for: .touchUpInside)

        trimButton.setTitle("剪辑", for: .normal)
        configureToolButton(trimButton)
        trimButton.addTarget(self, action: #selector(handleTrimTap), for: .touchUpInside)

        speedButton.setTitle("变速", for: .normal)
        configureToolButton(speedButton)
        speedButton.addTarget(self, action: #selector(handleSpeedTap), for: .touchUpInside)

        scopeButton.setTitle("示波器", for: .normal)
        configureToolButton(scopeButton)
        scopeButton.addTarget(self, action: #selector(handleScopeTap), for: .touchUpInside)

        configureToolRow(bottomRow1)
        configureToolRow(bottomRow2)
        bottomRow1.addArrangedSubview(geometryButton)
        if asset.mediaType == .video {
            bottomRow1.addArrangedSubview(playButton)
            bottomRow1.addArrangedSubview(trimButton)
            bottomRow2.addArrangedSubview(speedButton)
            bottomRow2.addArrangedSubview(scopeButton)
        } else {
            bottomRow1.addArrangedSubview(scopeButton)
        }

        bottomBar.axis = .vertical
        bottomBar.alignment = .center
        bottomBar.spacing = 8
        bottomBar.addArrangedSubview(bottomRow1)
        if asset.mediaType == .video {
            bottomBar.addArrangedSubview(bottomRow2)
        }
        view.addSubview(bottomBar)

        geometryPanel.delegate = self
        geometryPanel.isHidden = true
        view.addSubview(geometryPanel)

        trimPanel.delegate = self
        trimPanel.isHidden = true
        view.addSubview(trimPanel)

        speedPanel.delegate = self
        speedPanel.isHidden = true
        view.addSubview(speedPanel)

        scopePanel.delegate = self
        view.addSubview(scopePanel)

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
        view.bringSubviewToFront(trimPanel)
        view.bringSubviewToFront(speedPanel)
        view.bringSubviewToFront(scopePanel)
    }

    /// 统一底部工具按钮：不允许被压缩到点不到
    /// - Parameter button: 画幅 / 播放 / 剪辑 / 变速 / 示波器
    private func configureToolButton(_ button: UIButton) {
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = UIColor(white: 0, alpha: 0.45)
        button.layer.cornerRadius = 16
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// 工具条一行：水平居中，间距固定
    /// - Parameter row: 第一行或第二行
    private func configureToolRow(_ row: UIStackView) {
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.distribution = .fill
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

    /// 预览铺满；底部工具条贴安全区；设置/画幅/剪辑/变速面板盖住全屏做蒙层
    private func initLayout() {
        previewView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        settingsButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            make.trailing.equalTo(view.safeAreaLayoutGuide).offset(-12)
        }
        exportButton.snp.makeConstraints { make in
            make.top.equalTo(settingsButton)
            make.trailing.equalTo(settingsButton.snp.leading).offset(-8)
        }
        bottomBar.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-16)
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
        }
        geometryPanel.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        trimPanel.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        speedPanel.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        scopePanel.pin(in: view)
        activityIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        exportProgressView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(32)
            make.bottom.equalTo(bottomBar.snp.top).offset(-16)
        }
        exportProgressLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(exportProgressView.snp.top).offset(-8)
        }
        settingsSheet.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
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
                self.configureVideoPlayer()
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

    /// 设置变更：照片从 source 重跑；视频刷新当前帧
    private func handlePipelineChanged() {
        if asset.mediaType == .image {
            reprocessPhotoPreview()
        } else {
            videoPlayer.refreshCurrentFrame()
        }
    }

    /// 经 session GPU 队列重跑照片预览
    private func reprocessPhotoPreview() {
        guard let source = photoSourceBuffer else { return }
        session.reprocessPhotoPreview(source: source) { [weak self] frame, snapshot in
            self?.previewView.inputFrame(frame)
            self?.scopePanel.apply(snapshot: snapshot)
        }
    }

    /// 按文档重建播放器：多段或非 1x 播 Composition，单段 1x 仍用原片 + 入出点
    private func configureVideoPlayer() {
        guard let videoAsset = videoAsset, !isTimelinePanelOpen else { return }
        let mapper = AlbumTimeMapper(timeline: session.document.timeline, sourceDuration: videoAsset.duration)
        if mapper.needsComposition, let composition = mapper.makeComposition(from: videoAsset) {
            videoPlayer.configure(
                with: composition,
                trimStart: .zero,
                trimEnd: mapper.playDuration
            )
            return
        }
        let segment = mapper.segments[0]
        videoPlayer.configure(
            with: videoAsset,
            trimStart: segment.sourceStart,
            trimEnd: segment.sourceEnd
        )
    }

    /// 剪辑/变速面板期间改绑原片整段，条带按源时间 scrub
    /// - Parameter asset: 相册原片
    private func configureVideoPlayerForTimelineEditing(asset: AVAsset) {
        videoPlayer.configure(
            with: asset,
            trimStart: .zero,
            trimEnd: asset.duration
        )
        videoPlayer.pause()
    }

    /// 进入导出独占：停播放器（释放 AVAsset，避免和 Reader 抢同一份资源）
    /// - Parameter work: 主线程；在 session 标记 isExporting 后执行
    private func enterExportMode(work: @escaping () -> Void) {
        geometryPanel.dismiss()
        isTimelinePanelOpen = false
        trimPanel.dismiss(notify: false)
        speedPanel.dismiss(notify: false)
        scopePanel.dismiss()
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
            if resumeVideo, self.asset.mediaType == .video, self.videoAsset != nil {
                self.configureVideoPlayer()
                self.videoPlayer.play()
                self.updatePlayButtonTitle()
            }
            completion?()
        }
    }

    /// 弹出设置
    @objc private func handleSettingsTap() {
        geometryPanel.dismiss()
        trimPanel.dismiss()
        speedPanel.dismiss()
        view.bringSubviewToFront(settingsSheet)
        settingsSheet.present()
        bringScopePanelToFrontIfNeeded()
    }

    /// 弹出画幅面板
    @objc private func handleGeometryTap() {
        guard !isExporting else { return }
        trimPanel.dismiss()
        speedPanel.dismiss()
        geometryPanel.geometry = session.document.geometry
        view.bringSubviewToFront(geometryPanel)
        geometryPanel.present()
        bringScopePanelToFrontIfNeeded()
    }

    /// 弹出剪辑面板；条带是源轴，先卸掉 Composition
    @objc private func handleTrimTap() {
        guard !isExporting, let videoAsset = videoAsset else { return }
        geometryPanel.dismiss()
        speedPanel.dismiss(notify: false)
        isTimelinePanelOpen = true
        configureVideoPlayerForTimelineEditing(asset: videoAsset)
        updatePlayButtonTitle()
        view.bringSubviewToFront(trimPanel)
        trimPanel.present(asset: videoAsset, timeline: session.document.timeline)
        bringScopePanelToFrontIfNeeded()
    }

    /// 弹出变速面板；条带是源轴 1x，先卸掉 Composition
    @objc private func handleSpeedTap() {
        guard !isExporting, let videoAsset = videoAsset else { return }
        geometryPanel.dismiss()
        trimPanel.dismiss(notify: false)
        isTimelinePanelOpen = true
        configureVideoPlayerForTimelineEditing(asset: videoAsset)
        updatePlayButtonTitle()
        view.bringSubviewToFront(speedPanel)
        speedPanel.present(asset: videoAsset, timeline: session.document.timeline)
        bringScopePanelToFrontIfNeeded()
    }

    /// 打开或关闭示波器浮层；不关闭画幅/剪辑
    @objc private func handleScopeTap() {
        guard !isExporting else { return }
        if scopePanel.isHidden {
            view.bringSubviewToFront(scopePanel)
            scopePanel.present()
        } else {
            scopePanel.dismiss()
        }
        updateScopeButtonAppearance()
    }

    /// 示波器开着时压在画幅/设置之上，才能对照画面读数
    private func bringScopePanelToFrontIfNeeded() {
        if !scopePanel.isHidden {
            view.bringSubviewToFront(scopePanel)
        }
    }

    /// 入口按钮高亮与浮层一致
    private func updateScopeButtonAppearance() {
        let on = !scopePanel.isHidden
        scopeButton.backgroundColor = on
            ? UIColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.85)
            : UIColor(white: 0, alpha: 0.45)
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
        scopeButton.isEnabled = false

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
        geometryButton.isEnabled = false
        trimButton.isEnabled = false
        speedButton.isEnabled = false
        scopeButton.isEnabled = false

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
            self.trimButton.isEnabled = true
            self.speedButton.isEnabled = true
            self.scopeButton.isEnabled = true
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
        session.processVideoPreviewFrame(pixelBuffer, preferredTransform: player.preferredTransform) { [weak self] frame, snapshot in
            self?.previewView.inputFrame(frame)
            self?.scopePanel.apply(snapshot: snapshot)
        }
    }
}

extension AlbumEditorViewController: AlbumGeometryPanelViewDelegate {
    /// 画幅文档变更：照片从 source 重跑；视频刷新当前帧
    func geometryPanel(_ panel: AlbumGeometryPanelView, didChange geometry: AlbumGeometryEdit) {
        session.document.geometry = geometry
        if asset.mediaType == .image {
            reprocessPhotoPreview()
        } else {
            videoPlayer.refreshCurrentFrame()
        }
    }
}

extension AlbumEditorViewController: AlbumTrimPanelViewDelegate {
    /// 面板打开时只写文档并按源时间 seek，不重建 Composition
    func trimPanel(
        _ panel: AlbumTrimPanelView,
        didChange timeline: AlbumTimelineEdit,
        previewTime: CMTime
    ) {
        session.document.timeline = timeline
        videoPlayer.pause()
        updatePlayButtonTitle()
        videoPlayer.scrub(to: previewTime)
    }

    /// 滚动条带只 seek
    func trimPanel(_ panel: AlbumTrimPanelView, didScrub previewTime: CMTime) {
        videoPlayer.pause()
        updatePlayButtonTitle()
        videoPlayer.scrub(to: previewTime)
    }

    /// 关掉面板后再按多段拼播放轴
    func trimPanelDidDismiss(_ panel: AlbumTrimPanelView) {
        isTimelinePanelOpen = false
        guard !isExporting, videoAsset != nil else { return }
        configureVideoPlayer()
        updatePlayButtonTitle()
    }
}

extension AlbumEditorViewController: AlbumSpeedPanelViewDelegate {
    /// 面板打开时只写文档并按源时间 seek，不重建 Composition
    func speedPanel(
        _ panel: AlbumSpeedPanelView,
        didChange timeline: AlbumTimelineEdit,
        previewTime: CMTime
    ) {
        session.document.timeline = timeline
        videoPlayer.pause()
        updatePlayButtonTitle()
        videoPlayer.scrub(to: previewTime)
    }

    /// 滚动条带只 seek
    func speedPanel(_ panel: AlbumSpeedPanelView, didScrub previewTime: CMTime) {
        videoPlayer.pause()
        updatePlayButtonTitle()
        videoPlayer.scrub(to: previewTime)
    }

    /// 整段页用 AVPlayer.rate 试听；关掉面板后走 Mapper
    func speedPanel(_ panel: AlbumSpeedPanelView, didChangePreviewRate rate: Float) {
        videoPlayer.setPreviewRate(rate)
    }

    /// 关掉面板后再按 needsComposition 拼播放轴
    func speedPanelDidDismiss(_ panel: AlbumSpeedPanelView) {
        isTimelinePanelOpen = false
        guard !isExporting, videoAsset != nil else { return }
        configureVideoPlayer()
        updatePlayButtonTitle()
    }
}

extension AlbumEditorViewController: AlbumScopePanelViewDelegate {
    /// 打开时开 GPU 旁路；静图立刻重跑一帧
    func scopePanel(_ panel: AlbumScopePanelView, didChangeEnabled enabled: Bool) {
        session.scopesEnabled = enabled
        updateScopeButtonAppearance()
        if enabled {
            if asset.mediaType == .image {
                reprocessPhotoPreview()
            } else {
                videoPlayer.refreshCurrentFrame()
            }
        }
    }

    /// Colorize 只影响波形累加；需要重跑当前预览帧
    func scopePanel(_ panel: AlbumScopePanelView, didChangeColorize colorize: Bool) {
        session.scopeColorize = colorize
        if asset.mediaType == .image {
            reprocessPhotoPreview()
        } else {
            videoPlayer.refreshCurrentFrame()
        }
    }
}
