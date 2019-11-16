mongodb = require 'mongodb'
mod = {} # do not export
class mod.Connection_policy
  name    : ''
  collection: null
  parent  : null
  options : null
  _unset  : {}
  
  constructor : (@parent, @name, @options)->
    @collection = @parent.mongodb.collection @name
    @_unset = {}
    if @options.user_id
      old_format_where = @format_where
      @format_where = (data, socket)=>
        where = old_format_where data, socket
        where.user_id = socket.user_id
        where
      old_format_data = @format_data
      @format_data = (data, socket)=>
        data = old_format_data data, socket
        data.user_id = socket.user_id
        data
      old_format_output = @format_output
      @format_output = (data)->
        old_format_output data
        delete data.user_id
        return
  
  request : (data, socket)->
    response = 
      switch : "webnative"
      request_uid : data.request_uid
    if data.collection?
      if @name == '*'
        @collection = @parent.mongodb.collection data.collection
    switch data.request
      when "collection_list"
        await @parent.mongodb.listCollections().toArray defer(err, document_list)
        if err
          response.error = err.toString()
        else
          response.list = document_list.map((t)->t.name).filter (t)-> t != 'system.indexes'
      when "find"
        await @collection.find(@format_where(data, socket), data.column or {}).toArray defer(err, res)
        if err
          response.error = err.toString()
        else
          for v in res
            @format_output v
          response.list = res
      when "count"
        await @collection.count @format_where(data, socket), defer(err, count)
        if err
          response.error = err.toString()
        else
          response.count = count
      when "insert"
        await @collection.insert @format_data(data, socket), defer(err, res)
        if err
          response.error = err.toString()
        else
          response.list = res
        data.insert = res[0]
        @broadcast data, socket
      when "update"
        upd_hash = $set:@format_data(data, socket)
        upd_hash.$unset = @_unset if h_count @_unset
        await @collection.update @format_where(data, socket), upd_hash, {multi:true}, defer(err, res)
        if err
          response.error = err.toString()
        @broadcast data, socket
      when "save"
        if data.where
          await @collection.count @format_where(data, socket), defer(err, res)
          p res
          if err
            response.error = err.toString()
          else if res == 0
            ins_hash  = @format_where(data, socket)
            ins_hash2 = @format_data(data, socket)
            for k,v of ins_hash2
              ins_hash[k] = v
            await @collection.insert ins_hash, defer(err, res)
            if err
              response.error = err.toString()
            else
              response.list = res
          else
            upd_hash = $set:@format_data(data, socket)
            upd_hash.$unset = @_unset if h_count @_unset
            await @collection.update @format_where(data, socket), upd_hash, defer(err, res)
            p err
            p res
            response.error = err.toString() if err
        else if !data.hash._id
          await @collection.insert @format_data(data, socket), defer(err, res)
          if err
            response.error = err.toString()
          else
            response.list = res
        else
          data.where =
            _id : data.hash._id
          delete data.hash._id
          upd_hash = $set:@format_data(data, socket)
          upd_hash.$unset = @_unset if h_count @_unset
          await @collection.update @format_where(data, socket), upd_hash, defer(err, res)
          response.error = err.toString() if err
        @broadcast data, socket
      when "delete", "remove"
        await @collection.remove @format_where(data, socket), defer(err, res)
        if err
          response.error = err.toString()
    socket.write response
  
  # default
  fix_oid : (ret)->
    if ret._id
      ret._id = new mongodb.ObjectID ret._id
    for k,v of ret
      if /_oid$/.test k
        ret[k] = new mongodb.ObjectID v if v
    ret
  
  format_where : (data, socket)->
    ret = data.where
    @fix_oid ret
    ret
  
  format_data : (data, socket)->
    @_unset = _unset = {}
    ret = data.hash
    walk = (t, path)->
      return t if typeof t != 'object'
      max_idx = path.length
      if t instanceof Array
        path.push ""
        for v,idx in t
          path[max_idx] = idx
          walk v, path
        path.pop()
        return
      
      max_idx = path.length
      path.push ""
      for k,v of t
        path[max_idx] = k
        if v?.$undefined?
          delete t[k]
          _unset[path.join "."] = ""
          continue
        walk v, path
      path.pop()
      return
    
    walk data.hash, []
    @fix_oid ret
    ret
  
  format_output : (data)->
    data
  
  broadcast : (data, miss_connection)->
    return if !data.hash?.broadcast
    _id = data.where?._id or data.hash?._id or data.insert?.insertedIds[0]
    p data
    return if !_id?
    @parent.broadcast {
      switch    : "webnative_broadcast"
      collection: data.collection
      _id
    }, miss_connection
    return

class Webnative
  primus  : null
  ws      : null
  mongodb : null
  allow_collection_hash : {}
  
  constructor : ()->
    @allow_collection_hash = {}
  
  connect_ws: (@ws)->
    @ws.on 'connection', (socket)=>
      # adapter
      socket.write = (t)->socket.send JSON.stringify t
      socket.on "message", (message)=>
        data = JSON.parse message
        return if data.switch != 'webnative'
        collection_policy = @allow_collection_hash[data.collection] or @allow_collection_hash['*']
        
        
        if !collection_policy
          return socket.write
            switch      : "webnative"
            request_uid : data.request_uid
            error       : "collection not allowed to read"
        collection_policy.request data, socket
        
  
  connect_primus: (@primus)->
    @primus.on 'connection', (socket)=>
      socket.on 'data', (data)=>
        return if data.switch != 'webnative'
        collection_policy = @allow_collection_hash[data.collection] or @allow_collection_hash['*']
        if !collection_policy
          return socket.write
            switch      : "webnative"
            request_uid : data.request_uid
            error       : "collection not allowed to read"
        collection_policy.request data, socket
    @
  
  connect_mongodb : (@mongodb)->
    @
  
  allow_collection: (collection, options={})->
    if collection instanceof Array
      for v in collection
        @allow_collection v
      return @
    cp = new mod.Connection_policy @, collection, options
    @allow_collection_hash[collection] = cp
    return @
  
  broadcast : (msg, miss_connection)->
    p "broadcast", msg
    @ws.clients.forEach (con)-> # FUCK ws@2.2.0
      return if con == miss_connection
      con.write msg
      return
    return
      

module.exports = Webnative