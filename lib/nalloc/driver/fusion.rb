require 'erb'

require Nalloc.libpath('nalloc/fusion_support/vmdk_parser')

class Nalloc::Driver::Fusion < Nalloc::Driver
  CONFIG_PATH      = File.expand_path("~/.nalloc/fusion")
  SUBNET_POOL_PATH = File.join(CONFIG_PATH, "subnet_pool")
  VM_STORE_PATH    = File.join(CONFIG_PATH, "vms")

  def name
    "fusion"
  end

  def destroy_cluster
    nil
  end

  # Creates the vm specifed using the supplied vmx template and vmdk.
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
  # @option vm_props  [Integer] :memsize_MB     Optional. Mem size in MB.
  # @option vm_props  [String]  :guest_os       Optional. VMware specific guest
  #                                             os tag.
  # @return nil
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
    write_vmx_template(vmx_template_path, dst_vmx_path, vm_props)

    # Finally snapshot the cloned vm. This will force any writes to be
    # performed against the local linked disk instead of the zygote's disk.
    vmrun("snapshot", dst_vmx_path, "base")

    nil
  rescue
    if created_vm_dir
      FileUtils.rm_rf(vm_dir)
    end

    raise
  end

  def write_vmx_template(template_path, dst_path, props)
    raw_template = File.read(template_path)
    template = ERB.new(raw_template)
    File.open(dst_path, 'w+') do |f|
      f.write(template.result(binding))
    end

    nil
  end

  def vmrun(*args)
    fullargs = ["-T", "fusion", args].flatten
    command = ["vmrun", *fullargs, :err => :close, :in => :close]
    result = IO.popen(command, &:read)
    raise "vmrun operation failed: #{command.inspect}" unless $?.success?

    result
  end
end
