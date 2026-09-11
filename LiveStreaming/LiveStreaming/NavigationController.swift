//
//  NavigationController.swift
//  LiveStreaming
//
//  根导航：关闭系统侧滑返回，避免预览/编辑页被边缘手势误退出。
//

import UIKit

/// 应用根 `UINavigationController`。返回只走导航栏/代码 `pop`，不走侧滑。
final class NavigationController: UINavigationController, UIGestureRecognizerDelegate {

    /// 关掉边缘返回手势，并把代理接到自身，防止系统在 push 后重新打开。
    override func viewDidLoad() {
        super.viewDidLoad()
        disableInteractivePop()
        interactivePopGestureRecognizer?.delegate = self
    }

    /// 再次确认手势保持关闭（系统在转场结束后可能改回 `isEnabled`）。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disableInteractivePop()
    }

    /// 关闭系统侧滑返回。
    private func disableInteractivePop() {
        interactivePopGestureRecognizer?.isEnabled = false
    }

    /// 侧滑返回始终不开始；其它手势不干预。
    /// - Parameter gestureRecognizer: 当前要开始的手势
    /// - Returns: 侧滑返回为 `false`，其余为 `true`
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === interactivePopGestureRecognizer {
            return false
        }
        return true
    }
}
