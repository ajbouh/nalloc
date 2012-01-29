require 'erb'
require 'json'
require 'set'
require 'tempfile'

require Nalloc.libpath('nalloc/node')

class Nalloc::Driver::Fusion < Nalloc::Driver
  # XXX - Better way of determining this
  VMRUN_PATH        = "/Applications/VMware Fusion.app/Contents/Library/vmrun"
  CONFIG_DIR        = File.expand_path("~/.nalloc/fusion")
  DEFAULTS_PATH     = File.join(CONFIG_DIR, "defaults.json")
  ADAPTER_POOL_PATH = File.join(CONFIG_DIR, "adapters.json")
  VM_STORE_PATH     = File.join(CONFIG_DIR, "vms")

  TEMPLATE_DIR              = Nalloc.path("templates/fusion")
  DEFAULT_VMX_TEMPLATE_PATH = File.join(TEMPLATE_DIR, "zygote.vmx.erb")
  IFACES_TEMPLATE_PATH      = File.join(TEMPLATE_DIR, "interfaces.erb")
  RESOLV_CONF_TEMPLATE_PATH = File.join(TEMPLATE_DIR, "resolv.conf.erb")

  DEFAULT_SSH_KEY = "id_rsa"

  class << self
    def save_adapters(adapters)
      File.open(ADAPTER_POOL_PATH, 'w+') do |f|
        f.write(adapters.to_json)
      end
    end

    def load_adapters
      adapters = JSON.parse(File.read(ADAPTER_POOL_PATH))
    end
  end

  def name
    "fusion"
  end

  # Begins allocation of the cluster specified by *specs*
  #
  # Side effects:
  # - Reserves an adapter from the pool for the lifetime of the cluster.
  # - Creates a directory to house the vms. This directory lives at
  #   VM_STORE_PATH/cluster_id
  #
  # @param  [String]  cluster_id  Globally unique cluster id.
  # @param  [Hash]    specs       Node properties. See #start_allocating_node
  #
  # @return [Hash]                Node name => block. See #start_allocating_node
  def start_allocating_nodes(cluster_id, specs)
    # .1 is the host adapter, .2 is the nat daemon
    raise "Subnets are limited to 251 nodes" if specs.length > 251

    return {} if specs.empty?

    Nalloc::Caution.attempt("Failed to reap cruft: allocating_nodes") { reap }

    # Create dir to house the vms, mkdir throws if cluster_dir exists
    cluster_dir = File.join(VM_STORE_PATH, cluster_id)
    FileUtils.mkdir(cluster_dir)

    unless adapter = acquire_adapter
      raise "Failed to allocate an adapter"
    end

    nodes    = {}
    network  = adapter["subnet"].split(".")[0, 3].join(".")
    gateway  = network + ".2"
    bcast    = network + ".255"
    host_ctr = 3
    specs.each do |name, spec|
      nodes[name] =
        start_allocating_node(cluster_id, name, spec, cluster_dir,
                              :ipaddr     => network + ".#{host_ctr}",
                              :netmask    => adapter["netmask"],
                              :gateway    => gateway,
                              :broadcast  => bcast,
                              :dns_server => gateway,
                              :adapter    => adapter["adapter_id"])
      host_ctr +=1
    end

    nodes
  end

  # Starts allocating a node that belongs to +cluster_id+ and is specified by
  # +specs+ and +props+
  #
  # @param  [String]  cluster_id  Globally unique cluster id.
  # @param  [String]  name        Node name.
  # @param  [Hash]    specs       Map of caller supplied node properties.
  #                                 :vmdk_path  => Optional.
  #                                 :vmx_path   => Optional.
  #                                 :memsize_MB => Optional. RAM to give the vm.
  #                                 :root_pass => Required. Root pass is
  #                                   needed to configure networking, etc.
  #                                 :username  => Required. Initial user.
  #                                 :ssh_key_name => Required. Private ssh key
  #                                   name. Corresponding public key will be
  #                                   added to initial user's authorized_keys
  #                                   file.
  # @param [String]  cluster_dir Where the vm will be housed
  #
  # @return block    Finishes allocating node, blocks until completion.
  def start_allocating_node(cluster_id, name, specs, cluster_dir, props)
    vmdk_path =
      File.expand_path(get_required_spec_option(name, specs, :vmdk_path))
    root_pass = get_required_spec_option(name, specs, :root_pass)
    user      = get_required_spec_option(name, specs, :username)

    ssh_key_name     = ENV['NALLOC_SSH_KEY'] || DEFAULT_SSH_KEY
    private_key_path = Nalloc::Node.find_ssh_key(ssh_key_name)
    public_key_path  = Nalloc::Node.find_ssh_key("#{ssh_key_name}.pub")

    vmx_template_path = specs[:vmx_template_path] || DEFAULT_VMX_TEMPLATE_PATH

    vmx_path = create_vm(vmx_template_path, cluster_dir, name, vmdk_path,
                         "vmnet#{props[:adapter]}",
                         :memsize_MB => specs[:memsize_MB],
                         :guest_os   => specs[:guest_os])

    vmrun("start", vmx_path, "nogui")

    lambda do
      # Set up network interface
      ifaces = Tempfile.new("nalloc_ifaces")
      write_template(IFACES_TEMPLATE_PATH, ifaces.path, props)
      copy_to_guest(root_pass, vmx_path, ifaces.path, "/etc/network/interfaces",
                    :mode => "0755")

      # Set up DNS
      resolv_conf = Tempfile.new("nalloc_resolv_conf")
      write_template(RESOLV_CONF_TEMPLATE_PATH, resolv_conf.path, props)
      copy_to_guest(root_pass, vmx_path, resolv_conf.path, "/etc/resolv.conf",
                    :mode => "0755")

      # Make sure .ssh exists and has correct permissions
      gr = make_guestrunner(root_pass, vmx_path)
      ssh_dir = "/home/#{user}/.ssh"
      gr.call("/bin/mkdir", "-p", ssh_dir)
      set_file_permissions_in_guest(root_pass, vmx_path, ssh_dir,
                                    :owner => user,
                                    :mode  => "0700")

      # Set authorized keys for user
      guest_auth_keys_path = "/home/#{user}/.ssh/authorized_keys"
      copy_to_guest(root_pass, vmx_path, public_key_path, guest_auth_keys_path,
                    :owner => user,
                    :mode  => "0600")

      # Bring up networking
      gr.call("/etc/init.d/networking", "restart")

      { "identity"          => vmx_path,
        "public_ip_address" => props[:ipaddr],
        "ssh" => {
          "user" => user,
          "private_key_name" => ssh_key_name,
          "public_host_key"  => Nalloc::Node.ssh_public_host_key(props[:ipaddr])
        }
      }
    end
  end

  # Stops running nodes belonging to *cluster_id* and releases the adapter
  # belonging to the cluster.
  #
  # Side effects:
  #   - If this cluster contains the last running vms then #reap will
  #     reclaim all disk space used by this cluster, as well as disk
  #     space used by other cluster that haven't been reaped.
  #
  # @param  [String]  cluster_id  Globally unique cluster id
  #
  # @return nil
  def destroy_cluster(cluster_id)
    find_active_nodes().each do |node|
      next unless node["cluster_id"] == cluster_id
      vmrun("stop", node["identity"])
    end

    Nalloc::Caution.attempt("Failed to reap cruft: destroy cluster") { reap }

    nil
  end

  # Cleans up disk space used by inactive VMs.
  #
  # NB: Sadly, this can only make progress if *no* VMs are running as vmrun wil
  # fail on "deleteVM" with an error claiming that the vm is in use.
  #
  # @return nil
  def reap
    # Can't delete any vms until all vms are down. vmrun will fail claiming
    # that the vm is in use, regardless of whether or not it is powered on.
    unless vmrun("list") =~ /running VMs: 0$/
      return nil
    end

    to_delete = Dir.glob(File.join(VM_STORE_PATH, '**', '*.vmx'))
    to_delete.each do |identity|
      vmrun("deleteVM", identity)
    end

    # Remove cluster dirs
    Dir.glob(File.join(VM_STORE_PATH, '*')).each do |cluster_dir|
      FileUtils.rm_rf(cluster_dir)
    end

    nil
  end

  # Creates the specified vm.
  #
  # NB: Fusion doesn't explicitly support cloning of vms. We approximate
  # the process using a method similar to the one detailed at
  # http://communities.vmware.com/docs/DOC-5611
  #
  # @Param  [String]  vmx_template_path  Path to the source vmx template
  # @param  [String]  vm_store_path      Directory that will house the vm.
  # @param  [String]  vm_name            The vm name.
  # @param  [String]  vmdk_path          Path to base vmdk.
  # @param  [String]  vmnet_adapter      Network adapter to use (i.e. vmnet0)
  # @param  [Hash]    opts               Optional VM properties.
  #
  # @option opts      [Integer] :memsize_MB  Ram allocated to vm.
  # @option opts      [String]  :guest_os    VMware specific guest os tag.
  #
  # @return [String]  Path to newly created vmx file.
  def create_vm(vmx_template_path, vm_store_path, vm_name, vmdk_path,
                vmnet_adapter, opts)
    vm_dir = File.join(vm_store_path, "#{vm_name}.vmwarevm")
    created_vm_dir = FileUtils.mkdir(vm_dir)

    vmx_template_props = {
      :name          => vm_name,
      :vmnet_adapter => vmnet_adapter,
      :vmdk_path     => vmdk_path,
      :memsize_MB    => opts[:memsize_MB],
      :guest_os      => opts[:guest_os],
    }

    # Write out the vmx file for the vm
    dst_vmx_path = File.join(vm_dir, "#{vm_name}.vmx")
    write_template(vmx_template_path, dst_vmx_path, vmx_template_props)

    # Finally snapshot the cloned vm. This will force any writes to be
    # performed against the local linked disk instead of the base disk.
    vmrun("snapshot", dst_vmx_path, "base")

    dst_vmx_path
  rescue
    FileUtils.rm_rf(vm_dir) if created_vm_dir

    raise
  end

  def write_template(template_path, dst_path, props)
    raw_template = File.read(template_path)
    template = ERB.new(raw_template)
    File.open(dst_path, 'w+') do |f|
      f.write(template.result(binding))
    end

    nil
  end

  def vmrun(*args)
    fullargs = ["-T", "fusion", args].flatten
    command = [VMRUN_PATH, *fullargs, :err => :close, :in => :close]
    result = IO.popen(command, &:read)
    raise "vmrun operation failed: #{command.inspect}" unless $?.success?

    result
  end

  def make_guestrunner(root_pass, vmx_path)
    lambda do |*command|
      vmrun("-gu", "root", "-gp", root_pass,
            "runProgramInGuest", vmx_path, *command)
    end
  end

  def copy_to_guest(root_pass, vmx_path, src_path, dst_path, opts={})
    vmrun("-gu", "root", "-gp", root_pass, "CopyFileFromHostToGuest",
          vmx_path, src_path, dst_path)
    set_file_permissions_in_guest(root_pass, vmx_path, dst_path, opts)
    nil
  end

  def set_file_permissions_in_guest(root_pass, vmx_path, target, opts={})
    gr = make_guestrunner(root_pass, vmx_path)

    if owner = opts[:owner]
      gr.call("/bin/chown", "#{owner}:#{owner}", target)
    end

    if mode = opts[:mode]
      gr.call("/bin/chmod", mode, target)
    end

    nil
  end

  # Acquires an adapter, if available
  #
  # @return  [Hash]     Adapter on success.
  #          NilClass   Nil otherwise.
  def acquire_adapter
    free_adapters = self.class.load_adapters()
    processed_clusters = Set.new([])

    find_active_nodes().each do |node|
      # All nodes in a cluster share the same adapter
      next if processed_clusters.include?(node["cluster_id"])
      read_adapter_ids_from_vmx(node["identity"]).each do |adapter_id|
        free_adapters.delete(adapter_id)
      end
      processed_clusters.add(node["cluster_id"])
    end

    free_adapters.values.first
  end

  # Returns the adapter ids used by the supplied vm
  #
  # @param  [String]  vmx_path
  #
  # @return [Array]   Adapter ids
  def read_adapter_ids_from_vmx(vmx_path)
    adapter_ids = Set.new([])

    IO.readlines(vmx_path).each do |line|
      if line =~ /\.vnet\s*=\s*"vmnet(\d+)"/
        adapter_ids.add($1)
      end
    end

    adapter_ids.to_a
  end

  # Returns all running nodes that have been allocated by nalloc
  #
  # @return [Array]  Array of hashes with keys "cluster_id", "identity"
  def find_active_nodes
    vms = []

    vmrun("list").split("\n").each do |line|
      next unless line =~ /^#{VM_STORE_PATH}/
      vms << {
        "cluster_id" => cluster_id_from_vmx_path(line),
        "identity"   => line,
      }
    end

    vms
  end

  def get_required_spec_option(node_name, specs, key)
    unless val = specs[key]
      raise "No #{key} specified for node #{node_name}"
    end
    val
  end

  def cluster_id_from_vmx_path(vmx_path)
    # Canonical path is:
    # <nalloc_root>/vms/<cluster_id>/<node_name>.vmwarevm/<node_name>.vmx
    parts = vmx_path.split(File::SEPARATOR)
    parts[-3]
  end
end
