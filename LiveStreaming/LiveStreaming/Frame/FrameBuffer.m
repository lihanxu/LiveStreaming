//
//  FrameBuffer.m
//  AwesomeCamera
//
//  Created by hxli on 2018/8/15.
//  Copyright © 2018年 ImagineVision. All rights reserved.
//

#import "FrameBuffer.h"

@interface FrameBuffer ()

@property (nonatomic, strong) NSMutableArray *buffer;
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, assign) NSUInteger bufferSize;

@end

@implementation FrameBuffer

+ (instancetype)newFrameBuffer
{
    FrameBuffer *frameBuffer = [[FrameBuffer alloc] init];
    return frameBuffer;
}

+ (instancetype)frameBufferWithSize:(NSUInteger)size
{
    FrameBuffer *frameBuffer = [[FrameBuffer alloc] init];
    [frameBuffer setBufferSize:size];
    return frameBuffer;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.bufferSize = DefaultBufferSize;
        self.condition =[[NSCondition alloc] init];
    }
    return self;
}

- (NSMutableArray *)buffer
{
    if (_buffer == nil) {
        _buffer = [[NSMutableArray alloc] init];
    }
    return _buffer;
}

- (void)setBufferSize:(NSUInteger)size
{
    _bufferSize = size;
}

- (void)inputFrame:(Frame *)frame
{
    if (frame == nil) {
        return;
    }
    [self.condition lock];
    if (self.buffer.count >= self.bufferSize) {
        [self.buffer removeObjectAtIndex:0];
    }
    [self.buffer addObject:frame];
    [self.condition signal];
    [self.condition unlock];
}

- (Frame *)popFrameWait:(NSInteger)ms
{
    [self.condition lock];
    if (ms != 0) {
        while (self.buffer.count == 0) {
//            NSLog(@"waitUntilDate");
            [self.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:ms * 1.0 / 1000.0]];
            break;
        }
    }
    Frame *frame = nil;
    if (self.buffer.count > 0) {
        frame = [self.buffer objectAtIndex:0];
        [self.buffer removeObjectAtIndex:0];
    }
    [self.condition unlock];
    return frame;
}

- (void)removeAllFrames
{
    [self.condition lock];
    if (self.buffer.count > 0) {
        [self.buffer removeAllObjects];
    }
    [self.condition unlock];
}

@end
