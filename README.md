# PartyQuest

Shows your party members' quest progress — in the Blizzard quest log and in
the pfQuest tracker. Built for **Octo WoW (client 1.12)**.

## What it does

* **Side panel on the quest log** – Select a quest on the left and the panel
  next to it shows how far each group member has got: objective by
  objective, in traffic-light colors. Failed quests (escort, timer) show in
  red. Anyone who does not have the quest, or does not have the addon, is
  noted in grey.
* **Counter in the quest list** – Behind each quest title, how many party
  members have the same quest in their log. Green when all of them are ready
  to turn it in.
* **pfQuest tracker** – Under each tracked quest, one line per member with
  their overall progress (`Thrall 6/8`, `Jaina done`).

## Requirement

Everyone whose progress you want to see needs the addon too.
Without pfQuest everything works except the tracker extension.

Version 1.1 works together with 1.0 in the same group. Members on 1.0 are
marked as "old version" in `/pq status`; the traffic savings only apply
once everyone is on 1.1.

In a raid only your own subgroup is shown by default (`/pq raid` switches
between own subgroup, whole raid and off).

## Commands

| Command | Effect |
| --- | --- |
| `/pq status` | Who is broadcasting, how many quests are queued |
| `/pq sync` | Request and send a full sync |
| `/pq log` | Quest log panel on/off |
| `/pq rows` | Counters in the quest list on/off |
| `/pq tracker` | pfQuest tracker lines on/off |
| `/pq self` | Your own progress in the panel on/off |
| `/pq raid` | In raids: own subgroup / whole raid / off |
| `/pq on` / `/pq off` | Sync on/off entirely |
| `/pq debug` | Debug output |

## How it works

Syncs over the addon channel (`SendAddonMessage`, prefix `PQT`) in party and
raid. Only changes are sent; a send queue throttles to one message every
0.3 s so the 1.12 client does not kick you for chat flooding.

A full quest log is only sent when someone asks for it: after your own
login/reload or when you join a group. After a loading screen only a short
hello with a hash of your quest log goes out; whoever finds that their copy
does not match asks you, and only you, for a full sync. A full sync ends
with a list of all quest keys, so quests that were turned in while a
message got lost disappear on the receiving side too. Turn-ins are also
detected while zone headers in your quest log are collapsed. Messages stay
below 250 bytes (vanilla limit: 255) — long quests are chunked
automatically, and dropped to no objective labels if needed, since the
receiver usually knows the texts from their own quest log anyway.

The quest key is the numeric quest id that pfQuest already resolved for
your quest log (`pfQuest.questlog`); without pfQuest a hash of the quest
title is used, and the title is sent alongside so mixed setups still find
each other.

The protocol is described at the top of `comm.lua`.

No XML, no modern APIs (`C_*`, `hooksecurefunc`, `#tbl`, `string.gmatch`,
`select`) — all Lua 5.0 / 1.12 compatible.

## Files

```
core.lua         namespace, config, roster, helpers
scan.lua         read own quest log, build diff
comm.lua         sync protocol (send/receive/throttle)
ui_questlog.lua  panel on the quest log + counters in the list
ui_tracker.lua   pfQuest tracker extension
slash.lua        /pq
_test/           offline test harness (not loaded by the game)
```

## Changelog

### 1.1.0
* Failed quests are shown as failed instead of "ready to turn in".
* Full syncs end with a key list, so stale quests no longer stick around.
* Turn-ins are reported while zone headers are collapsed.
* Long titles match between clients (same normalisation on both sides).
* pfQuest tracker: lines no longer overlap the next entry.
* Much less traffic: no full resync on every loading screen or roster
  change; state hash in the hello, targeted requests.
* Raids: own subgroup only by default, `/pq raid`.
* Quest ids come from `pfQuest.questlog` instead of a database lookup
  on every scan.
* `/pq status` shows old versions and the send queue; `/pq on` requests
  data from the group.

### 1.0.0
* First version.
