# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "nalloc"
  s.version     = File.read("version.txt")
  s.authors     = ["The Nalloc Authors"]
  s.email       = ["nalloc@tsumobi.com"]
  s.homepage    = ""
  s.summary     = %q{A primitive tool for allocating nodes and using them.}

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency 'rake'
  s.add_development_dependency 'cucumber'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'simplecov'

  s.add_runtime_dependency 'trace'
  s.add_runtime_dependency 'json'
  s.add_runtime_dependency 'fog'
end


