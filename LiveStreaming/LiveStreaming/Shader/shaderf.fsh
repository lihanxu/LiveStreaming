// 预览片元着色器：采样 RGBA 纹理后 swizzle 成 BGRA 输出。
precision highp float;
varying vec2 texCoordVarying;
uniform highp sampler2D samplerRGBA;

void main()
{
    gl_FragColor = texture2D(samplerRGBA, texCoordVarying).bgra;
}
