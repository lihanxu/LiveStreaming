//
//  Frame.h
//  StreamPlayer
//
//  Created by hanxu li on 2020/9/10.
//  Copyright © 2020 Imagine Vision. All rights reserved.
//
//  处理链路中的音视频帧。VideoFrame 同时可带 CVPixelBuffer 与 Metal 纹理。
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>

/// 帧媒体类型
typedef NS_ENUM(NSInteger, FrameType) {
    FrameTypeAudio,
    FrameTypeVideo,
};

/// 视频载荷类型
typedef NS_ENUM(NSInteger, FrameDataType) {
    FrameDataTypePixel,
    FrameDataTypeUint,
};

/// 色彩标准
typedef NS_ENUM(NSInteger, RecType) {
    RecType601 = 0,
    RecType709,
};

/// 音视频帧基类。
@interface Frame : NSObject

/// 音频或视频
@property (nonatomic, assign) FrameType type;
/// 原始字节（若使用）；dealloc 时 free
@property (nonatomic, assign) void *data;
/// data 长度
@property (nonatomic, assign) UInt32 length;
/// 显示时间戳
@property (nonatomic, assign) UInt64 pts;

/// 拷贝一段字节构造帧
/// @param data 源数据
/// @param length 字节数
/// @param pts 时间戳
- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts;

@end


/// 音频帧，额外带 ASBD。
@interface AudioFrame : Frame

/// 音频格式描述
@property (nonatomic, assign) AudioStreamBasicDescription asbd;

@end


/// 视频帧：宽高 + pixel buffer + 可选 Metal 纹理。
@interface VideoFrame : Frame

/// 像素宽
@property (nonatomic, assign) NSInteger frameWidth;
/// 像素高
@property (nonatomic, assign) NSInteger frameHeight;
/// 预览和编码读取的像素；setter 会 Retain/Release
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
/// 上游滤镜已生成的 Metal 纹理，下游可直接复用
@property (nonatomic, strong) id <MTLTexture> texture;
/// 载荷类型
@property (nonatomic, assign) FrameDataType dateType;
/// Rec.601 / Rec.709
@property (nonatomic, assign) RecType recType;
/// 是否 full range
@property (nonatomic, assign) BOOL fullRange;

/// 浅拷贝：共享 data / pixelBuffer / texture，不复制像素
- (id)weakCopy;

@end
