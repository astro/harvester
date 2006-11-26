create table sources (
  collection varchar(256) not null,
  rss varchar(256) not null,
  last varchar(40),
  title varchar(256),
  link varchar(256),
  description text,
  unique (collection, rss)
);

create table items (
  rss varchar(256) not null,
  title varchar(256),
  link varchar(256),
  date timestamp,
  description text,
  unique (rss, link)
);

create view last48hrs as select items.rss, items.title, items.link, sources.title as blogtitle, sources.collection from items, sources where items.rss = sources.rss and now() - interval '48 hour' < items.date order by date;

create table jabbersubscriptions (
  jid varchar(256) not null,
  collection varchar(256) not null,
  unique (jid, collection)
);

create table jabbersettings (
  jid varchar(256) primary key,
  respect_status boolean,
  message_type varchar(16)
);
