function(key, values, rereduce)
{
  Number.prototype.z = function(digits)
  {
    var s = this.toString();
    while(s.length < digits)
      s = "0" + s;
    return s;
  };

  /* Build up items from input */
  var items;
  if (rereduce)
  {
    items = [];
    for(var v in values)
      items = items.concat(values[v]);
  }
  else
    items = values;

  /* Convert dates to milliseconds since 1970 */
  items = items.map(function(item)
		    {
		      var d = /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/.exec(item.date);
		      if (d)
		      {
			var di = d.map(function(s) {
					 return new Number(s);
				       });
			var date = new Date(di[1], di[2], di[3], di[4], di[5], di[6]);
			item.date = date.getTime();
			return item;
		      }
		      else
			return false;
		    });
  items = items.filter(function(item)
		       {
			 return (item != false);
		       });

  /* Sort by date desc */
  items = items.sort(function(item1, item2)
		     {
		       if (item1.date > item2.date)
			 return -1;
		       else if (item1.date < item2.date)
			 return 1;
		       else
			 return 0;
		     });

  /* Kick old items */
  var MAX_AGE = 2 * 24 * 60 * 60 * 1000;
  var newest = items[0].date;
  var min_date = newest - MAX_AGE;
  items = items.filter(function(item)
		       {
			 return (item.date >= min_date);
		       });
   /* Convert dates back to strings */
  items = items.map(function(item)
		    {
		      var date = new Date(item.date);
		      item.date = date.getFullYear() +
				    "-" +
				    date.getMonth().z(2) +
				    "-" +
				    date.getDay().z(2) +
				    "T" +
				    date.getHours().z(2) +
				    ":" +
				    date.getMinutes().z(2) +
				    ":" +
				    date.getSeconds().z(2);
		      return item;
		    });
  return items;
}