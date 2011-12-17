When /^I execute "([^"]*)" on "([^"]*)"$/ do |command, node_name|
  node = Nalloc::Node.find_in_cluster(@cluster, node_name)
  @output = node.pread(command).chomp
end

Then /^I should see "([^"]*)"$/ do |text|
  @output.should == text
end

Then /^the following commands should succeed:$/ do |table|
  commands = {}
  expectations = {}
  table.hashes.each do |row|
    name = row['Node']
    commands[name] = row['Command']
    expectations[name] = row['Output'] if row['Output']
  end

  outputs = {}
  commands.each do |name, command|
    node = Nalloc::Node.find_in_cluster(@cluster, name)
    output = node.pread(command).chomp
    outputs[name] = output if expectations[name]
  end

  outputs.should == expectations
end
