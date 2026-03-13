Pod::Spec.new do |s|
  s.name             = 'retro_cam_plugin'
  s.version          = '0.1.0'
  s.summary          = 'DAZZ Retro Camera native plugin for iOS'
  s.description      = <<-DESC
    iOS native plugin providing AVFoundation camera capture and Metal-based
    real-time retro/CCD filter rendering for the DAZZ Retro Camera app.
  DESC
  s.homepage         = 'https://github.com/your-org/dazz-retro-camera'
  s.license          = { :type => 'MIT', :file => '../../LICENSE' }
  s.author           = { 'DAZZ Team' => 'dev@dazz.app' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
