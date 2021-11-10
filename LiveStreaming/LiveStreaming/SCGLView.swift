//
//  SCGLView.swift
//  LiveStreaming
//
//  Created by anker on 2021/11/9.
//

import UIKit
import GLKit

protocol SCGLViewProtocol: NSObjectProtocol {
    func inputPixelBuffer(_ pixelBuffer: CVPixelBuffer);
    func start()
    func stop()
    func clearColor()
}

class SCGLView: UIView {
    var context: EAGLContext?
    var displayLink: CADisplayLink?
    var isStarted: Bool = false
    
    var _backingWidth: GLint = 0
    var _backingHeight: GLint = 0
    
    var rgbaTexture: CVOpenGLESTexture?
    var videoTextureCache: CVOpenGLESTextureCache?
    
    var frameBufferHandle: GLuint = GLuint()
    var colorBufferHandle: GLuint = GLuint()
    var quadTextureCoord: [GLfloat] = [
        0.0, 1.0, //左上角
        1.0, 1.0, //右上角
        0.0, 0.0, //左下角
        1.0, 0.0, //右下角
    ]
    var quadVertexCoord: [GLfloat] = [
        -1.0, -1.0, //左下角
        1.0, -1.0, //右下角
        -1.0, 1.0, //左上角
        1.0, 1.0, //右上角
    ]
    
    var glLayer: CAEAGLLayer?
    var program: GLuint = GLuint()
    var frameBuffer: FrameBuffer = FrameBuffer(size: 3)
    
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
    
    override class var layerClass: AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    override func layoutSubviews() {
        guard glLayer == nil else {
            return
        }
        setupLayer()
        setupContext()
        _ = loadShaders()
        createFBO()
        initUniform()
        initTextureCache()
    }
    
    private func setupLayer() {
        glLayer = layer as? CAEAGLLayer
        glLayer?.isOpaque = true
//        glLayer?.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: false]
        glLayer?.shouldRasterize = false
    }
    
    private func setupContext() {
        context = EAGLContext(api: .openGLES3)
        EAGLContext.setCurrent(context)
    }
    
    private func deleteFBO() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        glDeleteRenderbuffers(1, &colorBufferHandle)
        colorBufferHandle = 0
    
        glDeleteFramebuffers(1, &frameBufferHandle)
        frameBufferHandle = 0
    }
    
    private func createFBO() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        glGenRenderbuffers(1, &colorBufferHandle)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        context?.renderbufferStorage(Int(GL_RENDERBUFFER), from: glLayer)
    
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &_backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &_backingHeight)
        print("gl Get Render buffer:\(_backingWidth) * \(_backingHeight)")
    
        glGenFramebuffers(1, &frameBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorBufferHandle)
    
        if (glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) != GL_FRAMEBUFFER_COMPLETE) {
            print("Failed to make complete framebuffer object %x", glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)))
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), 0)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }
    
    private func initUniform() {
        glUseProgram(program)
        glUniform1i(glGetUniformLocation(program, "samplerRGBA"), 0)
        glUniform1f(glGetUniformLocation(program, "preferredRotation"), 0)
    }
    
    private func initTextureCache() {
        if videoTextureCache == nil {
            let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, context!, nil, &videoTextureCache)
            if (err != kCVReturnSuccess) {
                print("Error at CVOpenGLESTextureCacheCreate %d", err)
            }
        }
    }
    
    private func cleanUpPixelBuffer() {
        frameBuffer.removeAllFrames()
    }
    
    private func cleanUpTextures() {
        rgbaTexture = nil
        if videoTextureCache != nil {
            CVOpenGLESTextureCacheFlush(videoTextureCache!, 0)
        }
    }
    
    @objc private func render() {
        if EAGLContext.current() != context {
            EAGLContext.setCurrent(context)
        }
        
        guard let frame: VideoFrame = frameBuffer.popFrameWait(0) as? VideoFrame else {
            glClearColor(0.0, 1.0, 0.0, 1.0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
            context?.presentRenderbuffer(Int(GL_RENDERBUFFER))
            return
        }
        
        glDisable(GLenum(GL_DEPTH_TEST))
        glViewport(0, 0, _backingWidth, _backingHeight)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glClearColor(0.0, 1.0, 0.0, 1.0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
        
        createTexture(frame.pixelBuffer)

        glUseProgram(program)
//        glUniform1i(glGetUniformLocation(program, "samplerRGBA"), 0)
        glUniform1f(glGetUniformLocation(program, "preferredRotation"), GLKMathDegreesToRadians(0))

        let position = glGetAttribLocation(program, "position")
        glEnableVertexAttribArray(GLuint(position))
        glVertexAttribPointer(GLuint(position), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE),0, quadVertexCoord)

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
    
    private func BUFFER_OFFSET(_ i: Int) -> UnsafeRawPointer? {
        return UnsafeRawPointer(bitPattern: i)
    }
    
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
            print("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
        }
        glBindTexture(CVOpenGLESTextureGetTarget(rgbaTexture!), CVOpenGLESTextureGetName(rgbaTexture!))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    }
}

extension SCGLView: SCGLViewProtocol {
    func inputPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard isStarted else {
            return
        }
        let frame = VideoFrame()
        frame.pixelBuffer = pixelBuffer
        frameBuffer.inputFrame(frame)
    }
    
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
    
    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        displayLink?.isPaused = true
        cleanUpPixelBuffer()
        clearColor()
    }
    
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
            print("Failed to compile vertex shader")
            return false
        }
        if compileShader(with: &fragShader, type: GLenum(GL_FRAGMENT_SHADER), file: fragFile) == false {
            print("Failed to compile fragment shader")
            return false
        }

        // Attach vertex/fragment shader to program.
        glAttachShader(self.program, vertShader)
        glAttachShader(self.program, fragShader)

        if linkProgram() == false {
            print("Failed to link program: %d", program)
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
            print("Shader compile log:\n%s", log)
        }
        #endif
        
        var status: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
        if status == GL_FALSE {
            glDeleteShader(shader)
            print("glGetShaderiv: %d", status)
            return false
        }

        return true
    }

    private func linkProgram() -> Bool {
        //链接
        glLinkProgram(program)
        #if DEBUG
        var logLength: GLint = 0
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &logLength)
        if (logLength > 0) {
            var log = [GLchar]()
            glGetProgramInfoLog(program, logLength, &logLength, &log)
            print("Program link log:\n%s", log)
        }
        #endif
        //获取链接状态
        var linkStatus: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linkStatus)
        if linkStatus == 0 {
            print("link program failed: %d", linkStatus)
            return false
        }
        print("link program success")
        return true
    }
}

