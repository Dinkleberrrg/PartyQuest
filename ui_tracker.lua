--[[ PartyQuest -- pfQuest tracker extension

     Appends one line per party member under each tracked quest:
       Thrall   6/8
       Jaina    done

     Implemented as a wrapper around pfQuest.tracker.ButtonEvent (which sets
     each button's height fresh on every call, so our extra height does not
     accumulate) and around tracker.DoLayout (width correction).

     PartyQuest loads before pfQuest (folder alphabet), so the hook is
     installed when pfQuest has loaded, with a retry loop as fallback.
     pfQuest stores ButtonEvent as each button's OnEvent script when it
     creates the button; buttons created before our hook would keep
     calling the original (their height snaps back while our lines stay
     visible). So the script of every button is checked and re-pointed.
]]--

local PQ = PartyQuest

local MAX_MEMBER_LINES = 5

--------------------------------------------------------------------------
-- Lines for one tracked quest
--------------------------------------------------------------------------
local function BuildTrackerLines(title, questid)
  local out, n = {}, 0
  if not PQ.db or PQ.db.tracker ~= "1" then return out, 0 end
  if not title then return out, 0 end

  local key = questid and ("q" .. questid) or nil
  if key and not tonumber(questid) then key = nil end

  local names, count = {}, 0
  for name in pairs(PQ.roster) do
    count = count + 1
    names[count] = name
  end
  if count == 0 then return out, 0 end
  table.sort(names, function(a, b) return a < b end)

  for i = 1, count do
    if n >= MAX_MEMBER_LINES then break end
    local name = names[i]
    local member = PQ.party[name]
    local q = member and PQ.FindQuest(member, key, title) or nil
    if q then
      local text
      if q.complete == 1 then
        text = PQ.C.green .. "done" .. PQ.C.off
      elseif q.complete == -1 then
        text = PQ.C.red .. "failed" .. PQ.C.off
      else
        local cur, req = PQ.QuestProgress(q)
        if req > 0 then
          text = PQ.ProgressColor(cur, req) .. cur .. "/" .. req .. PQ.C.off
        else
          text = PQ.C.grey .. "in progress" .. PQ.C.off
        end
      end
      n = n + 1
      out[n] = PQ.ClassColor(name) .. PQ.Truncate(name, 12) .. PQ.C.off .. "  " .. text
    end
  end

  return out, n
end

--------------------------------------------------------------------------
-- Decorate a single tracker button
--------------------------------------------------------------------------
local function DecorateButton(btn)
  if not btn or btn.empty or not btn.title then return end

  btn.pqlines = btn.pqlines or {}
  local existing = table.getn(btn.pqlines)
  for i = 1, existing do btn.pqlines[i]:Hide() end

  if not PQ.db or PQ.db.tracker ~= "1" then return end
  if not pfQuest or not pfQuest.tracker or pfQuest.tracker.mode ~= "QUEST_TRACKING" then return end

  local height = btn:GetHeight()
  if not height or height <= 0 then return end -- collapsed

  local lines, n = BuildTrackerLines(btn.title, btn.questid)
  if n == 0 then return end

  local fontsize = tonumber(pfQuest_config and pfQuest_config["trackerfontsize"]) or 12
  local font = (pfUI and pfUI.font_default) or "Fonts\\FRIZQT__.TTF"

  for i = 1, n do
    if not btn.pqlines[i] then
      local fs = btn:CreateFontString(nil, "HIGH", "GameFontNormal")
      fs:SetJustifyH("LEFT")
      btn.pqlines[i] = fs
    end
    local fs = btn.pqlines[i]
    fs:SetFont(font, fontsize)
    fs:ClearAllPoints()
    local offset = -(height + fontsize * (i - 1))
    fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 26, offset)
    fs:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -8, offset)
    fs:SetText(lines[i])
    fs:Show()
  end

  btn:SetHeight(height + n * fontsize)
end

--------------------------------------------------------------------------
-- Install hooks (as soon as pfQuest exists)
--------------------------------------------------------------------------
local installer = CreateFrame("Frame", "PartyQuestTrackerInit", UIParent)
installer.next = 0
installer.tries = 0

local function InstallHooks()
  if not pfQuest or not pfQuest.tracker then return nil end
  local tracker = pfQuest.tracker
  if tracker.pqHooked then return true end

  local originalEvent = tracker.ButtonEvent
  tracker.ButtonEvent = function(self)
    local btn = self or this
    originalEvent(btn)
    DecorateButton(btn)
  end
  tracker.pqButtonEvent = tracker.ButtonEvent

  local originalLayout = tracker.DoLayout
  tracker.DoLayout = function()
    originalLayout()
    -- Widen if our lines are longer than the quest texts
    local width = tracker:GetWidth() - 30
    for _, btn in pairs(tracker.buttons) do
      if btn.pqlines then
        local count = table.getn(btn.pqlines)
        for i = 1, count do
          local fs = btn.pqlines[i]
          if fs:IsShown() then
            local w = fs:GetStringWidth() + 20
            if w > width then width = w end
          end
        end
      end
    end
    tracker:SetWidth(math.min(width, 300) + 30)
  end

  tracker.pqHooked = true
  PQ.Debug("hooked pfQuest tracker")
  return true
end

-- Points every button's OnEvent at our wrapper (see header).
local function FixButtonScripts()
  local tracker = pfQuest.tracker
  for _, btn in pairs(tracker.buttons) do
    if btn.GetScript and btn:GetScript("OnEvent") ~= tracker.pqButtonEvent then
      btn:SetScript("OnEvent", tracker.pqButtonEvent)
    end
  end
end

-- Redraws every tracker button when party data has changed.
local function RefreshTracker()
  if not pfQuest or not pfQuest.tracker or not pfQuest.tracker.pqHooked then return end
  local tracker = pfQuest.tracker
  for _, btn in pairs(tracker.buttons) do
    if not btn.empty and btn.title then
      tracker.ButtonEvent(btn)
    end
  end
  tracker.DoLayout()
end

installer:RegisterEvent("ADDON_LOADED")
installer:SetScript("OnEvent", function()
  if arg1 == "pfQuest" and not installer.ok then
    installer.ok = InstallHooks()
  end
end)

installer:SetScript("OnUpdate", function()
  if GetTime() < installer.next then return end
  installer.next = GetTime() + 1

  if not installer.ok then
    installer.tries = installer.tries + 1
    installer.ok = InstallHooks()
    if not installer.ok and installer.tries > 30 then
      -- pfQuest is apparently not installed -- switch the module off quietly
      installer:SetScript("OnUpdate", nil)
    end
    return
  end

  FixButtonScripts()

  if PQ.dataRev ~= installer.rev then
    installer.rev = PQ.dataRev
    RefreshTracker()
  end
end)

PQ.RefreshTracker = RefreshTracker
