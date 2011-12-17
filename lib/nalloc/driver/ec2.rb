require 'fog'
require 'digest/sha2'

class Nalloc::Driver::Ec2 < Nalloc::Driver
  def initialize
    @compute = ::Fog::Compute.new(:provider => 'AWS')
  end

  def name; "ec2" end
  def compute; @compute end

  def trace_op(operation_name, &b)
    Nalloc.trace(:operation => operation_name, &b)
  end

  def trace_node(node, &b)
    Nalloc.trace(:name => node, :node => node, &b)
  end

  # Returns a list of { 'cluster_id', 'identity' } elements
  def find_active_nodes
    return @compute.servers.map do |server|
      next nil if ["terminated", "shutting-down"].member?(server.state)
      next nil unless cluster_id = server.tags["cluster_id"]
      { 'cluster_id' => cluster_id, 'identity' => server.identity }
    end.compact
  end

  def start_allocating_nodes(cluster_id, specs)
    nodes = {}
    specs.each do |name, spec|
      trace_node(name) do
        nodes[name] = start_allocating_node(cluster_id, name, spec)
      end
    end
    return nodes
  end

  def start_allocating_node(cluster_id, name, spec)
    ssh_key_name = spec[:ssh_key_name]
    private_key_path = Nalloc::Node.find_ssh_key(ssh_key_name)
    public_key_path = Nalloc::Node.find_ssh_key("#{ssh_key_name}.pub")

    # Make sure public tcp ports are open.
    ports = spec[:public_ports] || [22]
    group = nil
    trace_op('looking for security group') do
      group_name = ports.sort.join('_')
      unless group = @compute.security_groups.get(group_name)
        trace_op('creating security group') do
          group_description = "Public ports #{ports.sort.join(' ')}"
          group = @compute.security_groups.create(
              :name => group_name,
              :description => group_description)
          ports.each { |port| group.authorize_port_range(port..port) }
        end
      end
    end

    server = nil
    trace_op('creating instance') do
      server = @compute.servers.new(
          :availability_zone => spec[:availability_zone] || 'us-east-1a',
          :image_id => spec[:system_identity] || 'ami-81b275e8',
          :flavor_id => spec[:flavor_id] || 'm1.small',
          :username => spec[:username] || 'ubuntu',
          :tags => { 'cluster_id' => cluster_id },
          :key_name => ssh_key_name,
          :public_key_path => public_key_path,
          :private_key_path => private_key_path,
          :groups => [group.identity])

      public_key_hash = Digest::SHA2.hexdigest(server.public_key)

      # Register key pair, if not registered.
      unless server.key_pair = @compute.key_pairs.get(public_key_hash)
        server.key_pair = @compute.key_pairs.create(
            :name => public_key_hash,
            :public_key => server.public_key)
      end

      server.save
    end

    return lambda do
      trace_node(name) do
        trace_op('waiting for instance') do
          # Wait until machine is up.
          server.wait_for { server.ready? }
        end

        volume_id = nil
        volume_device = nil
        if snapshot_id = spec[:snapshot_id]
          snapshot = @compute.snapshots.get(snapshot_id)
          volume_device = "/dev/sdh"
          volume = @compute.volumes.new(
              :snapshot_id => snapshot_id,
              :server => server,
              :availability_zone => server.availability_zone,
              :size => snapshot.volume_size,
              :device => volume_device,
              # below doesn't actually work unfortunately...
              :delete_on_termination => true)
          volume.save
          volume_id = volume.id

          volume.wait_for { volume.state == "in-use" }
        end

        trace_op('configuring private key') do
          server.setup(:key_data => [server.private_key])
        end

        public_host_key = ""
        trace_op('scanning public host key') do
          public_host_key = Nalloc::Node.ssh_public_host_key(
              server.public_ip_address)
        end

        {
          "identity" => server.identity,
          "system_identity" => server.image_id,
          "public_ip_address" => server.public_ip_address,
          "private_ip_address" => server.private_ip_address,
          "ssh" => {
            "user" => server.username,
            "private_key_name" => ssh_key_name,
            "public_host_key" => public_host_key
          },
          "ec2" => {
            "volume_id" => volume_id,
            "volume_device" => volume_device
          }
        }
      end
    end
  end

  def destroy_cluster(cluster_id)
    self.find_active_nodes.each do |result|
      next unless result['cluster_id'] == cluster_id

      trace_node(result['identity']) do
        trace_op('destroy instance') do
          server = @compute.servers.get(result['identity'])
          volumes = server.volumes
          server.destroy
          volumes.each { |vol| vol.wait_for { ready? }; vol.destroy }
        end
      end
    end
  end
end
