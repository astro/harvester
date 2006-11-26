#!/bin/sh

cd /home/astro/harvester
nice -n +19 /usr/bin/ruby -rubygems fetch.rb
nice -n +19 /usr/bin/ruby -rubygems generate.rb

