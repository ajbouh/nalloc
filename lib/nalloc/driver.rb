require Nalloc.libpath('nalloc/caution')
require 'json'

class Nalloc::Driver
  DESTRUCTION_POLICIES = [:on_error, :always, :never]

  # Create an instance of the driver with the given name.
  def self.create(name)
    raise "name can't be nil" unless name
    require Nalloc.libpath("nalloc/driver/#{name}")
    class_name = name.split('_').map{ |s| s.capitalize }.join

    self.const_get(class_name).new
  end

  # Recreate instance from driver details stored in cluster.
  def self.recreate(cluster_driver)
    create(cluster_driver['name'])
  end

  def self.trace_phase(phase_name, &b)
    Nalloc.trace(:phase => phase_name, &b)
  end

  # Allocates a cluster, blocking until completion.
  # Returns the cluster, or the result of the block if one is given.
  # If a block is given, ENV['NALLOC_CLUSTER'] is temporarily set and the
  # cluster is yielded to it.
  # options[:destroy] may be :never, :always, :on_error; defaults to :on_error
  def self.allocate_cluster(driver, specs, options=nil)
    options ||= {}

    # Default to the first-listed policy.
    destruction_policy = options[:destroy] || DESTRUCTION_POLICIES.first
    unless DESTRUCTION_POLICIES.member?(destruction_policy)
      raise "#{options[:destroy].inspect} isn't valid for :destroy."
    end

    region_done = trace_phase('allocation')
    start = Time.now
    error = true
    cluster_id = (0...32).map{ ('a'..'z').to_a[rand(26)] }.join

    nodes = {}

    # Start allocating all nodes, then finish them one-by-one.
    driver.start_allocating_nodes(cluster_id, specs).each do |name, pending|
      nodes[name] = pending.call
    end

    finish = Time.now
    cluster = {
      'convention' => 1,
      'identity' => cluster_id,
      # NOTE 12/14/2011 Since we're just storing name here, we don't need a
      # whole hash. At some point in the future, increment the convention and
      # stop using a whole hash. Consider supporting the old convention for a
      # reasonable period of time.
      'driver' => {
        'name' => driver.name
      },
      'nodes' => nodes,
      'allocation' => {
        'timestamp' => start.to_s,
        'utc' => start.to_i,
        'host' => `hostname`.chomp,
        'duration' => (finish - start)
      }
    }
    region_done.call

    # If a cluster_path is specified, save the cluster
    cluster_json = cluster.to_json
    if cluster_path = options[:cluster_path]

      if cluster_path == "-"
        $stdout.puts cluster_json
      else
        Nalloc::Io.write_file(cluster_path, cluster_json)
      end
    end

    result = cluster
    if block_given?
      previous_cluster_json = ENV['NALLOC_CLUSTER']
      ENV['NALLOC_CLUSTER'] = cluster_json
      result = yield cluster
    end

    error = false

    return result
  ensure
    # Close a region if needed
    region_done.call if region_done

    # Reset env var
    ENV['NALLOC_CLUSTER'] = previous_cluster_json if previous_cluster_json

    # Decide whether or not to destroy the cluster.
    # Always destroy partial allocations.
    destroy = true
    if cluster
      # We only get here if allocation succeeded.
      case destruction_policy
      when :always
        destroy = true
      when :on_error
        destroy = error
      when :never
        destroy = false
      else
        raise "impossible."
      end
    end

    if cluster_id and destroy
      trace_phase('destruction') do

        # Attempt to destroy the cluster.  If we're destroying because an
        # exception was raised above, just log any exceptions destroy_cluster
        # raises.
        log_message = error ? "Couldn't destroy #{cluster_id}" : nil
        Nalloc::Caution.attempt(log_message) do
          driver.destroy_cluster(cluster_id)
        end
      end
    end
  end
end
