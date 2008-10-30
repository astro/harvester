require 'rubygems'
require 'open-uri'
require 'feed-normalizer'
require 'erubis'
require 'mongrel'

# Convert feeds

require 'yaml'

p "Convert feeds"
c, feeds = YAML.load_file('config.yaml'), []
c['collections'].each { |k,v| feeds << v }
File.open('feeds.txt', 'w') { |f| f.puts(feeds.flatten.join("\n")) }
p "Feeds converted"

# Feed Aggregator

class RSSHandler < Mongrel::HttpHandler
  def process(request, response)
    p "Processing feeds..."
    response.start(200) do |head,out|
      head["Content-Type"] = "text/html"
      
      stories = []
      File.open('feeds.txt', 'r').each_line do |f|
        begin
          feed = FeedNormalizer::FeedNormalizer.parse open(f.strip)
          stories.push(*feed.entries) unless feed.nil?
          p " #{f.strip} done."
        rescue => e #OpenURI::HTTPError, RuntimeError, SocketError, Errno::ETIMEDOUT, ::OpenSSL::SSL::SSLError => e
          p "[ERR] #{f.strip} => #{e.message}"
        end
      end
      
      eruby = Erubis::Eruby.new(File.read('news.eruby'))
      out.write(eruby.result(binding()))
    end
  end
end

p "Feed aggregator..."
h = Mongrel::HttpServer.new("0.0.0.0", "80")
h.register("/", RSSHandler.new)
h.register("/files", Mongrel::DirHandler.new("files/"))
h.run.join
