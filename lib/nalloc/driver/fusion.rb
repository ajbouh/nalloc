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
end
