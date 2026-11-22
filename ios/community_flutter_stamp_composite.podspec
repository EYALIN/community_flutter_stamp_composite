#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint community_flutter_stamp_composite.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'community_flutter_stamp_composite'
  s.version          = '1.2.0'
  s.summary          = 'Native JPEG composite for GPS stamp photos in Flutter.'
  s.description      = <<-DESC
Decodes a camera JPEG straight to the output size, applies EXIF orientation, rotation, mirror and a stamp overlay, writes JPEG with EXIF and GPS, and draws map snapshots.
                       DESC
  s.homepage         = 'https://github.com/EYALIN/community_flutter_stamp_composite'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Community Flutter Plugins' => 'community-flutter-plugins@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files = 'community_flutter_stamp_composite/Sources/community_flutter_stamp_composite/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'community_flutter_stamp_composite_privacy' => ['community_flutter_stamp_composite/Sources/community_flutter_stamp_composite/PrivacyInfo.xcprivacy']}
end
