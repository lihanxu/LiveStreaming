//
//  Frame.m
//  StreamPlayer
//
//  Created by hanxu li on 2020/9/10.
//  Copyright © 2020 Imagine Vision. All rights reserved.
//

#import "Frame.h"

@implementation Frame

- (void)dealloc
{
    if (self.data != NULL) {
        free(self.data);
        self.data = NULL;
    }
}

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

- (nonnull id)copyWithZone:(nullable NSZone *)zone {
    return self;
}

@end


@implementation AudioFrame

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.type = FrameTypeAudio;
    }
    return self;
}

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

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.type = FrameTypeVideo;
    }
    return self;
}

- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts
{
    self = [super initWithData:data length:length pts:pts];
    if (self) {
        self.type = FrameTypeVideo;
    }
    return self;
}

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
