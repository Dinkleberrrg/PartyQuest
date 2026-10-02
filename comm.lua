--[[ PartyQuest -- comm
     Addon channel protocol over SendAddonMessage (present in 1.12).

     Message format, fields separated by tab:
       H <ver>                                  hello / version
       R                                        please send a full sync
       Q <key> <lvl> <complete> <start> <title> <objblob>
                                                quest (possibly split up)
       D <key>                                  quest gone (turned in/abandoned)

     objblob: objectives separated by "~", fields per objective by "#":
       label#cur#req#done

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

local sender = CreateFrame("Frame", "PartyQuestSender", UIParent)
sender.next = 0
sender:SetScript("OnUpdate", function()
  if PQ.queueHead > PQ.queueCount then return end
  if GetTime() < sender.next then return end

  local channel = PQ.InGroup()
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
  local title = PQ.Truncate(PQ.Clean(q.title or ""), 48)

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

--------------------------------------------------------------------------
-- Public send functions
--------------------------------------------------------------------------

function PQ.SendHello()
  if not PQ.InGroup() then return end
  Enqueue("H\t" .. PQ.protocol .. "." .. PQ.versionStr)
end

function PQ.SendRequest()
  if not PQ.InGroup() then return end
  Enqueue("R")
end

-- full = true  -> send everything (for new group members)
-- full = nil   -> send changes only
function PQ.Broadcast(full)
  if not PQ.db or PQ.db.enabled ~= "1" then return end
  if not PQ.InGroup() then
    -- still track our own state so a later full sync is accurate
    PQ.DiffOwnQuestlog()
    return
  end

  local changed, removed, nRemoved = PQ.DiffOwnQuestlog()

  if full then
    for key, q in pairs(PQ.mine) do
      local msgs, n = BuildQuestMessages(key, q)
      for i = 1, n do Enqueue(msgs[i]) end
    end
  else
    for key, q in pairs(changed) do
      local msgs, n = BuildQuestMessages(key, q)
      for i = 1, n do Enqueue(msgs[i]) end
    end
  end

  for i = 1, nRemoved do
    Enqueue("D\t" .. removed[i])
  end
end

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

local function HandleQuest(member, fields, count)
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
    q = { title = title, level = level, complete = complete, obj = {}, objCount = 0 }
    member.quests[key] = q
  end

  q.level    = level
  q.complete = complete
  if title ~= "" then q.title = title end
  if q.title and q.title ~= "" then member.byTitle[q.title] = q end

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

function PQ.OnAddonMessage(prefix, message, channel, from)
  if prefix ~= PQ.prefix then return end
  if not message or not from then return end
  if from == UnitName("player") then return end
  if not PQ.db or PQ.db.enabled ~= "1" then return end

  local fields, count = PQ.Split(message, "\t")
  local cmd = fields[1]
  local member = PQ.GetMember(from)

  if cmd == "H" then
    member.version = fields[2]
    member.time = GetTime()
    PQ.Touch()
    -- New player around: send our own state, slightly staggered so not
    -- everyone fires at the same moment.
    PQ.ScheduleFullSync(1 + math.random() * 2)

  elseif cmd == "R" then
    PQ.ScheduleFullSync(0.5 + math.random() * 1.5)

  elseif cmd == "Q" then
    HandleQuest(member, fields, count)

  elseif cmd == "D" then
    local key = fields[2]
    if key and member.quests[key] then
      local title = member.quests[key].title
      if title and member.byTitle[title] == member.quests[key] then
        member.byTitle[title] = nil
      end
      member.quests[key] = nil
      member.time = GetTime()
      PQ.Touch()
    end
  end
end

--------------------------------------------------------------------------
-- Timing / events
--------------------------------------------------------------------------

local timer = CreateFrame("Frame", "PartyQuestTimer", UIParent)
timer.fullAt  = nil
timer.deltaAt = nil

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

timer:SetScript("OnUpdate", function()
  local now = GetTime()
  if timer.fullAt and now >= timer.fullAt then
    timer.fullAt = nil
    timer.deltaAt, timer.deltaFirst = nil, nil
    PQ.Broadcast(true)
  elseif timer.deltaAt and now >= timer.deltaAt then
    timer.deltaAt, timer.deltaFirst = nil, nil
    PQ.Broadcast(nil)
  end
end)

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
    PQ.UpdateRoster()
    if PQ.InGroup() then
      PQ.SendHello()
      PQ.SendRequest()
      PQ.ScheduleFullSync(2)
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    PQ.UpdateRoster()
    if PQ.InGroup() then
      PQ.SendHello()
      PQ.SendRequest()
      PQ.ScheduleFullSync(6)
    else
      PQ.ScheduleDelta(3)
    end

  else
    -- QUEST_LOG_UPDATE / UNIT_QUEST_LOG_CHANGED / QUEST_WATCH_UPDATE
    PQ.ScheduleDelta(1)
  end
end)
