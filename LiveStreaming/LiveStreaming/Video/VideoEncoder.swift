//
//  VideoEncoder.swift
//  LiveStreaming
//
//  Created by hansen on 2022/10/9.
//

import UIKit
import VideoToolbox

class VideoEncoder: NSObject {
    
    deinit {
        guard let encoderSession = encoderSession else {
           return
        }

        VTCompressionSessionCompleteFrames(encoderSession, untilPresentationTimeStamp: CMTime.invalid)
        VTCompressionSessionInvalidate(encoderSession)
        self.encoderSession = nil
    }
    
    /// 编码器
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
    
    fileprivate func processEncoded(sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else { return }
        print("attachments: \(attachments)")
        
        var status: OSStatus
        let rawDic: CFDictionary = Unmanaged.fromOpaque(CFArrayGetValueAtIndex(attachments, 0)).takeUnretainedValue()
        let keyFrame: Bool = !CFDictionaryContainsKey(rawDic, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        if keyFrame {
            print("IDR frame")

            let formatDes = CMSampleBufferGetFormatDescription(sampleBuffer)
            var sps: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            var spsCount: Int = 0
            var nalHearderLenght: Int32 = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes!, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalHearderLenght)
            if status == noErr {
                print("sps: \(String(describing: sps)), spsSize: \(spsSize), spsCount:\(spsCount), NAL header lenght: \(nalHearderLenght)")
                
                var pps: UnsafePointer<UInt8>?
                var ppsSize: Int = 0
                var ppsCount: Int = 0
                
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes!, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: &nalHearderLenght)
                if status == noErr {
                    print("pps: \(String(describing: sps)), ppsSize: \(spsSize), ppsCount:\(spsCount), NAL header lenght: \(nalHearderLenght)")
                }
                let spsData: NSData = NSData(bytes: sps, length: spsSize)
                let ppsData: NSData = NSData(bytes: pps, length: ppsSize)
                handle(sps: spsData, pps: ppsData)
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
                // 前四个字符为NALUnit长度
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
    
    fileprivate var NALUHeader: [UInt8] = [0, 0, 0, 1]
    var fileHandler: FileHandle?

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
    
    private func encode(data: NSData, isKeyFrame: Bool) {
        guard let fh = fileHandler else {
            return
        }
        let headerData: NSData = NSData(bytes: NALUHeader, length: NALUHeader.count)
        fh.write(headerData as Data)
        fh.write(data as Data)
    }
}

func VideoEncoder_EncoderOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) -> Void {
    guard status == noErr else {
        print("error: \(status)")
        return
    }

    if infoFlags == .frameDropped {
        print("frame dropped")
        return
    }
    
    guard let sampleBuffer = sampleBuffer else {
        print("sampleBuffer = nil")
        return
    }
    
    if CMSampleBufferDataIsReady(sampleBuffer) == false {
        print("sampleBuffer data is not ready")
        return
    }
    
    let encoder: VideoEncoder = Unmanaged.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
    encoder.processEncoded(sampleBuffer: sampleBuffer)
}

