Given /^the nodes:$/ do |table|
  @node_specs = {}
  table.hashes.each do |row|
    name = row['Name']
    @node_specs[name] = {
      :ssh_key_name => Nalloc.path('keys', 'id_cucumber'),
      :bootstrap_command => @node_bootstrap_command
    }
    if username = ENV['NALLOC_USER']
      @node_specs[name][:username] = username
    end

    if root_pass = ENV['NALLOC_ROOT_PASS']
      @node_specs[name][:root_pass] = root_pass
    end

    if vmdk_path = ENV['NALLOC_VMDK_PATH']
      @node_specs[name][:vmdk_path] = vmdk_path
    end
  end
end

Given /^I know the cluster platform$/ do
  @cluster_platform = ENV['CLUSTER_PLATFORM'] || 'virtual_box'

  @driver = Nalloc::Driver.create(@cluster_platform)

  @active_servers = lambda do
    @driver.find_active_nodes.inject([]) do |ary, node|
      cluster_id = @cluster && @cluster['identity']
      next ary unless node['cluster_id'] == cluster_id
      ary.push(node['identity'])
    end
  end
end

When /^I allocate the nodes$/ do
  node_specs = @node_specs.dup
  unless @pretending
    node_specs.each do |name, node_spec|
      node_spec[:hostname] = name
    end
  end

  @cluster = Nalloc::Driver.allocate_cluster(@driver, @node_specs)
end

Given /^I have the following nodes allocated$/ do |table|
  step 'the nodes:', table
  step 'I know the cluster platform'
  step 'I allocate the nodes'
end

Then /^each node should be tagged with "([^"]*)"$/ do |id|
  @active_servers.call.each do |identity|
    @cluster['nodes'].values.any? { |node| node['identity'] == id }
  end
end

When /^I destroy it$/ do
  driver = Nalloc::Driver.recreate(@cluster['driver'])
  driver.destroy_cluster(@cluster['identity'])
end

Then /^the number of active nodes (?:should be|is) (\d+)$/ do |count|
  count.should == @active_servers.call.length.to_s
end

Then /^the layout should be representable as JSON$/ do
  json = @cluster.to_json
  @parsed_cluster = JSON.parse(json)
  @parsed_cluster.should == @cluster
end

