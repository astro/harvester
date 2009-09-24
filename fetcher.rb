#!/usr/bin/env ruby

require 'yaml'
require 'eventmachine'
Thread::abort_on_exception = true

$: << 'lib'
require 'mrss'
require 'download'
require 'db'


config = YAML::load File.new('config.yaml')
timeout = config['settings']['timeout'].to_i
sizelimit = config['settings']['size limit'].to_i
DB.init! config['db']['driver'], config['db']['user'], config['db']['password']

#######################
# Database maintenance
#######################

puts "Looking for sources to purge..."
purge = []
$dbi.select_all("SELECT collection, rss FROM sources") { |dbc,dbr|
  purge << [dbc, dbr] unless (config['collections'][dbc] || []).include? dbr
}

purge_rss = []
purge.each { |c,r|
  puts "Removing #{c}:#{r}..."
  $dbi.do "DELETE FROM sources WHERE collection=? AND rss=?", c, r
  purge_rss << r
}

purge_rss.delete_if { |r|
  purge_this = true

  config['collections'].each { |cfc,cfr|
    if purge_this
      puts "Must keep #{r} because it's still in #{cfc}" if cfr.include? r
      purge_this = !(cfr.include? r)
    end
  }

  !purge_this
}
purge_rss.each { |r|
  puts "Purging items from feed #{r}"
  $dbi.do "DELETE FROM items WHERE rss=?", r
}

###########
# Fetching
###########

maxurlsize = 0
config['collections'].each { |collection,rss_urls|
  rss_urls.each { |rss_url|
    maxurlsize = (rss_url.size > maxurlsize) ? rss_url.size : maxurlsize
  }
}

last_get_started = Time.new
pending = 0

EM.run {
  config['collections'].each do |collection,rss_urls|
    rss_urls.each { |rss_url|
      Download.download(collection, rss_url).callback do
        pending -= 1
        EM.stop if pending < 1
      end
      pending += 1
    }
  end
}
