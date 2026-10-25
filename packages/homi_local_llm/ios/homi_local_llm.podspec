trial = ENV['HOMI_LLAMA_TRIAL'] == '1'
Pod::Spec.new do |s|
  s.name = 'homi_local_llm'
  s.version = '0.0.1'
  s.summary = 'Explicit local model import and pinned inference trial.'
  s.description = s.summary
  s.homepage = 'https://github.com/ggml-org/llama.cpp'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'Safe at Home' => 'local@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm,cpp}'
  s.dependency 'Flutter'
  s.frameworks = ['UIKit', 'UniformTypeIdentifiers']
  s.platform = :ios, trial ? '16.4' : '15.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_CPLUSPLUSFLAGS' => "$(inherited) -DHOMI_LLAMA_TRIAL=#{trial ? 1 : 0}",
    'OTHER_LDFLAGS' => trial ? '$(inherited) -framework llama' : '$(inherited)'
  }
  if trial
    raise 'Run tool/prepare_homi_local_llm.py --runtime first.' unless File.directory?(File.join(__dir__, '.generated/ios/llama.xcframework'))
    s.vendored_frameworks = '.generated/ios/llama.xcframework'
  end
end
