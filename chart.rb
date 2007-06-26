#!/usr/bin/ruby

require 'dbi'
require 'yaml'
require 'gruff'

config = YAML::load File.new('config.yaml')
timeout = config['settings']['timeout'].to_i
sizelimit = config['settings']['size limit'].to_i
dbi = DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password'])

class StatsPerCollection
  attr_reader :days

  def initialize
    @collections = {}
    @days = []
  end

  def add_one(collection, day)
    @days << day unless @days.index(day)

    c = @collections[collection] || {}
    c[day] = (c[day] || 0) + 1
    @collections[collection] = c
  end

  def each
    @collections.each { |n,c|
      v = []
      @days.each { |d|
        v << c[d].to_i
      }

      yield n, v
    }
  end
end

c = StatsPerCollection.new
dbi.select_all("select date(items.date) as date,sources.collection from items left join sources on sources.rss=items.rss where date > now() - interval '14 days' order by date") { |date,collection|
  c.add_one(collection, date.day)
}

g = Gruff::Line.new(400)
g.title = "Harvested items per day"

c.each(&g.method(:data))

labels = {}
c.days.each_with_index do |d,i|
  labels[i] = d.to_s
end
g.labels = labels

g.write("#{config['settings']['output']}/chart.jpg")


