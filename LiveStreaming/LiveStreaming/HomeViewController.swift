//
//  HomeViewController.swift
//  LiveStreaming
//
//  应用首页：两个入口分别进入实时流预览和系统相册。
//

import UIKit

/// 首页。只负责导航，不持有采集或相册资源。
class HomeViewController: UIViewController {

    /// 进入当前实时流预览页
    private let liveButton = UIButton(type: .system)
    /// 进入系统相册浏览页
    private let albumButton = UIButton(type: .system)
    /// 垂直排列两个入口
    private let stackView = UIStackView()

    /// 搭 UI 并设导航标题
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "首页"
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)
        initUI()
        initLayout()
    }

    /// 配置按钮文案和堆叠样式
    private func initUI() {
        configureEntryButton(liveButton, title: "实时流预览")
        liveButton.addTarget(self, action: #selector(handleLiveTap), for: .touchUpInside)

        configureEntryButton(albumButton, title: "相册")
        albumButton.addTarget(self, action: #selector(handleAlbumTap), for: .touchUpInside)

        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.alignment = .fill
        stackView.addArrangedSubview(liveButton)
        stackView.addArrangedSubview(albumButton)
        view.addSubview(stackView)
    }

    /// 入口按钮水平居中，宽度随屏宽留边
    private func initLayout() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            liveButton.heightAnchor.constraint(equalToConstant: 56),
            albumButton.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    /// 统一入口按钮外观
    /// - Parameters:
    ///   - button: 要配置的按钮
    ///   - title: 展示文案
    private func configureEntryButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        button.layer.cornerRadius = 14
    }

    /// 从 Storyboard 取出原预览页再 push，保证 SCGLView 的 IBOutlet 可用
    @objc private func handleLiveTap() {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let preview = storyboard.instantiateViewController(withIdentifier: "LivePreviewViewController")
        navigationController?.pushViewController(preview, animated: true)
    }

    /// 打开相册页；权限在相册页内申请
    @objc private func handleAlbumTap() {
        navigationController?.pushViewController(AlbumViewController(), animated: true)
    }
}
