--[[
  Agent Bridge  v0.1
  ------------------------------------------------------------------
  The simplest possible "an external agent can drive it" Barotrauma mod.

  Every ~0.5s it:
    1. writes a JSON snapshot of crew/sub state to AgentBridge/state.json
    2. reads AgentBridge/command   (a tiny line-based command file)
    3. runs the command exactly once (deduped on file contents)
    4. writes the result to AgentBridge/ack.json

  A Claude Code agent runs as a separate process: it reads state.json,
  decides, and writes the command file. No sockets, no server — two
  files on disk are the entire IPC layer.

  Everything that touches the game API is wrapped in pcall() via safe()
  so version/context differences degrade to defaults instead of crashing
  the round.
--]]

-- IO directory. The LuaCs File sandbox only permits writes under a few roots
-- (save folder, LocalMods/, WorkshopMods/). A game-root-relative path like
-- "AgentBridge" is read-only — File.Write throws, safe() swallows it, and
-- state.json/ack.json silently never appear. So the bridge lives under
-- LocalMods/. The write probe at load (below) confirms this on the real build.
local DIR        = "LocalMods/AgentBridgeIO"
local STATE_PATH = DIR .. "/state.json"
local CMD_PATH   = DIR .. "/command"
local ACK_PATH   = DIR .. "/ack.json"

local TICK_SECONDS = 0.5   -- wall-clock tick interval, frame-rate independent
local lastTick     = -1    -- negative so the first frame always ticks
local seq          = 0
local lastCmdRaw   = nil

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

-- Run fn in a pcall; return its value, or `default` on error/nil.
local function safe(fn, default)
  local ok, res = pcall(fn)
  if ok and res ~= nil then return res end
  return default
end

-- Minimal JSON encoder for the flat tables/arrays we emit.
local function jsonEncode(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    -- guard against NaN/inf leaking into the file
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
  elseif t == "table" then
    local n, isArray = 0, true
    for k, _ in pairs(v) do
      n = n + 1
      if type(k) ~= "number" then isArray = false end
    end
    local parts = {}
    if isArray then
      for i = 1, n do parts[#parts + 1] = jsonEncode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. tostring(k) .. '":' .. jsonEncode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

-- Ensure the IO directory exists, then prove the sandbox actually lets us write
-- there. A swallowed File.Write is the #1 silent failure mode, so surface the
-- result once at load rather than discovering it as a perpetually-missing
-- state.json. The first tick overwrites this placeholder with real state.
safe(function()
  if File.DirectoryExists ~= nil and not File.DirectoryExists(DIR) then
    File.CreateDirectory(DIR)
  end
end)
do
  local ok, err = pcall(function() File.Write(STATE_PATH, "{}") end)
  if ok then
    print("[AgentBridge] write probe OK -> " .. STATE_PATH)
  else
    print("[AgentBridge] WRITE PROBE FAILED for " .. STATE_PATH ..
          " (" .. tostring(err) .. ") -- choose a writable root under LocalMods/.")
  end
end

----------------------------------------------------------------------
-- state snapshot  (the observability half)
----------------------------------------------------------------------

-- Top-priority order identifier for a character, or "none". The engine's
-- GetCurrentOrderWithTopPriority() already skips dismissed/priority<1 orders.
local function currentOrderId(ch)
  return safe(function()
    local o = ch.GetCurrentOrderWithTopPriority()
    return o ~= nil and tostring(o.Identifier) or "none"
  end, "none")
end

local function snapshotCrew()
  local crew = {}
  local list = Character.CharacterList
  if list == nil then return crew end
  for _, ch in pairs(list) do
    local onTeam = safe(function() return ch.IsOnPlayerTeam end, false)
    local human  = safe(function() return ch.IsHuman end, false)
    if onTeam and human then
      crew[#crew + 1] = {
        name         = safe(function() return ch.Name end, "?"),
        job          = safe(function() return tostring(ch.JobIdentifier) end, "?"),
        isBot        = safe(function() return ch.IsBot end, false),
        isControlled = safe(function() return Character.Controlled == ch end, false),
        health       = safe(function() return math.floor(ch.HealthPercentage) end, -1),
        bleeding     = safe(function() return math.floor((ch.Bloodloss or 0) * 10) / 10 end, 0),
        oxygen       = safe(function() return math.floor(ch.OxygenAvailable) end, -1),
        dead         = safe(function() return ch.IsDead end, false),
        room         = safe(function()
                          if ch.CurrentHull ~= nil and ch.CurrentHull.DisplayName ~= nil then
                            return tostring(ch.CurrentHull.DisplayName)
                          end
                          return "outside"
                        end, "?"),
        order        = currentOrderId(ch),
      }
    end
  end
  return crew
end

local function writeState()
  local state = {
    t          = safe(function() return math.floor(Timer.GetTime() * 100) / 100 end, 0),
    roundStarted = safe(function() return Game.RoundStarted end, false),
    controlled = safe(function()
                   return Character.Controlled ~= nil and Character.Controlled.Name or "none"
                 end, "none"),
    crew       = snapshotCrew(),
  }
  safe(function() File.Write(STATE_PATH, jsonEncode(state)) end)
end

----------------------------------------------------------------------
-- command handling  (the control half)
----------------------------------------------------------------------
-- Command file format is deliberately trivial so the agent needs no
-- serializer: first token = verb, everything after the first line = arg.
--
--   ping
--
--   say
--   Reactor is climbing, I'm heading to engineering.
--
--   order
--   operatereactor Bjorn Vade      (order id first, then bot name or job)
--
-- Dedup is by exact file contents. To re-issue an identical command,
-- change the file at all (e.g. append a trailing "# 2").

-- Find an alive, on-player-team human by exact name, then exact job, then a
-- name substring. Bot names contain spaces, so the order grammar puts the
-- single-token order id first and treats the rest of the line as the target.
local function findCrew(target)
  if target == nil or target == "" then return nil end
  local want = target:lower()
  local list = safe(function() return Character.CharacterList end, nil)
  if list == nil then return nil end
  local byName, byJob, bySub
  for _, ch in pairs(list) do
    local match = safe(function()
      return ch.IsOnPlayerTeam and ch.IsHuman and not ch.IsDead
    end, false)
    if match then
      local name = safe(function() return tostring(ch.Name) end, ""):lower()
      local job  = safe(function() return tostring(ch.JobIdentifier) end, ""):lower()
      if name == want and byName == nil then byName = ch end
      if job  == want and byJob  == nil then byJob  = ch end
      if bySub == nil and name:find(want, 1, true) then bySub = ch end
    end
  end
  return byName or byJob or bySub
end

-- The reactor Item + its Reactor component on the player sub. operatereactor
-- needs a concrete target; most other orders let the bot AI find their own.
local function findReactor()
  local sub = safe(function() return Submarine.MainSub end, nil)
  if sub == nil then return nil, nil end
  local items = safe(function() return sub.GetItems(true) end, nil)
  if items == nil then return nil, nil end
  for _, item in pairs(items) do
    local reactor = safe(function() return item.GetComponentString("Reactor") end, nil)
    if reactor ~= nil then return item, reactor end
  end
  return nil, nil
end

-- Issue a crew order: "<orderId> <bot name|job>". force=true bypasses the
-- SetOrder hearing-gate so distant bots still obey; manual priority makes the
-- bot act now instead of deferring to its autonomous objectives.
local function handleOrder(arg)
  local orderId, target = tostring(arg or ""):match("^%s*(%S+)%s*(.-)%s*$")
  orderId = orderId and orderId:lower() or ""
  if orderId == "" then
    return { ok = false, error = "usage: order <orderId> <bot name|job>" }
  end

  local prefab = safe(function() return OrderPrefab.Prefabs[orderId] end, nil)
  if prefab == nil then return { ok = false, error = "unknown order: " .. orderId } end

  local bot = findCrew(target)
  if bot == nil then
    return { ok = false, error = "no crew matches '" .. tostring(target) .. "'" }
  end

  -- reactor is target-specific; everything else is constructed target-less.
  local built, order = pcall(function()
    if orderId == "operatereactor" then
      local item, comp = findReactor()
      if item == nil then error("no reactor found on the sub") end
      return Order(prefab, "powerup", item, comp)
    end
    return Order(prefab, nil, nil)
  end)
  if not built then return { ok = false, error = "build: " .. tostring(order) } end

  -- best-effort manual priority; don't fail the order if the call is absent.
  order = safe(function()
    return order.WithManualPriority(CharacterInfo.HighestManualOrderPriority)
  end, order)

  local set, err = pcall(function() bot.SetOrder(order, true, true, true) end)
  if not set then return { ok = false, error = "setorder: " .. tostring(err) } end

  return {
    ok = true, did = "order", order = orderId,
    target = safe(function() return tostring(bot.Name) end, "?"),
  }
end

local function handleCommand(verb, arg)
  if verb == "ping" then
    return { ok = true, did = "pong" }

  elseif verb == "say" then
    local who = Character.Controlled
    if who == nil then return { ok = false, error = "no controlled character" } end
    local said = safe(function()
      who.Speak(tostring(arg or ""), nil, 0.0, "", 0.0)
      return true
    end, false)
    return { ok = said, did = "say", text = tostring(arg or "") }

  elseif verb == "order" then
    return handleOrder(arg)

  else
    return { ok = false, error = "unknown verb: " .. tostring(verb) }
  end
  -- NEXT VERB (see README): "console" via DebugConsole.ExecuteCommand, gated.
end

local function readAndRunCommand()
  local raw = nil
  if safe(function() return File.Exists(CMD_PATH) end, false) then
    raw = safe(function() return File.Read(CMD_PATH) end, nil)
  end
  if raw == nil or raw == "" or raw == lastCmdRaw then return end

  lastCmdRaw = raw
  seq = seq + 1

  -- An optional leading "@<nonce>" line exists only to make otherwise-identical
  -- commands distinct on disk (so they aren't deduped); strip it before parsing.
  local body = raw:gsub("^@[^\n]*\r?\n", "", 1)
  local verb, arg = body:match("^%s*(%S+)%s*\r?\n?(.*)$")
  verb = verb and verb:lower() or ""

  local result = handleCommand(verb, arg)
  result.seq = seq
  safe(function() File.Write(ACK_PATH, jsonEncode(result)) end)
  print("[AgentBridge] ran '" .. verb .. "' seq=" .. seq .. " ok=" .. tostring(result.ok))
end

-- Resume across cl_reloadluacs: keep the ack sequence monotonic (a reset to 0
-- would make the watcher's "wait for seq to advance" hang on the next command),
-- and treat the command file already on disk as consumed so a reload doesn't
-- replay the last command.
seq = safe(function()
  local raw = (File.Exists(ACK_PATH) and File.Read(ACK_PATH)) or ""
  local n = raw:match('"seq"%s*:%s*(%d+)')
  return n and tonumber(n) or 0
end, 0)
lastCmdRaw = safe(function()
  return (File.Exists(CMD_PATH) and File.Read(CMD_PATH)) or nil
end, nil)

----------------------------------------------------------------------
-- tick loop
----------------------------------------------------------------------

Hook.Add("think", "agentbridge.tick", function()
  local now = safe(function() return Timer.GetTime() end, nil)
  if now == nil or now - lastTick < TICK_SECONDS then return end
  lastTick = now
  writeState()
  readAndRunCommand()
end)

print("[AgentBridge] loaded. state -> " .. STATE_PATH .. ", commands <- " .. CMD_PATH)
