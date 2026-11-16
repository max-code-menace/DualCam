Pod::Spec.new do |s|
  s.name           = 'DualCamera'
  s.version        = '1.0.0'
  s.summary        = 'Front + back camera at the same time (AVCaptureMultiCamSession)'
  s.description    = 'Local Expo module for DualCam: live dual preview, capture, merge and save.'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'AVFoundation', 'Photos', 'UIKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end
