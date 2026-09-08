Pod::Spec.new do |s|
  s.name             = 'OFFilterKit'
  s.version          = '0.1.0'
  s.summary          = 'LiveStreaming 滤镜内核：处理图、Metal / MediaPipe / Core ML 节点。'
  s.homepage         = 'https://github.com/hansen/LiveStreaming'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Hansen' => 'hansen' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
  s.requires_arc     = true
  s.static_framework = true

  s.source_files = 'Sources/**/*.{swift,h,m,metal}'
  s.public_header_files = 'Sources/Frame/Frame.h'
  s.resource_bundles = {
    'OFFilterKit' => [
      'Resources/LUT/*.png',
      'Resources/Cartoon/*.mlmodel',
      'Resources/FaceLandmarker/*.task'
    ]
  }

  s.frameworks = 'Foundation', 'UIKit', 'Metal', 'CoreVideo', 'CoreMedia', 'CoreImage', 'CoreGraphics', 'Vision', 'CoreML', 'QuartzCore'

  s.dependency 'MediaPipeTasksVision'
  s.dependency 'CocoaLumberjack/Swift'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES'
  }

  # 静态 framework 不会打进 App，default.metallib 必须再拷进 resource bundle
  s.script_phases = [
    {
      :name => 'Copy Metal Library into OFFilterKit.bundle',
      :execution_position => :after_compile,
      :script => <<-SCRIPT
        set -e
        DEST="${TARGET_BUILD_DIR}/OFFilterKit.bundle"
        mkdir -p "$DEST"
        for CANDIDATE in \\
          "${TARGET_BUILD_DIR}/${PRODUCT_NAME}.framework/default.metallib" \\
          "${TARGET_BUILD_DIR}/default.metallib"
        do
          if [ -f "$CANDIDATE" ]; then
            cp -f "$CANDIDATE" "$DEST/default.metallib"
            echo "OFFilterKit: copied Metal library from $CANDIDATE"
            exit 0
          fi
        done
        echo "error: OFFilterKit default.metallib not found" >&2
        exit 1
      SCRIPT
    }
  ]
end
