//
//  VideoEncoder.swift
//  LiveStreaming
//
//  Created by hansen on 2022/10/9.
//
//  VideoToolbox H.264 硬编，Annex-B 写入临时目录 temp.h264。尚未做推流封装。
//

import UIKit
import VideoToolbox
import CocoaLumberjack

/// 实时 H.264 编码器。
class VideoEncoder: NSObject {
    
    /// 结束会话并释放编码器
    deinit {
        guard let encoderSession = encoderSession else {
           return
        }

        VTCompressionSessionCompleteFrames(encoderSession, untilPresentationTimeStamp: CMTime.invalid)
        VTCompressionSessionInvalidate(encoderSession)
        self.encoderSession = nil
    }
    
    /// VideoToolbox 压缩会话
    private var encoderSession: VTCompressionSession?

    /// 初始化Encoder
    /// - parameter width: 编码视频的宽度
    /// - parameter height: 编码视频的高度
    /// - parameter bitRate: 码率，单位时间传送的数据位数（kbps），数值越高越清晰，编码压力越大
    /// - parameter frameRate: 帧率，每秒显示的帧数
    ///
    /// 初始化编码器，设置宽高，码率，帧率等信息
    init(width: Int, height: Int, bitRate: Float, frameRate: Float) {
        super.init()
        
        // 初始化文件写入路径
        let path = NSTemporaryDirectory() + "/temp.h264"
        try? FileManager.default.removeItem(atPath: path)
        if FileManager.default.createFile(atPath: path, contents: nil, attributes: nil) {
            fileHandler = FileHandle(forWritingAtPath: path)
        }
        
        // 初始化编码器
        VTCompressionSessionCreate(allocator: nil,
                                    width: Int32(width),
                                    height: Int32(height),
                                    codecType: kCMVideoCodecType_H264,
                                    encoderSpecification: nil,
                                    imageBufferAttributes: nil,
                                    compressedDataAllocator: nil,
                                    outputCallback: VideoEncoder_EncoderOutputCallback,
                                    refcon: Unmanaged.passUnretained(self).toOpaque(),
                                    compressionSessionOut: &encoderSession)
        guard let session = encoderSession else {
            fatalError("create compression session failed!!!")
        }
        
        // 配置文件和等级
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        // 实时流
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true as CFTypeRef)
        // 关键字间隔（GOP）
        let gop: Int = 10
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop as CFTypeRef)
        // 比特率和速率
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [width * height * 2 * 4, 1] as CFArray)
        // 准备开始编码
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    /// 输入数据流
    func input(sampleBuffer: CMSampleBuffer) {
        guard let session = encoderSession else { return }
        
        // 获取 pts、 duration、pixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetOutputDuration(sampleBuffer)
        let flags = CVPixelBufferLockFlags(rawValue: 0)
        
        // 加锁，编码
        CVPixelBufferLockBaseAddress(pixelBuffer, flags)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: duration, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, flags)
    }
    
    /// 把编码后的 sample 拆成 Annex-B：关键帧先写 SPS/PPS，再按 NALU 写文件
    /// - Parameter sampleBuffer: VideoToolbox 回调给出的压缩帧
    fileprivate func processEncoded(sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else { return }
        
        var status: OSStatus
        let rawDic: CFDictionary = Unmanaged.fromOpaque(CFArrayGetValueAtIndex(attachments, 0)).takeUnretainedValue()
        let keyFrame: Bool = !CFDictionaryContainsKey(rawDic, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        if keyFrame {
            // 关键帧：从 format description 取出 SPS / PPS
            let formatDes = CMSampleBufferGetFormatDescription(sampleBuffer)
            var sps: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            var spsCount: Int = 0
            var nalHearderLenght: Int32 = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes!, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalHearderLenght)
            if status == noErr {
                var pps: UnsafePointer<UInt8>?
                var ppsSize: Int = 0
                var ppsCount: Int = 0
                
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes!, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: &nalHearderLenght)
                if status == noErr {
                    let spsData: NSData = NSData(bytes: sps, length: spsSize)
                    let ppsData: NSData = NSData(bytes: pps, length: ppsSize)
                    handle(sps: spsData, pps: ppsData)
                }
            }
        }
        
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr {
            var bufferOffset: Int = 0
            let AVCCHeaderLength = 4
                    
            while bufferOffset < (totalLength - AVCCHeaderLength) {
                var NALUnitLength: UInt32 = 0
                // AVCC：前 4 字节是 NALU 长度（大端），换成 00 00 00 01 起始码
                memcpy(&NALUnitLength, dataPointer?.advanced(by: bufferOffset), AVCCHeaderLength)
                // 大端到主机端。iOS中是小端序
                NALUnitLength = CFSwapInt32BigToHost(NALUnitLength)
                let data: NSData = NSData(bytes: dataPointer?.advanced(by: bufferOffset + AVCCHeaderLength), length: Int(NALUnitLength))
                encode(data: data, isKeyFrame: keyFrame)
                
                // 前进到下一个NAL单元
                bufferOffset += Int(AVCCHeaderLength)
                bufferOffset += Int(NALUnitLength)
            }
        }
    }
    
    /// Annex-B 起始码 00 00 00 01
    fileprivate var NALUHeader: [UInt8] = [0, 0, 0, 1]
    /// 写入 NSTemporaryDirectory()/temp.h264
    var fileHandler: FileHandle?

    /// 关键帧前写入 SPS、PPS（各带起始码）
    private func handle(sps: NSData, pps: NSData) {
        guard let fh = fileHandler else {
            return
        }
        
        let headerData: NSData = NSData(bytes: NALUHeader, length: NALUHeader.count)
        fh.write(headerData as Data)
        fh.write(sps as Data)
        fh.write(headerData as Data)
        fh.write(pps as Data)
    }
    
    /// 把一个 NALU 写成起始码 + 载荷
    /// - Parameters:
    ///   - data: NALU 内容（不含长度头）
    ///   - isKeyFrame: 是否关键帧（当前仅透传，未单独处理）
    private func encode(data: NSData, isKeyFrame: Bool) {
        guard let fh = fileHandler else {
            return
        }
        let headerData: NSData = NSData(bytes: NALUHeader, length: NALUHeader.count)
        fh.write(headerData as Data)
        fh.write(data as Data)
    }
}

/// VideoToolbox 编码完成回调：校验状态后转回 VideoEncoder.processEncoded
func VideoEncoder_EncoderOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) -> Void {
    guard status == noErr else {
        DDLogError("video encode error: \(status)")
        return
    }

    if infoFlags == .frameDropped {
        DDLogWarn("video encode frame dropped")
        return
    }
    
    guard let sampleBuffer = sampleBuffer else {
        DDLogError("video encode sampleBuffer is nil")
        return
    }
    
    if CMSampleBufferDataIsReady(sampleBuffer) == false {
        DDLogError("video encode sampleBuffer data is not ready")
        return
    }
    
    let encoder: VideoEncoder = Unmanaged.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
    encoder.processEncoded(sampleBuffer: sampleBuffer)
}

