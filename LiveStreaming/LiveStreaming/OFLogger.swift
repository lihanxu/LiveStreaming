//
//  OFLogger.swift
//  LiveStreaming
//
//  Created by anker on 2021/12/6.
//

import CocoaLumberjack

enum OFLogger {
    static func setup() {
        dynamicLogLevel = .debug
        
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

private final class OFLogFormatter: NSObject, DDLogFormatter {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private let lock = NSLock()
    
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
