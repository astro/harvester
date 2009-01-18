function(key, values, rereduce)
{
  var flatten = function(flatten, a)
  {
    var r = [];
    for(var i in a)
    {
      var v = a[i];
      if (v["type"])
	r.push(v);
      else
	r = r.concat(flatten(flatten, v));
    }
    return r;
  };
  values = flatten(flatten, values);

  log({"values": values.length});
  var feeds = {}, items = [];

  /* Fill feeds dict and items array from all values */
  for(var v in values)
  {
    var value = values[v];
    if (value["type"] == "feed")
      feeds[value["rss"]] = value;
    else
      items.push(value);
  }
  log({"items": items.length});

  /* Append items to feeds or put into unassoc_items */
  var unassoc_items = [];
  for(var i in items)
  {
    var item = items[i];
    if (feeds[item["rss"]])
    {
      var feed = feeds[item["rss"]];
      if (feed["items"] == null)
	feed["items"] = [];
      feed["items"].push(item);
    }
    else
      unassoc_items.push(item);
  }
  log({"unassoc_items": unassoc_items.length});

  /* Return unassoc_items and feeds */
  var res = unassoc_items;
  for(var f in feeds)
  {
    res.push(feeds[f]);
  }
  return res;
}