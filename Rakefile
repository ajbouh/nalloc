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
require Nalloc.libpath('nalloc/fusion_support/adapter_pool')
require Nalloc.libpath('nalloc/fusion_support/networking_manipulator')

# Util scripts
UTIL_PATH            = Nalloc.path("util")
ADD_ADAPTERS_PATH    = File.join(UTIL_PATH, "add-fusion-adapters")
REMOVE_ADAPTERS_PATH = File.join(UTIL_PATH, "remove-fusion-adapters")
ADAPTERS_PATH        = File.join(Nalloc::Driver::Fusion::CONFIG_DIR, "adapters.json")

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
      if File.exist?(Nalloc::Driver::Fusion::CONFIG_DIR)
        abort "It looks like you've already set up the fusion adapter"
      end
      FileUtils.mkdir_p(Nalloc::Driver::Fusion::VM_STORE_PATH)

      # XXX - Make this configurable and not collide with existing subnets
      puts "Allocating adapter pool"
      net_manip = Nalloc::FusionSupport::NetworkingManipulator.new
      free_adapters = net_manip.get_free_adapters()[0, 5]
      unless free_adapters.length == 5
        abort "ERROR: Couldn't find enough free adapters"
      end
      to_add = []
      pool_path = Nalloc::Driver::Fusion::ADAPTER_POOL_PATH
      adapter_pool = Nalloc::FusionSupport::AdapterPool.new(pool_path)
      free_adapters.each_with_index do |adapter_id, ii|
        to_add << [adapter_id, "10.20.#{30 + ii}.0", "255.255.255.0"]
        adapter_pool.release("adapter_id" => adapter_id,
                             "subnet"     => to_add[-1][1],
                             "netmask"    => to_add[-1][2])
      end
      sh "sudo #{ADD_ADAPTERS_PATH} #{to_add.flatten.join(' ')}"
      # Write out the adapters we're using so we can remove them during teardown
      File.open(ADAPTERS_PATH, 'w+') do |f|
        f.write(free_adapters.to_json)
      end

      puts "Setting defaults"
      defaults = {}
      ["vmdk_path", "vmx_template_path"].each do |path_opt|
        ans = ask("Would you like to set a default for #{path_opt} (yes/no)?")
        if ans == "yes"
          name = path_opt.gsub("_path", '')
          loop do
            path = ask("Please enter the path for the #{name}: ")
            real_path = File.expand_path(path)
            if File.exist?(real_path)
              defaults[path_opt] = real_path
              break
            else
              puts "Sorry, #{real_path} doesn't appear to exist..."
            end
          end
        end
      end
      Nalloc::Driver::Fusion.write_defaults(defaults)

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

    if File.exist?(ADAPTERS_PATH)
      adapters = JSON.parse(File.read(ADAPTERS_PATH))
      puts "Removing dedicated nalloc adapters"
      sh "sudo #{REMOVE_ADAPTERS_PATH} #{adapters.join(' ')}"
    end
    puts

    FileUtils.rm_rf(Nalloc::Driver::Fusion::CONFIG_DIR)

    puts "Teardown complete. You'll need to restart Fusion for the adapter to"\
         + " be fully removed."
  end
end
