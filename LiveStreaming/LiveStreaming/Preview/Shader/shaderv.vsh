// 预览顶点着色器：全屏四边形 + 可选旋转。
attribute vec4 position;          // NDC 顶点
attribute vec2 texCoord;          // 纹理坐标
uniform float preferredRotation;  // 绕 Z 旋转角（弧度）
varying vec2 texCoordVarying;     // 传给片元
void main()
{
    mat4 rotationMatrix = mat4(cos(preferredRotation), -sin(preferredRotation), 0.0, 0.0,
                               sin(preferredRotation),  cos(preferredRotation), 0.0, 0.0,
                               0.0, 0.0, 1.0, 0.0,
                               0.0, 0.0, 0.0, 1.0);
    gl_Position = position * rotationMatrix;
    texCoordVarying = texCoord;
}
