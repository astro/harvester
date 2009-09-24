require 'dbi'

module DB
  def self.init!(driver, user, password)
    $dbi = DBI::connect(driver, user, password)
    #$dbi['AutoCommit'] = false
  end

  def self.get_collection_source_exist_and_last(collection, url)
    db_url, last = $dbi.select_one("SELECT rss, last FROM sources WHERE collection=? AND rss=?", collection, url)
    yield db_url ? true : false, last
  end


  def self.update_by_mrss(collection, rss_url, rss, last_modified=nil, is_new=false)
    # Update source
    if is_new
      do_ "INSERT INTO sources (collection, rss, last, title, link, description) VALUES (?, ?, ?, ?, ?, ?)",
      collection, rss_url, last_modified, rss.title, rss.link, rss.description
      puts "#{rss_url}\tSource added"
    else
      do_ "UPDATE sources SET last=?, title=?, link=?, description=? WHERE collection=? AND rss=?",
      last_modified, rss.title, rss.link, rss.description, collection, rss_url
      puts "#{rss_url}\tSource updated"
    end

    items_new, items_updated = 0, 0
    rss.items.each { |item|
      description = item.description
      
      # Link mangling
      begin
        link = URI::join((rss.link.to_s == '') ? uri.to_s : rss.link.to_s, item.link || rss.link).to_s
      rescue URI::Error
        link = item.link
      end

      # Push into database
      db_title = $dbi.select_one "SELECT title FROM items WHERE rss=? AND link=?", rss_url, link
      item_is_new = db_title.nil?

      if item_is_new
        begin
          do_ "INSERT INTO items (rss, title, link, date, description) VALUES (?, ?, ?, ?, ?)",
          rss_url, item.title, link, item.date, description
          items_new += 1
        rescue $DBI::ProgrammingError
          puts description
          puts "#{$!.class}: #{$!}\n#{$!.backtrace.join("\n")}"
        end
      else
        do_ "UPDATE items SET title=?, description=? WHERE rss=? AND link=?",
        item.title, description, rss_url, link
        items_updated += 1
      end

      # Remove all enclosures
      do_ "DELETE FROM enclosures WHERE rss=? AND link=?", rss_url, link
      # Re-add all enclosures
      item.enclosures.each do |enclosure|
        href = URI::join((rss.link.to_s == '') ? link.to_s : rss.link.to_s, enclosure['href']).to_s
        do_ "INSERT INTO enclosures (rss, link, href, mime, title, length) VALUES (?, ?, ?, ?, ?, ?)",
        rss_url, link, href, enclosure['type'], enclosure['title'], enclosure['length']
      end
    }
    puts "#{rss_url}\tNew: #{items_new} Updated: #{items_updated}"
  end

  def self.do_(query, *params)
    query_parts = query.split('?')
    query = ''
    params = params.select do |param|
      if param.nil?
        query << query_parts.shift + 'NULL'
        false
      else
        query << query_parts.shift + '?'
        true
      end
    end
    query << query_parts.join('?')

    $dbi.do query, *params
  end
end
