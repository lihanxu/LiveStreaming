//
//  AppDelegate.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/11/8.
//
//  启动时配置 CocoaLumberjack 与 AVAudioSession（播放+录音，允许蓝牙 A2DP）。
//

import UIKit
import AVFoundation
import CocoaLumberjack

@main
/// 应用入口。
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// 主窗口（Storyboard 创建）
    var window: UIWindow?


    /// 启动：先装日志，再激活音频会话
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        OFLogger.setup()
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 听筒默认会让 playAndRecord 走窄带；开扬声器，蓝牙仍可用 A2DP
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setActive(true)
        } catch {
            DDLogError("AVAudioSession setCategory failed!!! \(error)")
        }
        
        return true
    }


}
