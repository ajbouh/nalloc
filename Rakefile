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

require 'highline/import'
require 'json'

require File.expand_path(
    File.join(File.dirname(__FILE__), %w[lib nalloc.rb]))

require Nalloc.libpath('nalloc/driver')
require Nalloc.libpath('nalloc/driver/fusion')
require Nalloc.libpath('nalloc/fusion_support/networking_manipulator')

# Util scripts
UTIL_PATH            = Nalloc.path("util")
ADD_ADAPTERS_PATH    = File.join(UTIL_PATH, "add-fusion-adapters")
REMOVE_ADAPTERS_PATH = File.join(UTIL_PATH, "remove-fusion-adapters")

task :default => 'test:run'
task 'gem:release' => 'test:run'

Cucumber::Rake::Task.new do |t|
  t.cucumber_opts = %w{--format pretty features}
end

task 'test:run' => 'cucumber'

namespace 'fusion' do
  desc "Installs prerequisites for nalloc's fusion driver"
  task 'setup', :num_adapters  do |task, args|
    args.with_defaults(:num_adapters => 5)

    begin
      if File.exist?(Nalloc::Driver::Fusion::CONFIG_DIR)
        abort "It looks like you've already set up the fusion adapter"
      end
      FileUtils.mkdir_p(Nalloc::Driver::Fusion::VM_STORE_PATH)

      num_adapters= Integer(args[:num_adapters])
      unless (num_adapters > 0) && (num_adapters < 100)
        abort "ERROR: num_adapters must be in [1, 99]"
      end

      # XXX - Make this configurable and not collide with existing subnets
      puts "Allocating adapter pool of size #{num_adapters}"
      net_manip = Nalloc::FusionSupport::NetworkingManipulator.new
      free_adapters = net_manip.get_free_adapters()[0, num_adapters]
      unless free_adapters.length == num_adapters
        abort "ERROR: Couldn't find enough free adapters"
      end
      to_add = []
      adapters = {}
      free_adapters.each_with_index do |adapter_id, ii|
        to_add << [adapter_id, "10.20.#{30 + ii}.0", "255.255.255.0"]
        adapters[adapter_id] = {
          "adapter_id" => adapter_id,
          "subnet"     => to_add[-1][1],
          "netmask"    => to_add[-1][2],
        }
      end
      sh "sudo #{ADD_ADAPTERS_PATH} #{to_add.flatten.join(' ')}"
      Nalloc::Driver::Fusion.save_adapters(adapters)

      puts "Setup complete. You'll need to restart fusion before the network"\
           + " adapter will be usable."
    rescue => e
      puts
      puts "Cleaning up due to error: '#{e}'"
      puts e.backtrace.join("\n")
      puts

      if File.exist?(Nalloc::Driver::Fusion::CONFIG_DIR)
        Rake::Task['fusion:teardown'].invoke
      end
    end
  end

  desc "The inverse of fusion:setup"
  task 'teardown' do
    unless File.exist?(Nalloc::Driver::Fusion::CONFIG_DIR)
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

    if File.exist?(Nalloc::Driver::Fusion::ADAPTER_POOL_PATH)
      adapter_ids = Nalloc::Driver::Fusion.load_adapters().keys
      puts "Removing dedicated nalloc adapters"
      sh "sudo #{REMOVE_ADAPTERS_PATH} #{adapter_ids.join(' ')}"
    end
    puts

    FileUtils.rm_rf(Nalloc::Driver::Fusion::CONFIG_DIR)

    puts "Teardown complete. You'll need to restart Fusion for the adapter to"\
         + " be fully removed."
  end
end
