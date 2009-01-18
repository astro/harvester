#!/bin/sh

export PATH=/bin:/usr/bin
export RUBYLIB=/usr/lib64/ruby/site_ruby/1.8:/usr/lib64/ruby/site_ruby/1.8/x86_64-linux:/usr/lib64/ruby/site_ruby:/usr/lib64/ruby/1.8:/usr/lib64/ruby/1.8/x86_64-linux:.

cd /home/astro/harvester
nice -n +19 ruby -rubygems fetch.rb
nice -n +19 ruby -rubygems generate.rb
nice -n +19 ruby -rubygems chart.rb
cp html/* ../public_html/harvester/
