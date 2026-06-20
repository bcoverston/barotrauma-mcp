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
-- Sentinel that gates the (footgun) console verb. Created out-of-band by the
-- operator; no bridge verb writes it, so the agent can't self-enable console.
local CONSOLE_FLAG  = DIR .. "/console.enabled"
local AUTONOMY_FILE = DIR .. "/autonomy"     -- operator-set capability level

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

-- The reactor Item + its Reactor component on the player sub. operatereactor
-- needs a concrete target; the hazard snapshot reads the reactor's status.
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

-- Player-sub hazard snapshot (additive `sub` block). Every game-API read is
-- safe()-wrapped, degrading to a default (-1 / false / "?") instead of crashing
-- the round. fires + flooding share one pass over HullList; leaks mirror the
-- engine's AIObjectiveFixLeaks.IsValidTarget gate so they match what the
-- `fixleaks` order acts on. Returns nil when there's no sub.
local function snapshotSub()
  local sub = safe(function() return Submarine.MainSub end, nil)
  if sub == nil then return nil end

  local fires, flooding = {}, {}
  local hulls = safe(function() return Hull.HullList end, nil)
  if hulls ~= nil then
    for _, hull in pairs(hulls) do
      if safe(function() return hull.Submarine == sub end, false) then
        local room = safe(function() return tostring(hull.DisplayName) end, "?")

        -- Active fires. hull.FireCount is a reliable scalar int (= FireSources.Count,
        -- real fires only). Neither pairs() nor the 0-based list indexer enumerate
        -- this CLR List<T> in this MoonSharp build (per-fire Size reads back 0), so
        -- report the fire-source count as the severity proxy instead.
        local nFires = safe(function() return hull.FireCount end, 0)
        if nFires > 0 then
          fires[#fires + 1] = { room = room, count = nFires }
        end

        -- WaterPercentage is unclamped (can exceed 100 under pressure); clamp it.
        -- Skip designer-marked wet rooms (ballast tanks etc.): IsWetRoom means the
        -- hull is meant to hold water, so its level isn't a flooding emergency.
        local pct = safe(function() return hull.WaterPercentage end, 0)
        if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
        pct = math.floor(pct + 0.5)
        local wet = safe(function() return hull.IsWetRoom end, false)
        if pct > 1 and not wet then flooding[#flooding + 1] = { room = room, pct = pct } end
      end
    end
  end

  local leaks = {}
  local gaps = safe(function() return Gap.GapList end, nil)
  if gaps ~= nil then
    for _, gap in pairs(gaps) do
      local breach = safe(function()
        return gap.Submarine == sub and gap.ConnectedWall ~= nil
           and gap.ConnectedDoor == nil and gap.Open > 0
      end, false)
      if breach then
        local room = safe(function()
          local h = gap.FlowTargetHull
          if h == nil then
            for _, e in pairs(gap.linkedTo) do
              if e ~= nil then h = e; break end
            end
          end
          if h ~= nil and h.DisplayName ~= nil then return tostring(h.DisplayName) end
          return "outside"
        end, "?")
        leaks[#leaks + 1] = {
          room    = room,
          open    = safe(function() return math.floor(gap.Open * 100) / 100 end, 0),
          toOcean = safe(function() return not gap.IsRoomToRoom end, false),
        }
      end
    end
  end

  -- reactor: nil when the sub has none. meltdown has no public flag — the real
  -- threshold is private (~Lerp(70,90,skill)); derive conservatively and also
  -- expose raw temp so the agent can apply its own threshold.
  local reactor = nil
  local _, r = findReactor()
  if r ~= nil then
    local temp = safe(function() return r.Temperature end, -1)
    reactor = {
      temp          = math.floor(temp + 0.5),
      meltdown      = (temp ~= -1 and temp > 90)
                        or safe(function() return r.MeltedDownThisRound end, false),
      fissionRate   = safe(function() return math.floor(r.FissionRate + 0.5) end, -1),
      turbineOutput = safe(function() return math.floor(r.TurbineOutput + 0.5) end, -1),
      -- output = kW generated. (The reactor's separate Load/demand field is a
      -- property that `new`-shadows a base field, which MoonSharp can't resolve, so
      -- it's omitted; output is the meaningful "is it producing power" signal and
      -- tracks served load at steady state.)
      output        = safe(function() return math.floor(-r.CurrPowerConsumption) end, -1),
      fuel          = safe(function() return math.floor(r.AvailableFuel) end, -1),
      autoTemp      = safe(function() return r.AutoTemp end, false),
      powerOn       = safe(function() return r.PowerOn end, false),
    }
  end

  return { fires = fires, leaks = leaks, flooding = flooding, reactor = reactor }
end

----------------------------------------------------------------------
-- autonomy levels  (operator-controlled capability ceiling)
----------------------------------------------------------------------
-- The agent's authority is gated by a level in the operator-owned file
-- LocalMods/AgentBridgeIO/autonomy (no bridge verb writes files, so the agent
-- can't raise its own ceiling). Absent file => the safest tier. See docs/AUTONOMY.md.
local DEFAULT_LEVEL = "observe"
local LEVELS     = { observe = 0, advise = 1, coordinate = 2, pilot = 3, override = 4 }
local LEVEL_NAME = { [0] = "observe", [1] = "advise", [2] = "coordinate", [3] = "pilot", [4] = "override" }
-- Minimum level each verb requires. Verbs absent here aren't level-gated.
local VERB_LEVEL = { ping = 0, say = 1, order = 2, report = 2, control = 2, console = 4 }
local VERB_ORDER = { "ping", "say", "order", "report", "control", "console" }

-- Current level (num, name), read live from the operator file each call.
local function currentLevel()
  local name = safe(function()
    if File.Exists(AUTONOMY_FILE) then
      return (File.Read(AUTONOMY_FILE) or ""):match("(%a+)")
    end
  end, nil)
  name = name and name:lower() or DEFAULT_LEVEL
  if LEVELS[name] == nil then name = DEFAULT_LEVEL end
  return LEVELS[name], name
end

local function writeState()
  local lvlNum, lvlName = currentLevel()
  local allows = {}
  for _, v in ipairs(VERB_ORDER) do
    if lvlNum >= VERB_LEVEL[v] then allows[#allows + 1] = v end
  end
  local state = {
    schemaVersion = 1,
    t          = safe(function() return math.floor(Timer.GetTime() * 100) / 100 end, 0),
    roundStarted = safe(function() return Game.RoundStarted end, false),
    controlled = safe(function()
                   return Character.Controlled ~= nil and Character.Controlled.Name or "none"
                 end, "none"),
    autonomy   = { level = lvlName, allows = allows },
    crew       = snapshotCrew(),
    sub        = snapshotSub(),
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

-- Gated passthrough to the debug console via Game.ExecuteCommand (LuaCs's
-- wrapper; the raw DebugConsole isn't a Lua global). OFF unless the operator
-- creates the sentinel file (CONSOLE_FLAG) — no bridge verb writes it, so the
-- agent can't self-enable. ExecuteCommand returns void, so a true ack means
-- "dispatched without a Lua error", not "the command succeeded". Cheat-gated
-- commands (spawnitem, fire, …) need a prior `console enablecheats`.
local function handleConsole(arg)
  if not safe(function() return File.Exists(CONSOLE_FLAG) end, false) then
    return { ok = false, error = "console disabled — create " .. CONSOLE_FLAG .. " to enable" }
  end
  local cmd = tostring(arg or "")
  if cmd == "" then return { ok = false, error = "usage: console <command line>" } end
  local ran, err = pcall(function() Game.ExecuteCommand(cmd) end)
  if not ran then return { ok = false, error = "exec: " .. tostring(err) } end
  return { ok = true, did = "console", cmd = cmd,
           note = "dispatched (console returns no value to confirm success)" }
end

-- Crew-wide report ("reportbreach"/"reportfire"/"reportintruders", or the short
-- breach/fire/intruders): unlike `order`, this binds no specific bot — it posts
-- to the crew and the nearest suitable IDLE bot self-assigns (the in-game
-- "Report …" buttons). The reporter is the controlled character and must be
-- inside the sub (the report's hull comes from its CurrentHull).
local REPORT_ALIAS = {
  breach = "reportbreach", leak = "reportbreach", water = "reportbreach",
  fire = "reportfire", intruders = "reportintruders", intruder = "reportintruders",
}
local function handleReport(arg)
  local id = tostring(arg or ""):match("^%s*(%S+)")
  id = id and id:lower() or ""
  id = REPORT_ALIAS[id] or id
  local prefab = safe(function() return OrderPrefab.Prefabs[id] end, nil)
  if prefab == nil then return { ok = false, error = "unknown report: " .. id } end

  local reporter = Character.Controlled
  if reporter == nil then return { ok = false, error = "no controlled character to report" } end
  local hull = safe(function() return reporter.CurrentHull end, nil)
  if hull == nil then return { ok = false, error = "reporter isn't inside the sub" } end

  local cm = safe(function() return Game.GameSession.CrewManager end, nil)
  if cm == nil then return { ok = false, error = "no CrewManager (round not running?)" } end

  -- Build like the report button (hull-targeted, orderGiver = reporter), then
  -- post crew-wide with a nil character so a suitable idle bot self-assigns.
  local built, order = pcall(function()
    return Order(prefab, hull, nil).WithOrderGiver(reporter)
  end)
  if not built then return { ok = false, error = "build: " .. tostring(order) } end

  local posted, err = pcall(function() cm.SetCharacterOrder(nil, order) end)
  if not posted then return { ok = false, error = "report: " .. tostring(err) } end
  return { ok = true, did = "report", report = id,
           reporter = safe(function() return tostring(reporter.Name) end, "?") }
end

-- Switch the locally-controlled character to a named/job-resolved crew member
-- (the `control` console command's behaviour: a direct Character.Controlled set,
-- no cheats). Falls back to the console command if the setter is unavailable.
local function handleControl(arg)
  local target = findCrew(arg)
  if target == nil then return { ok = false, error = "no crew matches '" .. tostring(arg) .. "'" } end
  if safe(function() return target.IsDead end, false) then
    return { ok = false, error = "cannot control a dead character" }
  end
  local set = safe(function() Character.Controlled = target; return true end, false)
  if not set then
    safe(function() Game.ExecuteCommand("control " .. tostring(target.Name)) end)
  end
  return {
    ok = safe(function() return Character.Controlled == target end, false),
    did = "control",
    target = safe(function() return tostring(target.Name) end, "?"),
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

  elseif verb == "console" then
    return handleConsole(arg)

  elseif verb == "report" then
    return handleReport(arg)

  elseif verb == "control" then
    return handleControl(arg)

  else
    return { ok = false, error = "unknown verb: " .. tostring(verb) }
  end
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

  -- Autonomy gate: refuse verbs above the operator-set level (the mod enforces;
  -- the agent can't escalate itself). Unknown verbs fall through to handleCommand.
  local lvlNum, lvlName = currentLevel()
  local need = VERB_LEVEL[verb]
  local result
  if need ~= nil and lvlNum < need then
    result = { ok = false, error = "'" .. verb .. "' needs autonomy level '" ..
               LEVEL_NAME[need] .. "' (current '" .. lvlName .. "')" }
  else
    result = handleCommand(verb, arg)
  end
  result.seq = seq
  result.level = lvlName
  safe(function() File.Write(ACK_PATH, jsonEncode(result)) end)
  print("[AgentBridge] ran '" .. verb .. "' seq=" .. seq .. " ok=" .. tostring(result.ok) .. " lvl=" .. lvlName)
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
