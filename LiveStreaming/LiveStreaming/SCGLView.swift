//
//  SCGLView.swift
//  LiveStreaming
//
//  Created by Hansen on 2021/11/9.
//
//  OpenGL ES 预览：从 VideoFrame 的 CVPixelBuffer 建 GLES 纹理，CADisplayLink 刷新。
//  采集/滤镜走 Metal，预览仍走 GL，两套 GPU 通过 IOSurface 共享像素。
//

import UIKit
import GLKit
import CocoaLumberjack

/// OpenGL ES 预览协议：入帧、启停、清屏。
protocol SCGLViewProtocol: NSObjectProtocol {
    /// 采集/滤镜线程投递一帧到环形缓冲
    func inputFrame(_ frame: VideoFrame)
    /// 启动 CADisplayLink 渲染循环
    func start()
    /// 暂停渲染并清空缓冲
    func stop()
    /// 用黑色清一次屏幕
    func clearColor()
}

/// 用 GLES3 把 VideoFrame 画到 CAEAGLLayer。
class SCGLView: UIView {
    /// GLES 上下文
    var context: EAGLContext?
    /// 与屏幕刷新同步的渲染时钟
    var displayLink: CADisplayLink?
    /// 是否已 start
    var isStarted: Bool = false
    /// 相册静图：队列空时仍重画上一帧，避免 DisplayLink 把唯一一帧弹出后变黑
    var holdsLastFrame = false
    /// 按像素宽高比 letterbox，不把画面拉满全屏
    var isAspectFitEnabled = false
    /// holdsLastFrame 时缓存的上一帧
    private var lastPresentedFrame: VideoFrame?
    
    /// 渲染缓冲实际像素宽
    var _backingWidth: GLint = 0
    /// 渲染缓冲实际像素高
    var _backingHeight: GLint = 0
    
    /// 当前帧对应的 GLES 纹理包装
    var rgbaTexture: CVOpenGLESTexture?
    /// CVPixelBuffer ↔ GLES 纹理缓存
    var videoTextureCache: CVOpenGLESTextureCache?
    
    /// FBO
    var frameBufferHandle: GLuint = GLuint()
    /// 颜色渲染缓冲（layer 存储）
    var colorBufferHandle: GLuint = GLuint()
    /// 全屏四边形纹理坐标（左上/右上/左下/右下）
    var quadTextureCoord: [GLfloat] = [
        0.0, 1.0, //左上角
        1.0, 1.0, //右上角
        0.0, 0.0, //左下角
        1.0, 0.0, //右下角
    ]
    /// 全屏四边形顶点（NDC：左下/右下/左上/右上），与纹理坐标组成 triangle strip
    var quadVertexCoord: [GLfloat] = [
        -1.0, -1.0, //左下角
        1.0, -1.0, //右下角
        -1.0, 1.0, //左上角
        1.0, 1.0, //右上角
    ]
    
    /// 承载 GLES 绘制的 layer
    var glLayer: CAEAGLLayer?
    /// 链好的着色器程序
    var program: GLuint = GLuint()
    /// 采集与渲染之间的环形帧队列，容量 3
    var frameBuffer: FrameBuffer = FrameBuffer(size: 3)
    
    /// 释放纹理、FBO、program 和上下文
    deinit {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        cleanUpTextures()
        deleteFBO()
        glDeleteProgram(program)
        program = 0
        EAGLContext.setCurrent(nil)
        context = nil
    }
    
    /// 用 CAEAGLLayer 替代默认 CALayer
    override class var layerClass: AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    /// 首次布局完成 GLES；之后尺寸或 contentsScale 变了只重建 FBO
    override func layoutSubviews() {
        super.layoutSubviews()
        if glLayer == nil {
            setupLayer()
            setupContext()
            _ = loadShaders()
            initUniform()
            initTextureCache()
        }
        updateDrawableSizeIfNeeded()
    }
    
    /// 配置不透明、按屏幕 scale 的 EAGL layer，避免 1x FBO 被放大发糊
    private func setupLayer() {
        glLayer = layer as? CAEAGLLayer
        glLayer?.isOpaque = true
        glLayer?.contentsScale = UIScreen.main.scale
        glLayer?.shouldRasterize = false
    }

    /// 按当前 bounds × scale 重建 renderbuffer；未变化则跳过
    private func updateDrawableSizeIfNeeded() {
        let scale = UIScreen.main.scale
        glLayer?.contentsScale = scale
        let pixelWidth = GLint((bounds.width * scale).rounded())
        let pixelHeight = GLint((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        if frameBufferHandle != 0, pixelWidth == _backingWidth, pixelHeight == _backingHeight {
            return
        }
        deleteFBO()
        createFBO()
    }
    
    /// 创建并设为当前 OpenGL ES 3 上下文
    private func setupContext() {
        context = EAGLContext(api: .openGLES3)
        EAGLContext.setCurrent(context)
    }
    
    /// 删除颜色缓冲和 FBO
    private func deleteFBO() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        glDeleteRenderbuffers(1, &colorBufferHandle)
        colorBufferHandle = 0
    
        glDeleteFramebuffers(1, &frameBufferHandle)
        frameBufferHandle = 0
    }
    
    /// 创建与 layer 绑定的 renderbuffer + framebuffer
    private func createFBO() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        glGenRenderbuffers(1, &colorBufferHandle)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        context?.renderbufferStorage(Int(GL_RENDERBUFFER), from: glLayer)
    
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &_backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &_backingHeight)
        DDLogInfo("gl render buffer: \(_backingWidth) * \(_backingHeight)")
    
        glGenFramebuffers(1, &frameBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorBufferHandle)
    
        if (glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) != GL_FRAMEBUFFER_COMPLETE) {
            DDLogError("Failed to make complete framebuffer object \(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)))")
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }
    
    /// 绑定采样器到 TEXTURE0，旋转角先置 0
    private func initUniform() {
        glUseProgram(program)
        glUniform1i(glGetUniformLocation(program, "samplerRGBA"), 0)
        glUniform1f(glGetUniformLocation(program, "preferredRotation"), 0)
    }
    
    /// 创建 CVOpenGLESTextureCache，供 pixel buffer 转纹理
    private func initTextureCache() {
        if videoTextureCache == nil {
            let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context!, nil, &videoTextureCache)
            if (err != kCVReturnSuccess) {
                DDLogError("CVOpenGLESTextureCacheCreate failed: \(err)")
            }
        }
    }
    
    /// 清空环形帧队列
    private func cleanUpPixelBuffer() {
        frameBuffer.removeAllFrames()
    }
    
    /// 释放当前 GLES 纹理并 flush cache
    private func cleanUpTextures() {
        rgbaTexture = nil
        if videoTextureCache != nil {
            CVOpenGLESTextureCacheFlush(videoTextureCache!, 0)
        }
    }
    
    /// CADisplayLink 回调：有新帧则画；holdsLastFrame 时队列空仍画上一帧
    @objc private func render() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }

        let popped = frameBuffer.popFrameWait(0) as? VideoFrame
        if let popped = popped {
            lastPresentedFrame = popped
        }
        guard let frame = popped ?? (holdsLastFrame ? lastPresentedFrame : nil) else {
            glClearColor(0.0, 1.0, 0.0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
            context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
            return
        }
        guard frame.pixelBuffer != nil else {
            return
        }

        // 绑定 FBO，从 pixel buffer 建纹理；相册开启等比时先按黑边算顶点
        glDisable(GLenum(GL_DEPTH_TEST))
        glViewport(0, 0, _backingWidth, _backingHeight)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))

        updateQuadVertices(for: frame)
        createTexture(frame.pixelBuffer)

        glUseProgram(program)
        glUniform1f(glGetUniformLocation(program, "preferredRotation"), GLKMathDegreesToRadians(0))

        let position = glGetAttribLocation(program, "position")
        glEnableVertexAttribArray(GLuint(position))
        glVertexAttribPointer(GLuint(position), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, quadVertexCoord)

        let textCoor = glGetAttribLocation(program, "texCoord")
        glEnableVertexAttribArray(GLuint(textCoor))
        glVertexAttribPointer(GLuint(textCoor), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, quadTextureCoord)

        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)

        context?.presentRenderbuffer(Int(GL_RENDERBUFFER))

        glDisableVertexAttribArray(GLuint(position))
        glDisableVertexAttribArray(GLuint(textCoor))
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    /// 按预览层与帧的宽高比更新 NDC 四边形；关闭等比时铺满
    /// - Parameter frame: 当前要画的帧
    private func updateQuadVertices(for frame: VideoFrame) {
        guard isAspectFitEnabled, _backingWidth > 0, _backingHeight > 0,
              frame.frameWidth > 0, frame.frameHeight > 0 else {
            quadVertexCoord = [
                -1.0, -1.0,
                1.0, -1.0,
                -1.0, 1.0,
                1.0, 1.0,
            ]
            return
        }
        let viewAspect = CGFloat(_backingWidth) / CGFloat(_backingHeight)
        let frameAspect = CGFloat(frame.frameWidth) / CGFloat(frame.frameHeight)
        if frameAspect > viewAspect {
            let heightNDC = GLfloat(viewAspect / frameAspect)
            quadVertexCoord = [
                -1.0, -heightNDC,
                1.0, -heightNDC,
                -1.0, heightNDC,
                1.0, heightNDC,
            ]
        } else {
            let widthNDC = GLfloat(frameAspect / viewAspect)
            quadVertexCoord = [
                -widthNDC, -1.0,
                widthNDC, -1.0,
                -widthNDC, 1.0,
                widthNDC, 1.0,
            ]
        }
    }
    
    /// 用当前 pixel buffer 创建 GLES 纹理并设置线性采样 / clamp
    /// - Parameter pixelBuffer: 滤镜输出的 BGRA 缓冲
    private func createTexture(_ pixelBuffer: CVPixelBuffer) {
        cleanUpTextures()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        glActiveTexture(GLenum(GL_TEXTURE0))
        let err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, videoTextureCache!, pixelBuffer, nil,
                                                               GLenum(GL_TEXTURE_2D), GL_RGBA, GLsizei(width), GLsizei(height),
                                                               GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), 0,
                                                                    &rgbaTexture)
        if err != kCVReturnSuccess {
            DDLogError("CVOpenGLESTextureCacheCreateTextureFromImage failed: \(err)")
        }
        glBindTexture(CVOpenGLESTextureGetTarget(rgbaTexture!), CVOpenGLESTextureGetName(rgbaTexture!))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    }
}

extension SCGLView: SCGLViewProtocol {
    /// 未 start 时丢弃，避免队列堆积
    func inputFrame(_ frame: VideoFrame) {
        guard isStarted else {
            return
        }
        frameBuffer.inputFrame(frame)
    }
    
    /// 创建或恢复 DisplayLink，目标 30fps
    func start() {
        guard isStarted == false else {
            return
        }
        isStarted = true
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(render))
            displayLink?.add(to: RunLoop.current, forMode: .default)
            displayLink?.preferredFramesPerSecond = 30
        } else {
            displayLink?.isPaused = false
        }
    }
    
    /// 暂停 DisplayLink，清空队列并黑屏
    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        displayLink?.isPaused = true
        lastPresentedFrame = nil
        cleanUpPixelBuffer()
        clearColor()
    }
    
    /// 用黑色清 FBO 并 present
    func clearColor() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }
}

extension SCGLView  {
    /// 编译并链接 shaderv.vsh / shaderf.fsh
    /// - Returns: 链接成功为 true
    private func loadShaders() -> Bool {
        //读取顶点、片元着色程序
        guard let verFile = Bundle.main.path(forResource: "shaderv", ofType: "vsh") else {
            return false
        }
        guard let fragFile = Bundle.main.path(forResource: "shaderf", ofType: "fsh") else {
            return false
        }

        var vertShader: GLuint = 0
        var fragShader: GLuint = 0

        // Create the shader program.
        program = glCreateProgram()

        if compileShader(with: &vertShader, type: GLenum(GL_VERTEX_SHADER), file: verFile) == false {
            DDLogError("Failed to compile vertex shader")
            return false
        }
        if compileShader(with: &fragShader, type: GLenum(GL_FRAGMENT_SHADER), file: fragFile) == false {
            DDLogError("Failed to compile fragment shader")
            return false
        }

        // Attach vertex/fragment shader to program.
        glAttachShader(self.program, vertShader)
        glAttachShader(self.program, fragShader)

        if linkProgram() == false {
            DDLogError("Failed to link program: \(program)")
            glDeleteShader(vertShader)
            glDeleteShader(fragShader)
            glDeleteProgram(program)
            program = 0
            return false
        }
        glDetachShader(program, vertShader)
        glDetachShader(program, fragShader)
        glDeleteShader(vertShader)
        glDeleteShader(fragShader)
        return true
    }

    /// 从文件编译单个 shader
    /// - Parameters:
    ///   - shader: 输出的 shader 对象
    ///   - type: 顶点或片元
    ///   - file: 着色器路径
    /// - Returns: 编译成功为 true
    private func compileShader(with shader: inout GLuint, type: GLenum, file: String) -> Bool {
        let content = try? String(contentsOfFile: file, encoding: String.Encoding.utf8)
        var source = (content! as NSString).utf8String
//        let contentCString = content?.cString(using: .utf8)
//        var source = UnsafePointer<GLchar>(contentCString)

        shader = glCreateShader(type)
        glShaderSource(shader, 1, &source, nil)
        glCompileShader(shader)
        
        #if DEBUG
        var logLength: GLint = 0
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &logLength)
        if logLength > 0 {
            var log = [GLchar]()
            glGetShaderInfoLog(shader, logLength, &logLength, &log)
            DDLogDebug("Shader compile log: \(String(cString: log))")
        }
        #endif
        
        var status: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
        if status == GL_FALSE {
            glDeleteShader(shader)
            DDLogError("glGetShaderiv compile status: \(status)")
            return false
        }

        return true
    }

    /// 链接 program，DEBUG 下打印 info log
    /// - Returns: 链接成功为 true
    private func linkProgram() -> Bool {
        //链接
        glLinkProgram(program)
        #if DEBUG
        var logLength: GLint = 0
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &logLength)
        if (logLength > 0) {
            var log = [GLchar]()
            glGetProgramInfoLog(program, logLength, &logLength, &log)
            DDLogDebug("Program link log: \(String(cString: log))")
        }
        #endif
        //获取链接状态
        var linkStatus: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linkStatus)
        if linkStatus == 0 {
            DDLogError("link program failed: \(linkStatus)")
            return false
        }
        DDLogInfo("link program success")
        return true
    }
}

