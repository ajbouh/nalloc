
When /^I generate a new random value$/ do
  length = 50
  @random_value = (0...length).map{ ('a'..'z').to_a[rand(26)] }.join
end

When /^I create a temporary file with that random value$/ do
  @tempfile = Tempfile.new('somefile')
  @local_path = @tempfile.path
  File.open(@local_path, 'w+') { |io| io << @random_value }
end

When /^I upload that file to "([^\"]*)" on "([^\"]*)"$/ do |remote_dest, node_name|
  node = Nalloc::Node.find_in_cluster(@cluster, node_name)
  node.upload(@local_path, remote_dest)
  @remote_path = File.join(remote_dest, File.basename(@local_path))
end

When /^I examine that file on "([^\"]*)"$/ do |node_name|
  node = Nalloc::Node.find_in_cluster(@cluster, node_name)
  @output = node.pread("cat #{@remote_path}")
end

When /^I examine "([^\"]*)" on "([^\"]*)"$/ do |remote_path, node_name|
  node = Nalloc::Node.find_in_cluster(@cluster, node_name)
  @output = node.pread("cat #{remote_path}")
end

Then /^I should see that random value$/ do
  @output.should == @random_value
end
