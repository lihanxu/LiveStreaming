//
//  OFFilterResources.swift
//  LiveStreaming
//
//  滤镜内核资源定位：优先 Pod resource bundle，退回模块 Bundle。
//

import Foundation

/// LUT / task / default.metallib 所在 Bundle。
public enum OFFilterResources {
    /// 资源 Bundle：开发源 Pod 为 `OFFilterKit.bundle`（含 PNG、task、metallib）
    public static var bundle: Bundle {
        let module = Bundle(for: OFAuxiliaryTools.self)
        if let url = module.url(forResource: "OFFilterKit", withExtension: "bundle"),
           let resourceBundle = Bundle(url: url) {
            return resourceBundle
        }
        return module
    }

    /// 查找资源 URL（先 resource bundle，再模块 bundle）
    /// - Parameters:
    ///   - name: 资源名（不含扩展名）
    ///   - ext: 扩展名，如 png / task
    /// - Returns: 文件 URL
    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        return Bundle(for: OFAuxiliaryTools.self).url(forResource: name, withExtension: ext)
    }
}
