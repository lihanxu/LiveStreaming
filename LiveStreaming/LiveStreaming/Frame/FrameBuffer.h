//
//  FrameBuffer.h
//  AwesomeCamera
//
//  Created by hxli on 2018/8/15.
//  Copyright © 2018年 ImagineVision. All rights reserved.
//
//  预览用环形帧缓冲：采集线程 input，渲染线程 pop。
//

#import <Foundation/Foundation.h>
#import "Frame.h"

/// 默认容量
#define DefaultBufferSize  (10)

/// 线程安全的帧队列，满时丢最旧帧。
@interface FrameBuffer : NSObject

/// 使用默认容量创建
+ (instancetype)newFrameBuffer;
/// 指定容量创建
/// @param size 最多缓存的帧数
+ (instancetype)frameBufferWithSize:(NSUInteger)size;

/// 入队一帧；已满则丢掉队头
/// @param frame 音视频帧
- (void)inputFrame:(Frame *)frame;
/// 取出队头；ms>0 时短等
/// @param ms 等待毫秒，0 表示不等待
- (Frame *)popFrameWait:(NSInteger)ms;
/// 清空队列
- (void)removeAllFrames;

@end
