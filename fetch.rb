#!/usr/bin/env ruby

require 'yaml'
require 'digest/md5'
require 'uri'
require 'net/http'
begin
  require 'net/https'
rescue LoadError
  $stderr.puts "WARNING: No https support!"
end
begin
  require 'fastthread'
rescue LoadError
  require 'thread'
end
Thread::abort_on_exception = true

require 'mrss'
require 'couchdb'


config = YAML::load File.new('config.yaml')
timeout = config['settings']['timeout'].to_i
sizelimit = config['settings']['size limit'].to_i
CouchDB::setup config['couchdb']['url'], config['couchdb']['db']

# Not for security, just as an identifier (MD5 is shorter...)
def hash(s)
  Digest::MD5.hexdigest s
end

###########
# Fetching
###########

maxurlsize = 0
rss_urls = []
CouchDB::transaction do |couchdb|
  config['collections'].each do |collection,urls|
    couchdb[collection] = {
      'type' => 'collection',
      'urls' => urls
    }
    urls.each do |url|
      rss_urls << url
    end
  end
end
rss_urls.each { |rss_url|
  maxurlsize = (rss_url.size > maxurlsize) ? rss_url.size : maxurlsize
}

last_get_started = Time.new
pending = []
pending_lock = Mutex.new

rss_urls.each do |rss_url|
  rss_url_id = hash(rss_url)
  pending_lock.synchronize { pending << rss_url }
  Thread.new {
    CouchDB::transaction { |couchdb|
      db_rss = couchdb[rss_url_id]
      is_new = db_rss['title'].nil?
      last = db_rss['last']

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
        puts "#{logprefix} #{response.code} #{response.message}"
      rescue
        puts "#{logprefix} Skipped (request error)"
        pending_lock.synchronize { pending.delete rss_url }
        Thread.exit
      end

      if response.kind_of? Net::HTTPOK
        if response.body.size > sizelimit
          puts "#{logprefix} #{response.body.size} bytes big!"
        else
          begin
            rss = MRSS::parse response.body
          rescue
            puts "#{logprefix} Parse error: #{$!.to_s}"
            Thread.exit
          end

          items_new, items_updated = 0, 0
          rss.items.each { |item|
            description = item.description
            
            # Link mangling
            begin
              link = URI::join((rss.link.to_s == '') ? uri.to_s : rss.link.to_s, item.link || rss.link).to_s
            rescue URI::Error
              link = item.link
            end
            item_id = rss_url_id + '-' + hash(item.link)

            # Push into database
            db_item = couchdb[item_id]
            db_item['date'] ||= item.date
            db_item['type'] = 'item'
            db_item['rss'] = rss_url
            db_item['title'] = item.title
            db_item['link'] = item.link
            db_item['description'] = description
            db_item['enclosures'] = item.enclosures.map { |enclosure|
              {'href' => URI::join((rss.link.to_s == '') ? link.to_s : rss.link.to_s, enclosure['href']).to_s,
                'mime' => enclosure['type'],
                'title' => enclosure['title'],
                'length' => enclosure['length']}
            }

            couchdb[item_id] = db_item
            items_updated += 1
          }
          puts "#{logprefix} New: #{items_new} Updated: #{items_updated}"

          # Update source
          couchdb[rss_url_id] = {
            'type' => 'feed',
            'rss' => rss_url,
            'last' => response['Last-Modified'],
            'title' => rss.title,
            'link' => rss.link,
            'description' => rss.description
          }
          puts "#{logprefix} Source updated"
        end
      end

      pending_lock.synchronize { pending.delete rss_url }
    }
  }
end

while Time.new < last_get_started + timeout and pending.size > 0
  sleep 1
end
pending_lock.synchronize {
  pending.each { |rss_url|
    puts "[#{rss_url.ljust maxurlsize}] Timed out"
  }
}
