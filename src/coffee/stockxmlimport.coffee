_ = require 'underscore'
Csv = require 'csv'
{InventoryUpdater} = require 'sphere-node-sync'
package_json = require '../package.json'
xmlHelpers = require '../lib/xmlhelpers'

class StockXmlImport extends InventoryUpdater

  CHANNEL_KEY = 'expectedStock'
  CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

  constructor: (options = {}) ->
    options.user_agent = "#{package_json.name} - #{package_json.version}" unless _.isEmpty options
    super(options)

  elasticio: (msg, cfg, cb, snapshot) ->
    if _.size(msg.attachments) > 0
      console.log 'elasticio XML mode'
      for attachment of msg.attachments
        continue unless attachment.match /xml$/i
        content = msg.attachments[attachment].content
        continue unless content
        xmlString = new Buffer(content, 'base64').toString()
        @run xmlString, 'XML', cb
    else if _.size(msg.body) > 0
      console.log 'elasticio CSV mode'
      queryString = 'where=' + encodeURIComponent("sku=\"#{msg.body.SKU}\"")
      @initMatcher(queryString).then (existingEntry) =>
        console.log "Query for sku '#{msg.body.SKU}' result: %j", existingEntry
        if msg.body.CHANNEL_KEY
          @ensureChannelByKey(@rest, msg.body.CHANNEL_KEY, CHANNEL_ROLES)
          .then (channel) =>
            @createOrUpdate([@createInventoryEntry(msg.body.SKU, msg.body.QUANTITY, msg.body.EXPECTED_DELIVERY, channel.id)], cb)
          .fail (msg) => @returnResult false, msg, cb
        else
          @createOrUpdate([@createInventoryEntry(msg.body.SKU, msg.body.QUANTITY, msg.body.EXPECTED_DELIVERY, msg.body.CHANNEL_ID)], cb)
      .fail (msg) => @returnResult false, msg, cb
      .done()
    else
      @returnResult false, 'No data found in elastic.io msg.', cb

  run: (fileContent, mode, callback) ->
    throw new Error 'String required' unless _.isString fileContent
    throw new Error 'Callback must be a function' unless _.isFunction callback

    if mode is 'XML'
      @performXML fileContent, callback
    else if mode is 'CSV'
      @performCSV fileContent, callback
    else
      throw new Error "Unknown stock import mode '#{mode}'!"

  performCSV: (fileContent, callback) ->
    Csv().from.string(fileContent)
    .to.array (data, count) =>
      header = data[0]
      stocks = @_mapStockFromCSV _.rest data
      @_perform stocks, callback
    .on 'error', (error) =>
      @returnResult false, error.message, callback

  _perform: (stocks, callback) ->
    console.log 'Stock entries to process: ', _.size(stocks)
    @initMatcher().then (result) =>
      @createOrUpdate stocks, callback
    .fail (msg) =>
      @returnResult false, msg, callback
    .done()

  _mapStockFromCSV: (rows, skuIndex = 0, quantityIndex = 1) ->
    _.map rows, (row) =>
      sku = row[skuIndex]
      quantity = row[quantityIndex]
      @createInventoryEntry sku, quantity

  performXML: (fileContent, callback) ->
    xmlHelpers.xmlTransform xmlHelpers.xmlFix(fileContent), (err, result) =>
      if err
        @returnResult false, "Error on parsing XML: #{err}", callback
      else
        @ensureChannelByKey(@rest, CHANNEL_KEY, CHANNEL_ROLES).then (channel) =>
          stocks = @_mapStockFromXML result.root, channel.id
          @_perform stocks, callback
        .fail (msg) =>
          @returnResult false, msg, callback
        .done()

  _mapStockFromXML: (xmljs, channelId) ->
    stocks = []
    return stocks unless xmljs.row
    for row in xmljs.row
      sku = xmlHelpers.xmlVal row, 'code'
      stocks.push @createInventoryEntry(sku, xmlHelpers.xmlVal(row, 'quantity'))
      appointedQuantity = xmlHelpers.xmlVal row, 'AppointedQuantity'
      if appointedQuantity
        expectedDelivery = xmlHelpers.xmlVal row, 'CommittedDeliveryDate'
        if expectedDelivery?
          expectedDelivery = new Date(expectedDelivery).toISOString()
        d = @createInventoryEntry(sku, appointedQuantity, expectedDelivery, channelId)
        stocks.push d
    stocks

module.exports = StockXmlImport
