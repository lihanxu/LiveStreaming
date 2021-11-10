//
//  FrameBuffer.h
//  AwesomeCamera
//
//  Created by hxli on 2018/8/15.
//  Copyright © 2018年 ImagineVision. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Frame.h"

#define DefaultBufferSize  (10)

@interface FrameBuffer : NSObject

+ (instancetype)newFrameBuffer;
+ (instancetype)frameBufferWithSize:(NSUInteger)size;

- (void)inputFrame:(Frame *)frame;
- (Frame *)popFrameWait:(NSInteger)ms;
- (void)removeAllFrames;

@end
