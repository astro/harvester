#!/usr/bin/env ruby

require 'singleton'
require 'yaml'
require 'rexml/document'
begin
  require 'xml/xslt'
rescue LoadError
  require 'xml/libxslt'
end
require 'time'
require 'iconv'
begin
  require 'hpricot'
rescue LoadError
  $stderr.puts "Hpricot not found, will not mangle relative links in <description/>"
end
require 'digest/md5'

require 'couchdb'


class LinkAbsolutizer
  def initialize(body)
    @body = body
  end

  def absolutize(base)
    if defined? Hpricot
      begin
        html = Hpricot("<html><body>#{@body}</body></html>")
        (html/'a').each { |a|
          begin
            f = a.get_attribute('href')
            t = URI::join(base, f.to_s).to_s
            puts "Rewriting #{f.inspect} => #{t.inspect}" if f != t
            a.set_attribute('href', t)
          rescue URI::Error
            puts "Cannot rewrite relative URL: #{a.get_attribute('href').inspect}" unless a.get_attribute('href') =~ /^[a-z]{2,10}:/
          end
        }
        (html/'img').each { |img|
          begin
            f = img.get_attribute('src')
            t = URI::join(base, f.to_s).to_s
            puts "Rewriting #{f.inspect} => #{t.inspect}" if f != t
            img.set_attribute('src', t)
          rescue URI::Error
            puts "Cannot rewrite relative URL: #{img.get_attribute('href').inspect}" unless img.get_attribute('href') =~ /^[a-z]{2,10}:/
          end
        }
        html.search('/html/body/*').to_s
      rescue Hpricot::Error => e
        $stderr.puts "Oops: #{e}"
        @body
      end
    else
      @body
    end
  end
end

class String
  def to_time
    Time.parse self
  end
end

class REXML::Element
  def elements=(e)
    @elements.delete_all ''
    e.each { |e1| add e1 }
  end
end


class EntityTranslator
  include Singleton

  def initialize
    @entities = {}
    %w(HTMLlat1.ent HTMLsymbol.ent HTMLspecial.ent).each do |file|
      begin
        load_entities_from_file(file)
      rescue Errno::ENOENT
        system("wget http://www.w3.org/TR/html4/#{file}")
        load_entities_from_file(file)
      end
    end
  end

  def load_entities_from_file(filename)
    IO::readlines(filename).to_s.scan(/<!ENTITY +(.+?) +CDATA +"(.+?)".+?>/m) do |ent,code|
      @entities[ent] = code
    end
  end

  def translate_entities(doc, with_xmldecl=true)
    oldclass = doc.class
    doc = doc.to_s

    @entities.each do |ent,code|
      doc.gsub!("&#{ent};", code)
    end

    "<?xml version='1.0' encoding='utf-8'?>\n#{doc}" if with_xmldecl

    if oldclass == REXML::Element
      REXML::Document.new(doc).root
    else
      doc
    end
  end

  def self.translate_entities(doc, with_xmldecl=true)
    instance.translate_entities(doc, with_xmldecl)
  end
end


require 'thread'
class Array
  def pmap(&block)
    results = []
    results_lock = Mutex.new
    threads = []
    each_with_index do |e,i|
      threads << Thread.new {
        r = block.call(e)
        results_lock.synchronize {
          results[i] = r
        }
      }
    end
    threads.each { |thread| thread.join }
    results
  end
end


class Hash
  def to_xml(name, children)
    e = REXML::Element.new(name)
    e.elements = children.select { |child|
      has_key? child
    }.map { |child|
      c = REXML::Element.new(child)
      c.text = self[child]
      c
    }
    e
  end
end


class XSLTFunctions
  FUNC_NAMESPACE = 'http://astroblog.spaceboyz.net/harvester/xslt-functions'

  def initialize(db)
    @db = db
    %w(collection-items feed-items item-description item-images item-enclosures).each { |func|
      XML::XSLT.extFunction(func, FUNC_NAMESPACE, self)
    }
  end

  def generate_root
    root = REXML::Element.new('collections')
    root.elements = collections.map { |collection,feeds|
      ec = REXML::Element.new('collection')
      ec.attributes['name'] = collection
      ec.elements = feeds.collect { |feed|
        f = @db[feed['_id']]
        f.to_xml 'feed', %w(rss title link description)
      }
      ec
    }
    EntityTranslator.translate_entities(root)
  end

  def collection_items(collection_name, max=23)
    feeds = collection(collection_name)
    items = feeds.inject([]) { |r,feed|
      r + feed["items"]
    }
    items.sort! { |i1,i2| i2['date'] <=> i1['date'] }
    items = items[0..(max - 1)]

    ei = REXML::Element.new('items')
    ei.elements = items.pmap { |item|
      item_doc = @db[item['_id']]
      x = item_doc.to_xml 'item', %w(rss title link date)
      p x.to_s
      x
    }
    EntityTranslator.translate_entities(ei)
  end

  def feed_items(rss, max=23)
    items = []
    collections.each { |collection,feeds|
      feeds.each { |feed|
        items += feed['items'] if feed['rss'] == rss
      }
    }
    items.sort! { |i1,i2| i2['date'] <=> i1['date'] }
    items = items[0..(max - 1)]

    ei = REXML::Element.new('items')
    ei.elements = items.pmap { |item|
      item_doc = @db[item['_id']]
      item_doc.to_xml 'item', %w(title date link)
    }
    EntityTranslator.translate_entities(ei)
  end

  def item_description(rss, item_link)
    puts "item_description(#{rss.inspect}, #{item_link.inspect})"
    desc = @db["#{hash rss}-#{hash item_link}"]['description']
    desc = EntityTranslator.translate_entities(desc, false)
    desc = LinkAbsolutizer.new(desc).absolutize(item_link)
    desc
  end

  def item_images(rss, item_link)
    desc = "<description>" + item_description(rss, item_link) + "</description>"
    images = REXML::Element.new('images')
    REXML::Document.new(desc.to_s).root.each_element('//img') { |img|
      images.add img
    }
    images
  end

  def item_enclosures(rss, item_link)
    e = REXML::Element.new('enclosures')
    if (enclosures = @db["#{hash rss}-#{hash item_link}"]['enclosures'])
      e.elements = enclosures.collect { |enclosure|
        enclosure.to_xml 'enclosure', %w(href mime title length)
      }
    end
    e
  end

  private

  def collections
    unless defined? @collections
      @collections = {}
      @db['_view/harvester/collections']['rows'].first['value'].each { |c|
        @collections[c['_id']] = c['feeds'] if c['_id'].size < 32
      }
    end
    @collections
  end

  def collection(name)
    if name == '%'
      collections.inject([]) { |r,(name,feeds)|
        r + feeds
      }
    else
      collections[name]
    end
  end

  def hash(s)
    Digest::MD5.hexdigest s
  end

end


config = YAML::load File.new('config.yaml')
CouchDB::setup config['couchdb']['url'], config['couchdb']['db']
CouchDB::transaction do |couchdb|
  f = XSLTFunctions.new(couchdb)

  xslt = XML::XSLT.new
  xslt.xml = f.generate_root.to_s

  templatedir = config['settings']['templates']
  outputdir = config['settings']['output']
  Dir.foreach(templatedir) { |templatefile|
    next if templatefile =~ /^\./
    
    puts "Processing #{templatefile}"
    xslt.xsl = "#{templatedir}/#{templatefile}"
    File::open("#{outputdir}/#{templatefile}", 'w') { |f| f.write(xslt.serve) }
  }
end
