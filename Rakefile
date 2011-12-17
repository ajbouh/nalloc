begin
  require 'cucumber'
  require 'cucumber/rake/task'
rescue LoadError
  abort '### Please install the "cucumber" gem ###'
end

begin
  require 'rspec'
rescue LoadError
  abort '### Please install the "rspec" gem ###'
end

task :default => 'test:run'
task 'gem:release' => 'test:run'

Cucumber::Rake::Task.new do |t|
  t.cucumber_opts = %w{--format pretty features}
end

task 'test:run' => 'cucumber'
