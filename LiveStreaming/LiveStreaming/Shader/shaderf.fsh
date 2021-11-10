
precision highp float;
varying vec2 texCoordVarying;
uniform highp sampler2D samplerRGBA;

void main()
{
   gl_FragColor = texture2D(samplerRGBA, texCoordVarying).bgra;
}
