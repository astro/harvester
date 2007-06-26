#!/usr/bin/env ruby

TABLE_SUBSCRIPTIONS = 'jabbersubscriptions'
TABLE_SETTINGS = 'jabbersettings'

require 'rubygems'
require 'dbi'
require 'yaml'
require 'xmpp4r'
require 'xmpp4r/discovery'
require 'xmpp4r/version'
require 'xmpp4r/roster'
require 'xmpp4r/dataforms'
require 'xmpp4r/vcard'

Jabber::debug = true

class ChatState
  def initialize(question, &block)
    @question = question
    @block = block
  end
end

class ChatDialog
  def initialize(&block)
    @sendblock = block
    @finished = false
    @state = nil
  end
  def set_state(question, &state)
    send question
    @state = state
  end
  def send(str)
    @sendblock.call str
  end
  def finished?
    @finished
  end
  def finish!
    @finished = true
  end
  def on_message(msg)
    @state.call msg
  end
end

class Interview < ChatDialog
  def initialize(dbi, user, collections, &block)
    raise 'No collections found!' unless collections.size > 0

    super(&block)
    @collections = collections
    @collections_keys = collections.keys

    set_state("Hello, I'm the Harvester Jabber service, aka AstroBot. " +
              "Type \"start\" to subscribe to feeds selectively.") { |msg|
      if msg == 'start'
        
        set_state("Should I respect your online status by sending you notifications only when you're online? Please notice that you need to grant authorization to receive presence updates from you in that case.") { |msg|
          if msg == 'yes' or msg == 'no'
            respect_status = (msg == 'yes')

            set_state("What type of message may I send to you? Valid answers are \"normal\", \"headline\" and \"chat\".") { |msg|
              if msg == 'normal' or msg == 'headline' or msg == 'chat'
                dbi.do "DELETE FROM #{TABLE_SETTINGS} WHERE JID=?", user
                dbi.do "INSERT INTO #{TABLE_SETTINGS} (jid, respect_status, message_type) VALUES (?, ?, ?)",
                  user, respect_status, msg
            
                collections_i = 0

                set_state(collection_question(collections_i)) { |msg|
                  if msg == 'yes' or msg == 'no'
                    puts "#{@collections_keys[collections_i]}: #{msg}"
                    dbi.execute "DELETE FROM #{TABLE_SUBSCRIPTIONS} WHERE jid=? AND collection=?", user, @collections_keys[collections_i]
                    if msg == 'yes'
                      dbi.do "INSERT INTO #{TABLE_SUBSCRIPTIONS} (jid, collection) VALUES (?, ?)", user, @collections_keys[collections_i]
                    end
                    
                    collections_i += 1
                    if collections_i < @collections.size
                      send collection_question(collections_i)
                    else
                      finish!
                      set_state('We\'ve done this interview. Talk to me if you want to repeat.') { |msg|
                      }
                    end
                  else
                    send 'I don\'t understand you. Please reply with either "yes" or "no".'
                  end
                }
              end
            }
          end
        }
      end
    }
  end

  def collection_question(i)
    if i >= @collections.size
      nil
    else
      "Do you want to receive updates to the collection \"#{@collections_keys[i]}\", which include " + 
        @collections[@collections_keys[i]].collect { |rss,title|
          title
        }.join(', ') + '? ("yes" or "no")'
    end
  end
end


def duration_to_s(duration)
  d = duration.to_i
  r = []
  while d >= 24 * 60 * 60
    r << "#{d / (24 * 60 * 60)} days"
    d %= 24 * 60 * 60
  end
  while d >= 60 * 60
    r << "#{d / (60 * 60)} hrs"
    d %= 60 * 60
  end
  while d >= 60
    r << "#{d / 60} min"
    d %= 60
  end
  (r.size > 0) ? r.join(', ') : 'no time'
end
  

config = YAML::load File.new('config.yaml')
collections = {}

dbi = DBI::connect(config['db']['driver'], config['db']['user'], config['db']['password'])


cl = Jabber::Client.new Jabber::JID.new(config['jabber']['jid'])
cl.on_exception { |e,|
  puts "HICKUP: #{e.class}: #{e}\n#{e.backtrace.join("\n")}"
  begin
    sleep 5
    cl.connect('::1')
    cl.auth config['jabber']['password']
  rescue
    sleep 10
    retry
  end
}
cl.connect('::1')
cl.auth config['jabber']['password']

Jabber::Version::SimpleResponder.new(cl, 'Harvester', '0.6', IO.popen('uname -sr') { |io| io.readlines.to_s.strip })

roster = Jabber::Roster::Helper.new(cl)
roster.add_subscription_request_callback { |item,presence|
  puts "Accepting subscription request from #{presence.from}"
  roster.accept_subscription(presence.from)

  roster.add(presence.from.strip, presence.from.node, true)
}

@chatdialogs = {}
@chatdialogs_lock = Mutex.new

cl.add_message_callback { |msg|
  puts "Message #{msg.type} from #{msg.from}: #{msg.body.inspect}"

  if msg.type == :chat and msg.body
    @chatdialogs_lock.synchronize {
      unless @chatdialogs.has_key? msg.from
        @chatdialogs[msg.from] = Interview.new(dbi, msg.from.strip.to_s, collections) { |str|
          cl.send Jabber::Message.new(msg.from, str).set_type(:chat)
        }
      else
        @chatdialogs[msg.from].on_message msg.body
      end

      @chatdialogs.delete_if { |jid,interview| interview.finished? }
    }
  end
}

cl.add_iq_callback { |iq|
  answer = iq.answer
  answer.type = :result

  command = answer.first_element('command')
  
  if iq.type == :get and iq.query.kind_of? Jabber::Discovery::IqQueryDiscoInfo
    if iq.query.node == 'config'
      answer.query.add Jabber::Discovery::Identity.new('automation', 'Configure subscriptions', 'command-node')
      [ 'jabber:x:data',
        'http://jabber.org/protocol/commands'].each { |feature|
          answer.query.add Jabber::Discovery::Feature.new(feature)
      }
    else
      answer.query.add Jabber::Discovery::Identity.new('headline', 'Harvester Jabber service', 'rss')
      [ Jabber::Discovery::IqQueryDiscoInfo.new.namespace,
        Jabber::Discovery::IqQueryDiscoItems.new.namespace,
        'http://jabber.org/protocol/commands'].each { |feature|
          answer.query.add Jabber::Discovery::Feature.new(feature)
      }
    end
  elsif iq.type == :get and iq.query.kind_of? Jabber::Discovery::IqQueryDiscoItems
    if iq.query.node == 'http://jabber.org/protocol/commands'
      answer.query.add Jabber::Discovery::Item.new(cl.jid, 'Configure subscriptions', 'config')
    else
      answer.query.add Jabber::Discovery::Item.new(cl.jid, 'Ad-hoc commands', 'http://jabber.org/protocol/commands')
    end
  elsif iq.type == :set and command and command.namespace == 'http://jabber.org/protocol/commands' and command.attributes['node'] == 'config'
    x = command.first_element('x')
    x = Jabber::Dataforms::XData.new.import(x) if x

    user = iq.from.strip.to_s

    if (x.nil? or x.type != :submit) and command.attributes['action'].nil?
      puts "#{iq.from} requested data form"
      command.attributes['status'] = 'executing'
      command.attributes['sessionid'] = Jabber::IdGenerator.instance.generate_id
      x = command.add(Jabber::Dataforms::XData.new(:form))
      x.add(Jabber::Dataforms::XDataTitle.new).text = 'Configure subscriptions'

      respect_status = x.add(Jabber::Dataforms::XDataField.new('respect-status', :boolean))
      respect_status.label = 'Respect your online status'
      message_type = x.add(Jabber::Dataforms::XDataField.new('message-type', :list_single))
      message_type.label = 'Message type of notifications'
      message_type.options = {'normal'=>'Normal message',
                              'chat'=>'Chat message',
                              'headline'=>'Headline message'}
      settings = dbi.execute "SELECT respect_status, message_type FROM #{TABLE_SETTINGS} WHERE jid=?", user
      while setting = settings.fetch
        respect_status.values = [(setting.shift ? '1' : '0')]
        message_type.values = [setting.shift]
      end

      collections.keys.sort.each { |collection|
        field = x.add(Jabber::Dataforms::XDataField.new("collection-#{collection}", :boolean))
        field.label = "Receive notifications for collection #{collection}"
        field.add(REXML::Element.new('desc')).text = collections[collection].collect { |rss,title| title }.join(', ')

        field.values = ['0']
        subscription = dbi.execute "SELECT jid FROM #{TABLE_SUBSCRIPTIONS} WHERE jid=? AND collection=?", user, collection
        while subscription.fetch
          field.values = ['1']
        end
      }
    else
      if x and x.type == :submit
        puts "#{iq.from} submitted data form"

        if x.field('respect-status') and x.field('message-type')
          respect_status = x.field('respect-status').values.include? '1'
          message_type = x.field('message-type').values.to_s

          dbi.do "DELETE FROM #{TABLE_SETTINGS} WHERE jid=?", user
          dbi.do "INSERT INTO #{TABLE_SETTINGS} (jid, respect_status, message_type) VALUES (?, ?, ?)",
            user, respect_status, message_type
        end

        x.each_element('field') { |f|
          if f.var =~ /^collection-(.+)$/
            collection = $1
            dbi.execute "DELETE FROM #{TABLE_SUBSCRIPTIONS} WHERE jid=? AND collection=?", user, collection
            if f.values.to_s == '1'
              dbi.do "INSERT INTO #{TABLE_SUBSCRIPTIONS} (jid, collection) VALUES (?, ?)", user, collection
            end
          end
        }

        command.delete_element 'x'
        command.attributes['status'] = 'completed'
        note = command.add(REXML::Element.new('note'))
        note.attributes['type'] = 'info'
        note.text = 'Thank you for making use of the advanced AstroBot configuration interface. You are truly worth being notified about all that hot stuff!'
      else
        # Do nothing, but send a result
        puts "#{iq.from} #{command.attributes['action']} data form"

        command.delete_element 'x'
        command.attributes['status'] = 'canceled'
      end
    end
  elsif iq.type == :get or iq.type == :get
    answer.type = :error
    answer.add Jabber::Error.new('feature-not-implemented', 'The requested feature hasn\'t been implemented.')
  else
    answer = ' '
  end

  cl.send answer
}

cl.send Jabber::Presence.new(:chat, 'The modern Harvester Jabber Service (Public Beta)')

messages_sent = 0
startup = Time.new
links = []
dbi.execute("SELECT link FROM last48hrs").each { |link,|
  links << link
}

chart_last_update = Time.at(0)
chart_filename = "#{config['settings']['output']}/chart.jpg"
avatar_hash = ""

loop {
  resend_presence = false

  ###
  # Update collections
  ###
  new_collections = Hash.new([])

  sources = dbi.execute "SELECT collection,rss,title FROM sources ORDER BY collection,title"
  while row = sources.fetch
    collection, rss, title = row
    new_collections[collection] += [[rss, title]]
  end
  
  collections = new_collections

  ###
  # Find new items
  ##
  # This fetches all items from the last 48 hours,
  # just to make sure to not miss anything due to
  # timezone overlaps and so on.
  ###
  new_links = []
  notifications = Hash.new([])
  items = dbi.execute "SELECT rss, blogtitle, title, link, collection FROM last48hrs"
  while row = items.fetch
    rss, blogtitle, title, link, collection = row

    unless links.include? link
      puts "New: #{link} (#{blogtitle}: #{title})"
      notifications[collection] += [[blogtitle, title, link]]

      resend_presence = true
    end
    
    new_links << link
  end

  notifications.keys.each { |collection|
    text = "Updates for #{collection}:"
    subject = []
    
    html = REXML::Element.new 'html'
    html.add_namespace 'http://jabber.org/protocol/xhtml-im'
    body = html.add REXML::Element.new('body')
    body.add_namespace 'http://www.w3.org/1999/xhtml'
    body.add(REXML::Element.new('h4')).text = "Updates for #{collection}"
    ul = body.add(REXML::Element.new('ul'))
    
    notifications[collection].each { |blogtitle, title, link|
      subject << blogtitle
      text += "\n#{blogtitle}: #{title}\n#{link}"

      li = ul.add(REXML::Element.new('li'))
      li.add REXML::Text.new("#{blogtitle}: ")
      a = li.add(REXML::Element.new('a'))
      a.attributes['href'] = link
      a.text = title
    }

    puts "#{Time.new} - #{text.inspect}"

    ##
    # Prepare subject
    subject.uniq!
    subject.sort! { |a,b| a.downcase <=> b.downcase }

    ##
    # Send for all who have subscribed
    subscriptions = dbi.execute "SELECT jid FROM #{TABLE_SUBSCRIPTIONS} WHERE collection=?", collection
    while row = subscriptions.fetch
      jid, = row

      respect_status = false
      message_type = :headline
      settings = dbi.execute "SELECT respect_status, message_type FROM #{TABLE_SETTINGS} WHERE jid=?", jid
      while setting = settings.fetch
        respect_status = setting.shift
        message_type = setting.shift.intern
      end
 
      if (respect_status and (roster[jid] ? roster[jid].online? : false)) or not respect_status
        msg = Jabber::Message.new
        msg.to, = jid
        msg.type = message_type
        msg.subject = subject.join', '
        msg.body = text
        msg.add html
        cl.send msg
      end

      messages_sent += 1
    end
  }

  links = new_links

  ##
  # Avatar
  ##
  if File::ctime(chart_filename) > chart_last_update
    chart_last_update = File::ctime(chart_filename)

    photo = IO::readlines(chart_filename).to_s
    avatar_hash = Digest::SHA1.new(photo).hexdigest
    vcard = Jabber::Vcard::IqVcard.new('NICKNAME' => 'Astrobot',
                                       'FN' => 'Harvester Jabber notification',
                                       'URL' => 'http://astroblog.spaceboyz.net/harvester/',
                                       'PHOTO/TYPE' => 'image/jpeg',
                                       'PHOTO/BINVAL' => Base64::encode64(photo))
    resend_presence = true
  end

  if resend_presence
    pres = Jabber::Presence.new(:chat,
                                "Sent #{messages_sent} messages in #{duration_to_s(Time.new - startup)}. Chewed #{links.size} feed items in the last 48 hours.")
    x = pres.add('x')
    x.add_namespace 'vcard-temp:x:update'
    x.add('photo').text = avatar_hash
    cl.send pres
  end

  ###
  # Loop
  ###
  print '.'; $stdout.flush
  sleep config['jabber']['interval'].to_i
}

