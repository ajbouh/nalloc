require 'fileutils'
require 'json'

module Nalloc
  module FusionSupport
  end
end

# Utility class for atomically managing the adapter pool shared between
# processes.
#
class Nalloc::FusionSupport::AdapterPool

  # @param  [String]  db_dir  Directory that houses the pool
  def initialize(db_dir)
    @db_path       = File.join(db_dir, "adapters.json")
    @lockfile_path = File.join(db_dir, "adapters.lockfile")

    # Create initial db
    if File.exist?(db_dir)
      unless File.exist?(@db_path) && File.exist?(@lockfile_path)
        raise "#{db_dir} exists, but it looks like it isn't an adapter pool"
      end
    else
      FileUtils.mkdir_p(db_dir)
      flock_db do
        save_adapters({})
      end
    end
  end

  # Atomically acquires an adapter from the pool
  #
  # @return  [Hash]  Keys are "adapter_id", "subnet", "netmask"
  # @return  [nil]
  def acquire
    flock_db do
      adapters = load_adapters

      adapter = nil
      if adapter_id = adapters.keys.first
        adapter = adapters.delete(adapter_id)
        save_adapters(adapters)
      end

      adapter
    end
  end

  # Atomically releases adapters to the pool
  #
  # @param  [Hash]  Same as #acquire
  #
  # @return [nil]
  def release(adapter)
    flock_db do
      adapters = load_adapters
      adapters[adapter["adapter_id"]] = adapter
      save_adapters(adapters)
    end

    nil
  end

  private

  def flock_db
    raise "You must supply a block" unless block_given?
    File.open(@lockfile_path, 'w+') do |lockfile|
      lockfile.flock(File::LOCK_EX)
      yield
    end
  end

  def load_adapters
    contents = File.read(@db_path)
    JSON.parse(contents)
  end

  def save_adapters(adapters)
    File.open(@db_path, 'w+') do |f|
      f.write(adapters.to_json)
    end

    nil
  end
end
