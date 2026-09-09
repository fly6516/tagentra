Pod::Spec.new do |s|
  s.name             = 'tagentra_pm3'
  s.version          = '0.1.0'
  s.summary          = 'Tagentra PM3 BLE/TCP bridge.'
  s.homepage         = 'https://github.com/fly6516/tagentra'
  s.license          = { :type => 'GPL-3.0-or-later' }
  s.author           = { 'Tagentra contributors' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
  s.frameworks = 'CoreBluetooth', 'Network'
end
