--[[ PartyQuest -- scan
     Reads your own quest log and turns it into a compact snapshot.
]]--

local PQ = PartyQuest

--------------------------------------------------------------------------
-- Quest key
--------------------------------------------------------------------------
-- Prefers the numeric quest id because that is identical on every client.
-- pfQuest already keeps the mapping questlog index -> quest id for the
-- whole log (pfQuest.questlog), so we read it from there; asking
-- pfDatabase:GetQuestIDs for every scan would reselect quest log entries
-- and, without a cache hit, search the whole database.
-- Without pfQuest we fall back to a hash of the title; the title is sent
-- along anyway, so the receiver still finds the quest either way (see
-- PQ.FindQuest).
local idCache = {}   -- [title .. "~" .. level] = "q<id>" (GetQuestIDs fallback)

function PQ.QuestKey(qlogid, title)
  if pfQuest and type(pfQuest.questlog) == "table" then
    for qid, data in pairs(pfQuest.questlog) do
      if data.qlogid == qlogid and data.title == title then
        if tonumber(qid) then return "q" .. tonumber(qid) end
        -- pfQuest knows the quest only by title: no id in its database
        return "t" .. PQ.Hash(title or "")
      end
    end
  end

  -- pfQuest.questlog lags behind for a moment after accepting a quest
  if pfDatabase and pfDatabase.GetQuestIDs then
    local _, level = GetQuestLogTitle(qlogid)
    local ck = (title or "") .. "~" .. (level or "")
    if idCache[ck] then return idCache[ck] end
    local ok, ids = pcall(function() return pfDatabase:GetQuestIDs(qlogid) end)
    if ok and type(ids) == "table" and ids[1] and tonumber(ids[1]) then
      idCache[ck] = "q" .. tonumber(ids[1])
      return idCache[ck]
    end
  end
  return "t" .. PQ.Hash(title or "")
end

--------------------------------------------------------------------------
-- Read a quest's objectives
--------------------------------------------------------------------------
-- GetQuestLogLeaderBoard returns text like "Kobold Miner slain: 3/8".
-- Some servers hand back a fullwidth colon (zhCN) or empty rows -- both
-- are handled here.
local function ReadObjectives(qlogid)
  local out, count = {}, 0
  local num = GetNumQuestLeaderBoards(qlogid) or 0
  for i = 1, num do
    local text, otype, done = GetQuestLogLeaderBoard(i, qlogid)
    if text then
      local normalized = gsub(text, "\239\188\154", ":")
      local _, _, label, cur, req = strfind(normalized, "(.*):%s*(%d+)%s*/%s*(%d+)")
      count = count + 1
      if cur and req then
        out[count] = {
          label = PQ.Clean(label),
          cur   = tonumber(cur) or 0,
          req   = tonumber(req) or 1,
          done  = (done and 1) or 0,
        }
      else
        -- Objective without a counter (e.g. "Speak to X") -> 0/1 or 1/1
        out[count] = {
          label = PQ.Clean(normalized),
          cur   = (done and 1) or 0,
          req   = 1,
          done  = (done and 1) or 0,
        }
      end
    end
  end
  return out, count
end

--------------------------------------------------------------------------
-- State string (basis for change detection and the state hash)
--------------------------------------------------------------------------
-- Works on our own snapshot and on received data alike, so both sides
-- compute the same string for the same quest.
function PQ.StateString(q)
  local parts, n = {}, 0
  n = n + 1; parts[n] = q.complete or 0
  for i = 1, (q.objCount or 0) do
    local o = q.obj and q.obj[i]
    n = n + 1
    if o then
      parts[n] = o.cur .. "/" .. o.req .. (o.done == 1 and "d" or "t")
    else
      parts[n] = "?"   -- a chunk went missing
    end
  end
  return table.concat(parts, ",")
end

-- One number for a whole quest log. Sent in the hello message: if the
-- receiver computes a different number for what it has stored, it asks
-- for a full sync -- otherwise nothing needs to be sent at all.
function PQ.StateHash(quests)
  local keys, n = {}, 0
  for key in pairs(quests) do
    n = n + 1
    keys[n] = key
  end
  table.sort(keys)
  local parts = {}
  for i = 1, n do
    parts[i] = keys[i] .. "=" .. PQ.StateString(quests[keys[i]])
  end
  return PQ.Hash(table.concat(parts, ";")), n
end

--------------------------------------------------------------------------
-- Overall progress of a quest, in percent
--------------------------------------------------------------------------
function PQ.QuestProgress(q)
  if not q then return 0, 0, 0 end
  if q.complete == 1 then return 1, 1, 100 end
  local cur, req = 0, 0
  for i = 1, (q.objCount or 0) do
    local o = q.obj[i]
    if o then
      cur = cur + (o.done == 1 and o.req or o.cur)
      req = req + o.req
    end
  end
  if req <= 0 then return 0, 0, 0 end
  return cur, req, cur / req * 100
end

--------------------------------------------------------------------------
-- Build a full quest log snapshot
--------------------------------------------------------------------------
-- Vanilla quirk: quests under a collapsed zone header are not returned by
-- GetQuestLogTitle at all. If we find fewer quests than
-- GetNumQuestLogEntries reports, the scan is partial. We remember which
-- header every quest sat under, so DiffOwnQuestlog can still tell "hidden"
-- from "turned in".
--
-- isComplete in 1.12: 1 = ready to turn in, -1 = failed, nil = in progress.
-- We store 1 / -1 / 0.
function PQ.ScanQuestLog()
  local snap, headers = {}, {}
  local _, numQuests = GetNumQuestLogEntries()
  numQuests = numQuests or 0
  local found = 0
  local header = ""

  for qlogid = 1, 50 do
    -- 1.12: title, level, questTag, isHeader, isCollapsed, isComplete
    local title, level, tag, isHeader, collapsed, complete = GetQuestLogTitle(qlogid)

    if isHeader then
      header = title or ""
      headers[header] = collapsed and true or false
    elseif title then
      local state = 0
      if complete == -1 then
        state = -1
      elseif complete then
        state = 1
      end

      local key = PQ.QuestKey(qlogid, title)
      local obj, objCount = ReadObjectives(qlogid)
      local q = {
        title    = title,
        level    = tonumber(level) or 0,
        complete = state,
        obj      = obj,
        objCount = objCount,
        qlogid   = qlogid,
        header   = header,
      }
      q.state = PQ.StateString(q)
      snap[key] = q

      found = found + 1
      if numQuests > 0 and found >= numQuests then break end
    end
  end

  local partial = (numQuests > 0 and found < numQuests) and true or nil
  return snap, partial, headers
end

--------------------------------------------------------------------------
-- Update our own state and report what changed
--------------------------------------------------------------------------
-- Returns: changed = { [key] = questdata }, removed = { key, key, ... }, nRemoved
function PQ.DiffOwnQuestlog()
  local snap, partial, headers = PQ.ScanQuestLog()
  local changed, removed, nRemoved = {}, {}, 0

  for key, q in pairs(snap) do
    local old = PQ.mine[key]
    if not old or old.state ~= q.state or old.title ~= q.title then
      changed[key] = q
    end
  end

  local newmine = {}
  for key, q in pairs(snap) do newmine[key] = q end

  for key, old in pairs(PQ.mine) do
    if not snap[key] then
      -- Partial scan: a quest whose header is still there but collapsed is
      -- probably just hidden. If its header is expanded, or gone entirely
      -- (last quest of that zone turned in), the quest is gone.
      if partial and old.header and headers[old.header] == true then
        newmine[key] = old
      else
        nRemoved = nRemoved + 1
        removed[nRemoved] = key
      end
    end
  end

  if partial then PQ.Debug("partial scan (collapsed header) -- hidden quests kept") end
  PQ.mine = newmine

  return changed, removed, nRemoved
end
