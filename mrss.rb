# Magic RSS
# Helps getting around with RSS while ignoring standards and tolerating much

$KCODE = "UTF-8"

require 'rexml/document'
require 'cgi'
require 'iconv'

# Search macros
class REXML::Element
  def s(expr)
    each_element(expr) { |e| return e }
    nil
  end

  def s_text(expr)
    if (e = s(expr))
      (e.cdatas.size > 0) ? e.cdatas.to_s : e.text
    else
      nil
    end
  end

  def s_attr(expr, attr)
    (e = s(expr)) ? e.attributes[attr] : nil
  end

  def atom_content(expr)
    e = s(expr)
    if e
      type = e.attributes['type']
      mode = e.attributes['mode']

      if type == 'xhtml' or mode == 'xml'
        e.children.to_s
      elsif type == 'html' or mode == 'escaped'
        if e.cdatas.size > 0
          e.cdatas.to_s
        else
          e.text
        end
      else # 'text'
        if e.cdatas.size > 0
          CGI::escapeHTML(e.cdatas.to_s)
        else
          CGI::escapeHTML(e.text.to_s)
        end
      end
    else
      nil
    end
  end

  def atom_content_text(expr)
    c = atom_content(expr)
    if c
      c.gsub!(/<.+?>/, '')
      CGI::unescapeHTML(c)
    else
      nil
    end
  end

  def atom_link
    link, rank = 0, 0

    each_element('link') do |e|
      rel = e.attributes['rel']
      type = e.attributes['type']

      e_rank = (rel == 'alternate' ? 2 : 1) *
        (rel == 'enclosure' ? 0 : 1) *
        ((type == 'text/html' ? 2 : 0) +
         (type == 'application/xhtml+xml' ? 1 : 0) +
         1)

      if e_rank > rank
        link = e.attributes['href']
        rank = e_rank
      end
    end

    link
  end
end

class AbstractMethod < RuntimeError; end

class MRSS
  def initialize(root)
    @root = root
  end

  # Common properties
  def items
    res = []

    @root.each_element(items_expr) do |i|
      item = self.class::Item.new(i)

      res << item unless item.title.to_s == '' and item.link.to_s == ''
    end

    res
  end

  # Abstract stuff
  def title
    raise AbstractMethod.new
  end

  def type
    raise AbstractMethod.new
  end

  def link
    raise AbstractMethod.new
  end

  def description
    raise AbstractMethod.new
  end

  def feed_expr
    raise AbstractMethod.new
  end

  def items_expr
    raise AbstractMethod.new
  end

  # Item

  class Item
    def initialize(e)
      @e = e
    end
    def title
      raise AbstractMethod.new
    end
    def link
      raise AbstractMethod.new
    end
    def description
      raise AbstractMethod.new
    end
    def date
      raise AbstractMethod.new
    end
    def enclosures
      raise AbstractMethod.new
    end
  end

  # Flavours

  # RSS 0.9 & 2.0
  class RSS < MRSS
    def title
      @root.s_text "#{feed_expr}/title"
    end
    def feed_expr
      "/rss/channel"
    end
    def items_expr
      "/rss/channel/item"
    end
    def link
      @root.s_text "#{feed_expr}/link"
    end
    def description
      @root.s_text "#{feed_expr}/description"
    end

    class Item < ::MRSS::Item
      def title
        @e.s_text "title"
      end
      def link
        @e.s_text "link"
      end
      def description
        @e.s_text("content:encoded") ||
          @e.s_text("encoded") ||
          @e.s_text("description")
      end
      def date
        d = @e.s_text('date') || @e.s_text('pubDate') || @e.s_text('dc:date')
        d.to_s.detect_time.localtime
      end
      def enclosures
        r = []
        @e.each_element('enclosure') do |e|
          h = {
            'href' => e.attributes['url'],
            'type' => e.attributes['type'],
            'title' => e.attributes['title'],
            'length' => e.attributes['length']
          }
          r << h
        end
        r
      end
    end
  end

  # RSS 1.0
  class RDF < RSS
    def feed_expr
      "/*/channel"
    end
    def items_expr
      "/*/item"
    end
  end

  # ATOM 0.3 & 1.0
  class ATOM < MRSS
    def feed_expr
      "/feed"
    end
    def items_expr
      "/feed/entry"
    end
    def title
      @root.atom_content_text "title"
    end
    def link
      @root.atom_link
    end
    def description
      @root.atom_content_text('tagline') ||
        @root.atom_content_text('subtitle')
    end

    class Item < ::MRSS::Item
      def title
        @e.atom_content_text "title"
      end
      def link
        @e.atom_link
      end
      def description
        @e.atom_content("content") ||
          @e.atom_content("summary")
      end
      def date
        d = @e.s_text('published') || @e.s_text('issued') || @e.s_text('updated')
        d.to_s.detect_time.localtime
      end
      def enclosures
        r = []
        @e.each_element("link") do |e|
          if e.attributes['rel'] == 'enclosure'
            h = {
              'href' => e.attributes['href'],
              'type' => e.attributes['type'],
              'title' => e.attributes['title'],
              'length' => e.attributes['length']
            }
            r << h
          end
        end
        r
      end
    end
  end


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

    k = case xml.name
        when 'rss'
          RSS
        when 'rdf'
          RDF
        when 'RDF'
          RDF
        when 'feed'
          ATOM
        else
          raise "Unknwon feed format: #{xml.name} (#{xml.namespace})"
        end
    k.new(xml)
  end
end

class String
  def detect_time
    s = self
    tz_offset = 0

    # Fix it up
    s.strip!

    s.scan(/([\+\-])(\d\d):?(\d\d)$/).each do |plus_minus,hours,minutes|
      tz_offset = ((hours.to_i * 60) + minutes.to_i) * 60
      tz_offset *= (plus_minus == '+') ? -1 : 1
    end

    # 2004-04-01T21:23+00:00
    # 2004-09-05T21:23Z
    s.scan(/^(\d+)-(\d+)-(\d+)T(\d+):(\d+)/).each do |y,mo,d,h,m|
      return Time.gm(y.to_i, mo.to_i, d.to_i, h.to_i, m.to_i) + tz_offset
    end

    # 2004-04-01T21:23:23+00:00
    s.scan(/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\+(\d+):(\d+)$/).each do |y,mo,d,h,m,s,tz_h,tz_m|
      return Time.gm(y.to_i, mo.to_i, d.to_i, h.to_i, m.to_i, s.to_i) + tz_offset
    end

    # Wed, 20 Apr 2005 19:38:15 +0200
    # Fri, 22 Apr 2005 10:31:12 GMT
    months = {"Jan" => 1, "Feb" => 2, "Mar" => 3, "Mär" => 3, "Apr" => 4, "May" => 5, "Mai" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Okt" => 10, "Nov" => 11, "Dec" => 12, "Dez" => 12 }
    s.scan(/^(.+?), +(\d+) (.+?) (\d+) (\d+):(\d+):(\d+) /).each do |wday,d,mo,y,h,m,s|
      return Time.gm(y.to_i, months[mo], d.to_i, h.to_i, m.to_i, s.to_i) + tz_offset
    end

    # 06 May 2007 02:20:00
    s.scan(/^(\d+) (.+?) (\d{4}) (\d\d):(\d\d):(\d\d)/).each do |d,mo,y,h,m,s|
      return Time.gm(y.to_i, months[mo], d.to_i, h.to_i, m.to_i, s.to_i) + tz_offset
    end

    Time.new
  end
end
