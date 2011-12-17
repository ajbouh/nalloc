require 'trace'
require Trace.libpath('trace/writer')

# Shouldn't really do this here.
Trace::Writer.trace!

module Nalloc
  # :stopdoc:
  LIBPATH = ::File.expand_path(::File.dirname(__FILE__)) + ::File::SEPARATOR
  PATH = ::File.dirname(LIBPATH) + ::File::SEPARATOR
  VERSION = ::File.read(PATH + 'version.txt').strip
  # :startdoc:

  # Returns the library path for the module. If any arguments are given,
  # they will be joined to the end of the library path using
  # <tt>File.join</tt>.
  #
  def self.libpath( *args )
    rv =  args.empty? ? LIBPATH : ::File.join(LIBPATH, args.flatten)
    return rv
  end

  # Returns the path for the module. If any arguments are given,
  # they will be joined to the end of the path using
  # <tt>File.join</tt>.
  #
  def self.path( *args )
    rv = args.empty? ? PATH : ::File.join(PATH, args.flatten)
    return rv
  end

  # HACK(adamb) Is there a better way to do this?
  require libpath('nalloc/console')
  CONSOLE = Nalloc::Console.new($stderr)

  def self.trace(h, &b)
    CONSOLE.update(h) do
      Trace::Writer.region(h, &b)
    end
  end

  # Update the trace with the given Hash for the duration of the indicated
  # instance method.
  def self.trace_instance_method(clazz, name, h)
    method = clazz.instance_method(name)
    clazz.send(:define_method, name) do |*args, &b|
      Nalloc.trace(h) do
        method.bind(self).call(*args, &b)
      end
    end
  end
end  # module Nalloc
