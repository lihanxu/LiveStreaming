//
//  FrameBuffer.m
//  AwesomeCamera
//
//  Created by hxli on 2018/8/15.
//  Copyright © 2018年 ImagineVision. All rights reserved.
//

#import "FrameBuffer.h"

@interface FrameBuffer ()

/// 实际存储
@property (nonatomic, strong) NSMutableArray *buffer;
/// 保护 buffer 的条件锁
@property (nonatomic, strong) NSCondition *condition;
/// 容量上限
@property (nonatomic, assign) NSUInteger bufferSize;

@end

@implementation FrameBuffer

/// 默认容量实例
+ (instancetype)newFrameBuffer
{
    FrameBuffer *frameBuffer = [[FrameBuffer alloc] init];
    return frameBuffer;
}

/// 指定容量实例
+ (instancetype)frameBufferWithSize:(NSUInteger)size
{
    FrameBuffer *frameBuffer = [[FrameBuffer alloc] init];
    [frameBuffer setBufferSize:size];
    return frameBuffer;
}

/// 默认容量 + 条件锁
- (instancetype)init
{
    self = [super init];
    if (self) {
        self.bufferSize = DefaultBufferSize;
        self.condition =[[NSCondition alloc] init];
    }
    return self;
}

/// 懒加载可变数组
- (NSMutableArray *)buffer
{
    if (_buffer == nil) {
        _buffer = [[NSMutableArray alloc] init];
    }
    return _buffer;
}

/// 更新容量上限
- (void)setBufferSize:(NSUInteger)size
{
    _bufferSize = size;
}

/// 入队；满则丢最旧，然后 signal 等待中的 pop
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

/// 出队；ms!=0 时最多等一次超时
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

/// 加锁清空
- (void)removeAllFrames
{
    [self.condition lock];
    if (self.buffer.count > 0) {
        [self.buffer removeAllObjects];
    }
    [self.condition unlock];
}

@end
