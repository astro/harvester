#!/usr/bin/env ruby

require 'dbi'
require 'yaml'
require 'uri'
require 'net/http'
begin
  require 'net/https'
rescue LoadError
  $stderr.puts "WARNING: No https support!"
end
require 'thread'
begin
  require 'htree'
rescue LoadError
  $stderr.puts "HTree not found, will not mangle relative links in <description/>"
end

require 'mrss'


config = YAML::load File.new('config.yaml')
timeout = config['settings']['timeout'].to_i
sizelimit = config['settings']['size limit'].to_i
dbi = DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password'])

#######################
# Database maintenance
#######################

puts "Looking for sources to purge..."
purge = []
dbi.select_all("SELECT collection, rss FROM sources") { |dbc,dbr|
  purge << [dbc, dbr] unless (config['collections'][dbc] || []).include? dbr
}

purge_rss = []
purge.each { |c,r|
  puts "Removing #{c}:#{r}..."
  dbi.do "DELETE FROM sources WHERE collection=? AND rss=?", c, r
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
  dbi.do "DELETE FROM items WHERE rss=?", r
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
pending = []
pending_lock = Mutex.new

config['collections'].each { |collection,rss_urls|
  rss_urls.each { |rss_url|
    pending_lock.synchronize { pending << rss_url }
    Thread.new {
      db_rss, last = dbi.select_one "SELECT rss, last FROM sources WHERE collection=? AND rss=?", collection, rss_url
      is_new = db_rss.nil?

      uri = URI::parse rss_url
      logprefix = "[#{uri.to_s.ljust maxurlsize}]"

      http = Net::HTTP.new uri.host, uri.port
      http.use_ssl = (uri.kind_of? URI::HTTPS) if defined? OpenSSL
      request = (if is_new or last.nil?
        puts "#{logprefix} GET"
        Net::HTTP::Get.new uri.request_uri
      else
        puts "#{logprefix} GET with If-Modified-Since: #{last}"
        Net::HTTP::Get.new uri.request_uri, {'If-Modified-Since'=>last}
      end)
      request.basic_auth(uri.user, uri.password) if uri.user
      
      last_get_started = Time.new
      begin
        response = http.request request
      rescue
        puts "Skipped (request error)"
        pending_lock.synchronize { pending.delete rss_url }
      end
      puts "#{logprefix} #{response.code} #{response.message}"

      if response.kind_of? Net::HTTPOK
        if response.body.size > sizelimit
          puts "#{logprefix} #{response.body.size} bytes big!"
        else
          begin
            rss = MRSS::parse response.body

            # Update source
            if is_new
              dbi.do "INSERT INTO sources (collection, rss, last, title, link, description) VALUES (?, ?, ?, ?, ?, ?)",
                collection, rss_url, response['Last-Modified'], rss.title, rss.link, rss.description
              puts "#{logprefix} Source added"
            else
              dbi.do "UPDATE sources SET last=?, title=?, link=?, description=? WHERE collection=? AND rss=?",
                response['Last-Modified'], rss.title, rss.link, rss.description, collection, rss_url
              puts "#{logprefix} Source updated"
            end

            items_new, items_updated = 0, 0
            rss.items.each { |item|
              # Link mangling
              link = URI::join((rss.link.to_s == '') ? uri.to_s : rss.link.to_s, item.link).to_s
              # Description mangling
              description = item.description
              if defined? HTree
                begin
                  html = HTree("<html><body>#{description}</body></html>").to_rexml
                  html.each_element('//a') { |a|
                    a.attributes['href'] = URI::join(link, a.attributes['href'].to_s).to_s
                  }
                  html.each_element('//img') { |img|
                    img.attributes['src'] = URI::join(link, img.attributes['src'].to_s).to_s
                  }
                  description = html.elements['/html/body'].children.to_s
                rescue HTree::Error => e
                  $stderr.puts "Oops: #{e}"
                end
              end

              # Push into database
              db_title = dbi.select_one "SELECT title FROM items WHERE rss=? AND link=?", rss_url, link
              item_is_new = db_title.nil?

              if item_is_new
                begin
                  dbi.do "INSERT INTO items (rss, title, link, date, description) VALUES (?, ?, ?, ?, ?)",
                    rss_url, item.title, link, item.date, description
                  items_new += 1
                rescue DBI::ProgrammingError
                  puts description
                  puts "#{$!.class}: #{$!}\n#{$!.backtrace.join("\n")}"
                end
              else
                dbi.do "UPDATE items SET title=?, description=? WHERE rss=? AND link=?",
                  item.title, description, rss_url, link
                items_updated += 1
              end
            }
            puts "#{logprefix} New: #{items_new} Updated: #{items_updated}"
          rescue
            puts "#{logprefix} Error: #{$!.class}: #{$!}\n#{$!.backtrace.join("\n")}"
          end
        end
      end

      pending_lock.synchronize { pending.delete rss_url }
    }
  }
}

while Time.new < last_get_started + timeout and pending.size > 0
  sleep 1
end
pending_lock.synchronize {
  pending.each { |rss_url|
    puts "[#{rss_url.ljust maxurlsize}] Timed out"
  }
}
