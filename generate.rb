#!/usr/bin/env ruby

require 'dbi'
require 'yaml'
require 'rexml/document'
require 'time'

class VarBinding < Hash
  def [](k)
    if k =~ /^snip\((.+),(\d+)\)$/
      var, length = $1, $2.to_i

      value = self[var]
      if value.size > length
        "#{value[0..length-3]}..."
      else
        value
      end
    elsif k=~ /^strip\((.+)\)$/
      value = self[$1]

      #puts "Strip:\n<<< #{value.inspect}\n>>> #{value.gsub(/<.+?>/, '').strip.inspect}"
      value.gsub(/<.+?>/, '').strip
    else
      super
    end
  end
end

BLOG_ATTR = %w(title link description)
ITEM_ATTR = %w(title link description date)

def escape(s)
  s.gsub(/&/, '&amp;').gsub(/"/, '&quot;').gsub(/</, '&lt;').gsub(/>/, '&gt;')
end

def parse_template_element(dbi, element, binding=VarBinding.new, attributes={})
  s = ''
  
  element.each { |child|
    if child.kind_of? REXML::Element
      
      if child.prefix == 'tmpl'
        case child.name
          when 'print'
            value = binding[child.attributes['var']]
            raise "Unbound variable #{child.attributes['var']}" unless value
            s += (child.attributes['escape'] == 'false' ? value : escape(value))
          when 'param'
            value = binding[child.attributes['var']]
            raise "Unbound variable #{child.attributes['var']}" unless value

            childattributes = attributes.merge({child.attributes['param'] => (child.attributes['escape'] == 'false' ? value : escape(value))})
            s += parse_template_element(dbi, child, binding, childattributes)
          when 'iter-blog'
            # Prepare query
            sorting = ''
            sorting_order = (child.attributes['reverse'] == 'true' ? 'DESC' : 'ASC')
            sorting = "ORDER BY LOWER(#{child.attributes['sort']}) #{sorting_order}" if BLOG_ATTR.include? child.attributes['sort']
            limit = "LIMIT #{child.attributes['max']}" if child.attributes['max'] =~ /^\d+$/

            blogs = dbi.execute "SELECT #{BLOG_ATTR.join(', ')} FROM sources WHERE collection=? #{sorting} #{limit}",
              child.attributes['collection']

            # Fetch row-by-row
            while row = blogs.fetch_hash do
              childbinding = binding.dup
              BLOG_ATTR.each { |column|
                childbinding[child.attributes[column]] = row[column].to_s if child.attributes[column]
              }
              s += parse_template_element(dbi, child, childbinding, attributes)
            end
          when 'iter-item'
            # Prepare query
            sorting = ''
            sorting_order = (child.attributes['reverse'] == 'true' ? 'DESC' : 'ASC')
            sorting = "ORDER BY LOWER(#{child.attributes['sort']}) #{sorting_order}" if ITEM_ATTR.include? child.attributes['sort']
            limit = "LIMIT #{child.attributes['max']}" if child.attributes['max'] =~ /^\d+$/
            blogcondition = 'AND sources.title LIKE ?'
            blog = '%'
            if child.attributes['blog']
              blogcondition = 'AND sources.title=?'
              blog = binding[child.attributes['blog']]
              raise "Unbound variable #{child.attributes['blog']}" unless blog
            end

            items = dbi.execute "SELECT #{ITEM_ATTR.collect{|a|'items.'+a}.join(', ')}, #{BLOG_ATTR.collect{|a|'sources.'+a+' AS blog'+a}.join(', ')} FROM items, sources WHERE items.rss=sources.rss AND sources.collection=? #{blogcondition} #{sorting} #{limit}",
              child.attributes['collection'], blog
            # Fetch row-by-row

            while row = items.fetch_hash
              childbinding = binding.dup
              ITEM_ATTR.each { |column|
                childbinding[child.attributes[column]] = (column == 'date' ?
                  row[column].to_time.strftime(binding['strftime'].to_s) :
                  row[column].to_s) if child.attributes[column]
              }
              childbinding[child.attributes['rssdate']] = row["date"].to_time.iso8601 if child.attributes['rssdate']
              BLOG_ATTR.each { |column2|
                column = "blog#{column2}"
                childbinding[child.attributes[column]] = row[column].to_s if child.attributes[column]
              }
              s += parse_template_element(dbi, child, childbinding, attributes)
            end
          else
            raise "Unknown template command: #{child.name}"
        end
        
      else
        childname = (child.prefix == '' ? child.name : "#{child.prefix}:#{child.name}")
        childattributes = attributes.collect { |k,v| " #{k}=\"#{v}\""}.to_s
        child.attributes.each { |k,v| childattributes += " #{k}=\"#{v}\""}
        #childattributes = attributes.merge(child.attributes).collect { |k,v| " #{k}=\"#{v}\"" }
        s += "<#{childname}#{childattributes}>" + parse_template_element(dbi, child, binding) + "</#{childname}>"
      end
      
    else
      s += child.to_s
    end
  }
  
  s
end


config = YAML::load File.new('config.yaml')
dbi = DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password'])

templatedir = config['settings']['templates']
outputdir = config['settings']['output']
Dir.foreach(templatedir) { |templatefile|
  next if templatefile =~ /^\./

  puts "Processing #{templatefile}"
  template = REXML::Document.new(File.new("#{templatedir}/#{templatefile}"))

  File.new("#{outputdir}/#{templatefile}", 'w').write parse_template_element(dbi, template, VarBinding.new.merge(config['vars']))
}
