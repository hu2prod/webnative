#!/usr/bin/env iced
require 'fy'
tic()
puts new Date
# ###################################################################################################
#    fast config
port = 44444 # choose jour port
db   = 'your_app_name'
# ###################################################################################################

process.on 'uncaughtException', (err) ->
  p err
  p err.stack

mongodb = require 'mongodb'
http  = require 'http'
WebSocketServer = require('ws').Server
Webnative = require 'webnative'

# ###################################################################################################
version_id = Date.now()
_dbserver = new mongodb.Server 'localhost', 27017
_db = new mongodb.Db db, _dbserver, w:1
await _db.open defer(err, db); throw err if err

# ###################################################################################################
ws = new WebSocketServer {port}
ws.on 'connection', (socket)-> # DEBUG mode
  socket.on "message", (message)->
    p JSON.parse message

wn = new Webnative
wn.connect_ws ws
wn.connect_mongodb db
wn.allow_collection "*"

puts "started in #{toc()} s"