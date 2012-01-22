require 'erb'
require 'json'
require 'set'
require 'tempfile'

require Nalloc.libpath('nalloc/fusion_support/vmdk_parser')
require Nalloc.libpath('nalloc/fusion_support/adapter_pool')
require Nalloc.libpath('nalloc/node')

class Nalloc::Driver::Fusion < Nalloc::Driver
  # XXX - Better way of determining this
  VMRUN_PATH        = "/Applications/VMware Fusion.app/Contents/Library/vmrun"
  CONFIG_DIR        = File.expand_path("~/.nalloc/fusion")
  DEFAULTS_PATH     = File.join(CONFIG_DIR, "defaults.json")
  ADAPTER_POOL_PATH = File.join(CONFIG_DIR, "adapter_pool")
  VM_STORE_PATH     = File.join(CONFIG_DIR, "vms")

  TEMPLATE_DIR              = Nalloc.path("templates/fusion")
  VMX_TEMPLATE_PATH         = File.join(TEMPLATE_DIR, "zygote.vmx.erb")
  IFACES_TEMPLATE_PATH      = File.join(TEMPLATE_DIR, "interfaces.erb")
  RESOLV_CONF_TEMPLATE_PATH = File.join(TEMPLATE_DIR, "resolv.conf.erb")

  def self.write_defaults(defaults)
    File.open(DEFAULTS_PATH, 'w+') do |f|
      f.write(defaults.to_json)
    end

    nil
  end

  # Returns default options used during node allocation
  #
  # @return [Hash]  'vmdk_path'         => Path to base vmdk
  #                 'vmx_template_path' => Path to vmx erb template
  def self.defaults
    unless @defaults
      raw_defaults = File.read(DEFAULTS_PATH)
      @defaults = JSON.parse(raw_defaults)
      @defaults.freeze
    end

    @defaults
  end

  def self.default_on(specs, prop)
    specs[prop] || self.defaults[prop.to_s]
  end

  def initialize(opts={})
    @adapter_pool = opts[:adapter_pool] || \
                    Nalloc::FusionSupport::AdapterPool.new(ADAPTER_POOL_PATH)
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

    adapter = @adapter_pool.acquire
    raise "Failed to allocate an adapter" unless adapter

    # If we fail writing out the adapter #destroy_cluster won't be able
    # to release it, hence the special case error handling here.
    begin
      adapter_path = File.join(VM_STORE_PATH, cluster_id, 'adapter.json')
      File.open(adapter_path, 'w+') do |f|
        f.write(adapter.to_json)
      end
    rescue
      @adapter_pool.release(adapter)
      raise
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
    vmdk_path = self.class.default_on(specs, :vmdk_path)
    raise "No vmdk_path specified for node #{name}" unless vmdk_path

    root_pass = self.class.default_on(specs, :root_pass)
    raise "No root_pass specified for node #{name}" unless root_pass

    user = specs[:username]
    raise "No user given for node #{name}" unless specs[:username]

    ssh_key_name = specs[:ssh_key_name]
    raise "No ssh_key_name given for node #{name}" unless specs[:ssh_key_name]

    private_key_path = Nalloc::Node.find_ssh_key(ssh_key_name)
    public_key_path  = Nalloc::Node.find_ssh_key("#{ssh_key_name}.pub")

    vmx_template_path = self.class.default_on(specs, :vmx_template_path)
    vmx_template_path ||= VMX_TEMPLATE_PATH

    vmx_path = create_vm(vmx_template_path, cluster_dir,
                         :name          => name,
                         :vmdk_path     => vmdk_path,
                         :vmnet_adapter => "vmnet#{props[:adapter]}",
                         :memsize_MB    => specs[:memsize_MB])

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
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/bin/mkdir", "-p", "/home/#{user}/.ssh")
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/bin/chown", "#{user}:#{user}", "/home/#{user}/.ssh")
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/bin/chmod", "0700", "/home/#{user}/.ssh")

      # Set authorized keys for user
      guest_auth_keys_path = "/home/#{user}/.ssh/authorized_keys"
      copy_to_guest(root_pass, vmx_path, public_key_path, guest_auth_keys_path,
                    :owner => user,
                    :mode  => "0600")

      # Bring up networking
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/etc/init.d/networking", "restart")

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
    # Release adapters if possible
    cluster_glob = File.join(VM_STORE_PATH, '*')
    all_clusters = Set.new(Dir.glob(cluster_glob).map {|p| File.basename(p) })
    act_clusters = Set.new(find_active_nodes().map {|n| n["cluster_id"] })
    inact_clusters = all_clusters - act_clusters
    inact_clusters.each do |cluster_id|
      adapter_path = File.join(VM_STORE_PATH, cluster_id, 'adapter.json')
      if File.exist?(adapter_path)
        adapter = JSON.parse(File.read(adapter_path))
        @adapter_pool.release(adapter)
        FileUtils.rm(adapter_path)
      end
    end

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

  # Creates the vm specifed by *vm_props*.
  #
  # NB: Fusion doesn't explicitly support cloning of vms. We approximate
  # the process using a method similar to the one detailed at
  # http://communities.vmware.com/docs/DOC-5611
  #
  # @param  [String]  vmx_template_path  Path to the source vmx template
  # @param  [String]  vm_store_path      Directory that will house the vm.
  # @param  [Hash]    vm_props           VM properties. Will be passed to vmx
  #                                      template.
  #
  # @option vm_props  [String]  :name           Required. The vm name.
  # @option vm_props  [String]  :vmdk_path      Required. Path to base vmdk.
  # @option vm_props  [String]  :vmnet_adapter  Required. vmnet0 for example.
  # @option vm_props  [Integer] :memsize_MB     Optional. Ram allocated to vm.
  # @option vm_props  [String]  :guest_os       Optional. VMware specific guest
  #                                             os tag.
  # @return [String]                     Path to newly created vmx file.
  def create_vm(vmx_template_path, vm_store_path, vm_props)
    vm_dir = File.join(vm_store_path, "#{vm_props[:name]}.vmwarevm")

    created_vm_dir = FileUtils.mkdir(vm_dir)

    # Rewrite the vmdk such that each extent is marked read-only and its
    # filename is an absolute path pointing to the correct zygote extent.
    vmdk_dir = File.dirname(vm_props[:vmdk_path])
    vmdk = Nalloc::FusionSupport::VmdkParser.parse_file(vm_props[:vmdk_path])
    vmdk["extents"].each do |extent|
      extent["access"] = "rdonly"
      unless extent["filename"].start_with?(File::SEPARATOR)
        extent["filename"] = File.absolute_path(File.join(vmdk_dir,
                                                          extent["filename"]))
      end
    end
    dst_vmdk_path = File.join(vm_dir, "#{vm_props[:name]}.vmdk")
    Nalloc::FusionSupport::VmdkParser.write_file(vmdk, dst_vmdk_path)

    # Write out the vmx file for the vm
    dst_vmx_path = File.join(vm_dir, "#{vm_props[:name]}.vmx")
    write_template(vmx_template_path, dst_vmx_path, vm_props)

    # Finally snapshot the cloned vm. This will force any writes to be
    # performed against the local linked disk instead of the zygote's disk.
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

  def copy_to_guest(root_pass, vmx_path, src_path, dst_path, opts={})
    vmrun("-gu", "root", "-gp", root_pass, "CopyFileFromHostToGuest",
          vmx_path, src_path, dst_path)

    if owner = opts[:owner]
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/bin/chown", "#{owner}:#{owner}", dst_path)
    end

    if mode = opts[:mode]
      vmrun("-gu", "root", "-gp", root_pass, "runProgramInGuest", vmx_path,
            "/bin/chmod", mode, dst_path)
    end

    nil
  end

  # Returns all running nodes that have been allocated by nalloc
  #
  # @return [Array]  Array of hashes with keys "cluster_id", "identity"
  def find_active_nodes
    vms = []

    vmrun("list").split("\n").each do |line|
      next unless line =~ /^#{VM_STORE_PATH}/
      parts = line.split(File::SEPARATOR)
      vms << {
        "cluster_id" => parts[-3],
        "identity"   => line,
      }
    end

    vms
  end
end
