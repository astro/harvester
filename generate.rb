#!/usr/bin/env ruby

require 'dbi'
require 'yaml'
require 'rexml/document'
require 'xml/xslt'
require 'time'


class XSLTFunctions
  FUNC_NAMESPACE = 'http://astroblog.spaceboyz.net/harvester/xslt-functions'

  def initialize(dbi)
    @dbi = dbi
    %w(collection-items feed-items item-description).each { |func|
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

    root
  end

  def collection_items(collection, max=23)
    items = REXML::Element.new('items')
    @dbi.select_all("SELECT items.title,items.date,items.link,items.rss FROM items,sources WHERE items.rss=sources.rss AND sources.collection=? ORDER BY items.date DESC LIMIT ?", collection, max.to_i) { |title,date,link,rss|
      item = items.add(REXML::Element.new('item'))
      item.add(REXML::Element.new('title')).text = title
      item.add(REXML::Element.new('date')).text = date.to_time.xmlschema
      item.add(REXML::Element.new('link')).text = link
      item.add(REXML::Element.new('rss')).text = rss
    }

    items
  end

  def feed_items(rss, max=23)
    items = REXML::Element.new('items')
    @dbi.select_all("SELECT title,date,link FROM items WHERE rss=? ORDER BY date DESC LIMIT ?", rss, max.to_i) { |title,date,link|
      item = items.add(REXML::Element.new('item'))
      item.add(REXML::Element.new('title')).text = title
      item.add(REXML::Element.new('date')).text = date.to_time.xmlschema
      item.add(REXML::Element.new('link')).text = link
    }

    items
  end

  def item_description(rss, item_link)
    @dbi.select_all("SELECT description FROM items WHERE rss=? AND link=?", rss, item_link) { |desc,|
      return desc
    }
    ''
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
