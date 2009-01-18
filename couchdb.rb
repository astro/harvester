require 'net/http'
require 'json'


module CouchDB
  @@server = nil
  @@db = nil

  def self.setup(server, db)
    @@server = server
    @@db = db
  end

  # Signals that this transaction needs to be restarted
  # because of an inconsistent state of document revisions
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
        if @revs[id].nil? || @revs[id] == json['_rev']
          # We didn't know the document's revision already
          # or it is just the old one
          @revs[id] = json['_rev']
          json
        else
          # The revision has changed since the last read/write,
          # we need to restart
          raise TransactionFailed
        end
      rescue NotFound
        if @revs[id].nil?
          # Umm... possible
          {}
        else
          # Not found but we've read it previously o.0
          raise TransactionFailed
        end
      end
    end

    def []=(id, doc)
      # Convert hashes & arrays to JSON documents
      doc = doc.to_json unless doc.kind_of?(String) || doc.nil?
      
      begin
        d = if doc
              CouchDB::put id, doc, @revs[id]
            else
              CouchDB::delete id, @revs[id]
            end
        json = JSON::parse(d)
        @revs[id] = json['rev']
      rescue PreconditionFailed
        # HTTP/1.0 412 Precondition failed
        if @revs[id]
          # We knew this document's id already
          # but somebody else put up a new revision
          raise TransactionFailed
        else
          # We cannot modify documents whose revision
          # we don't know yet, so simply get it...
          self[id]
          # ...and try again
          retry
        end
      end
    end
  end

  # The transaction wrapper to be used:
  #   CouchDB::transaction { |couchdb|
  #     json = couchdb['foobar']
  #     # do stuff with json struct
  #     couchdb['foobar'] = json
  #   }
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

  # HTTP actions go here
  class << self
    def delete(id, prev_rev=nil)
      headers = prev_rev ? {'If-Match' => "\"#{prev_rev}\""} : {}
      request :Delete, id, headers
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

# Concurrent exploitation of transaction restarting
if $0 == __FILE__
  Thread::abort_on_exception = true
  CouchDB::setup "http://127.0.0.1:5984", "harvester"
  threads = []
  10.times do |i|
    threads << Thread.new do
      CouchDB::transaction { |couchdb|
        puts "#{i} reading"
        couchdb["test"]
        sleep 0.1
        puts "#{i} writing"
        couchdb["test"] = '{"title": "Test Blog", "url": "http://localhost/"}'
        sleep 0.01
        puts "#{i} deleting"
        couchdb["test"] = nil
        puts "#{i} done"
      }
    end
  end
  threads.each { |thread| thread.join }
end
