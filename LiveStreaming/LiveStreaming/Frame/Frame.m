//
//  Frame.m
//  StreamPlayer
//
//  Created by hanxu li on 2020/9/10.
//  Copyright © 2020 Imagine Vision. All rights reserved.
//

#import "Frame.h"

@implementation Frame

/// 释放 malloc 的 data
- (void)dealloc
{
    if (self.data != NULL) {
        free(self.data);
        self.data = NULL;
    }
}

/// 分配并 memcpy 一份 data
- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts
{
    self = [super init];
    if (self) {
        self.data = (uint *)malloc(sizeof(uint *) * length);
        memcpy(self.data, data, length);
        self.length = length;
        self.pts = pts;
    }
    return self;
}

/// NSCopying：当前实现直接返回 self，不深拷贝
- (nonnull id)copyWithZone:(nullable NSZone *)zone {
    return self;
}

@end


@implementation AudioFrame

/// 默认类型为音频
- (instancetype)init
{
    self = [super init];
    if (self) {
        self.type = FrameTypeAudio;
    }
    return self;
}

/// 带 data 初始化，并标成音频
- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts
{
    self = [super initWithData:data length:length pts:pts];
    if (self) {
        self.type = FrameTypeAudio;
    }
    return self;
}

@end


@implementation VideoFrame

/// 释放 data 与 pixelBuffer、清空 texture
- (void)dealloc
{
    if (self.data != NULL) {
        free(self.data);
        self.data = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = nil;
    }
    self.texture = nil;
}

/// 默认类型为视频
- (instancetype)init
{
    self = [super init];
    if (self) {
        self.type = FrameTypeVideo;
    }
    return self;
}

/// 带 data 初始化，并标成视频
- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts
{
    self = [super initWithData:data length:length pts:pts];
    if (self) {
        self.type = FrameTypeVideo;
    }
    return self;
}

/// 浅拷贝宽高、缓冲和纹理引用
- (id)weakCopy
{
    VideoFrame *frame = [[VideoFrame alloc] init];
    [frame setFrameHeight:self.frameHeight];
    [frame setFrameWidth:self.frameWidth];
    [frame setData:self.data];
    [frame setPixelBuffer:self.pixelBuffer];
    [frame setTexture:self.texture];
    [frame setDateType:self.dateType];
    [frame setRecType:self.recType];
    [frame setFullRange:self.fullRange];
    [frame setPts:self.pts];
    return frame;
}

/// 替换 pixelBuffer 时先 Release 旧的再 Retain 新的
- (void)setPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (_pixelBuffer != pixelBuffer) {
        if (_pixelBuffer) {
            CVPixelBufferRelease(_pixelBuffer);
            _pixelBuffer = nil;
        }
        if (pixelBuffer) {
            _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
        } else {
            _pixelBuffer = nil;
        }
    }
}

@end
