module Nalloc
  module FusionSupport
  end
end

# Simple parser for VMware .vmdk files.
# TODO(mp): Make this more robust
#
# See the following for a description of the file format:
# http://www.vmware.com/support/developer/vddk/vmdk_50_technote.pdf
class Nalloc::FusionSupport::VmdkParser
  COMMENT_REGEX      = /^#/
  BLANK_LINE_REGEX   = /^\s+$/
  DDB_ENTRY_REGEX    = /^ddb\.([^\s=]+)\s*=\s*"([^"]+)"$/
  HEADER_ENTRY_REGEX = /^([^\s=]+)\s*=\s*([^\s]+)$/
  EXTENT_ENTRY_REGEX = /([^\s]+)\s+(\d+)\s+([^\s]+)\s+"([^"]+)"\s*(\d+)?$/

  # Parses the vmdk file at +path+ into a hash representation.
  #
  # @param  [String]  path  Where the vmdk lives on disk
  #
  # @return [Hash]          headers => Hash of [name] => [value]
  #                         ddb     => Hash of [name] => [value]
  #                         extents => Array of extent hashes of the form:
  #                           access   => rw | rdonly | noaccess
  #                           size     => In 512B sectors
  #                           type     => See doc for list of types.
  #                           filename => Path to raw bits for extent.
  #                           offset   => Optional. See doc for more details.
  def self.parse_file(path)
    vmdk = {
      "headers" => {},
      "extents" => [],
      "ddb"     => {}}

    IO.readlines(path).each do |line|
      case line
      when DDB_ENTRY_REGEX
        vmdk["ddb"][$1.downcase] = $2.downcase
      when HEADER_ENTRY_REGEX
        vmdk["headers"][$1.downcase] = $2.downcase
      when EXTENT_ENTRY_REGEX
        extent = {
          "access"   => $1.downcase,
          "size"     => $2.downcase,
          "type"     => $3.downcase,
          "filename" => $4.downcase}
        extent["offset"] = $5.downcase if $5
        vmdk["extents"] << extent
      when COMMENT_REGEX
      when BLANK_LINE_REGEX
        # Do nothing
      else
        raise "Unable to parse line: '#{line}'"
      end
    end

    vmdk
  end

  # Writes out the supplied vmdk hash, +vmdk+, to the path given by +path+
  # The basic format is (headers, extents, ddb).
  #
  # @param  [Hash]    vmdk  Vmdk to write. Probably returned from .parse_file
  # @param  [String]  path  Where to write the vmdk
  #
  # @return nil
  def self.write_file(vmdk, path)
    File.open(path, "w+") do |f|
      for k, v in vmdk["headers"]
        f.write("%s=%s\n" % [k, v])
      end
      f.write("\n")

      for s in vmdk["extents"]
        f.write("%s %s %s \"%s\" %s\n" % [s["access"], s["size"], s["type"],
                                          s["filename"], s["offset"]])
      end
      f.write("\n")

      for k, v in vmdk["ddb"]
        f.write("ddb.%s = \"%s\"\n" % [k, v])
      end
    end

    nil
  end
end
