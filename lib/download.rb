require 'uri'
require 'em-http'

module Download
  def self.get(url, last_modified=nil, etag=nil)
    df = EM::DefaultDeferrable.new
    head = last_modified ? {'If-Modified-Since' => last_modified} : {}
    http = EM::HttpRequest.new(url).get :head => head
    http.callback do
      if http.response_header.status == 200
        df.succeed http.response, http.response_header['LAST_MODIFIED']
      else
        df.fail http.response_header.status
      end
    end
    http.errback do
      df.fail http.errors
    end
    df
  end

  def self.download(collection, url)
    df = EM::DefaultDeferrable.new

    DB.get_collection_source_exist_and_last(collection, url) do |exists, last|
      last_modified = last.to_s.empty? ? nil : last

      puts "#{url}\tGET"

      download = Download.get(url, last_modified)
      download.callback do |body, last_modified|
        puts "#{url}\tOK: #{body.length} bytes"
      
        rss = nil
        begin
          rss = MRSS::parse body
        rescue Exception => e
          puts "#{url}\t#{e.class}"
        end
        DB.update_by_mrss(collection, url, rss, last_modified, !exists) if rss
        df.succeed
      end
      download.errback do |status|
        puts "#{url}\t#{status.inspect}"
        df.succeed
      end
    end

    df
  end
end
