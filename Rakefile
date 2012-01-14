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

require File.expand_path(
    File.join(File.dirname(__FILE__), %w[lib nalloc.rb]))

require Nalloc.libpath('nalloc/driver')
require Nalloc.libpath('nalloc/driver/fusion')
require Nalloc.libpath('nalloc/resource_pool')
require Nalloc.libpath('nalloc/fusion_support/networking_manipulator')
require Nalloc.libpath('nalloc/fusion_support/subnet')

UTIL_PATH           = File.expand_path("util", File.dirname(__FILE__))
ADD_ADAPTER_PATH    = File.join(UTIL_PATH, "add-fusion-adapter")
REMOVE_ADAPTER_PATH = File.join(UTIL_PATH, "remove-fusion-adapter")
ADAPTER_PATH        = File.join(Nalloc::Driver::Fusion::CONFIG_PATH, "adapter")

task :default => 'test:run'
task 'gem:release' => 'test:run'

Cucumber::Rake::Task.new do |t|
  t.cucumber_opts = %w{--format pretty features}
end

task 'test:run' => 'cucumber'

namespace 'fusion' do
  desc "Installs prerequisites for nalloc's fusion driver"
  task 'setup' do
    begin
      puts
      if File.exist?(Nalloc::Driver::Fusion::CONFIG_PATH)
        abort "It looks like you've already set up the fusion adapter"
      end
      FileUtils.mkdir_p(Nalloc::Driver::Fusion::VM_STORE_PATH)

      puts "Adding dedicated network adapter for nalloc"
      net_manip = Nalloc::FusionSupport::NetworkingManipulator.new
      unless free_adapter = net_manip.get_free_adapter
        abort "ERROR: Couldn't find a free adapter"
      end
      # XXX - Fix subnet collision
      sh "sudo #{ADD_ADAPTER_PATH} #{free_adapter} 10.20.0.0 255.255.0.0"
      File.open(ADAPTER_PATH, 'w+') {|f| f.write("#{free_adapter}") }
      puts

      puts "Filling subnet pool"
      # Fusion reserves ips in the subnet 10.20.0.0 for its nat daemon
      subnets = 1.upto(255).map do |ii|
        Nalloc::FusionSupport::Subnet.new(free_adapter,
                                          "10.20.#{ii}.0",
                                          "255.255.255.0")
      end
      resource_pool =
        Nalloc::ResourcePool.new(Nalloc::Driver::Fusion::SUBNET_POOL_PATH)
      resource_pool.release(*subnets)
      puts "Done.\n\n"

      puts "Setup complete. You'll need to restart fusion before the network"\
           + " adapter will be usable."
    rescue => e
      puts
      puts "Cleaning up due to error: '#{e}'"
      if File.exist?(ADAPTER_PATH)
        puts "Removing adapter #{free_adapter}"
        sh "sudo #{REMOVE_ADAPTER_PATH} #{free_adapter}"
      end
      FileUtils.rm_rf(Nalloc::Driver::Fusion::CONFIG_PATH)
      raise e
    end
  end

  desc "The inverse of fusion:setup"
  task 'teardown' do
    puts

    unless File.exist?(Nalloc::Driver::Fusion::CONFIG_PATH)
      abort "It looks like you've already torn down fusion support"
    end

    # Check that no vms exist
    vms = Dir.glob(File.join(Nalloc::Driver::Fusion::VM_STORE_PATH, '*'))
    unless vms.empty?
      puts "It looks like you have one or more (in)active vms:"
      puts vms.join("\n")
      puts "Please destroy them first."
      abort
    end

    if File.exist?(ADAPTER_PATH)
      adapter = File.read(ADAPTER_PATH)
      puts "Removing dedicated nalloc adapter"
      sh "sudo #{REMOVE_ADAPTER_PATH} #{adapter}"
    end
    puts

    FileUtils.rm_rf(Nalloc::Driver::Fusion::CONFIG_PATH)

    puts "Teardown complete. You'll need to restart Fusion for the adapter to"\
         + " be fully removed."
  end
end
