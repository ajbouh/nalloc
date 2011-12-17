require 'optparse'
require 'json'

module Nalloc::Cli
  class ClusterOption
    def initialize
      @default = "dev.json"
    end

    def parser=(opts)
      opts.on("--cluster cluster.json", "Specify cluster path") do |path|
        @json = File.read(path)
      end
    end

    def cluster
      unless json = @json || ENV['NALLOC_CLUSTER']
        json = File.read(@default) if File.exist?(@default)
      end

      cluster = JSON.parse(json) if json

      unless cluster
        raise "NALLOC_CLUSTER or --cluster is required (#@default not found)"
      end

      return cluster
    end
  end
end
