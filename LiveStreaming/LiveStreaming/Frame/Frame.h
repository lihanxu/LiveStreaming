//
//  Frame.h
//  StreamPlayer
//
//  Created by hanxu li on 2020/9/10.
//  Copyright © 2020 Imagine Vision. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(NSInteger, FrameType) {
    FrameTypeAudio,
    FrameTypeVideo,
};

typedef NS_ENUM(NSInteger, FrameDataType) {
    FrameDataTypePixel,
    FrameDataTypeUint,
};

typedef NS_ENUM(NSInteger, RecType) {
    RecType601 = 0,
    RecType709,
};


@interface Frame : NSObject

@property (nonatomic, assign) FrameType type;
@property (nonatomic, assign) void *data;
@property (nonatomic, assign) UInt32 length;
@property (nonatomic, assign) UInt64 pts;

- (instancetype)initWithData:(uint *)data length:(UInt32)length pts:(UInt64)pts;

@end


@interface AudioFrame : Frame

@property (nonatomic, assign) AudioStreamBasicDescription asbd;

@end


@interface VideoFrame : Frame

@property (nonatomic, assign) NSInteger frameWidth;
@property (nonatomic, assign) NSInteger frameHeight;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, strong) id <MTLTexture> texture;
@property (nonatomic, assign) FrameDataType dateType;
@property (nonatomic, assign) RecType recType;
@property (nonatomic, assign) BOOL fullRange;

- (id)weakCopy;

@end

