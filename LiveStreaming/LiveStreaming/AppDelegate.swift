//
//  AppDelegate.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/8.
//

import UIKit
import AVFoundation
import CocoaLumberjack

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        OFLogger.setup()
        
        do {
            // options: .allowBluetoothA2DP
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, options: [.allowBluetoothA2DP])
//            let hwSampleRate: Double = 44100.0;
//            try audioSession.setPreferredSampleRate(hwSampleRate)
//            let bufferDuration: TimeInterval = 1024.0 / hwSampleRate;
//            try audioSession.setPreferredIOBufferDuration(bufferDuration)
            
            try audioSession.setActive(true)
        } catch  {
            DDLogError("AVAudioSession setCategory failed!!! \(error)")
        }
        
        return true
    }


}

