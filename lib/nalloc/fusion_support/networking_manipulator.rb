require 'set'
require 'tempfile'

module Nalloc
  module FusionSupport
  end
end

# Utility class for munging the networking file used by fusion. The format of
# this file is undocumented, so we're careful to only manipulate the subset
# that we understand (this has the added benefit of making this relatively
# future-proof). Our current understanding of the format is:
#   - First line is "VERSION=1,0"
#   - Subsequent lines are of the form
#     "answer VNET_<ADAPTER_ID>_<PROPERTY_NAME> <VALUE>"
#
# NB: All methods in this class touch disk and either read or rewrite the
#     underlying networking config file.
class Nalloc::FusionSupport::NetworkingManipulator
  DEFAULT_NETWORKING_PATH = "/Library/Preferences/VMware Fusion/networking"
  ALL_ADAPTERS = 1.upto(99).to_a

  # @param  [String]  path  Path to the networking config
  def initialize(path=nil)
    @config_path = path || DEFAULT_NETWORKING_PATH
  end

  # Returns all adapters that are not currently in use
  #
  # @return [Array]  Adapter ids
  def read_free_adapters
    free_adapters = ALL_ADAPTERS.dup

    IO.readlines(@config_path).each do |line|
      if adapter = parse_adapter_id(line)
        free_adapters.delete(adapter)
      end
    end

    free_adapters.to_a.sort
  end

  # Adds the specified adapters to the networking config
  #
  # @param  [Hash]  adapters  Adapters to add.
  #                           adapter_id => {
  #                             :subnet  => [String]
  #                             :netmask => [String]
  #                           }
  # @return nil
  def add_adapters(adapters)
    atomically_replace_file(@config_path) do |tmpfile|
      existing_adapters = Set.new([])

      # Copy over existing configuration
      IO.readlines(@config_path).each do |line|
        if adapter = parse_adapter_id(line)
          existing_adapters << adapter if adapters.has_key?(adapter)
        end
        tmpfile.write(line)
      end

      unless existing_adapters.empty?
        errstr = "The following adapters already exist: " \
                 + existing_adapters.to_a.join(", ")
        raise errstr
      end

      # Append our adapters. We don't bother tagging the adapters with a
      # comment because Fusion will remove them upon restart.
      adapters.each do |adapter, net_props|
        props = {
          "DHCP" => "no",
          "NAT"  => "yes",
          "VIRTUAL_ADAPTER"  => "yes",
          "HOSTONLY_NETMASK" => net_props[:netmask],
          "HOSTONLY_SUBNET"  => net_props[:subnet],
        }
        for k, v in props
          tmpfile.write("answer VNET_#{adapter}_#{k} #{v}\n")
        end
      end

      nil
    end
  end

  # Removes the supplied adapters from the networking config. Note that this
  # will also remove adapters that we didn't add, so be careful.
  #
  # @param  Array  adapters  Adapter ids to remove
  #
  # @return Hash             adapter => true  if adapter was removed
  #                                  => false if the adapter wasn't present
  def remove_adapters(adapters)
    atomically_replace_file(@config_path) do |tmpfile|
      adapters_found = adapters.inject({}) {|h, i| h[i] = false; h }
      adapters = Set.new(adapters)

      IO.readlines(@config_path).each do |line|
        should_skip = false

        if adapter = parse_adapter_id(line)
          if adapters.include?(adapter)
            should_skip = true
            adapters_found[adapter] = true
          end
        end

        tmpfile.write(line) unless should_skip
      end

      adapters_found
    end
  end

  private

  def parse_adapter_id(line)
    if line =~ /^answer VNET_(\d+)/
      Integer($1)
    else
      nil
    end
  end

  # Yields an open temporary file that will be renamed to the supplied path
  # upon completion of the supplied block. Note that this will attempt to
  # preserve ownership of the file, but won't throw if the operation fails.
  #
  # @param  [String]  path  Path to file being modified
  # @param  [Block]         The temporary file that will ultimately replace
  #                         +path+ will be yielded to this block.
  #
  # @return [Object]        Return value of the supplied block is used.
  def atomically_replace_file(path)
    Tempfile.open("nalloc_tmp_#{File.basename(path)}") do |tmpfile|

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
    end
  end

end
