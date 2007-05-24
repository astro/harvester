#!/usr/bin/env ruby

require 'singleton'
require 'dbi'
require 'yaml'
require 'rexml/document'
require 'xml/xslt'
require 'time'
require 'iconv'

class String
  def to_time
    Time.parse self
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


class XSLTFunctions
  FUNC_NAMESPACE = 'http://astroblog.spaceboyz.net/harvester/xslt-functions'

  def initialize(dbi)
    @dbi = dbi
    %w(collection-items feed-items item-description item-enclosures).each { |func|
      XML::XSLT.extFunction(func, FUNC_NAMESPACE, self)
    }
  end

  def generate_root
    root = REXML::Element.new('collections')
    @dbi.select_all("SELECT collection FROM sources GROUP BY collection") { |name,|
      collection = root.add(REXML::Element.new('collection'))
      collection.attributes['name'] = name
      @dbi.select_all("SELECT rss,title,link,description FROM sources WHERE collection=?", name) { |rss,title,link,description|
        feed = collection.add(REXML::Element.new('feed'))
        feed.add(REXML::Element.new('rss')).text = rss
        feed.add(REXML::Element.new('title')).text = title
        feed.add(REXML::Element.new('link')).text = link
        feed.add(REXML::Element.new('description')).text = description
      }
    }

    EntityTranslator.translate_entities(root)
  end

  def collection_items(collection, max=23)
    items = REXML::Element.new('items')
    @dbi.select_all("SELECT items.title,items.date,items.link,items.rss FROM items,sources WHERE items.rss=sources.rss AND sources.collection LIKE ? ORDER BY items.date DESC LIMIT ?", collection, max.to_i) { |title,date,link,rss|
      item = items.add(REXML::Element.new('item'))
      item.add(REXML::Element.new('title')).text = title
      item.add(REXML::Element.new('date')).text = date.to_time.xmlschema
      item.add(REXML::Element.new('link')).text = link
      item.add(REXML::Element.new('rss')).text = rss
    }

    EntityTranslator.translate_entities(items)
  end

  def feed_items(rss, max=23)
    items = REXML::Element.new('items')
    @dbi.select_all("SELECT title,date,link FROM items WHERE rss=? ORDER BY date DESC LIMIT ?", rss, max.to_i) { |title,date,link|
      item = items.add(REXML::Element.new('item'))
      item.add(REXML::Element.new('title')).text = title
      item.add(REXML::Element.new('date')).text = date.to_time.xmlschema
      item.add(REXML::Element.new('link')).text = link
    }

    EntityTranslator.translate_entities(items)
  end

  def item_description(rss, item_link)
    @dbi.select_all("SELECT description FROM items WHERE rss=? AND link=?", rss, item_link) { |desc,|
      return EntityTranslator.translate_entities(desc, false)
    }
    ''
  end

  def item_enclosures(rss, link)
    #p [rss,link]
    enclosures = REXML::Element.new('enclosures')
    @dbi.select_all("SELECT href, mime, title, length FROM enclosures WHERE rss=? AND link=? ORDER BY length DESC", rss, link) { |href,mime,title,length|
      enclosure = enclosures.add(REXML::Element.new('enclosure'))
      enclosure.add(REXML::Element.new('href')).text = href
      enclosure.add(REXML::Element.new('mime')).text = mime
      enclosure.add(REXML::Element.new('title')).text = title
      enclosure.add(REXML::Element.new('length')).text = length
    }
    #p enclosures.to_s
    enclosures
  end
end


config = YAML::load File.new('config.yaml')
f = XSLTFunctions.new(DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password']))

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
