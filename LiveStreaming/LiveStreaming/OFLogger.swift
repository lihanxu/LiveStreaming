//
//  OFLogger.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/12/6.
//
//  CocoaLumberjack 初始化：os_log + 按天滚动的文件日志。
//

import CocoaLumberjack

/// 应用启动时配置日志。
enum OFLogger {
    /// 注册 TTY（Xcode/终端）+ os_log + 按天滚动的文件 logger（保留 7 天）
    static func setup() {
        dynamicLogLevel = .debug

        // 1. stderr，Xcode 控制台和从终端起的进程都能看到
        if let ttyLogger = DDTTYLogger.sharedInstance {
            ttyLogger.logFormatter = OFLogFormatter()
            DDLog.add(ttyLogger)
        }

        // 2. 系统统一日志，Console.app 可查
        let osLogger = DDOSLogger.sharedInstance
        osLogger.logFormatter = OFLogFormatter()
        DDLog.add(osLogger)
        
        let fileLogger = DDFileLogger()
        fileLogger.rollingFrequency = 60 * 60 * 24
        fileLogger.logFileManager.maximumNumberOfLogFiles = 7
        fileLogger.logFormatter = OFLogFormatter()
        DDLog.add(fileLogger)
        
        DDLogInfo("CocoaLumberjack ready, log dir: \(fileLogger.logFileManager.logsDirectory)")
    }
}

/// 统一日志格式：时间 [级别] 文件:行号 内容
private final class OFLogFormatter: NSObject, DDLogFormatter {
    /// 仅输出时分秒毫秒；DateFormatter 非线程安全，格式化时加锁
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    /// 保护 dateFormatter
    private let lock = NSLock()
    
    /// 把 DDLogMessage 格式化成一行字符串
    /// - Parameter logMessage: Lumberjack 消息
    /// - Returns: 可写入 os_log / 文件的文本
    func format(message logMessage: DDLogMessage) -> String? {
        lock.lock()
        let time = dateFormatter.string(from: logMessage.timestamp)
        lock.unlock()
        
        let level: String
        switch logMessage.flag {
        case .error:
            level = "E"
        case .warning:
            level = "W"
        case .info:
            level = "I"
        case .debug:
            level = "D"
        default:
            level = "V"
        }
        let file = (logMessage.file as NSString).lastPathComponent
        return "\(time) [\(level)] \(file):\(logMessage.line) \(logMessage.message)"
    }
}
