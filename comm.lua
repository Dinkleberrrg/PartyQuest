--[[ PartyQuest -- comm
     Addon channel protocol over SendAddonMessage (present in 1.12).

     Message format, fields separated by tab:
       H <ver> <proto> <hash> <count> <reply>   hello / version / state hash
       R [<name>]                               please send a full sync
                                                (to everyone, or only <name>)
       Q <key> <lvl> <complete> <start> <title> <objblob>
                                                quest (possibly split up)
       D <key>                                  quest gone (turned in/abandoned)
       L <total> <start> <key,key,...>          key list closing a full sync:
                                                anything not listed is gone

     complete: 1 = ready to turn in, 0 = in progress, -1 = failed.
     objblob: objectives separated by "~", fields per objective by "#":
       label#cur#req#done

     Compatibility with v1.0 (protocol 1): v1.0 sent "H 1.<version>" and
     no hash, knows no L, and ignores the extra H fields. It answers every
     H and every R with a full sync. So mixed groups keep working; v1.0
     members just do not benefit from the lower traffic.

     When does a full sync happen?
       - own login/reload or joining a group: we send R, then H; everybody
         answers R with their quest log and requests ours via the hash
       - loading screen (zoning): only H; others answer with their own H,
         and whoever sees a hash mismatch asks with a targeted R
       - someone new in the group: they do the above; we send a late H so
         they can check our state

     Hard limit in vanilla: prefix + "\t" + message < 255 characters.
     So the blob gets chunked when needed, and in the extreme case sent
     without labels (the receiver usually has the quest in their own log
     and knows the labels anyway).
]]--

local PQ = PartyQuest

local MAX_MSG      = 230   -- safety margin below the 255 limit
local SEND_DELAY   = 0.30  -- seconds between two messages (anti-disconnect)
local QUEUE_LIMIT  = 120
local LABEL_MAX    = 22

PQ.queue      = {}
PQ.queueCount = 0
PQ.queueHead  = 1

--------------------------------------------------------------------------
-- Sending (throttled)
--------------------------------------------------------------------------

local function Enqueue(msg)
  if PQ.queueCount - PQ.queueHead + 1 >= QUEUE_LIMIT then
    -- Queue is filling up: drop the oldest rather than flood the client
    PQ.queue[PQ.queueHead] = nil
    PQ.queueHead = PQ.queueHead + 1
  end
  PQ.queueCount = PQ.queueCount + 1
  PQ.queue[PQ.queueCount] = msg
end

function PQ.QueueLength()
  return PQ.queueCount - PQ.queueHead + 1
end

local sender = CreateFrame("Frame", "PartyQuestSender", UIParent)
sender.next = 0
sender:SetScript("OnUpdate", function()
  if PQ.queueHead > PQ.queueCount then return end
  if GetTime() < sender.next then return end

  local channel = PQ.SyncChannel()
  if not channel then
    -- no group any more: throw the queue away
    for i = PQ.queueHead, PQ.queueCount do PQ.queue[i] = nil end
    PQ.queueHead, PQ.queueCount = 1, 0
    return
  end

  local msg = PQ.queue[PQ.queueHead]
  PQ.queue[PQ.queueHead] = nil
  PQ.queueHead = PQ.queueHead + 1
  if PQ.queueHead > PQ.queueCount then PQ.queueHead, PQ.queueCount = 1, 0 end

  if msg then
    SendAddonMessage(PQ.prefix, msg, channel)
    PQ.Debug("send: " .. msg)
  end
  sender.next = GetTime() + SEND_DELAY
end)

--------------------------------------------------------------------------
-- Building quest messages
--------------------------------------------------------------------------

local function EncodeObjective(o, withLabel)
  local label = withLabel and PQ.Truncate(o.label or "", LABEL_MAX) or ""
  return label .. "#" .. o.cur .. "#" .. o.req .. "#" .. o.done
end

-- Builds one or more Q messages for a single quest.
local function BuildQuestMessages(key, q)
  local out, n = {}, 0
  local title = PQ.NormTitle(q.title)

  local withLabel = true
  local attempt = 0

  while attempt < 2 do
    attempt = attempt + 1
    out, n = {}, 0

    local i = 1
    while i <= q.objCount do
      local start = i
      local head = "Q\t" .. key .. "\t" .. q.level .. "\t" .. q.complete .. "\t" .. start .. "\t"
        .. (start == 1 and title or "") .. "\t"
      local blob, parts = "", 0
      while i <= q.objCount do
        local piece = EncodeObjective(q.obj[i], withLabel)
        local candidate = (parts == 0) and piece or (blob .. "~" .. piece)
        if strlen(head) + strlen(candidate) > MAX_MSG and parts > 0 then break end
        blob = candidate
        parts = parts + 1
        i = i + 1
        if strlen(head) + strlen(blob) > MAX_MSG then break end
      end
      n = n + 1
      out[n] = head .. blob
      if parts == 0 then break end -- emergency brake against an endless loop
    end

    -- Quest with no objectives at all (e.g. a pure turn-in quest)
    if q.objCount == 0 then
      n = 1
      out[1] = "Q\t" .. key .. "\t" .. q.level .. "\t" .. q.complete .. "\t1\t" .. title .. "\t"
    end

    -- If it takes more than 3 messages with labels: drop the labels.
    if n <= 3 or not withLabel then break end
    withLabel = false
  end

  return out, n
end

-- Builds the L messages listing every key we have.
local function BuildListMessages()
  local keys, total = {}, 0
  for key in pairs(PQ.mine) do
    total = total + 1
    keys[total] = key
  end

  local out, n = {}, 0
  local i = 1
  repeat
    local start = i
    local head = "L\t" .. total .. "\t" .. start .. "\t"
    local blob = ""
    while i <= total do
      local candidate = (blob == "") and keys[i] or (blob .. "," .. keys[i])
      if strlen(head) + strlen(candidate) > MAX_MSG and blob ~= "" then break end
      blob = candidate
      i = i + 1
    end
    n = n + 1
    out[n] = head .. blob
  until i > total

  return out, n
end

--------------------------------------------------------------------------
-- Public send functions
--------------------------------------------------------------------------

-- full = true  -> send everything (answer to a request)
-- full = nil   -> send changes only
function PQ.Broadcast(full)
  -- Keep our own snapshot current even while syncing is off or we are
  -- alone, so the panel's "You" lines and a later full sync are accurate.
  local changed, removed, nRemoved = PQ.DiffOwnQuestlog()

  if not PQ.db or PQ.db.enabled ~= "1" then return end
  if not PQ.SyncChannel() then return end

  local list = full and PQ.mine or changed
  for key, q in pairs(list) do
    local msgs, n = BuildQuestMessages(key, q)
    for i = 1, n do Enqueue(msgs[i]) end
  end

  for i = 1, nRemoved do
    Enqueue("D\t" .. removed[i])
  end

  if full then
    local msgs, n = BuildListMessages()
    for i = 1, n do Enqueue(msgs[i]) end
  end
end

-- reply = true: answer to someone else's hello (they must not answer again)
function PQ.SendHello(reply)
  if not PQ.db or PQ.db.enabled ~= "1" then return end
  if not PQ.SyncChannel() then return end
  -- Flush pending changes first, so the hash matches what was sent.
  PQ.Broadcast(nil)
  local hash, count = PQ.StateHash(PQ.mine)
  Enqueue("H\t" .. PQ.versionStr .. "\t" .. PQ.protocol .. "\t" .. hash .. "\t" .. count
    .. "\t" .. (reply and "1" or "0"))
  PQ.lastHello = GetTime()
end

-- name = nil: everybody please; otherwise only that player
function PQ.SendRequest(name)
  if not PQ.db or PQ.db.enabled ~= "1" then return end
  if not PQ.SyncChannel() then return end
  if name then
    Enqueue("R\t" .. name)
  else
    Enqueue("R")
  end
end

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

local function HandleQuest(member, fields)
  -- Q \t key \t lvl \t complete \t start \t title \t objblob
  local key      = fields[2]
  local level    = tonumber(fields[3]) or 0
  local complete = tonumber(fields[4]) or 0
  local start    = tonumber(fields[5]) or 1
  local title    = fields[6] or ""
  local blob     = fields[7] or ""

  if not key or key == "" then return end

  local q = member.quests[key]
  if start == 1 or not q then
    if q then PQ.UnindexTitle(member, q) end
    q = { title = title, level = level, complete = complete, obj = {}, objCount = 0 }
    member.quests[key] = q
  end

  q.level    = level
  q.complete = complete
  if title ~= "" then q.title = title end
  PQ.IndexTitle(member, q)

  if blob ~= "" then
    local pieces, pn = PQ.Split(blob, "~")
    for i = 1, pn do
      local f, fn = PQ.Split(pieces[i], "#")
      if fn >= 4 then
        local idx = start + i - 1
        q.obj[idx] = {
          label = f[1] or "",
          cur   = tonumber(f[2]) or 0,
          req   = tonumber(f[3]) or 1,
          done  = tonumber(f[4]) or 0,
        }
        if idx > q.objCount then q.objCount = idx end
      end
    end
  end

  member.time = GetTime()
  PQ.Touch()
end

local function RemoveQuest(member, key)
  local q = member.quests[key]
  if not q then return end
  PQ.UnindexTitle(member, q)
  member.quests[key] = nil
end

-- L \t total \t start \t keys: collect, then drop everything not listed.
local function HandleList(member, fields)
  local total = tonumber(fields[2])
  local start = tonumber(fields[3]) or 1
  if not total then return end

  if start == 1 then
    member.list, member.listN = {}, 0
  end
  if not member.list then return end -- missed the first part

  local keys, kn = PQ.Split(fields[4] or "", ",")
  for i = 1, kn do
    if keys[i] ~= "" and not member.list[keys[i]] then
      member.list[keys[i]] = true
      member.listN = member.listN + 1
    end
  end

  if member.listN >= total then
    for key in pairs(member.quests) do
      if not member.list[key] then RemoveQuest(member, key) end
    end
    member.list, member.listN = nil, nil
    member.time = GetTime()
    PQ.Touch()
  end
end

local function HandleHello(member, from, fields)
  local proto = tonumber(fields[3])
  member.time = GetTime()

  if not proto then
    -- v1.0 sent "1.<version>"; it also sends R right after, which gets
    -- our data to them. Nothing else to do here.
    member.proto = 1
    member.version = gsub(fields[2] or "?", "^%d+%.", "")
    PQ.Touch()
    return
  end

  member.proto = proto
  member.version = fields[2]
  PQ.Touch()

  local hash = tonumber(fields[4])
  if hash and hash ~= PQ.StateHash(member.quests) then
    -- Our copy of their quest log is stale: ask only them.
    if not member.requested or GetTime() - member.requested > 5 then
      member.requested = GetTime()
      PQ.SendRequest(from)
    end
  end

  -- Answer a fresh hello with our own, so they can check our state too.
  if fields[6] ~= "1" then
    PQ.ScheduleHello(0.5 + math.random() * 1.5, true)
  end
end

local lastRosterCheck = 0

function PQ.OnAddonMessage(prefix, message, channel, from)
  if prefix ~= PQ.prefix then return end
  if not message or not from then return end
  if from == UnitName("player") then return end
  if not PQ.db or PQ.db.enabled ~= "1" then return end

  -- Only people in our roster count (in a raid: our subgroup). A message
  -- from someone unknown may mean the roster event has not arrived yet.
  if not PQ.roster[from] then
    if GetTime() - lastRosterCheck < 1 then return end
    lastRosterCheck = GetTime()
    PQ.OnRosterChanged()
    if not PQ.roster[from] then return end
  end

  local fields = PQ.Split(message, "\t")
  local cmd = fields[1]
  local member = PQ.GetMember(from)

  if cmd == "H" then
    HandleHello(member, from, fields)

  elseif cmd == "R" then
    local target = fields[2]
    if not target or target == "" or target == UnitName("player") then
      PQ.ScheduleFullSync(0.5 + math.random() * 1.5)
    end

  elseif cmd == "Q" then
    HandleQuest(member, fields)

  elseif cmd == "D" then
    local key = fields[2]
    if key and member.quests[key] then
      RemoveQuest(member, key)
      member.time = GetTime()
      PQ.Touch()
    end

  elseif cmd == "L" then
    HandleList(member, fields)
  end
end

--------------------------------------------------------------------------
-- Timing / events
--------------------------------------------------------------------------

local timer = CreateFrame("Frame", "PartyQuestTimer", UIParent)
timer.fullAt  = nil
timer.deltaAt = nil
timer.helloAt = nil

function PQ.ScheduleFullSync(delay)
  local at = GetTime() + (delay or 1)
  if not timer.fullAt or at < timer.fullAt then timer.fullAt = at end
end

function PQ.ScheduleDelta(delay)
  local at = GetTime() + (delay or 1)
  if not timer.deltaAt or at > timer.deltaAt then timer.deltaAt = at end
  -- Never defer longer than 3s, even under a barrage of events
  if timer.deltaFirst and at - timer.deltaFirst > 3 then timer.deltaAt = timer.deltaFirst + 3 end
  if not timer.deltaFirst then timer.deltaFirst = GetTime() end
end

-- A plain hello wins over a reply if both are pending.
function PQ.ScheduleHello(delay, reply)
  local at = GetTime() + (delay or 1)
  if not timer.helloAt or at < timer.helloAt then timer.helloAt = at end
  if not reply then timer.helloPlain = true end
end

timer:SetScript("OnUpdate", function()
  local now = GetTime()
  if timer.fullAt and now >= timer.fullAt then
    timer.fullAt = nil
    timer.deltaAt, timer.deltaFirst = nil, nil
    PQ.Broadcast(true)
  elseif timer.deltaAt and now >= timer.deltaAt then
    timer.deltaAt, timer.deltaFirst = nil, nil
    PQ.Broadcast(nil)
  elseif timer.helloAt and now >= timer.helloAt and not timer.fullAt then
    -- (waits for a pending full sync, so the hash goes out after the data)
    local reply = not timer.helloPlain
    timer.helloAt, timer.helloPlain = nil, nil
    PQ.SendHello(reply)
  end
end)

-- Rebuilds the roster and reacts to joins. Returns true if it already
-- greeted the group (so the caller does not need to send another hello).
function PQ.OnRosterChanged()
  local joined, nJoined, wasAlone = PQ.UpdateRoster()
  if nJoined == 0 or not PQ.SyncChannel() then return nil end

  if wasAlone then
    -- We just joined (or logged in / reloaded inside a group): ask
    -- everybody for their quest log. The hello follows a little later,
    -- once our own quest log is loaded after a login.
    PQ.SendRequest()
    PQ.ScheduleHello(3)
  else
    -- Someone new: they ask us themselves. The late hello (as a reply,
    -- so nobody answers it) lets them check our state once our answer
    -- has gone out, and makes v1.0 members send us theirs.
    PQ.ScheduleHello(3, true)
  end
  return true
end

local events = CreateFrame("Frame", "PartyQuestEvents", UIParent)
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
events:RegisterEvent("QUEST_WATCH_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function()
  if event == "CHAT_MSG_ADDON" then
    PQ.OnAddonMessage(arg1, arg2, arg3, arg4)

  elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
    PQ.OnRosterChanged()

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- First call after login/reload: the roster is empty, so everybody
    -- counts as joined and OnRosterChanged sends H + R. After a loading
    -- screen only a hello goes out; the hashes decide whether anything
    -- needs to be resent.
    PQ.ScheduleDelta(3)
    if not PQ.OnRosterChanged() and PQ.SyncChannel() then
      PQ.ScheduleHello(4)
    end

  else
    -- QUEST_LOG_UPDATE / UNIT_QUEST_LOG_CHANGED / QUEST_WATCH_UPDATE
    PQ.ScheduleDelta(1)
  end
end)
