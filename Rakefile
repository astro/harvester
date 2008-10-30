require 'rake'
require 'rake/testtask'
require 'rake/rdoctask'

RUN_DIR = File.dirname(__FILE__)

namespace 'harvester' do
  
  # TODO: parse the config file and make it sexy
  desc 'Show configuration'
  task :config do
    system "cat config.yaml"
  end
  
  desc 'Setup harvester'
  task :setup do
    # backup config.yaml
    # interactive config
    # save config.yaml
    puts "TODO!"
  end
  
  desc 'Patch db.sql for use with MySQL'
  task :patch_db_for_mysql do
    system "patch -p0 db.sql < harvester-current-mysql.diff"
  end
  
  desc 'Fetch the feeds'
  task :fetch do
    system "cd #{RUN_DIR} && nice -n +19 /usr/bin/ruby -rubygems fetch.rb"  
  end
  
  desc 'Generate the HTML'
  task :generate do
    system "cd #{RUN_DIR} && nice -n +19 /usr/bin/ruby -rubygems generate.rb"
  end
  
  desc 'Run the havester'
  task :run do
    Rake::Task['harvester:fetch'].invoke
    Rake::Task['harvester:generate'].invoke
  end
  
end
