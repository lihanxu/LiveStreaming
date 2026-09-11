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
import CoreMedia
import CocoaLumberjack
import OFFilterKit

/// 相册单资源或多段拼接编辑：OpenGL 预览 + 设置卡片 + 导出。
class AlbumEditorViewController: UIViewController {
    /// 工程内各段对应的相册资源，与 `session.project.clips` 对齐
    private var phAssets: [PHAsset]
    /// 各段已加载的 AVAsset；未加载完时对应下标可能尚未填入
    private var videoAssets: [AVAsset?] = []
    /// 多段连播时当前正在解码的下标
    private var playbackClipIndex = 0
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
    /// 主路播放器
    private let clipPlayerA = AlbumVideoPlayer()
    /// overlap 时的入段播放器
    private let clipPlayerB = AlbumVideoPlayer()
    /// 0 表示 A 为主路
    private var primaryPlayerIndex = 0
    /// 当前出段解码
    private var videoPlayer: AlbumVideoPlayer {
        return primaryPlayerIndex == 0 ? clipPlayerA : clipPlayerB
    }
    /// 当前入段解码
    private var incomingPlayer: AlbumVideoPlayer {
        return primaryPlayerIndex == 0 ? clipPlayerB : clipPlayerA
    }
    /// 副路已绑定的 clip；未预热为 nil
    private var incomingPreparedIndex: Int?
    /// 当前选中段已加载的 AVAsset；未加载完为 nil
    private var videoAsset: AVAsset? {
        let index = session.project.selectedIndex
        guard videoAssets.indices.contains(index) else { return nil }
        return videoAssets[index]
    }

    /// 入口资源（照片或第一段视频）
    private var asset: PHAsset {
        return phAssets[0]
    }

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
    /// 拼接入口；打开二级面板
    private let joinButton = UIButton(type: .system)
    /// 示波器入口；照片与视频都显示
    private let scopeButton = UIButton(type: .system)
    /// 剪辑/变速面板打开时播放器走原片源时间，关掉后再按 Composition 重建
    private var isTimelinePanelOpen = false
    /// 拼接面板打开时按选中段预览，关掉后再按工程连播
    private var isJoinPanelOpen = false
    /// 底部工具条容器；视频选项多时分两行，避免示波器被压扁
    private let bottomBar = UIStackView()
    /// 工具条第一行
    private let bottomRow1 = UIStackView()
    /// 工具条第二行（视频：变速 + 拼接 + 示波器）
    private let bottomRow2 = UIStackView()
    /// 画幅底部面板
    private let geometryPanel = AlbumGeometryPanelView()
    /// 视频收尾底部面板
    private let trimPanel = AlbumTrimPanelView()
    /// 视频变速底部面板
    private let speedPanel = AlbumSpeedPanelView()
    /// 拼接二级面板
    private let joinPanel = AlbumJoinPanelView()
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
        self.phAssets = [asset]
        super.init(nibName: nil, bundle: nil)
        session.project = AlbumProject(clips: [AlbumProjectClip(localIdentifier: asset.localIdentifier)])
        if asset.mediaType == .video {
            videoAssets = [nil]
        }
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
        clipPlayerA.delegate = self
        clipPlayerB.delegate = self
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
        if asset.mediaType == .video, videoAsset != nil, !isExporting, joinPanel.isHidden {
            videoPlayer.play()
            updatePlayButtonTitle()
        }
        if !joinPanel.isHidden {
            reloadJoinPanel()
        }
    }

    /// 离开页停预览与视频
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        previewView.stop()
        videoPlayer.pause()
        incomingPlayer.pause()
        scopePanel.dismiss()
    }

    /// 释放视频资源
    deinit {
        clipPlayerA.teardown()
        clipPlayerB.teardown()
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

        joinButton.setTitle("拼接", for: .normal)
        configureToolButton(joinButton)
        joinButton.addTarget(self, action: #selector(handleJoinTap), for: .touchUpInside)

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
            bottomRow2.addArrangedSubview(joinButton)
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

        joinPanel.delegate = self
        joinPanel.isHidden = true
        view.addSubview(joinPanel)

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
        view.bringSubviewToFront(joinPanel)
        view.bringSubviewToFront(scopePanel)
        updateEditorTitle()
    }

    /// 统一底部工具按钮：不允许被压缩到点不到
    /// - Parameter button: 画幅 / 播放 / 剪辑 / 变速 / 拼接 / 示波器
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
        joinPanel.snp.makeConstraints { make in
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
                self.videoAssets[0] = avAsset
                self.configureVideoPlayer()
                self.updateEditorTitle()
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

    /// 按文档重建播放器：拼接面板打开时只预览选中段并循环
    private func configureVideoPlayer() {
        teardownIncoming()
        let index: Int
        if isJoinPanelOpen || isTimelinePanelOpen {
            index = session.project.selectedIndex
        } else if session.project.isMultiClip {
            index = playbackClipIndex
        } else {
            index = session.project.selectedIndex
        }
        guard videoAssets.indices.contains(index), videoAssets[index] != nil else { return }
        if isTimelinePanelOpen {
            return
        }
        let loops = isJoinPanelOpen || !session.project.isMultiClip
        bindPlayer(videoPlayer, clipIndex: index, reportsFrames: true, loops: loops)
        videoPlayer.setVolume(1)
    }

    /// 把某一 clip 绑到指定播放器
    /// - Parameters:
    ///   - player: 主路或副路
    ///   - clipIndex: 工程下标
    ///   - reportsFrames: 副路关闭出帧
    ///   - loops: 是否在出点循环
    private func bindPlayer(
        _ player: AlbumVideoPlayer,
        clipIndex: Int,
        reportsFrames: Bool,
        loops: Bool
    ) {
        guard videoAssets.indices.contains(clipIndex), let clipAsset = videoAssets[clipIndex] else { return }
        let document = session.project.clips[clipIndex].document
        let mapper = AlbumTimeMapper(timeline: document.timeline, sourceDuration: clipAsset.duration)
        player.loopsAtTrimEnd = loops
        if mapper.needsComposition, let composition = mapper.makeComposition(from: clipAsset) {
            player.configure(
                with: composition,
                trimStart: .zero,
                trimEnd: mapper.playDuration
            )
        } else {
            let segment = mapper.segments[0]
            player.configure(
                with: clipAsset,
                trimStart: segment.sourceStart,
                trimEnd: segment.sourceEnd
            )
        }
        player.setReportsFrames(reportsFrames)
    }

    /// 卸掉入段，主路音量恢复
    private func teardownIncoming() {
        incomingPlayer.teardown()
        incomingPreparedIndex = nil
        videoPlayer.setVolume(1)
    }

    /// 全部 clip 已加载时才能算工程轴
    /// - Returns: Mapper；缺片为 nil
    private func projectMapperIfReady() -> AlbumProjectMapper? {
        let loaded = videoAssets.compactMap { $0 }
        guard loaded.count == session.project.clips.count, loaded.count >= 1 else {
            return nil
        }
        return AlbumProjectMapper(
            assets: loaded,
            documents: session.project.clips.map { $0.document },
            transitions: session.project.transitions
        )
    }

    /// 当前段尾部接缝重叠；拼接/剪辑面板打开时不预热
    /// - Returns: 重叠时长
    private func overlapAfterCurrentClip() -> CMTime {
        if isJoinPanelOpen || isTimelinePanelOpen {
            return .zero
        }
        return projectMapperIfReady()?.overlapDuration(atJunction: playbackClipIndex) ?? .zero
    }

    /// 主路还剩多少 clip 播放时间
    /// - Returns: 剩余
    private func remainingPlayTimeOnPrimary() -> CMTime {
        let index = playbackClipIndex
        guard session.project.clips.indices.contains(index),
              videoAssets.indices.contains(index),
              let asset = videoAssets[index] else {
            return .zero
        }
        let mapper = AlbumTimeMapper(
            timeline: session.project.clips[index].document.timeline,
            sourceDuration: asset.duration
        )
        let playTime: CMTime
        if mapper.needsComposition {
            playTime = videoPlayer.currentTime()
        } else if let start = mapper.segments.first?.sourceStart {
            playTime = CMTimeMaximum(CMTimeSubtract(videoPlayer.currentTime(), start), .zero)
        } else {
            playTime = videoPlayer.currentTime()
        }
        return CMTimeMaximum(CMTimeSubtract(mapper.playDuration, playTime), .zero)
    }

    /// 接缝前预热下一段，停在入点
    private func prepareIncomingIfNeeded() {
        let next = playbackClipIndex + 1
        guard next < session.project.clips.count else { return }
        if incomingPreparedIndex == next {
            return
        }
        bindPlayer(incomingPlayer, clipIndex: next, reportsFrames: false, loops: false)
        incomingPlayer.setVolume(0)
        incomingPlayer.pause()
        incomingPreparedIndex = next
    }

    /// 工程画布：clip0 几何输出再缩到预览长边。单段传 0 跳过 cover。
    /// - Returns: 画布宽高
    private func previewCanvasSize() -> (Int, Int) {
        guard session.project.isMultiClip,
              self.videoAssets.indices.contains(0),
              let first = videoAssets[0],
              let track = first.tracks(withMediaType: .video).first,
              let geometry = session.project.clips.first?.document.geometry else {
            return (0, 0)
        }
        let geo = AlbumGeometryKernel.outputPixelSize(
            sourceWidth: Int(track.naturalSize.width.rounded()),
            sourceHeight: Int(track.naturalSize.height.rounded()),
            geometry: geometry,
            preferredTransform: track.preferredTransform
        )
        let scaled = AlbumMediaConverter.scaledSize(
            originalWidth: geo.0,
            originalHeight: geo.1,
            maxLongEdge: AlbumMediaConverter.previewMaxLongEdge
        )
        return AlbumMediaConverter.evenSize(width: scaled.0, height: scaled.1)
    }

    /// 导航标题：多段时标明拼接
    private func updateEditorTitle() {
        if asset.mediaType != .video {
            title = "照片编辑"
            return
        }
        title = session.project.isMultiClip ? "多段拼接" : "视频编辑"
    }

    /// 把当前工程灌进拼接面板
    private func reloadJoinPanel() {
        session.project.syncTransitions()
        joinPanel.reload(
            assets: videoAssets,
            selectedIndex: session.project.selectedIndex,
            transitions: session.project.transitions
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
        isJoinPanelOpen = false
        trimPanel.dismiss(notify: false)
        speedPanel.dismiss(notify: false)
        joinPanel.dismiss(notify: false)
        scopePanel.dismiss()
        teardownIncoming()
        videoPlayer.teardown()
        primaryPlayerIndex = 0
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
        isJoinPanelOpen = false
        joinPanel.dismiss()
        view.bringSubviewToFront(settingsSheet)
        settingsSheet.present()
        bringScopePanelToFrontIfNeeded()
    }

    /// 弹出画幅面板
    @objc private func handleGeometryTap() {
        guard !isExporting else { return }
        trimPanel.dismiss()
        speedPanel.dismiss()
        isJoinPanelOpen = false
        joinPanel.dismiss()
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
        joinPanel.dismiss(notify: false)
        isJoinPanelOpen = false
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
        joinPanel.dismiss(notify: false)
        isJoinPanelOpen = false
        isTimelinePanelOpen = true
        configureVideoPlayerForTimelineEditing(asset: videoAsset)
        updatePlayButtonTitle()
        view.bringSubviewToFront(speedPanel)
        speedPanel.present(asset: videoAsset, timeline: session.document.timeline)
        bringScopePanelToFrontIfNeeded()
    }

    /// 弹出拼接二级面板
    @objc private func handleJoinTap() {
        guard !isExporting, asset.mediaType == .video else { return }
        settingsSheet.dismiss()
        geometryPanel.dismiss()
        trimPanel.dismiss(notify: false)
        speedPanel.dismiss(notify: false)
        isTimelinePanelOpen = false
        isJoinPanelOpen = true
        session.project.syncTransitions()
        playbackClipIndex = session.project.selectedIndex
        configureVideoPlayer()
        videoPlayer.pause()
        updatePlayButtonTitle()
        view.bringSubviewToFront(joinPanel)
        joinPanel.present(
            assets: videoAssets,
            selectedIndex: session.project.selectedIndex,
            transitions: session.project.transitions
        )
        bringScopePanelToFrontIfNeeded()
    }

    /// 从相册挑一段视频接到工程尾部
    private func beginPickClip() {
        guard !isExporting, asset.mediaType == .video else { return }
        guard session.project.clips.count < AlbumProject.maximumClipCount else { return }
        let picker = AlbumViewController(videoOnly: true) { [weak self] picked in
            self?.appendVideoClip(picked)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    /// 加载并追加第二段及以后
    /// - Parameter picked: 用户选中的视频
    private func appendVideoClip(_ picked: PHAsset) {
        guard picked.mediaType == .video else { return }
        guard session.project.appendingClip(localIdentifier: picked.localIdentifier) else { return }
        phAssets.append(picked)
        videoAssets.append(nil)
        playbackClipIndex = session.project.selectedIndex
        updateEditorTitle()
        reloadJoinPanel()
        activityIndicator.startAnimating()
        exportButton.isEnabled = false
        let slot = videoAssets.count - 1
        AlbumMediaConverter.loadVideoAsset(asset: picked) { [weak self] avAsset in
            guard let self = self else { return }
            self.activityIndicator.stopAnimating()
            self.exportButton.isEnabled = true
            guard let avAsset = avAsset, self.videoAssets.indices.contains(slot) else {
                _ = self.session.project.removingSelectedClip()
                if self.phAssets.indices.contains(slot) {
                    self.phAssets.remove(at: slot)
                }
                if self.videoAssets.indices.contains(slot) {
                    self.videoAssets.remove(at: slot)
                }
                self.playbackClipIndex = self.session.project.selectedIndex
                self.updateEditorTitle()
                self.reloadJoinPanel()
                self.showAlert(title: "加载失败", message: "无法读取视频资源")
                return
            }
            self.videoAssets[slot] = avAsset
            if self.isJoinPanelOpen {
                self.configureVideoPlayer()
                self.videoPlayer.pause()
                self.videoPlayer.refreshCurrentFrame()
                self.reloadJoinPanel()
            } else {
                self.configureVideoPlayer()
                self.videoPlayer.refreshCurrentFrame()
            }
            self.updateEditorTitle()
        }
    }

    /// 删除当前选中段，至少留一段
    private func removeSelectedClip() {
        guard !isExporting, session.project.clips.count >= 2 else { return }
        let index = session.project.selectedIndex
        guard session.project.removingSelectedClip() else { return }
        if phAssets.indices.contains(index) {
            phAssets.remove(at: index)
        }
        if videoAssets.indices.contains(index) {
            videoAssets.remove(at: index)
        }
        playbackClipIndex = session.project.selectedIndex
        updateEditorTitle()
        configureVideoPlayer()
        videoPlayer.pause()
        videoPlayer.refreshCurrentFrame()
        reloadJoinPanel()
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
        if videoPlayer.isPlaying() {
            videoPlayer.pause()
            incomingPlayer.pause()
        } else {
            videoPlayer.play()
            let overlap = overlapAfterCurrentClip()
            if CMTimeCompare(overlap, .zero) > 0,
               CMTimeCompare(remainingPlayTimeOnPrimary(), overlap) <= 0,
               incomingPreparedIndex != nil {
                incomingPlayer.play()
            }
        }
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
        let loaded = videoAssets.compactMap { $0 }
        guard loaded.count == session.project.clips.count, loaded.count >= 1 else {
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
        joinButton.isEnabled = false

        enterExportMode { [weak self] in
            guard let self = self else { return }
            DDLogInfo("album export video tapped clips=\(loaded.count)")
            self.session.exportVideo(
                assets: loaded,
                documents: self.session.project.clips.map { $0.document },
                transitions: self.session.project.transitions,
                progress: { [weak self] value in
                    self?.setExportUI(
                        visible: true,
                        progress: value,
                        text: String(format: "导出中 %d%%", Int(value * 100))
                    )
                },
                completion: { [weak self] result in
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
                }
            )
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
            self.joinButton.isEnabled = true
            self.updateEditorTitle()
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
        guard player === videoPlayer, !isExporting else { return }
        let clipIndex: Int
        if isJoinPanelOpen {
            clipIndex = session.project.selectedIndex
        } else if session.project.isMultiClip {
            clipIndex = playbackClipIndex
        } else {
            clipIndex = session.project.selectedIndex
        }
        let geometry: AlbumGeometryEdit
        if session.project.clips.indices.contains(clipIndex) {
            geometry = session.project.clips[clipIndex].document.geometry
        } else {
            geometry = session.document.geometry
        }
        var incomingBuffer: CVPixelBuffer?
        var incomingTransform = CGAffineTransform.identity
        var incomingGeometry = AlbumGeometryEdit()
        var kind = AlbumTransitionKind.cut
        var progress: Float = 0
        let overlap = overlapAfterCurrentClip()
        if CMTimeCompare(overlap, .zero) > 0 {
            let remaining = remainingPlayTimeOnPrimary()
            let warmup = CMTimeAdd(overlap, CMTime(seconds: 0.25, preferredTimescale: 600))
            if CMTimeCompare(remaining, warmup) <= 0 {
                prepareIncomingIfNeeded()
            }
            if CMTimeCompare(remaining, overlap) <= 0 {
                if videoPlayer.isPlaying(), !incomingPlayer.isPlaying(), incomingPreparedIndex != nil {
                    incomingPlayer.play()
                }
                let overlapSeconds = max(CMTimeGetSeconds(overlap), 0.001)
                progress = Float(min(1, max(0, 1 - CMTimeGetSeconds(remaining) / overlapSeconds)))
                incomingBuffer = incomingPlayer.copyDisplayedPixelBuffer()
                incomingTransform = incomingPlayer.preferredTransform
                if let incomingIndex = incomingPreparedIndex,
                   session.project.clips.indices.contains(incomingIndex) {
                    incomingGeometry = session.project.clips[incomingIndex].document.geometry
                }
                if session.project.transitions.indices.contains(playbackClipIndex) {
                    kind = session.project.transitions[playbackClipIndex].kind
                }
                videoPlayer.setVolume(1 - progress)
                incomingPlayer.setVolume(progress)
            } else {
                videoPlayer.setVolume(1)
            }
        }
        let canvas = previewCanvasSize()
        session.processVideoPreviewFrame(
            outgoing: pixelBuffer,
            outgoingTransform: player.preferredTransform,
            outgoingGeometry: geometry,
            incoming: incomingBuffer,
            incomingTransform: incomingTransform,
            incomingGeometry: incomingGeometry,
            transitionKind: kind,
            progress: progress,
            canvasWidth: canvas.0,
            canvasHeight: canvas.1
        ) { [weak self] frame, snapshot in
            self?.previewView.inputFrame(frame)
            self?.scopePanel.apply(snapshot: snapshot)
        }
    }

    /// 多段：当前 clip 播完接下一段；overlap 时副路已在入段上，直接升为主路
    func videoPlayerDidReachTrimEnd(_ player: AlbumVideoPlayer) {
        guard player === videoPlayer else { return }
        guard session.project.isMultiClip, !isExporting, !isJoinPanelOpen else { return }
        let next = playbackClipIndex + 1
        if next < session.project.clips.count {
            if incomingPreparedIndex == next {
                handoffToIncoming(nextIndex: next)
                return
            }
            playbackClipIndex = next
        } else {
            playbackClipIndex = 0
            teardownIncoming()
        }
        session.project.selectedIndex = playbackClipIndex
        updateEditorTitle()
        configureVideoPlayer()
        videoPlayer.play()
        updatePlayButtonTitle()
    }

    /// 把已预热的入段升为主路，避免淡入后再从 0 起播
    /// - Parameter nextIndex: 下一段下标
    private func handoffToIncoming(nextIndex: Int) {
        let incoming = incomingPlayer
        let outgoing = videoPlayer
        incoming.setReportsFrames(true)
        incoming.setVolume(1)
        incoming.loopsAtTrimEnd = false
        primaryPlayerIndex = 1 - primaryPlayerIndex
        outgoing.teardown()
        incomingPreparedIndex = nil
        playbackClipIndex = nextIndex
        session.project.selectedIndex = nextIndex
        updateEditorTitle()
        if !videoPlayer.isPlaying() {
            videoPlayer.play()
        }
        updatePlayButtonTitle()
    }
}

extension AlbumEditorViewController: AlbumJoinPanelViewDelegate {
    /// 去相册挑下一段
    func joinPanelDidRequestAddClip(_ panel: AlbumJoinPanelView) {
        beginPickClip()
    }

    /// 选中段：预览该 clip 的成片区间
    func joinPanel(_ panel: AlbumJoinPanelView, didSelectClip index: Int) {
        guard session.project.clips.indices.contains(index) else { return }
        session.project.selectedIndex = index
        playbackClipIndex = index
        configureVideoPlayer()
        videoPlayer.pause()
        videoPlayer.refreshCurrentFrame()
        updatePlayButtonTitle()
    }

    /// 删除当前段
    func joinPanelDidRequestDeleteSelected(_ panel: AlbumJoinPanelView) {
        removeSelectedClip()
    }

    /// 接缝写入工程草稿
    func joinPanel(
        _ panel: AlbumJoinPanelView,
        didChangeTransitionAt index: Int,
        transition: AlbumTransition
    ) {
        session.project.applyingTransition(transition, at: index)
    }

    /// 关掉拼接面板后按工程连播
    func joinPanelDidDismiss(_ panel: AlbumJoinPanelView) {
        isJoinPanelOpen = false
        guard !isExporting else { return }
        updateEditorTitle()
        configureVideoPlayer()
        updatePlayButtonTitle()
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
