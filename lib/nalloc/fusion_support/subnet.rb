module Nalloc
  module FusionSupport
  end
end

class Nalloc::FusionSupport::Subnet
  attr_reader :adapter, :address, :netmask

  def initialize(adapter, address, netmask)
    @adapter = adapter
    @address = address
    @netmask = netmask
  end

  def resource_id
    "#{@adapter}:#{@address}:#{@netmask}"
  end
end
