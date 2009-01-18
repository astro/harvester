function(key, values, rereduce)
{
  log({"reduce": rereduce});
  var feeds = <feeds/>;
  if (rereduce)
  {
    for(var v in values)
    {
      var f = values[v];
      for(var ff in f)
      {
	feeds += f[ff];
      }
    }
  }
  else
  {
    for(var v in values)
    {
      feeds += new XML(values[v]);
    }
  }
  return feeds;
}