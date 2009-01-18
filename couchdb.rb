require 'net/http'
require 'json'


module CouchDB
  @@server = nil
  @@db = nil

  def self.setup(server, db)
    @@server = server
    @@db = db
  end

  class TransactionFailed < RuntimeError
  end

  class Transaction
    def initialize
      @revs = {}
    end

    def [](id)
      begin
        d = CouchDB::get id
        json = JSON::parse(d)
        @revs[id] = json['_rev']
        json
      rescue NotFound
        {}
      end
    end

    def []=(id, doc)
      doc = doc.to_json unless doc.kind_of? String

      begin
        d = CouchDB::put id, doc, @revs[id]
        json = JSON::parse(d)
        @revs[id] = json['rev']
      rescue PreconditionFailed
        if @revs[id]
          raise TransactionFailed
        else
          self[id]
          retry
        end
      end
    end
  end

  def self.transaction(&block)
    begin
      block.call Transaction.new
    rescue TransactionFailed
      $stderr.puts "Transaction failed, restarting..."
      retry
    end
  end

  class PreconditionFailed < RuntimeError
  end
  class NotFound < RuntimeError
  end

  class << self
    def delete(id)
      request :Delete, id
    end
    
    def get(id)
      request :Get, id
    end
    
    def put(id, json, prev_rev=nil)
      headers = prev_rev ? {'If-Match' => "\"#{prev_rev}\""} : {}
      request :Put, id, headers, json
    end
    
    private
    
    def request(method, id, headers={}, body=nil)
      uri = URI::parse("#{@@server}/#{@@db}/#{id}")
      req = Net::HTTP.const_get(method).new(uri.path, headers) # path?
      if body
        req['Content-type'] = 'application/json'
        req.body = body
      end
      res = Net::HTTP.start(uri.host, uri.port) {|http|
        http.request(req)
      }
      case res
      when Net::HTTPSuccess then res.body
      when Net::HTTPPreconditionFailed then raise PreconditionFailed
      when Net::HTTPNotFound then raise NotFound
      else raise res.class.to_s
      end
    end
  end
end

if $0 == __FILE__
  Thread::abort_on_exception = true
  CouchDB::setup "http://127.0.0.1:5984", "harvester"
  threads = []
  10.times do |i|
    threads << Thread.new do
      CouchDB::transaction { |couchdb|
        puts "#{i} reading"
        couchdb["test"]
        puts "#{i} writing"
        couchdb["test"] = '{"title": "Test Blog", "url": "http://localhost/"}'
        puts "#{i} done"
      }
    end
  end
  threads.each { |thread| thread.join }
end
