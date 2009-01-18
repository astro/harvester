#!/usr/bin/env ruby

require 'yaml'
require 'couchdb'


config = YAML::load File.new('config.yaml')
CouchDB::setup config['couchdb']['url'], config['couchdb']['db']

CouchDB::transaction do |couchdb|
  begin
    couchdb[''] = {}
  rescue
    if $!.to_s == 'Net::HTTPConflict'
      puts "Database already exists"
    else
      raise
    end
  end

  views = {}
  Dir.foreach('couchdb') do |f|
    if f =~ /^(.+?)_(.+?)_(.+).js$/
      name = $1
      view = $2
      method = $3
      views[name] ||= {}
      views[name][view] ||= {}
      views[name][view][method] = IO::readlines("couchdb/#{f}").to_s
    end
  end

  views.each { |name,view|
    couchdb["_design/#{name}"] = {
      'language' => 'javascript',
      'views' => view
    }
  }
end
