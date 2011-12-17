require 'digest/sha1'

require Nalloc.libpath('nalloc/io')
require Nalloc.libpath('nalloc/node')

class Nalloc::Driver::VirtualBox < Nalloc::Driver
  def initialize
    @trace = false

    # Must be stable, we find stale vms with it.
    @suffix = "_nalloc_vbox"
  end

  def name; "virtual_box" end

  # Returns a list of { 'cluster_id', 'identity' } elements
  def find_active_nodes
    return vbox_vm_names(true).map do |vm|
      # NOTE This assumes that cluster ids won't contain '_'s.
      next nil unless /^.+_([^_]+)#{@suffix}$/ =~ vm
      { 'cluster_id' => $1, 'identity' => vm }
    end.compact
  end

  # Allocates instances and interfaces for this cluster
  # Has a side-effect of cleaning up lingering instances and host-only
  # interfaces that may be left over from other clusters.
  def start_allocating_nodes(cluster_id, specs)
    raise "Default netmask maxes out at 254 nodes" if specs.length > 254

    # Skip ahead if we aren't allocating instances
    return {} if specs.empty?

    # Don't prematurely exhaust our limited supply of host-only interfaces.
    Nalloc::Caution.attempt("Failed to reap cruft: allocating_nodes") { reap }

    iface_name = vbox_regex("hostonlyif", "create",
        /Interface '([^']+)' was successfully created/)

    # Look up host-only interface details
    cluster_iface = vbox_find_hostonlyifs(:name => iface_name)

    # Use sequential IPv4 addresses, starting from gateway address.
    last_ipv4 = cluster_iface['IPAddress'].split('.').map{ |n| n.to_i }

    # Pick a random base port to start from.
    # NOTE Unlucky numbers will cause port mapping to fail.
    last_ssh_nat_port = (rand * 1200 + 1024).to_i

    nodes = {}
    specs.each do |name, spec|
      last_ipv4[-1] = last_ipv4[-1] + 1
      last_ssh_nat_port = last_ssh_nat_port + 1

      unless template_name = spec[:system_image]
        vagrant_ovf = nil
        vagrant_box = spec[:vagrant_box] || 'lucid32'
        if vagrant_box
          glob = File.expand_path("~/.vagrant.d/boxes/#{vagrant_box}/*.ovf")
          vagrant_ovf = assert_file_exists("valid vagrant_box",
              Dir[glob].first)
        end

        ovf_path = assert_file_exists("ovf_path",
            spec[:ovf_path] || vagrant_ovf)

        template_name = template_ovf(ovf_path)
      end

      # Currently assuming that the initial key for the box is id_vagrant.
      # This should probably be configurable, somehow.
      nodes[name] = self.start_allocating_node(cluster_id, name, spec,
          :ipv4_address => last_ipv4.join('.'),
          :ssh_nat_port => last_ssh_nat_port,
          :netmask => cluster_iface['NetworkMask'],
          :hostonlyif => iface_name,
          :template_name => template_name,
          :template_key_path => Nalloc.path('keys', 'id_vagrant'))
    end
    return nodes
  end

  # Terminates instances and interfaces allocated for this cluster.
  # Has a side-effect of cleaning up lingering instances and host-only
  # interfaces that may be left over from other clusters.
  def destroy_cluster(cluster_id)

    # Only power off nodes that are running.
    find_active_nodes.each do |details|
      next unless details['cluster_id'] == cluster_id
      vbox("controlvm", details['identity'], "poweroff")
    end

    # HACK Not sure why this is needed, or if this is always enough time
    sleep 1

    # Remove (now) terminated instances and unused host-only interfaces.
    Nalloc::Caution.attempt("Failed to reap cruft: destroy cluster") { reap }
  end

  def start_allocating_node(cluster_id, name, spec, vbox_info)
    ipv4 = vbox_info[:ipv4_address]
    netmask = vbox_info[:netmask]
    hostonlyif = vbox_info[:hostonlyif]
    ssh_nat_port = vbox_info[:ssh_nat_port]

    user = spec[:username] || 'vagrant'

    raise "ssh_key_name not given" unless ssh_key_name = spec[:ssh_key_name]
    private_key_path = Nalloc::Node.find_ssh_key(ssh_key_name)
    public_key_path = Nalloc::Node.find_ssh_key("#{ssh_key_name}.pub")

    # Fix private key permissions.
    File.chmod(0600, private_key_path)

    # Temporary directory for vm
    dir = "/tmp/nalloc/vbox/#{cluster_id}/#{name}"
    FileUtils.mkdir_p(dir)

    identity = vbox_clonevm(vbox_info[:template_name], 'zygote',
        "#{name}_#{cluster_id}#{@suffix}")

    # Paraphrased from http://www.virtualbox.org/manual/ch06.html
    #
    # VirtualBox provides support for the industry-standard "virtio"
    # networking drivers, which are part of the open-source KVM project.
    #
    # VirtualBox then expects a special software interface for virtualized
    # environments to be provided by the guest, thus avoiding the complexity
    # of emulating networking hardware and improving network performance.
    #
    # The "virtio" networking drivers are available for these guest OSs:
    # - Linux kernels v2.6.25 or later can be configured for virtio support
    # - For Windows 2000, XP and Vista, virtio drivers can be downloaded and
    #   installed from the KVM project web page.[28]
    vbox("modifyvm", identity,
        # Set up nat network, using port forwarding.
        "--nic1", "nat",
        "--nictype1", "virtio",
        "--natpf1", "guestssh,tcp,,#{ssh_nat_port},,22",
        # Set up host-only network
        "--nic2", "hostonly",
        "--nictype2", "virtio",
        "--hostonlyadapter2", hostonlyif)

    # Start it
    vbox("startvm", identity, "--type", "headless")

    # Return a lambda that will finish the job and block until complete
    return lambda do
      # Enable host-only adapter (eth1) via ssh over nat adapter (eth0)
      # Set authorized_keys to public_key_contents
      public_key_contents = File.read(public_key_path).chomp

      first_nat_ssh_connection(name, user, vbox_info[:template_key_path],
          ssh_nat_port, "sudo sh -c '(echo \"#NALLOC-BEGIN
# The contents below are automatically generated by nalloc.
# Please do not modify any of these contents.
auto eth1
iface eth1 inet static
      address #{ipv4}
      netmask #{netmask}
#NALLOC-END\" > /etc/network/interfaces) &&
/sbin/ifup eth1 &&
mkdir -p ~/.ssh &&
(echo \"#{public_key_contents}\" > ~/.ssh/authorized_keys)'")

      next {
        "identity" => identity,
        "system_identity" => vbox_info[:template_name],
        "public_ip_address" => ipv4,
        "ssh" => {
          "user" => user,
          "private_key_name" => ssh_key_name,
          "public_host_key" => Nalloc::Node.ssh_public_host_key(ipv4)
        }
      }
    end
  end

  private

  # Repeatedly attempt to connect to the instance via the NAT interface.
  # Either timeout, or execute the given command. Given its tolerance of
  # connection failure, this method is intended to be used as the first
  # ssh connection to an instance. After successfully returning, just ssh
  # normally.
  def first_nat_ssh_connection(name, user, private_key_path, ssh_nat_port,
      command)
    # Fix permissions on the file, so ssh doesn't complain.
    File.chmod(0600, private_key_path)

    nat_ssh_config, tmp = Nalloc::Io.write_tempfile("ssh_config", "Host #{name}
  HostName 127.0.0.1
  User #{user}
  Port #{ssh_nat_port}
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile #{private_key_path}
  IdentitiesOnly yes
  NoHostAuthenticationForLocalhost yes")

    # For some reason, the hostonlyif gets lossy during boot. Try to connect
    # as many times as you can in a fixed time window.
    Timeout.timeout(240) do
      loop do
        # If ssh exits with 255, just retry as the node may not be ready.
        system("ssh", "-F", nat_ssh_config, name, "pwd",
            :err => :close, :out => :close)
        break if $?.success?
        unless 255 == $?.exitstatus
          raise "Unexpected ssh error connecting via NAT-forwarded port."
        end
      end
    end

    system("ssh", "-F", nat_ssh_config, name, command,
        :err => :close, :out => :close)
  end

  # Remove vms no longer running, and otherwise unused host-only interfaces.
  def reap
    vms = vbox_vm_names(false)
    vms_not_running = vms - vbox_vm_names(true)

    # Unregister and delete vms that match but aren't running.
    vms_not_running.each do |vm|
      next unless vm.end_with?(@suffix)
      vbox("unregistervm", vm, "--delete")
      vms.delete(vm)
    end

    # Delete unused host-only interfaces
    vbox_find_hostonlyifs(:not_used_by => vms).each do |iface|
      vbox("hostonlyif", "remove", iface['Name'])
    end
  end

  def assert_file_exists(description, path)
    raise "#{description} not given" unless path
    raise "#{description} doesn't exist: #{path}" unless File.exist?(path)
    return path
  end

  def template_ovf(ovf_path)
    ovf_digest = Digest::SHA1.hexdigest(File.read(ovf_path))
    template_name = "template_#{ovf_digest}"

    existing_vms = vbox_vm_names.inject({}) { |h, name| h[name] = true; h }

    # We blindly trust that vms with proper names
    unless existing_vms[template_name]
      vbox('import', ovf_path, '--vsys', '0', '--vmname', template_name)
      vbox('snapshot', template_name, 'take', 'zygote')
    end

    template_name
  end

  def vbox_clonevm(source, snapshot, name)
    vbox_regex("clonevm", source,
        "--snapshot", snapshot, "--options", "link",
        "--name", name, "--register",
        /Machine has been successfully cloned as "([^"]+)"/)
  end

  # Returns host-only interfaces as an Array of Hashes
  # :name => "vmnetN"; Returns interface with that name, if it exists.
  # :not_used_by => ["identity"]; Returns interfaces unused by the given vms.
  def vbox_find_hostonlyifs(options=nil)
    ifaces = vbox("list", "hostonlyifs").split("\n\n").map do |text|
      Hash[text.lines.map { |l| [$1, $2] if /^([^:]+):\s+(.+)$/ =~ l }]
    end

    # Remove hostonlyifs used by the specified vms, if any.
    options ||= {}
    if options[:name]
      return ifaces.select{ |i| i['Name'] == options[:name] }.first
    end

    (options[:not_used_by] || []).each do |id|
      vbox("showvminfo", id, "--machinereadable").lines.each do |line|
        next unless /hostonlyadapter\d="([^"]+)"/ =~ line
        ifaces.delete_if{ |iface| iface['Name'] == $1 }
      end
    end

    return ifaces
  end

  # Collect vms by name, return as a list.
  # Optionally only returns ones that are running.
  def vbox_vm_names(only_running=false)
    what = only_running ? "runningvms" : "vms"
    return vbox("list", what).split("\n").map do |vm|
      $1 if /^"([^"]+)" (.+)$/ =~ vm
    end
  end

  # Convenience for running virtualbox operations.
  # If the operation doesn't succeed, raises an exception.
  def vbox(*args)
    command = ["VBoxManage", *args, :err => :close, :in => :close]
    result = IO.popen(command, &:read)
    raise "VBoxManage operation failed: #{command.inspect}" unless $?.success?

    result
  end

  # Runs operation, returning the first matching group.
  # If the pattern doesn't match, raises an exception.
  def vbox_regex(*args, pattern)
    result = vbox(*args)
    raise "Could not find #{pattern}" unless pattern =~ result
    return $1
  end
end
