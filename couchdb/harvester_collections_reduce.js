function(key, values, rereduce)
{
  var all;

  if (rereduce)
  {
    all = [];
    for(var v in values)
      all = all.concat(values[v]);
  }
  else
    all = values;

  var feeds = {}, items = new Array(), collections = new Array();
  for(var a in all)
  {
    var ae = all[a];
    if (ae.type == "collection")
      collections.push(ae);
    else if (ae.type == "feed")
      feeds[ae.rss] = ae;
    else if (ae.type == "item")
      items.push(ae);
  }

  var unassoc_items = new Array();
  for(var i in items)
  {
    var item = items[i];
    if (feeds[item.rss])
    {
      var feed = feeds[item.rss];
      feed.items.push(item);
    }
    else
      unassoc_items.push(item);
  }

  var unassoc_feeds = new Array();
  for(var f in feeds)
  {
    var feed = feeds[f];
    var belongs_to_collection = false;
    for(var c in collections)
    {
      var collection = collections[c];
      if (collection.urls.indexOf(feed.rss) >= 0)
      {
	collection.feeds.push(feed);
	belongs_to_collection = true;
      }
    }
    if (!belongs_to_collection)
      unassoc_feeds.push(feed);
  }

  var result = collections;
  result = result.concat(unassoc_items);
  result = result.concat(unassoc_feeds);
  return result;
}