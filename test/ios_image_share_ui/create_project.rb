require 'xcodeproj'
require 'fileutils'

destination = File.expand_path(ARGV.fetch(0, 'build/image-share-ui/ShareQA.xcodeproj'))
FileUtils.mkdir_p(File.dirname(destination))
project = Xcodeproj::Project.new(destination)
app = project.new_target(:application, 'ShareSender', :ios, '15.0')
tests = project.new_target(:ui_test_bundle, 'ShareUITests', :ios, '15.0')
tests.add_dependency(app)

[app, tests].each do |target|
  source = project.main_group.new_file(File.join(__dir__, "#{target.name}.swift"))
  target.source_build_phase.add_file_reference(source)
  target.build_configurations.each do |config|
    config.build_settings.merge!(
      'PRODUCT_BUNDLE_IDENTIFIER' => "io.foxbiz.imageqa.#{target.name}",
      'SWIFT_VERSION' => '5.0',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGNING_ALLOWED' => 'NO',
      'TARGETED_DEVICE_FAMILY' => '1,2'
    )
  end
end

tests.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = 'ShareSender'
end
app.build_configurations.each do |config|
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
end
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project.path, 'ShareSender')
