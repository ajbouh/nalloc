require 'tempfile'
require 'tmpdir'

require 'simplecov'

SimpleCov.start do
  add_filter '/features/'
  add_filter '/external/'
end

require File.dirname(__FILE__) + '/../../lib/nalloc.rb'
require Nalloc.libpath('nalloc/driver')
require Nalloc.libpath('nalloc/node')
