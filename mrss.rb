# Magic RSS
# Helps getting around with RSS while ignoring standards and tolerating much

require 'rexml/document'
require 'cgi'
require 'iconv'

class MRSS
  attr_reader :type, :title, :link, :description, :items
  def self.parse(body)
    begin
      xml = REXML::Document.new(body).root
    rescue REXML::ParseException
      xml = REXML::Document.new(Iconv::iconv('UTF-8', 'ISO-8859-15', body).to_s).root
    end

    begin
      # Try to validate UTF-8
      Iconv::iconv('UTF-8', 'UTF-8', xml.to_s).to_s
    rescue Iconv::IllegalSequence, Iconv::InvalidCharacter
      xml = REXML::Document.new(Iconv::iconv('UTF-8', 'ISO-8859-15', body).to_s).root
    end

    new xml
  end

  def initialize(xml)
    @type = nil
    @title = ""
    @link = ""
    @description = ""
    @items = []

    if xml.name == "rss"
      @type = :rss
      toplevel = "//*/channel/*"
      items = "//*/item"
    elsif xml.name == "RDF"
      @type = :rdf
      toplevel = "//*/channel/*"
      items = "//*/item"
    elsif xml.name == "feed"
      @type = :atom
      toplevel = "//feed/*"
      items = "//*/entry"
    end

    xml.elements.each(toplevel) do |e|
      if e.name == "title"
        @title = e.text
      end

      if @type == :atom
        if e.name == "link"
          # better something than nothing
          @link = e.attributes["href"] unless @link
          # better text/html
          if ['text/html', 'application/xhtml+xml'].include? e.attributes["type"]
            @link = e.attributes["href"]
          end
        end
        if e.name == "tagline"
          @description = e.text
        end
      else
        case e.name
          when "link" then @link = e.text
          when "description" then @description = e.text
        end
      end
    end

    xml.elements.each(items) do |e|
      @items.push(MRSSItem.new(e, @type))
    end

    # Remove any meaningless items
    @items.delete_if do |item|
      item.title == '' and item.link == ''
    end
  end
end

class MRSSItem
  attr_reader :title, :link, :description, :date

  def initialize(ele, type)
    @title = ""
    @link = ""
    @description = ""
    @date = Time.new

    ele.elements.each do |e|

      # Compat hacks:
      e.name.sub!(/^encoded$/, 'description')
      e.name.sub!(/^pubDate$/, 'date')
      e.name.sub!(/^issued$/, 'date') # ATOM 0.3
      e.name.sub!(/^published$/, 'date') # ATOM 1.0
      e.name.sub!(/^updated$/, 'date') # ATOM 1.0

      case e.name
        when "title" then @title = e.text
        when "date" then @date = detect_time(e.text)
      end

      if type == :atom
        if e.name == "link"
          @link = e.attributes["href"]
        end

        if e.name == "content"
          if e.cdatas.size() > 0
            @description = e.cdatas.to_s
          else
            @description = e.children.to_s # for ATOM 1.0, e.text isn't quite it
          end
        end
      else
        case e.name
          when "link" then @link = e.text
          # Always take longest description
          when "description" then @description = e.text if @description.to_s.size < e.text.to_s.size
        end
      end
    end

    # If, for some reason, we still have funny escaped HTML in @description
    # which is not what the author meant it to be, we might deal with a b0rken
    # RSS/Atom feed. Or we're just lazy to check the specs for all those
    # RSS and Atom formats, which might just be the case as well.

    if detect_escaped_html(@description)
      @description = CGI.unescapeHTML(@description)
    end
  end

  def detect_escaped_html(t)
    # We might want to have better heuristics here in the future.
    t.match(/^\s*&lt;p/) || t.match(/^\s*&#60;p/)
  end

  def detect_time(s)
    # Fix it up
    s.strip!

    # 2004-04-01T21:23+00:00
    # 2004-09-05T21:23Z
    s.scan(/^(\d+)-(\d+)-(\d+)T(\d+):(\d+)/).each do |y,mo,d,h,m|
      return Time.local(y.to_i, mo.to_i, d.to_i, h.to_i, m.to_i)
    end

    # 2004-04-01T21:23:23+00:00
    s.scan(/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\+(\d+):(\d+)$/).each do |y,mo,d,h,m,s,tz_h,tz_m|
      return Time.local(y.to_i, mo.to_i, d.to_i, h.to_i, m.to_i, s.to_i)
    end

    # Wed, 20 Apr 2005 19:38:15 +0200
    # Fri, 22 Apr 2005 10:31:12 GMT
    months = {"Jan" => 1, "Feb" => 2, "Mar" => 3, "Mär" => 3, "Apr" => 4, "May" => 5, "Mai" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Okt" => 10, "Nov" => 11, "Dec" => 12, "Dez" => 12 }
    s.scan(/^(.+?), +(\d+) (.+?) (\d+) (\d+):(\d+):(\d+) /).each do |wday,d,mo,y,h,m,s|
      return Time.local(y.to_i, months[mo], d.to_i, h.to_i, m.to_i, s.to_i)
    end

    Time.new
  end
end
