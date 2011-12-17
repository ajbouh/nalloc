require 'tempfile'

module Nalloc::Io
  protected

  def self.write_tempfile(basename, contents)
    file = Tempfile.open(basename)
    file << contents
    file.flush
    return file.path, file
  end

  # Construct a file path and write the specified contents to it.
  def self.write_file(*path_fragments, contents)
    path = File.join(*path_fragments)
    File.open(path, 'w') { |io| io << contents }
    return path
  end
end
