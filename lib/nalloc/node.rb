require 'tempfile'
require Nalloc.libpath('nalloc/io')

class Nalloc::Node

  # Returns the path to an ssh private key file with the specified name.
  # Raises an exception if the name provided is invalid for any reason.
  # The given name is assumed to be a path if
  #   It's an absolute path, or begins with ".#{File::SEPARATOR}"
  # Otherwise, ~/.ssh and nalloc's own keys/ folder is searched.
  def self.find_ssh_key(name)
    if name == File.absolute_path(name) or /^\.#{File::SEPARATOR}/ =~ name
      return File.expand_path(name)
    end

    path = File.expand_path("~/.ssh/#{name}")
    raise "Can't find ssh key named: #{name}" unless File.exist?(path)

    # Fix permissions on the file, so ssh doesn't complain.
    File.chmod(0600, path)

    return path
  end

  def self.ssh_public_host_key(host)
    # Scan key.
    result = IO.popen(["ssh-keyscan", host, :err => :close], &:read).chomp
    raise "Failed to scan ssh host key." unless $?.success?

    result
  end

  def self.find_in_cluster(cluster, name)
    raise "cluster not given" unless cluster
    raise "name not given" unless name

    nodes = cluster['nodes']
    details = nodes[name]
    raise "Bad node: #{name}; Options: #{nodes.keys.inspect}" unless details
    self.new(details)
  end

  attr_reader :details

  def initialize(details)
    @details = details
    ssh_details = details['ssh']

    known_hosts, @known_hosts_tempfile = Nalloc::Io.write_tempfile("known_hosts",
        ssh_details['public_host_key'])

    key = self.class.find_ssh_key(ssh_details['private_key_name'])

    ssh_options = [
      "-i", key,
      "-o", "StrictHostKeyChecking=yes",
      "-o", "PasswordAuthentication=no",
      "-o", "UserKnownHostsFile=#{known_hosts}"
    ]

    @ssh_host = "#{ssh_details['user']}@#{details['public_ip_address']}"
    @ssh_args = [*ssh_options, @ssh_host]

    @rsync_args = ['rsync', '-rzPLk',
        '--chmod=Da+rX,Dog-w,Fu+rw,Fog-rwx',
        '-e', "ssh #{ssh_options.join(' ')}",
        '--rsync-path', 'sudo rsync']
  end

  def upload(local_src, remote_dest)
    dest = "#{@ssh_host}:#{remote_dest}"
    unless system(*@rsync_args, local_src, dest,
        :err => :close, :out => :close)
      raise "Upload failed from #{local_src} to #{dest}."
    end
  end

  def download(remote_src, local_dest)
    src = "#{@ssh_host}:#{remote_src}"
    unless system(*@rsync_args, src, local_dest,
        :err => :close, :out => :close)
      raise "Download failed from #{src} to #{local_dest}."
    end
  end

  def execute(*commands)
    command = timed_sudoification(commands)
    unless system('ssh', *@ssh_args, command, :err => :close, :out => :close)
      raise "Error during execute on #{@ssh_host}: #{command}"
    end
  end

  def pread(*commands)
    command = timed_sudoification(commands)
    result = IO.popen(['ssh', *@ssh_args, command, :err => :close], &:read)

    unless $?.success?
      raise "Error during pread on #{@ssh_host}: #{command}"
    end
    result
  end

  def become_ssh_session(*command)
    exec('ssh', *@ssh_args, *command)
  end

  private

  def timed_sudoification(commands)
    commands = commands.collect do |command|
      # Don't time or sudo shell operations
      case command
      when /^cd /, /^export /
        command
      else
        "/usr/bin/time -p sudo -E sh -c #{command.inspect}"
      end
    end

    "set -x; " + commands.join(" && ")
  end
end
