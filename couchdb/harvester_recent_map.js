function(doc)
{
  if (doc.type == "item")
  {
    emit(doc._id, {"_id": doc._id,
                   "type": "item",
		   "rss": doc.rss,
		   "date": doc.date});
  }
}
