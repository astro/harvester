function(doc)
{
  if (doc.type == "collection")
  {
    emit(doc._id, {"_id": doc._id,
		   "type": "collection",
		   "urls": doc.urls,
		   "feeds": []});
  }
  else if (doc.type == "feed")
  {
    emit(doc._id, {"_id": doc._id,
		   "type": "feed",
		   "rss": doc.rss,
		   "items": []});
  }
  else if (doc.type == "item")
  {
    emit(doc._id, {"_id": doc._id,
		   "type": "item",
		   "rss": doc.rss,
		   "date": doc.date});
  }
}
