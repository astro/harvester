function(doc)
{
  if (doc.type == "feed")
  {
    emit(doc.rss, doc);
  }
  else if (doc.type == "item")
  {
    doc["description"] = null;
    emit([doc.rss, doc.link], doc);
  }
}
