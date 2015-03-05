# Description:
#   Queries Zendesk for information about support tickets
#
# Configuration:
#   HUBOT_ZENDESK_USER
#   HUBOT_ZENDESK_TOKEN
#   HUBOT_ZENDESK_SUBDOMAIN
#
# Commands:
#   hubot views - list all views available to ticketbot
#   hubot view (open|closed|hold|solved) <view name or id> - list all tickets with a view, optionally filtered by state
#   hubot ticket <number> - returns a ticket (hosted on S3).
#   hubot add_note <number> - add an internal note to a ticket

# TODO
# ====
#
# 1 - Silently upload tickets when comments are added
# 2 - Show view with filters
# 3 - Ticket Search
# 4 - Look for mentions of @ticketbot and send a loving message
# 5 - Monitor ticket updates and broadcast to #cf-support


global.Intl = require('intl') if !global.Intl?

zendesk = require 'node-zendesk'
_       = require 'underscore'
fs      = require 'fs'
hb      = require 'handlebars'
hb_intl = require 'handlebars-intl'
https   = require 'https'
knox    = require 'knox'
async   = require 'async'

zendesk_bot_user = 804361298

client = zendesk.createClient
  username:  process.env.HUBOT_ZENDESK_USER
  token:     process.env.HUBOT_ZENDESK_TOKEN
  remoteUri: "https://#{process.env.HUBOT_ZENDESK_SUBDOMAIN}.zendesk.com/api/v2"

client.users.showMany = (ids, cb) ->
  this.request 'GET', ['users', 'show_many', "?ids=#{ids}"], cb

templates =
  files: [
    "ticket.html"
    "comment.html"
    "ticket-lines.txt"
  ], templates: {}

expires = new Date()

async.each templates.files, (filename, callback) ->
  fs.readFile "./templates/#{filename}", "utf8", (err, data) ->
    return callback(err) if err?
    templates.templates[filename] = hb.compile data;

s3_client = knox.createClient
  key: process.env.S3_KEY
  secret: process.env.S3_SECRET
  bucket: "gss-zendesk-tickets"

hb_intl.registerWith hb
intl_data =
  locales: "en-US"

# set up services
services_json = process.env.VCAP_SERVICES

if services_json?
  vcap_services = JSON.parse(services_json)
  creds = vcap_services.rediscloud[0].credentials

  process.env.REDIS_URL= "redis://ticketbot:#{creds.password}@#{creds.hostname}:#{creds.port}/ticketbot"
  console.log process.env.REDIS_URL

String::truncate = (n) ->
  @substr(0, n - 1) + ((if @length > n then "&hellip;" else ""))

set_comment_author = (comment, callback) ->

  # look up comment authors
  client.users.show comment.author_id, (err, req, r) ->

    return callback(err) if err

    attachments = []

    comment.author = r

    _.each comment.attachments, (a) ->
      a.ticket_id = comment.ticket_id
      attachments.push a

    return callback(null, attachments);

upload_attachment = (attachment, callback) ->

  https.get attachment.content_url, (res) ->

    headers =
      'Content-Length': res.headers['content-length']
      'Content-Type': res.headers['content-type']

    key = "/attachments/#{attachment.ticket_id}/#{attachment.file_name}"

    s3_client.putStream res, key, headers, (err, res) ->
      # check `err`, then do `res.pipe(..)` or `res.resume()` or whatever.
      return callback err if err

    signed_url = s3_client.signedUrl key, expires
    attachment.signed_url = signed_url

    return callback(null)

send_message = (client, bot, channel, text, callback) ->

  params =
    channel: channel.id
    text: text
    username: bot.name
    icon_url: bot.profile.image_48
    as_user: true

  client._apiCall "chat.postMessage", params, (data) ->
    callback data.ts

update_message = (client, channel, ts, text, callback) ->

  params =
    ts: ts
    channel: channel.id
    text: text

  client._apiCall "chat.update", params, (data) ->
    callback data if callback?

delete_message = (client, channel, ts) ->

  params =
    ts: ts
    channel: channel.id

  client._apiCall "chat.delete", params

take_note = (robot, msg, note_callback) ->

  msg.reply "Okay, i'm listening... send me the word 'end' to finish or 'cancel' to cancel!"

  username = msg.message.user.name

  note =
    msg: []
    timestamp: new Date()
    callback: note_callback

  robot.brain.set "#{username}_note", note

upload_ticket = (ticket_id, upload_callback) -> # callback = (err, ticket)

  client.tickets.show ticket_id, (err, req, ticket) ->

    return upload_callback("I couldn't find ticket #{ticket_id}", null) if !ticket?

    expires = new Date()
    expires.setHours expires.getHours() + 48

    jobs = []
    comment_jobs = []

    # get comments for the ticket
    jobs.push (callback) ->
      client.tickets.getComments ticket_id, (err, req, comments) ->
        return callback(err) if err
        ticket.comments = comments[0].comments
        callback null, ticket.comments

    jobs.push (callback) ->
      client.users.show ticket.requester_id, (err, req, r) ->
        return callback err if err
        ticket.requester = r
        return callback(null, ticket)

    jobs.push (callback) ->
      client.users.show ticket.submitter_id, (err, req, r) ->
        return callback err if err
        ticket.submitter = r
        return callback(null, ticket)

    jobs.push (callback) ->
      client.users.show ticket.assignee_id, (err, req, r) ->
        return callback err if err
        ticket.assignee = r
        return callback(null, ticket)

    # run all pending jobs
    async.series jobs, (err, jobs_results) ->

      # if an error occurs at all
      if err
        msg.send "ERROR : #{err}"
        return

      _.each ticket.comments, (comment) ->
        comment.ticket_id = ticket.id

      async.map ticket.comments, set_comment_author, (err, attachments) ->

        attachments = _.flatten(attachments)

        async.each attachments, upload_attachment, (err) ->

          # if an error occurs at all
          if err
            msg.send "ERROR : #{err}"
            return

          html = templates.templates["ticket.html"] ticket,
            data:
              intl: intl_data

          req = s3_client.put "ticket_#{ticket_id}.html",
            'Content-Length': Buffer.byteLength(html)
            'Content-Type': 'text/html'

          req.on 'response', (res) ->

            return upload_callback("Upload failed", null) if res.statusCode <> 200

            console.log 'saved to %s', req.url
            return upload_callback(null, ticket)

          req.end html


wait = (client, bot, channel, text, callback) ->

  message = text

  stages = [
    'o____'
    '_o___'
    '__o__'
    '___o_'
    '____o'
    '___o_'
    '__o__'
    '_o___'
  ]

  i = 0
  display = "#{message}#{stages[i]}"

  jobs = [
    (callback) ->
  ]

  send_message client, bot, channel, display, (ts) ->

    interval = setInterval () ->

      display = "#{message}#{stages[i]}"
      i = i + 1
      i = 0 if i >= stages.length

      update_message client, channel, ts, display, (data) ->
    , 250

    callback interval, ts

module.exports = (robot) ->

  slack = robot.adapter.client
  bot = slack.getUserByName 'ticketbot' if slack?

  robot_re = new RegExp "^\@?#{robot.name}", "i"

  robot.hear /.+/i, (msg) ->

    return if msg.message.text.match robot_re

    username = msg.message.user.name
    note = robot.brain.get "#{username}_note"

    if note?
      note.msg.push msg.message.text
      robot.brain.set "#{username}_note", note

  robot.respond /(END|CANCEL)$/i, (msg) ->

    cancelled = msg.match[1].toLowerCase() == "cancel"

    username = msg.message.user.name
    note = robot.brain.get "#{username}_note"

    if note?
      robot.brain.set "#{username}_note", null
      note.callback note.msg.join("<br>\n"), cancelled

  robot.respond /take_note$/i, (msg) ->
    take_note robot, msg, (note, cancelled) ->

      unless cancelled
        console.log "output: \n"
        console.log note

  robot.respond /add_note ([\d]+)$/i, (msg) ->

    ticket_id = msg.match[1]
    username = msg.message.user.name

    channel = slack.getChannelGroupOrDMByName msg.envelope.message.room

    wait_interval = null
    wait_message_ts = null

    take_note robot, msg, (note, cancelled) ->

      if cancelled
        msg.reply "Comment cancelled!"
        return

      wait slack, bot, channel, "Please wait ", (interval, ts) ->
        wait_interval = interval
        wait_message_ts = ts

      client.tickets.show ticket_id, (err, req, ticket) ->

        if !ticket?
          clearInterval wait_interval
          update_message slack, channel, wait_message_ts, "I couldn't find ticket #{ticket_id}"
          return

        markup = templates.templates["comment.html"]
          author: msg.message.user
          content: note
        , data:
            intl: intl_data

        update =
          ticket:
            comment:
              author_id: zendesk_bot_user
              html_body: markup
              public: false

        client.tickets.update ticket.id, update, (err, req, ticket) ->
          clearInterval wait_interval
          update_message slack, channel, wait_message_ts, "Comment posted to #{ticket_id}"

  robot.respond /view (open|pending|hold|solved)?\s?(.+)$/i, (msg) ->

    channel = slack.getChannelGroupOrDMByName msg.envelope.message.room

    wait_interval = null
    wait_message_ts = null

    wait slack, bot, channel, "Please wait ", (interval, ts) ->
      wait_interval = interval
      wait_message_ts = ts

    state = msg.match[1]
    view_id = msg.match[2]

    jobs = [
      (tickets, callback) ->
        # filter and sort

        tickets = _.reject tickets, (t) -> t.status != state if state?
        requester_ids = _.map tickets, (t) -> t.requester_id

        client.users.showMany requester_ids.join(","), (err, req, users) ->
          return callback err if err?

          _.each tickets, (ticket) ->
            ticket.requester = _.find users, (user) -> user.id == ticket.requester_id

          callback null, tickets
    ]

    if isNaN(view_id)

      jobs.unshift (callback) ->

        client.views.listCompact (err, req, results) ->
          callback(err) if err
          view = _.find results, (view) -> view.title.toLowerCase() == view_id.toLowerCase()
          return callback("Couldn't find view '#{view_id}'") if !view?
          callback(null, view.id)

      , (id, callback) ->
        # retrieve tickets
        client.views.tickets id, (err, req, results) ->
          return callback(err) if err
          callback(null, results[0].tickets)

    else
      view_id = parseInt view_id

      jobs.unshift (callback) ->
        # retrieve tickets
        client.views.tickets view_id, (err, req, results) ->
          return callback(err) if err
          callback(null, results[0].tickets)

    async.waterfall jobs,
      (err, tickets) ->
        output = templates.templates["ticket-lines.txt"]
          tickets: tickets
        , data:
            intl: intl_data

        clearInterval wait_interval

        if err
          msg.send err
          delete_message slack, channel, wait_message_ts
        else
          update_message slack, channel, wait_message_ts, output


  robot.respond /views$/i, (msg) ->

    channel = slack.getChannelGroupOrDMByName msg.envelope.message.room

    wait_interval = null
    wait_message_ts = null

    wait slack, bot, channel, "Please wait ", (interval, ts) ->
      wait_interval = interval
      wait_message_ts = ts

    async.waterfall [
      (callback) ->
        client.views.listCompact (err, req, results) ->
          return callback(err) if err
          callback(null, results)
      , (views, callback) ->
        view_ids = _.map views, (v) ->
          return v.id

        client.views.showCounts view_ids.join(","), (err, req, counts) ->
          return callback(err) if err
          callback(null, views, counts.view_counts)
    ], (err, views, counts) ->
      output = null

      _.each views, (view) ->

        count = _.find counts, (c) ->
          c.view_id == view.id

        view.pretty_count = count.pretty

        output = _.map views, (v) ->
          "#{v.id} :- _#{v.title}_ *#{v.pretty_count} tickets*"

      clearInterval wait_interval

      if err
        console.log err
        delete_message slack, channel, wait_message_ts
      else
        update_message slack, channel, wait_message_ts, output.join("\n")

  robot.respond /ticket ([\d]+)$/i, (msg) ->

    ticket_id = msg.match[1]
    username = msg.message.user.name

    channel = slack.getChannelGroupOrDMByName msg.envelope.message.room

    wait_interval = null
    wait_message_ts = null

    wait slack, bot, channel, "Please wait ", (interval, ts) ->
      wait_interval = interval
      wait_message_ts = ts

    client.tickets.show ticket_id, (err, req, ticket) ->

      if !ticket?
        clearInterval wait_interval
        update_message slack, channel, wait_message_ts, "I couldn't find ticket #{ticket_id}"
        return

      expires = new Date()
      expires.setHours expires.getHours() + 48

      jobs = []
      comment_jobs = []

      # get comments for the ticket
      jobs.push (callback) ->
        client.tickets.getComments ticket_id, (err, req, comments) ->
          return callback(err) if err
          ticket.comments = comments[0].comments
          callback null, ticket.comments

      jobs.push (callback) ->
        client.users.show ticket.requester_id, (err, req, r) ->
          return callback err if err
          ticket.requester = r
          return callback(null, ticket)

      jobs.push (callback) ->
        client.users.show ticket.submitter_id, (err, req, r) ->
          return callback err if err
          ticket.submitter = r
          return callback(null, ticket)

      jobs.push (callback) ->
        client.users.show ticket.assignee_id, (err, req, r) ->
          return callback err if err
          ticket.assignee = r
          return callback(null, ticket)

      # run all pending jobs

      async.series jobs, (err, jobs_results) ->

        # if an error occurs at all
        if err
          msg.send "ERROR : #{err}"
          return

        _.each ticket.comments, (comment) ->
          comment.ticket_id = ticket.id

        async.map ticket.comments, set_comment_author, (err, attachments) ->

          attachments = _.flatten(attachments)

          async.each attachments, upload_attachment, (err) ->

            # if an error occurs at all
            if err
              msg.send "ERROR : #{err}"
              return

            html = templates.templates["ticket.html"] ticket,
              data:
                intl: intl_data

            req = s3_client.put "ticket_#{ticket_id}.html",
              'Content-Length': Buffer.byteLength(html)
              'Content-Type': 'text/html'

            req.on 'response', (res) ->

              if 200 == res.statusCode

                console.log 'saved to %s', req.url

                ticket_url = s3_client.signedUrl("ticket_#{ticket_id}.html", expires);

                robot.emit 'slack.attachment',
                  message: msg.message
                  content:
                    color: "#7CD197"
                    pretext: "Ticket requested by @#{username} "
                    text: "<#{ticket_url}|#{ticket.subject}> "
                    fields: [{
                      title: "Description"
                      value: ticket.description.truncate(200)
                    },{
                      title: "Created at"
                      value: ticket.created_at
                    },{
                      title: "Updated at"
                      value: ticket.updated_at
                    }]

              clearInterval wait_interval
              delete_message slack, channel, wait_message_ts

              return

            req.end html
