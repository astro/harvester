#!/usr/bin/env ruby

require 'yaml'
require 'eventmachine'
require 'dnsruby'
require 'uri'

Dnsruby::Resolver::use_eventmachine true
Dnsruby::Resolver::start_eventmachine_loop false

class GodObject
  include Singleton

  def self.method_missing m, *a
    puts "Sending #{m}(#{a.inspect}) to #{inspect}"
    instance.send m, *a
  end
end

class DNSName
  def self.parse_ip_address(ip)
    begin
      Dnsruby::IPv4::create(ip)
    rescue ArgumentError
      begin
        Dnsruby::IPv6::create(ip)
      rescue ArgumentError
        nil
      end
    end
  end

  def initialize(dns, name)
    if address = DNSName.parse_ip_address(name)
      @result = [:succeed, [address.to_s]]
    else
      df = dns.send_async(Dnsruby::Message.new(name))
      df.callback &method(:on_success)
      df.errback &method(:on_fail)
      @result = nil
    end
    @deferrables = []
  end

  def defer
    d = EM::DefaultDeferrable.new
    if @result
      apply_result_to d
    else
      @deferrables << d
    end
    d
  end

  private

  def apply_result_to(d)
    d.send *@result
    d.send *@result
  end

  def apply_result_to_all
    @deferrables.each { |d|
      apply_result_to d
    }
    @deferrables = []
  end

  def on_success(msg)
    addresses = msg.answer.select { |a|
      a.kind_of?(Dnsruby::RR::IN::A) ||
      a.kind_of?(Dnsruby::RR::IN::AAAA)
    }.map { |a| a.address.to_s }
    @result = [:succeed, addresses]
    apply_result_to_all
  end

  def on_fail(msg, err)
    @result = [:fail, err]
    apply_result_to_all
  end
end

class DNSCache < GodObject
  def initialize
    @dns = Dnsruby::Resolver.new
    @queries = {}
  end

  def resolve(name)
    q = if @queries.has_key? name
          @queries[name]
        else
          @queries[name] = DNSName.new(@dns, name)
        end
    q.defer
  end
end

class HTTPConnection
  module C
    attr_accessor :handler

    def connection_completed
      @handler.opened!
      @state = :headers
      @headers = ['']
      @chunked = false
      @length = 0
      @dumb = true
      @body = ''
    end

    def send_requests(requests)
      send_data requests.to_s
      puts "sent requests: #{requests.to_s.inspect}"
    end

    def receive_data(data)
      send "receive_#{@state}", data
    end

    def unbind
      if @dumb
        @handler.handle_eof
      end
      @handler.handle_disconnected!
    end

    private

    def receive_headers(data)
      puts "receive_headers: #{data.inspect}"
      while data.size > 0
        line, rest = data.split("\n", 2)
        data = rest

        line.strip!
        @headers[-1] += line
        if @headers.last == ''
          @headers.pop
          http_ver, status, status_text = @headers.shift.split(' ', 3)
          header_hash = {}
          @headers.each { |header|
            k, v = header.split(': ', 2)
            header_hash[k.downcase] = v
          }
          @handler.handle_response(status, status_text, header_hash)

          # Reset for the next header
          @headers = ['']

          if header_hash['transfer-encoding'] == 'chunked'
            @dumb = false
            @chunked = true
            @state = :chunklen
            receive_chunklen data
          elsif (l = header_hash['content-length'])
            @dumb = false
            @chunked = false
            @length = l.to_i
            @state = :body
            receive_body data          
          else
            @dumb = true
            @state = :body
            receive_body data          
          end

          break
        else
          @headers << ''
        end
      end
    end

    def receive_body(data)
      p data
      if @dumb
        body = data
        @handler.handle_chunk(body)
      else
        body = (@length > 0) ? data[0..(@length - 1)] : ''
        rest = data[@length..-1].to_s
        puts "#{@length} #{body.size} #{data.size}"
        @length -= body.size

        @handler.handle_chunk(body)

        if rest != ''
          if @chunked
            @state = :chunklen
            receive_chunklen rest
          else
            @handler.handle_eof
            @state = :headers
            receive_headers rest
          end
        end
      end
    end

    def receive_chunklen(data)
      @body += data
      if ((c, rest) = @body.split("\n", 2)) && c
        c.strip!
        if c == ''
          @body = ''
          receive_chunklen rest
        else
          @length = c.to_i(16)
          puts "#{c.inspect} -> #{@length}"
          if @length > 0
            @state = :body
            receive_body rest
          else
            @handler.handle_eof
            @trailerline = ''
            @state = :chunktrailer
            receive_chunktrailer rest
          end
        end
      end
    end

    def receive_chunktrailer(data)
      while data.size > 0
        line, rest = data.split("\n", 2)
        @trailerline += line

        if rest
          if @trailerline.strip == ''
            @state = :headers
            receive_headers rest
          else
            puts "discarding trailerline #{@trailerline.inspect}"
            @trailerline = ''
          end
        end
      end
    end
  end

  def initialize(host, port)
    @requests = []
    @host = host
    @port = port
    open_connection
  end

  def open_connection
    @opened = false
    @c = EM.connect @host, @port, C
    @c.handler = self
  end

  def opened!
    @opened = true
    may_send
  end

  def request(text, &block)
    @requests << [text, block]
    if @c
      may_send
    else
      open_connection
    end
  end

  def handle_disconnected!
    @opened = false
    @c = nil
    if @requests.size > 0
      open_connection
    end
  end

  def handle_response(status, text, headers)
    puts "#{object_id} response: #{status} #{text} #{headers.inspect}"
  end

  def handle_chunk(data)
    puts "#{object_id} body: #{data.inspect}"
  end

  def handle_eof
    puts "#{object_id} eof"
    @requests.shift
  end

  private

  def may_send
    if @opened
      @c.send_requests(@requests.map { |r| r[0] })
    end
  end
end

class ConnectionPool < GodObject
  def initialize
    @connections = {}
  end

  def request(scheme, host, port, text, &block)
    target = [scheme, host, port]
    c = if @connections.has_key? target
          @connections[target]
        else
          @connections[target] = new_connection(*target)
        end
    c.request(text, &block)
  end

  private

  def new_connection(scheme, host, port)
    case scheme
    when 'http' then HTTPConnection
    else raise "Unsupported URL scheme: #{scheme}"
    end.new(host, port)
  end
end

class Transfer
  def initialize(url)
    @can_go = false
    @has_addresses = false
    @error = nil

    @uri = URI::parse(url)
    d = DNSCache.resolve(@uri.host)
    d.callback { |addresses|
      puts "dns for #{@uri.host}: #{addresses.inspect}"
      @addresses = addresses
      @has_addresses = true
      may_go
    }
    d.errback { |err|
      puts "dns for #{@uri.host}: #{err}"
      @error = err.to_s
      @has_addresses = true
      may_go
    }

    @receivers = []
  end

  def get(spawnable)
    @receivers << spawnable
  end

  def go!
    @can_go = true
    may_go
  end

  private

  def notify_receivers(*msg)
    @receivers.each { |r| r.notify *msg }
  end

  def may_go
    if @can_go && @has_addresses
      if @error
        notify_receivers :error, @error
      else
        # TODO: RR-addresses
        request_headers = {
          'Host' => @uri.host,
          'Connection' => 'Keep-Alive',
          'Accept-Encoding' => 'chunked, identity'}
        ConnectionPool.request(@uri.scheme, @addresses[0], @uri.port,
                               "GET #{@uri.request_uri} HTTP/1.1\r\n" +
                               request_headers.map { |k,v|
                                 "#{k}: #{v}\r\n"
                               }.to_s +
                               "\r\n") { |*msg|
          notify_receivers *msg
        }
      end
    end
  end
end

class TransferManager < GodObject
  def initialize
    @transfers = {}
  end

  def get(url, spawnable)
    t = if @transfers.has_key? url
          @transfers[url]
        else
          @transfers[url] = Transfer.new(url)
        end
    t.get spawnable
  end

  ##
  # Call this after everybody has made his get request, so nobody gets
  # chunks starts at the half of the stream just because he has
  # requested too late and the network was too fast.
  #
  # TODO: this can be solved more elegantly
  def go!
    @transfers.each { |url,t|
      t.go!
    }
  end
end

EM.run do
  reader = EM.spawn { |*m| puts "reader: #{m.inspect}" }
  #YAML::load_file('config.yaml')['collections'].each { |cat,urls|
  #  urls.each { |url|
  #    TransferManager.get(url, reader)
  #  }
  #}
%w(
http://spaceboyz.net/~astro/gitorious/
http://spaceboyz.net/
).each{|u|
    TransferManager.get(u, reader) }
  TransferManager.go!
end

=begin
require 'dbi'
require 'yaml'
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

require 'mrss'


config = YAML::load File.new('config.yaml')
timeout = config['settings']['timeout'].to_i
sizelimit = config['settings']['size limit'].to_i
dbi = DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password'])

# Hack, an explicit lock would look much better
class << dbi
  def transaction(*a)
    Thread::critical = true
    super
    Thread::critical = false
  end
end

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

dbi['AutoCommit'] = false
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
          begin dbi.transaction do
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
              description = item.description

              # Link mangling
              begin
                link = URI::join((rss.link.to_s == '') ? uri.to_s : rss.link.to_s, item.link || rss.link).to_s
              rescue URI::Error
                link = item.link
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

              # Remove all enclosures
              dbi.do "DELETE FROM enclosures WHERE rss=? AND link=?", rss_url, link
              # Re-add all enclosures
              item.enclosures.each do |enclosure|
                href = URI::join((rss.link.to_s == '') ? link.to_s : rss.link.to_s, enclosure['href']).to_s
                dbi.do "INSERT INTO enclosures (rss, link, href, mime, title, length) VALUES (?, ?, ?, ?, ?, ?)",
                  rss_url, link, href, enclosure['type'], enclosure['title'], enclosure['length']
              end
            }
            puts "#{logprefix} New: #{items_new} Updated: #{items_updated}"
          end; rescue
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
=end
