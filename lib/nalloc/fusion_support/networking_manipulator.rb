require 'set'
require 'tempfile'

module Nalloc
  module FusionSupport
  end
end

# Utility class for munging the networking file used by fusion. This file
# in undocumented, so we're careful to only manipulate the subset that we
# understand (this has the added benefit of making this relatively
# future-proof).
class Nalloc::FusionSupport::NetworkingManipulator
  DEFAULT_NETWORKING_PATH = "/Library/Preferences/VMware Fusion/networking"

  # @param  [String]  path  Path to the networking config
  def initialize(path=nil)
    @config_path = path || DEFAULT_NETWORKING_PATH
  end

  # Returns an adapter that is not currently in use
  #
  # @return [Integer]  Adapter index on success
  # @return nil        If there are no free adapters
  def get_free_adapter
    free_adapters = Set.new(0.upto(9).map {|i| i })

    IO.readlines(@config_path).each do |line|
      if line =~ /^answer VNET_(\d)/
        free_adapters.delete(Integer($1))
      end
    end

    free_adapters.to_a.sort.first
  end

  # Adds an adapter to the specified config and tags it as being added
  # by nalloc.
  #
  # @param  [Integer] index    Interface index. Should be in [0, 9]
  # @param  [String]  subnet   Subnet belonging to this adapter
  # @param  [String]  netmask  Netmask for subnet
  #
  # @return nil
  def add_adapter(index, subnet, netmask)
    atomically_replace_file(@config_path) do |tmpfile|
    # Copy over existing configuration
      IO.readlines(@config_path).each do |line|
        if line =~ /VNET_#{index}/
          raise "Adapter #{index} already exists"
        else
          tmpfile.write(line)
        end
      end

      # Append our adapter
      props = {
        "DHCP" => "no",
        "NAT"  => "yes",
        "VIRTUAL_ADAPTER"  => "yes",
        "HOSTONLY_NETMASK" => netmask,
        "HOSTONLY_SUBNET"  => subnet,
      }
      tmpfile.write("# NALLOC_ADAPTER #{index}\n")
      for k, v in props
        tmpfile.write("answer VNET_#{index}_#{k} #{v}\n")
      end

      nil
    end
  end

  # Removes the adapter from the specified config. Cowardly refuses to
  # remove any adapters not tagged as being added by nalloc.
  #
  # @param  [Integer] index  Interface index.
  #
  # @return [TrueClass || FalseClass]  True if adapter was found, false if not
  def remove_adapter(index)
    atomically_replace_file(@config_path) do |tmpfile|
      adapter_found  = false

      IO.readlines(@config_path).each do |line|
        case line
        when /^answer VNET_#{index}/
          adapter_found = true
          next
        else
          tmpfile.write(line)
        end
      end

      adapter_found
    end
  end

  private

  # Yields an open temporary file that will be renamed to the supplied path
  # upon completion of the supplied block.
  #
  # @param  [String]  path  Path to file being modified
  # @param  [Block]         The temporary file that will ultimately replace
  #                         +path+ will be yielded to this block.
  #
  # @return [Object]        Return value of the supplied block is used.
  def atomically_replace_file(path)
    tmpfile = Tempfile.new("nalloc_tmp_#{File.basename(path)}")

    # Preserve ownership (if possible) and mode
    stats = File.stat(path)
    begin
      tmpfile.chown(stats.uid, stats.gid)
    rescue Errno::EPERM
    end
    tmpfile.chmod(stats.mode)

    ret = yield tmpfile

    File.rename(tmpfile.path, path)

    ret
  ensure
    if tmpfile
      tmpfile.close unless tmpfile.closed?
      begin
        tmpfile.unlink
      rescue
      end
    end
  end

end
