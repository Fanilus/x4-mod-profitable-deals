-- Profitable Deals
-- Map button under Trade Ledger: pick an owned ship, size a deal to its free
-- container bay, and queue buy, sell, and return-to-base orders.

local MOD_ID = "pd_profitable_deals"
local BTN_ID = "pd_profitable_deals_btn"
local BTN_MODE = "pd_profitable_deals"
local BTN_TITLE = "Deals"
local MTL_BTN_ID = "mtl_trade_ledger_btn"

_G.__PD_GUARD = _G.__PD_GUARD or {}
if _G.__PD_GUARD.loaded then return end
_G.__PD_GUARD.loaded = true

_G.__PD_STATE = _G.__PD_STATE or {
  sortKey = "profit",
  sortAsc = false,
  page = 1,
  pageSize = 12,
  fillMode = "full",
  dataMode = "live",
  shipKey = nil,
  homeKey = "auto",
  status = "",
}
local STATE = _G.__PD_STATE

local mapMenu = nil
local initialized = false
local popupOpen = false
local wrappedRightBar = {}

local offerCache = nil
local offerCacheAt = 0
local CACHE_TTL = 8

local function log(msg)
  if DebugError then DebugError("uix: [PD] " .. tostring(msg)) end
end

local function now()
  if os and os.clock then return os.clock() end
  return 0
end

local function num(v)
  local n = tonumber(v)
  if not n or n ~= n then return nil end
  return n
end

local function norm(s)
  return string.lower(tostring(s or ""))
end

local function cloneTable(t)
  if type(t) ~= "table" then return {} end
  if Helper and type(Helper.tableCopy) == "function" then
    return Helper.tableCopy(t, 6)
  end
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      local inner = {}
      for kk, vv in pairs(v) do inner[kk] = vv end
      out[k] = inner
    else
      out[k] = v
    end
  end
  return out
end

local function rowHeight()
  if Helper and Helper.scaleY then return Helper.scaleY(12) end
  return 24
end

local function safeMoney(value)
  if type(value) ~= "number" then return "" end
  if type(ConvertMoneyString) == "function" and Helper and Helper.round then
    return ConvertMoneyString(Helper.round(value, 2), true, true, 0, true)
  end
  return tostring(math.floor(value + 0.5))
end

local function safeInt(value)
  if type(value) ~= "number" then return "" end
  if type(ConvertIntegerString) == "function" then
    return ConvertIntegerString(value, true, 0, true)
  end
  return tostring(math.floor(value))
end

local function fmtDuration(seconds)
  seconds = math.floor(num(seconds) or 0)
  if seconds < 0 then seconds = 0 end
  if seconds < 60 then return tostring(seconds) .. "s" end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then return tostring(minutes) .. "m" end
  local hours = math.floor(minutes / 60)
  minutes = minutes - hours * 60
  if hours < 48 then return string.format("%dh %02dm", hours, minutes) end
  local days = math.floor(hours / 24)
  hours = hours - days * 24
  return string.format("%dd %dh", days, hours)
end

local function ffiString(value)
  if value == nil or not ffi or not ffi.string then return "" end
  local ok, text = pcall(ffi.string, value)
  if ok and text then return text end
  return ""
end

local function to64(id)
  if id == nil or id == 0 or id == "0" then return nil end
  if type(ConvertIDTo64Bit) == "function" then
    local ok, value = pcall(ConvertIDTo64Bit, id)
    if ok and value ~= nil and value ~= 0 then return value end
  end
  if type(id) == "number" or type(id) == "cdata" then return id end
  if type(ConvertStringTo64Bit) == "function" then
    local ok, value = pcall(ConvertStringTo64Bit, tostring(id))
    if ok and value ~= nil and value ~= 0 then return value end
  end
  return nil
end

local function toLua(id)
  if id == nil or id == 0 or id == "0" then return nil end
  if type(id) ~= "number" and type(ConvertIDTo64Bit) ~= "function" then
    return id
  end
  local id64 = id
  if type(id) ~= "number" then
    id64 = to64(id)
  end
  if not id64 or type(ConvertStringToLuaID) ~= "function" then return nil end
  local ok, value = pcall(ConvertStringToLuaID, tostring(id64))
  if ok and value and value ~= 0 and value ~= "0" then return value end
  return nil
end

local function sameId(a, b)
  if a == nil or b == nil then return false end
  return tostring(a) == tostring(b)
end

local function componentName(id)
  if not id or type(GetComponentData) ~= "function" then return "?" end
  local ok, name = pcall(GetComponentData, id, "name")
  if ok and name and name ~= "" then return tostring(name) end
  return "?"
end

local function componentSector(id)
  if not id or type(GetComponentData) ~= "function" then return nil end
  local ok, sector = pcall(GetComponentData, id, "sector")
  if ok and sector and sector ~= 0 then return sector end
  return nil
end

local function sectorName(sector)
  if not sector then return "" end
  return componentName(sector)
end

---------------------------------------------------------------
-- Map right bar, directly under the Trade Ledger button
---------------------------------------------------------------
local function makeEntry(sample)
  local entry = cloneTable(sample)
  entry.id = BTN_ID
  entry.name = BTN_TITLE
  entry.mode = BTN_MODE
  entry.helpOverlayText = "Profitable Deals"
  entry.helpOverlayID = "pd_profitable_deals"
  entry.selectable = true
  entry.enabled = true
  entry.hidden = false
  entry.icon = "mapst_fs_trade"
  entry.iconid = "fs_trade"
  return entry
end

local function placeButton(config)
  if type(config) ~= "table" or type(config.rightBar) ~= "table" then return config end
  local bar = config.rightBar
  local sample = nil
  for i = 1, #bar do
    local entry = bar[i]
    if type(entry) == "table" and not entry.spacing and entry.id ~= BTN_ID then
      sample = entry
      break
    end
  end
  if not sample then return config end

  for i = #bar, 1, -1 do
    if type(bar[i]) == "table" and bar[i].id == BTN_ID then
      table.remove(bar, i)
    end
  end

  local insertAt = #bar + 1
  for i = 1, #bar do
    if type(bar[i]) == "table" and bar[i].id == MTL_BTN_ID then
      insertAt = i + 1
      break
    end
  end
  table.insert(bar, insertAt, makeEntry(sample))
  return config
end

local function wrapRightBarCallback(id, fn)
  if wrappedRightBar[id] then return fn end
  wrappedRightBar[id] = true
  return function(config)
    local result = nil
    if type(fn) == "function" then
      result = fn(config)
    end
    placeButton(config)
    return result
  end
end

local function createRightBar_on_start(config)
  return placeButton(config)
end

---------------------------------------------------------------
-- Ships, bases, cargo
---------------------------------------------------------------
local wareCache = {}

local function wareInfo(ware)
  if ware == nil then return nil end
  local cached = wareCache[ware]
  if cached then return cached end
  local info = { name = tostring(ware), volume = nil, transport = "" }
  if type(GetWareData) == "function" then
    local ok, name, volume, transport = pcall(GetWareData, ware, "name", "volume", "transport")
    if ok then
      info.name = tostring(name or ware)
      info.volume = num(volume)
      info.transport = string.lower(tostring(transport or ""))
    end
  end
  wareCache[ware] = info
  return info
end

local function transportTags(text)
  local tags = {}
  for word in string.gmatch(tostring(text or ""), "%S+") do
    tags[string.lower(word)] = true
  end
  return tags
end

local function holdsContainer(tags)
  return tags and tags.container
end

local function containerSpace(ship64, shipLua)
  local capacity = 0
  if mapMenu and ship64 and type(mapMenu.getCargoTransportTypes) == "function" then
    local ok, types = pcall(mapMenu.getCargoTransportTypes, ship64, false)
    if ok and type(types) == "table" then
      for i = 1, #types do
        local entry = types[i]
        if holdsContainer(entry.tags) then
          capacity = capacity + (tonumber(entry.capacity) or 0)
        end
      end
    end
  end
  if capacity <= 0 and ship64 and C and ffi and type(C.GetNumCargoTransportTypes) == "function" then
    local ok, err = pcall(function()
      local count = tonumber(C.GetNumCargoTransportTypes(ship64, true)) or 0
      if count <= 0 then return end
      local buf = ffi.new("StorageInfo[?]", count)
      local filled = tonumber(C.GetCargoTransportTypes(buf, count, ship64, true, false)) or count
      if filled < 0 then filled = 0 end
      if filled > count then filled = count end
      for i = 0, filled - 1 do
        if holdsContainer(transportTags(ffiString(buf[i].transport))) then
          capacity = capacity + (tonumber(buf[i].capacity) or 0)
        end
      end
    end)
    if not ok then log("containerSpace: " .. tostring(err)) end
  end

  local used = 0
  local cargoId = shipLua or ship64
  if cargoId and type(GetComponentData) == "function" and type(GetWareData) == "function" then
    local ok, cargo = pcall(GetComponentData, cargoId, "cargo")
    if (not ok or type(cargo) ~= "table") and ship64 and ship64 ~= cargoId then
      ok, cargo = pcall(GetComponentData, ship64, "cargo")
    end
    if ok and type(cargo) == "table" then
      for ware, amount in pairs(cargo) do
        local transport, volume = GetWareData(ware, "transport", "volume")
        if transport == "container" then
          used = used + (tonumber(amount) or 0) * (tonumber(volume) or 0)
        end
      end
    end
  end
  local free = capacity - used
  if free < 0 then free = 0 end
  return free, capacity
end

local function travelSpeed(ship64)
  if not C or type(C.GetDefensibleSpeeds) ~= "function" then return 5000 end
  local ok, info = pcall(C.GetDefensibleSpeeds, ship64)
  if ok and info then
    local speed = num(info.travelspeed) or num(info.speed)
    if speed and speed > 200 then return speed end
  end
  return 5000
end

local function listOwned(className)
  local out = {}
  if type(GetContainedObjectsByOwner) ~= "function" or type(IsComponentClass) ~= "function" then
    return out
  end
  local ok, objects = pcall(GetContainedObjectsByOwner, "player")
  if not ok or type(objects) ~= "table" then return out end
  for _, object in pairs(objects) do
    if IsComponentClass(object, className) then
      out[#out + 1] = object
    end
  end
  return out
end

local function rememberObject(list, seen, object)
  if object == nil or object == 0 or object == "0" then return end
  local key = tostring(object)
  if key == "" or seen[key] then return end
  seen[key] = true
  list[#list + 1] = object
end

local function collectOwnedObjects()
  local list, seen = {}, {}
  if type(GetContainedObjectsByOwner) == "function" then
    local ok, objects = pcall(GetContainedObjectsByOwner, "player")
    if ok and type(objects) == "table" then
      for _, object in pairs(objects) do
        rememberObject(list, seen, object)
      end
    end
  end
  if C and type(ConvertStringToLuaID) == "function" then
    local readers = { "GetPlayerOccupiedShipID", "GetPlayerControlledShipID", "GetPlayerShipID" }
    for i = 1, #readers do
      local reader = C[readers[i]]
      if type(reader) == "function" then
        local ok, id64 = pcall(reader)
        if ok and id64 and id64 ~= 0 then
          local okLua, luaId = pcall(ConvertStringToLuaID, tostring(id64))
          if okLua then rememberObject(list, seen, luaId) end
        end
      end
    end
  end
  if type(GetSubordinates) == "function" then
    local index = 1
    while index <= #list and index <= 5000 do
      local ok, subordinates = pcall(GetSubordinates, list[index])
      if ok and type(subordinates) == "table" then
        for _, subordinate in pairs(subordinates) do
          rememberObject(list, seen, subordinate)
        end
      end
      index = index + 1
    end
  end
  return list
end

local function isTradeShip(object)
  if type(IsComponentClass) == "function" then
    if IsComponentClass(object, "spacesuit") then return false end
    if not IsComponentClass(object, "ship") then return false end
  end
  if type(GetComponentData) == "function" then
    local ok, isunit, iswreck = pcall(GetComponentData, object, "isunit", "iswreck")
    if ok and (isunit or iswreck) then return false end
  end
  return true
end

local function shipRecord(shipLua)
  if not isTradeShip(shipLua) then return nil end
  local ship64 = to64(shipLua)
  local free, capacity = containerSpace(ship64, shipLua)
  local name = componentName(shipLua)
  local idcode = ""
  if type(GetComponentData) == "function" then
    local ok, code = pcall(GetComponentData, shipLua, "idcode")
    if ok and code and code ~= "" then idcode = tostring(code) end
  end
  local label = name
  if idcode ~= "" then label = name .. " (" .. idcode .. ")" end
  return {
    key = tostring(shipLua),
    lua = shipLua,
    id64 = ship64,
    name = name,
    label = label,
    free = free,
    capacity = capacity,
    speed = travelSpeed(ship64),
    sector = componentSector(ship64) or componentSector(shipLua),
  }
end

local shipCache = nil
local shipCacheAt = 0

local function playerShips(force)
  local t = now()
  if not force and shipCache and (t - shipCacheAt) < 5 then
    return shipCache
  end
  local ships = {}
  local raw = collectOwnedObjects()
  for i = 1, #raw do
    local record = shipRecord(raw[i])
    if record then ships[#ships + 1] = record end
  end
  table.sort(ships, function(a, b)
    if a.capacity ~= b.capacity then return a.capacity > b.capacity end
    return norm(a.label) < norm(b.label)
  end)
  STATE.scanNote = string.format("player objects %d, ships %d", #raw, #ships)
  shipCache = ships
  shipCacheAt = t
  return ships
end

local function stationRecord(stationLua, source)
  local station64 = to64(stationLua)
  if not station64 then return nil end
  local sector = componentSector(station64) or componentSector(stationLua)
  return {
    key = tostring(stationLua),
    lua = stationLua,
    id64 = station64,
    name = componentName(stationLua),
    sectorName = sectorName(sector),
    sector = sector,
    source = source or "",
  }
end

local function dockedStation(ship)
  if not ship or not C or type(C.GetContextByClass) ~= "function" then return nil end
  if type(GetComponentData) == "function" then
    local ok, docked = pcall(GetComponentData, ship.lua, "isdocked")
    if not ok or not docked then return nil end
  end
  local ok, container = pcall(C.GetContextByClass, ship.id64, "container", false)
  if not ok or not container or container == 0 then return nil end
  local lua = toLua(container)
  if not lua or type(IsComponentClass) ~= "function" or not IsComponentClass(lua, "station") then
    return nil
  end
  local record = stationRecord(lua, "dock")
  if record then record.id64 = container end
  return record
end

local function commanderStation(ship)
  if not ship or type(GetCommander) ~= "function" then return nil end
  local ok, commander = pcall(GetCommander, ship.lua)
  if not ok or not commander or commander == 0 then return nil end
  if type(IsComponentClass) == "function" and not IsComponentClass(commander, "station") then
    return nil
  end
  return stationRecord(commander, "commander")
end

local function playerStations()
  local stations = {}
  local raw = listOwned("station")
  for i = 1, #raw do
    local record = stationRecord(raw[i], "owned")
    if record then stations[#stations + 1] = record end
  end
  table.sort(stations, function(a, b) return norm(a.name) < norm(b.name) end)
  return stations
end

local function findByKey(list, key)
  if not key then return nil end
  for i = 1, #list do
    if list[i].key == key then return list[i] end
  end
  return nil
end

local function resolveHome(ship, stations)
  if STATE.homeKey and STATE.homeKey ~= "auto" and STATE.homeKey ~= "none" then
    local picked = findByKey(stations, STATE.homeKey)
    if picked then return picked end
  end
  if STATE.homeKey == "none" then return nil end
  return dockedStation(ship) or commanderStation(ship)
end

---------------------------------------------------------------
-- Route and time
---------------------------------------------------------------
local function distanceMeters(a, b)
  if not a or not b or not C or type(C.GetDistanceBetween) ~= "function" then return nil end
  local ok, dist = pcall(C.GetDistanceBetween, a, b)
  dist = ok and num(dist) or nil
  if dist and dist >= 0 then return dist end
  return nil
end

local function sectorJumps(fromSector, toSector)
  if not fromSector or not toSector then return 0 end
  if sameId(fromSector, toSector) then return 0 end
  if type(FindJumpRoute) ~= "function" then return 1 end
  local ok, route = pcall(FindJumpRoute, fromSector, toSector)
  if not ok or route == nil then return 1 end
  local jumps = num(route)
  if jumps then return math.max(0, math.floor(jumps + 0.001)) end
  if type(route) == "table" then
    local count = #route
    if count <= 1 then return 0 end
    return count - 1
  end
  return 1
end

local function legPlan(fromId, fromSector, toId, toSector, speed)
  if not toId then
    return { seconds = 0, jumps = 0, label = "" }
  end
  if fromId and sameId(fromId, toId) then
    return { seconds = 45, jumps = 0, label = "already here" }
  end
  local jumps = sectorJumps(fromSector, toSector)
  local safeSpeed = speed
  if not safeSpeed or safeSpeed < 200 then safeSpeed = 5000 end
  local seconds
  if jumps <= 0 then
    local dist = distanceMeters(fromId, toId)
    if dist then
      seconds = dist / safeSpeed + 50
    else
      seconds = 90
    end
  else
    -- Rough estimate: about 250 km of travel per jump, plus docking.
    seconds = jumps * ((250000 / safeSpeed) + 25) + 50
  end
  return { seconds = seconds, jumps = jumps }
end

---------------------------------------------------------------
-- Known prices
---------------------------------------------------------------
local function tradeList(station64, shipLua, stale)
  if type(GetTradeList) ~= "function" then return {} end
  local ok, result
  if shipLua then
    if stale then
      ok, result = pcall(GetTradeList, station64, shipLua, false)
    else
      ok, result = pcall(GetTradeList, station64, shipLua)
    end
  else
    if stale then
      ok, result = pcall(GetTradeList, station64, nil, false)
    else
      ok, result = pcall(GetTradeList, station64)
    end
  end
  if ok and type(result) == "table" then return result end
  return {}
end

local function offerAmount(tradedata)
  local amount = num(tradedata.amount) or num(tradedata.offeramount) or num(tradedata.stock)
  if (not amount or amount <= 0) then
    amount = num(tradedata.desiredamount)
  end
  if not amount or amount <= 0 then return 0 end
  return math.floor(amount)
end

local function collectOffers(shipLua, force)
  local t = now()
  local includeStale = STATE.dataMode == "all"
  local cacheKey = tostring(shipLua or "none") .. "|" .. (includeStale and "all" or "live")
  if not force and offerCache and offerCache.key == cacheKey and (t - offerCacheAt) < CACHE_TTL then
    return offerCache.rows, offerCache.stations
  end

  local rows = {}
  if type(GetClusters) ~= "function" or type(GetSectors) ~= "function"
    or type(GetContainedStations) ~= "function" or type(GetComponentData) ~= "function" then
    log("Map functions for scanning stations are missing")
    offerCache = { key = cacheKey, rows = rows, stations = 0 }
    offerCacheAt = t
    return rows, 0
  end

  local stations = 0
  local clusters = GetClusters(true) or {}
  for c = 1, #clusters do
    local sectors = GetSectors(clusters[c]) or {}
    for s = 1, #sectors do
      local sector64 = sectors[s]
      local sectorLabel = tostring(GetComponentData(sector64, "name") or "")
      local stationList = GetContainedStations(sector64, true) or {}
      for n = 1, #stationList do
        local station64 = stationList[n]
        stations = stations + 1
        local stationLabel = tostring(GetComponentData(station64, "name") or "?")
        local seen = {}
        local function takeOffer(tradedata, stale)
          if type(tradedata) ~= "table" or not tradedata.ware or tradedata.ismissionoffer or not tradedata.id then
            return
          end
          local info = wareInfo(tradedata.ware)
          local price = num(tradedata.price) or num(tradedata.unitprice)
          local amount = offerAmount(tradedata)
          local side = nil
          if tradedata.isselloffer then
            side = "sell"
          elseif tradedata.isbuyoffer then
            side = "buy"
          end
          if not (info and info.transport == "container" and info.volume and info.volume > 0
            and side and price and price > 0 and amount > 0) then
            return
          end
          local key = tostring(tradedata.ware) .. "|" .. side
          if not stale then
            seen[key] = true
          elseif seen[key] then
            return
          end
          rows[#rows + 1] = {
            ware = tradedata.ware,
            wareName = info.name,
            volume = info.volume,
            price = price,
            amount = amount,
            minamount = math.floor(num(tradedata.minamount) or 1),
            side = side,
            stale = stale and true or false,
            offerId = tradedata.id,
            station64 = station64,
            station = stationLabel,
            sector64 = sector64,
            sector = sectorLabel,
          }
        end
        for _, tradedata in pairs(tradeList(station64, shipLua, false)) do
          takeOffer(tradedata, false)
        end
        if includeStale then
          for _, tradedata in pairs(tradeList(station64, shipLua, true)) do
            takeOffer(tradedata, true)
          end
        end
      end
    end
  end

  offerCache = { key = cacheKey, rows = rows, stations = stations }
  offerCacheAt = t
  log("stations " .. tostring(stations) .. ", offers " .. tostring(#rows) .. ", mode " .. (includeStale and "all" or "live"))
  return rows, stations
end

local function buildDeals(offers, ship, home)
  local byWare = {}
  for i = 1, #offers do
    local offer = offers[i]
    local bucket = byWare[offer.ware]
    if not bucket then
      bucket = { sells = {}, buys = {} }
      byWare[offer.ware] = bucket
    end
    if offer.side == "sell" then
      bucket.sells[#bucket.sells + 1] = offer
    else
      bucket.buys[#bucket.buys + 1] = offer
    end
  end

  local deals = {}
  for _, bucket in pairs(byWare) do
    table.sort(bucket.sells, function(a, b) return a.price < b.price end)
    table.sort(bucket.buys, function(a, b) return a.price > b.price end)
    local sellCount = math.min(#bucket.sells, 12)
    local buyCount = math.min(#bucket.buys, 12)
    if sellCount > 0 and buyCount > 0 then
      local sample = bucket.sells[1]
      local units = math.floor((ship.free or 0) / sample.volume)
      if units >= 1 then
        for s = 1, sellCount do
          local sell = bucket.sells[s]
          for b = 1, buyCount do
            local buy = bucket.buys[b]
            if buy.price > sell.price and not sameId(sell.station64, buy.station64) then
              local amount = math.min(units, sell.amount, buy.amount)
              local full = amount >= units
              local staleDeal = sell.stale or buy.stale
              if amount >= 1 and amount >= (sell.minamount or 1) and amount >= (buy.minamount or 1) then
                if (STATE.fillMode ~= "full" or full) and (STATE.dataMode == "all" or not staleDeal) then
                  local buyLeg = legPlan(ship.id64, ship.sector, sell.station64, sell.sector64, ship.speed)
                  local sellLeg = legPlan(sell.station64, sell.sector64, buy.station64, buy.sector64, ship.speed)
                  local homeLeg = { seconds = 0, jumps = 0 }
                  if home then
                    homeLeg = legPlan(buy.station64, buy.sector64, home.id64, home.sector, ship.speed)
                  end
                  local seconds = buyLeg.seconds + sellLeg.seconds + homeLeg.seconds
                  local cost = sell.price * amount
                  local profit = (buy.price - sell.price) * amount
                  deals[#deals + 1] = {
                    wareName = sample.wareName,
                    volume = sample.volume,
                    amount = amount,
                    units = units,
                    full = full,
                    buyStock = sell.amount,
                    sellStock = buy.amount,
                    buyPrice = sell.price,
                    sellPrice = buy.price,
                    buyName = sell.station,
                    buySector = sell.sector,
                    buyStation64 = sell.station64,
                    sellName = buy.station,
                    sellSector = buy.sector,
                    sellStation64 = buy.station64,
                    buyOfferId = sell.offerId,
                    sellOfferId = buy.offerId,
                    buyStale = sell.stale and true or false,
                    sellStale = buy.stale and true or false,
                    cost = cost,
                    profit = profit,
                    seconds = seconds,
                    jumps = buyLeg.jumps + sellLeg.jumps + homeLeg.jumps,
                    buySeconds = buyLeg.seconds,
                    sellSeconds = sellLeg.seconds,
                    homeSeconds = homeLeg.seconds,
                    buyJumps = buyLeg.jumps,
                    sellJumps = sellLeg.jumps,
                    homeJumps = homeLeg.jumps,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  return deals
end

local function sortValue(deal, key)
  if key == "ware" then return norm(deal.wareName) end
  if key == "buy" then return deal.buyPrice end
  if key == "sell" then return deal.sellPrice end
  if key == "amount" then return deal.amount end
  if key == "cost" then return deal.cost end
  if key == "profit" then return deal.profit end
  if key == "time" then return deal.seconds end
  if key == "fresh" then
    local rank = 0
    if deal.buyStale then rank = rank + 1 end
    if deal.sellStale then rank = rank + 1 end
    return rank
  end
  return deal.profit
end

local function sortDeals(deals)
  local key = STATE.sortKey
  local asc = STATE.sortAsc
  table.sort(deals, function(a, b)
    local va = sortValue(a, key)
    local vb = sortValue(b, key)
    if va == vb then
      if a.profit == b.profit then return norm(a.wareName) < norm(b.wareName) end
      return a.profit > b.profit
    end
    if asc then return va < vb else return va > vb end
  end)
  if #deals > 240 then
    local trimmed = {}
    for i = 1, 240 do trimmed[i] = deals[i] end
    return trimmed
  end
  return deals
end

local function headerLabel(label, key)
  if STATE.sortKey ~= key then return label end
  if STATE.sortAsc then return label .. " ^" end
  return label .. " v"
end

local function toggleSort(key)
  if STATE.sortKey == key then
    STATE.sortAsc = not STATE.sortAsc
  else
    STATE.sortKey = key
    STATE.sortAsc = (key == "ware" or key == "fresh")
  end
end

---------------------------------------------------------------
-- Queue orders
---------------------------------------------------------------
local function queueTrade(offerId, ship64, amount)
  if type(AddTradeToShipQueue) ~= "function" then
    return false, "AddTradeToShipQueue is not available in this game version"
  end
  local offerLua = offerId
  if type(ConvertIDTo64Bit) == "function" and type(ConvertStringToLuaID) == "function" then
    local ok, id64 = pcall(ConvertIDTo64Bit, offerId)
    if ok and id64 and id64 ~= 0 then
      local okLua, luaId = pcall(ConvertStringToLuaID, tostring(id64))
      if okLua and luaId then offerLua = luaId end
    end
  end
  local shipArg = ship64
  if type(ConvertStringTo64Bit) == "function" then
    local ok, converted = pcall(ConvertStringTo64Bit, tostring(ship64))
    if ok and converted then shipArg = converted end
  end
  local ok, err = pcall(AddTradeToShipQueue, offerLua, shipArg, amount, false)
  if not ok then return false, err end
  return true
end

local function queueReturn(ship64, home)
  if not home then return true end
  if not C or type(C.CreateOrder) ~= "function" or type(SetOrderParam) ~= "function" or type(C.EnableOrder) ~= "function" then
    return false, "no way to queue a return order"
  end
  if type(C.IsOrderSelectableFor) == "function" then
    local ok, allowed = pcall(C.IsOrderSelectableFor, "DockAndWait", ship64)
    if ok and not allowed then
      return false, "this ship cannot be ordered to dock"
    end
  end
  local destination = home.lua
  if type(ConvertStringToLuaID) == "function" then
    local ok, luaId = pcall(ConvertStringToLuaID, tostring(home.id64))
    if ok and luaId then destination = luaId end
  end
  local ok, idxOrErr = pcall(C.CreateOrder, ship64, "DockAndWait", false)
  if not ok then return false, idxOrErr end
  local idx = tonumber(idxOrErr) or 0
  if idx <= 0 then return false, "return order was not created" end
  local paramOk, paramErr = pcall(SetOrderParam, ship64, idx, 1, nil, destination)
  if not paramOk then return false, paramErr end
  local enableOk, enableErr = pcall(C.EnableOrder, ship64, idx)
  if not enableOk then return false, enableErr end
  return true
end

local function executeDeal(deal, ship, home)
  if not ship then
    STATE.status = "Select a ship first."
    return
  end
  if ship.free < 1 then
    STATE.status = "The container bay is already full."
    return
  end
  local bought, buyErr = queueTrade(deal.buyOfferId, ship.id64, deal.amount)
  if not bought then
    STATE.status = "Buy order was not queued: " .. tostring(buyErr)
    log(STATE.status)
    return
  end
  local sold, sellErr = queueTrade(deal.sellOfferId, ship.id64, deal.amount)
  if not sold then
    STATE.status = "Buy was queued, sell was not: " .. tostring(sellErr)
    log(STATE.status)
    return
  end
  local returned, returnErr = queueReturn(ship.id64, home)
  if not returned then
    STATE.status = "Buy and sell were queued, return was not: " .. tostring(returnErr)
    log(STATE.status)
    return
  end
  local homeName = home and home.name or "no return"
  STATE.status = string.format(
    "Queued for %s: buy %s x %d at %s, sell at %s, return to %s.",
    ship.name,
    deal.wareName,
    deal.amount,
    deal.buyName,
    deal.sellName,
    homeName
  )
  log(STATE.status)
end

---------------------------------------------------------------
-- Window
---------------------------------------------------------------
local function restorePicking()
  if mapMenu and mapMenu._pd_prevPicking ~= nil then
    mapMenu.picking = mapMenu._pd_prevPicking
    mapMenu._pd_prevPicking = nil
  end
end

local rebuilding = false

local function releaseScan()
  offerCache = nil
  offerCacheAt = 0
  shipCache = nil
  shipCacheAt = 0
end

local function closePopup()
  if not mapMenu then return end
  if mapMenu.contextMenuData and mapMenu.contextMenuData.mode == BTN_MODE then
    pcall(mapMenu.closeContextMenu)
  end
  popupOpen = false
  restorePicking()
end

local function openPopup(force) end

local function reopen(force)
  rebuilding = true
  closePopup()
  rebuilding = false
  openPopup(force and true or false)
end

local function showOnMap(object64)
  if not object64 or not mapMenu or not Helper or type(Helper.closeMenuAndOpenNewMenu) ~= "function" then
    return
  end
  closePopup()
  Helper.closeMenuAndOpenNewMenu(mapMenu, "MapMenu", { 0, 0, true, object64 })
  if type(mapMenu.cleanup) == "function" then
    mapMenu.cleanup()
  end
end

local function freshLabel(deal)
  if deal.buyStale and deal.sellStale then return "Stale" end
  if deal.buyStale then return "Stale buy" end
  if deal.sellStale then return "Stale sell" end
  return "Live"
end

local function buildPopup(frame, force)
  local titleBg = (Color and Color["row_title_background"]) or (Color and Color["row_background_blue"]) or nil
  local inactive = Color and Color["text_inactive"] or nil
  local negative = Color and Color["text_negative"] or nil
  local rowH = rowHeight()
  local cols = 9
  local money = 0
  if type(GetPlayerMoney) == "function" then
    money = num(GetPlayerMoney()) or 0
  end

  local t = frame:addTable(cols, { tabOrder = 1, reserveScrollBar = true, highlightMode = "off" })
  if t.setColWidthMinPercent then
    t:setColWidthMinPercent(1, 12)
    t:setColWidthMinPercent(2, 18)
    t:setColWidthMinPercent(3, 18)
    t:setColWidth(4, Helper.scaleX(80), false)
    t:setColWidth(5, Helper.scaleX(110), false)
    t:setColWidth(6, Helper.scaleX(110), false)
    t:setColWidth(7, Helper.scaleX(80), false)
    t:setColWidth(8, Helper.scaleX(90), false)
    t:setColWidth(9, Helper.scaleX(70), false)
  end

  do
    local row = t:addRow(false, { fixed = true, bgColor = titleBg })
    row[1]:setColSpan(cols):createText("Profitable Deals", (Helper and Helper.headerRowCenteredProperties) or nil)
  end

  local ships = playerShips(force)
  local ship = findByKey(ships, STATE.shipKey) or ships[1]
  if ship then STATE.shipKey = ship.key end

  local stations = playerStations()
  local home = ship and resolveHome(ship, stations) or nil
  if home and STATE.homeKey ~= "none" and not findByKey(stations, home.key) then
    stations[#stations + 1] = home
  end

  local shipOpts = {}
  if #ships == 0 then
    shipOpts[1] = { id = "none", text = "Ship: none found", icon = "", displayremoveoption = false }
  else
    for i = 1, #ships do
      local s = ships[i]
      shipOpts[#shipOpts + 1] = {
        id = s.key,
        text = string.format("Ship: %s  ·  free %s / %s m3", s.label, safeInt(s.free), safeInt(s.capacity)),
        icon = "",
        displayremoveoption = false,
      }
    end
  end

  do
    local row = t:addRow(true, { fixed = true })
    row[1]:setColSpan(cols):createDropDown(shipOpts, {
      height = rowH,
      startOption = ship and ship.key or "none",
    })
    row[1].handlers.onDropDownConfirmed = function(_, id)
      if id and id ~= "none" then
        STATE.shipKey = id
        STATE.page = 1
        STATE.status = ""
        reopen(false)
      end
    end
  end

  local homeOpts = {
    { id = "auto", text = "Return: auto (dock or commander)", icon = "", displayremoveoption = false },
    { id = "none", text = "Return: do not return", icon = "", displayremoveoption = false },
  }
  for i = 1, #stations do
    local station = stations[i]
    local where = station.sectorName ~= "" and (" · " .. station.sectorName) or ""
    homeOpts[#homeOpts + 1] = {
      id = station.key,
      text = "Return: " .. station.name .. where,
      icon = "",
      displayremoveoption = false,
    }
  end
  local homeStart = STATE.homeKey or "auto"
  if homeStart ~= "auto" and homeStart ~= "none" and not findByKey(stations, homeStart) then
    homeStart = "auto"
    STATE.homeKey = "auto"
  end

  local fillOpts = {
    { id = "full", text = "Volume: full bay only", icon = "", displayremoveoption = false },
    { id = "any", text = "Volume: whatever the stations have", icon = "", displayremoveoption = false },
  }

  do
    local row = t:addRow(true, { fixed = true })
    row[1]:setColSpan(4):createDropDown(homeOpts, { height = rowH, startOption = homeStart })
    row[1].handlers.onDropDownConfirmed = function(_, id)
      STATE.homeKey = id or "auto"
      STATE.page = 1
      reopen(false)
    end
    row[5]:setColSpan(2):createDropDown(fillOpts, { height = rowH, startOption = STATE.fillMode or "full" })
    row[5].handlers.onDropDownConfirmed = function(_, id)
      STATE.fillMode = id or "full"
      STATE.page = 1
      reopen(false)
    end
    local priceOpts = {
      { id = "live", text = "Prices: live only", icon = "", displayremoveoption = false },
      { id = "all", text = "Prices: live and stale", icon = "", displayremoveoption = false },
    }
    row[7]:setColSpan(2):createDropDown(priceOpts, { height = rowH, startOption = STATE.dataMode or "live" })
    row[7].handlers.onDropDownConfirmed = function(_, id)
      STATE.dataMode = id or "live"
      STATE.page = 1
      reopen(false)
    end
    row[9]:createButton({ mouseOverText = "Rescan known prices", height = rowH }):setText("Refresh")
    row[9].handlers.onClick = function()
      STATE.page = 1
      STATE.status = ""
      reopen(true)
    end
  end

  local info = "Select a ship with a container bay."
  if ship then
    local homeText = home and (home.name .. (home.sectorName ~= "" and (" · " .. home.sectorName) or "")) or "no return"
    info = string.format(
      "Free %s / %s m3 · travel %s m/s · account %s · return: %s",
      safeInt(ship.free),
      safeInt(ship.capacity),
      safeInt(ship.speed),
      safeMoney(money),
      homeText
    )
  end
  do
    local row = t:addRow(false, { fixed = true })
    row[1]:setColSpan(cols):createText(info, { halign = "left" })
  end
  if STATE.status and STATE.status ~= "" then
    local row = t:addRow(false, { fixed = true })
    row[1]:setColSpan(cols):createText(STATE.status, { halign = "left" })
  end

  local deals = {}
  local offerCount, stationCount = 0, 0
  if ship and ship.free > 0 then
    local offers, scanned = collectOffers(ship.lua, force)
    offerCount = #offers
    stationCount = scanned or 0
    deals = sortDeals(buildDeals(offers, ship, home))
  end

  do
    local row = t:addRow(true, { fixed = true, bgColor = titleBg })
    local function sortButton(col, key, text, tip)
      row[col]:createButton({ height = rowH, mouseOverText = tip }):setText(headerLabel(text, key))
      row[col].handlers.onClick = function()
        toggleSort(key)
        reopen(false)
      end
    end
    sortButton(1, "ware", "Ware", "Sort by ware")
    sortButton(2, "buy", "Buy", "Sort by buy price")
    sortButton(3, "sell", "Sell", "Sort by sell price")
    sortButton(4, "amount", "Amount", "Sort by amount")
    sortButton(5, "cost", "Cost", "Credits needed to fill this run")
    sortButton(6, "profit", "Profit", "Sort by profit")
    sortButton(7, "time", "Time", "Rough travel time to buy, sell, and return")
    sortButton(8, "fresh", "Fresh", "Live prices are covered now. Stale prices are from an older visit.")
    row[9]:createText("Exec")
  end

  if not ship then
    local row = t:addRow(false, {})
    local why = "No owned ships found."
    if STATE.scanNote and STATE.scanNote ~= "" then
      why = why .. " " .. STATE.scanNote .. "."
    end
    row[1]:setColSpan(cols):createText(why, { color = inactive })
    return
  end
  if ship.free <= 0 then
    local row = t:addRow(false, {})
    row[1]:setColSpan(cols):createText("The selected ship's container bay is full. Free some space.", { color = inactive })
    return
  end
  if #deals == 0 then
    local row = t:addRow(false, {})
    local why = string.format(
      "No deals. Live offers: %d, stations: %d. Needs known prices and a gap between a cheap sell offer and a higher buy offer.",
      offerCount, stationCount
    )
    if STATE.fillMode == "full" then
      why = why .. " Full-bay mode hides stations that cannot fill the ship."
    end
    if STATE.dataMode ~= "all" then
      why = why .. " Live-only mode hides stations that are not currently covered."
    end
    row[1]:setColSpan(cols):createText(why, { color = inactive })
    return
  end

  local pageSize = math.max(5, tonumber(STATE.pageSize) or 12)
  local total = #deals
  local maxPage = math.max(1, math.ceil(total / pageSize))
  if STATE.page > maxPage then STATE.page = maxPage end
  if STATE.page < 1 then STATE.page = 1 end
  local startIndex = (STATE.page - 1) * pageSize + 1
  local endIndex = math.min(total, startIndex + pageSize - 1)

  do
    local row = t:addRow(true, { fixed = true })
    row[1]:setColSpan(5):createText(string.format(
      "Deals %d-%d of %d · page %d/%d · orders are appended to the queue",
      startIndex, endIndex, total, STATE.page, maxPage
    ), { halign = "left" })
    row[6]:createButton({ height = rowH }):setText("< Prev")
    row[6].handlers.onClick = function()
      STATE.page = math.max(1, STATE.page - 1)
      reopen(false)
    end
    row[7]:createButton({ height = rowH }):setText("Next >")
    row[7].handlers.onClick = function()
      STATE.page = math.min(maxPage, STATE.page + 1)
      reopen(false)
    end
    row[8]:setColSpan(2):createText(STATE.dataMode == "all" and "Live and stale" or "Live only", { halign = "right" })
  end

  for i = startIndex, endIndex do
    local deal = deals[i]
    local row = t:addRow(true, {})
    local fillText = deal.full and "full bay" or string.format("%d%% of bay", math.floor(deal.amount * 100 / math.max(1, deal.units)))
    row[1]:createText(deal.wareName, { mouseOverText = string.format("%s m3 each · %s", tostring(deal.volume), fillText) })
    row[2]:createButton({
      height = rowH,
      mouseOverText = string.format("Show buy station on map\n%s · station has %s · %s each", deal.buySector, safeInt(deal.buyStock), safeMoney(deal.buyPrice)),
    }):setText(deal.buyName .. "  " .. safeMoney(deal.buyPrice))
    row[2].handlers.onClick = function()
      showOnMap(deal.buyStation64)
    end
    row[3]:createButton({
      height = rowH,
      mouseOverText = string.format("Show sell station on map\n%s · station buys %s · %s each", deal.sellSector, safeInt(deal.sellStock), safeMoney(deal.sellPrice)),
    }):setText(deal.sellName .. "  " .. safeMoney(deal.sellPrice))
    row[3].handlers.onClick = function()
      showOnMap(deal.sellStation64)
    end
    row[4]:createText(safeInt(deal.amount), { mouseOverText = fillText })
    local costOpts = { mouseOverText = "Credits needed to buy this run" }
    if deal.cost > money then
      costOpts.color = negative
      costOpts.mouseOverText = "Player account has less than this buy costs"
    end
    row[5]:createText(safeMoney(deal.cost), costOpts)
    row[6]:createText(safeMoney(deal.profit), {
      mouseOverText = string.format("Margin %s per unit", safeMoney(deal.sellPrice - deal.buyPrice)),
    })
    local tip = string.format(
      "Buy %s (%d jumps)\nSell %s (%d jumps)\n%s\nTravel %s m/s. About 250 km per jump, plus docking.",
      fmtDuration(deal.buySeconds), deal.buyJumps,
      fmtDuration(deal.sellSeconds), deal.sellJumps,
      home and string.format("Return to %s: %s (%d jumps)", home.name, fmtDuration(deal.homeSeconds), deal.homeJumps) or "No return",
      safeInt(ship.speed)
    )
    row[7]:createText(fmtDuration(deal.seconds), { mouseOverText = tip })
    local freshTip = string.format(
      "Buy price: %s\nSell price: %s\nLive means a ship or satellite covers that station right now.",
      deal.buyStale and "stale" or "live",
      deal.sellStale and "stale" or "live"
    )
    local freshOpts = { mouseOverText = freshTip }
    if deal.buyStale or deal.sellStale then
      freshOpts.color = inactive
    end
    row[8]:createText(freshLabel(deal), freshOpts)
    row[9]:createButton({
      height = rowH,
      mouseOverText = string.format("Buy at %s, sell at %s, return to %s", deal.buyName, deal.sellName, home and home.name or "-"),
    }):setText("Exec")
    row[9].handlers.onClick = function()
      executeDeal(deal, ship, home)
      reopen(false)
    end
  end
end

local function hookUserQuestion()
  if not mapMenu or mapMenu._pd_hooked_question then return end
  mapMenu._pd_hooked_question = true
  if type(mapMenu.createUserQuestionContext) ~= "function" then
    log("createUserQuestionContext is missing")
    return
  end
  mapMenu._pd_oldQuestion = mapMenu._pd_oldQuestion or mapMenu.createUserQuestionContext
  local old = mapMenu._pd_oldQuestion
  mapMenu.createUserQuestionContext = function(frame)
    if mapMenu.contextMenuData and mapMenu.contextMenuData.mode == BTN_MODE then
      local force = mapMenu.contextMenuData.forceRescan and true or false
      mapMenu.contextMenuData.forceRescan = false
      local ok, err = pcall(buildPopup, frame, force)
      if not ok then log("window: " .. tostring(err)) end
      return
    end
    return old(frame)
  end
end

openPopup = function(force)
  if not mapMenu then return end
  hookUserQuestion()
  popupOpen = true
  if mapMenu._pd_prevPicking == nil then
    mapMenu._pd_prevPicking = mapMenu.picking
  end
  mapMenu.picking = false

  local width = math.min(Helper.scaleX(1500), Helper.viewWidth - 2 * Helper.borderSize)
  local topPad = Helper.scaleY(90)
  local bottomPad = Helper.scaleY(60)
  local height = math.min(Helper.scaleY(860), Helper.viewHeight - topPad - bottomPad)
  if height < Helper.scaleY(220) then height = Helper.scaleY(220) end
  local x = math.floor((Helper.viewWidth - width) / 2)
  local y = math.floor(Helper.viewHeight - bottomPad - height)
  if y < topPad then y = topPad end

  mapMenu.contextMenuMode = "userquestion"
  mapMenu.contextMenuData = {
    mode = BTN_MODE,
    xoffset = x,
    yoffset = y,
    width = width,
    height = height,
    forceRescan = force and true or false,
  }
  if type(mapMenu.createContextFrame) ~= "function" then
    log("createContextFrame is missing")
    closePopup()
    return
  end
  local oldMode = mapMenu.mode
  mapMenu.mode = "tradecontext"
  local ok, err = pcall(mapMenu.createContextFrame, width, height, x, y)
  mapMenu.mode = oldMode
  if not ok then
    log("createContextFrame: " .. tostring(err))
    closePopup()
  end
end

local function togglePopup()
  if not mapMenu then return end
  if popupOpen and mapMenu.contextMenuData and mapMenu.contextMenuData.mode == BTN_MODE then
    closePopup()
    return
  end
  openPopup(false)
end

local function hookRightBarClick()
  if not mapMenu or mapMenu._pd_hooked_rightbar then return end
  mapMenu._pd_hooked_rightbar = true
  if type(mapMenu.buttonToggleRightBar) ~= "function" then return end
  local old = mapMenu.buttonToggleRightBar
  mapMenu.buttonToggleRightBar = function(mode, confirmed)
    if mode == BTN_MODE then
      togglePopup()
      return
    end
    return old(mode, confirmed)
  end
end

local function hookClose()
  if not mapMenu or mapMenu._pd_hooked_close then return end
  mapMenu._pd_hooked_close = true
  if type(mapMenu.closeContextMenu) ~= "function" then return end
  local old = mapMenu.closeContextMenu
  mapMenu.closeContextMenu = function(...)
    if mapMenu.contextMenuData and mapMenu.contextMenuData.mode == BTN_MODE then
      popupOpen = false
      restorePicking()
      if not rebuilding then
        releaseScan()
      end
    end
    return old(...)
  end
end

local function hookCallbackRegistry()
  if not mapMenu or mapMenu._pd_hooked_register or type(mapMenu.registerCallback) ~= "function" then return end
  mapMenu._pd_hooked_register = true
  local old = mapMenu.registerCallback
  mapMenu.registerCallback = function(callbackName, callbackFunction, id)
    if callbackName == "createRightBar_on_start" and id ~= MOD_ID then
      callbackFunction = wrapRightBarCallback(id or "?", callbackFunction)
    end
    return old(callbackName, callbackFunction, id)
  end
  local callbacks = mapMenu.uix_callbacks and mapMenu.uix_callbacks["createRightBar_on_start"]
  if type(callbacks) == "table" then
    for id, fn in pairs(callbacks) do
      if id ~= MOD_ID and type(fn) == "function" then
        callbacks[id] = wrapRightBarCallback(id, fn)
      end
    end
  end
end

local function safeRegister(menu, name, fn)
  if type(menu.registerCallback) == "function" then
    pcall(menu.registerCallback, name, fn, MOD_ID)
  end
end

local function attemptInit()
  if initialized then return end
  if not Helper or type(Helper.getMenu) ~= "function" then return end
  mapMenu = Helper.getMenu("MapMenu")
  if not mapMenu then return end
  hookRightBarClick()
  hookClose()
  hookUserQuestion()
  hookCallbackRegistry()
  safeRegister(mapMenu, "createRightBar_on_start", createRightBar_on_start)
  initialized = true
  log("map button ready")
end

local function init()
  log("profitable_deals.lua loaded")
  if Helper and type(Helper.registerMenu) == "function" and not _G.__PD_GUARD.hookedRegisterMenu then
    _G.__PD_GUARD.hookedRegisterMenu = true
    local old = Helper.registerMenu
    Helper.registerMenu = function(menu, ...)
      local result = old(menu, ...)
      pcall(attemptInit)
      return result
    end
  end
  attemptInit()
end

if Register_OnLoad_Init then
  Register_OnLoad_Init(init, MOD_ID .. "_init")
else
  init()
end
