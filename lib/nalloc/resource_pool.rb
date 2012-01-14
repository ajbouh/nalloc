require 'fileutils'
require 'yaml'

module Nalloc
end

# Utility class for atomically managing a pool of resources shared between
# processes.
#
# A resource must be serializable using yaml and must implement the
# resource_id() instance method.
class Nalloc::ResourcePool

  # @param  [String]  db_dir  Directory that houses the pool
  def initialize(db_dir)
    @db_path       = File.join(db_dir, "resources.yaml")
    @lockfile_path = File.join(db_dir, "resources.lockfile")

    # Create initial db
    if File.exist?(db_dir)
      unless File.exist?(@db_path) && File.exist?(@lockfile_path)
        raise "#{db_dir} exists, but it looks like it isn't a resource pool"
      end
    else
      FileUtils.mkdir_p(db_dir)
      flock_db do
        save_resources({})
      end
    end
  end

  # Atomically acquires a resource from the pool
  #
  # @return  [Object]  If any resources are available
  # @return  [nil]     If none are available.
  def acquire
    flock_db do
      resources = load_resources

      resource = nil
      if resource_id = resources.keys.first
        resource = resources.delete(resource_id)
        save_resources(resources)
      end

      resource
    end
  end

  # Atomically releases resources to the pool
  #
  # @param  [Array]  Resources to release
  #
  # @return [nil]
  def release(*to_release)
    flock_db do
      resources = load_resources

      to_release.each do |resource|
        resources[resource.resource_id] = resource
      end

      save_resources(resources)
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

  def load_resources
    File.open(@db_path, 'r') do |f|
      YAML.load(f)
    end
  end

  def save_resources(resources)
    File.open(@db_path, 'w+') do |f|
      YAML.dump(resources, f)
    end

    nil
  end
end
