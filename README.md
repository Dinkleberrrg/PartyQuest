# PartyQuest

Shows your party members' quest progress — in the Blizzard quest log and in
the pfQuest tracker. Built for **Octo WoW (client 1.12)**.

## What it does

* **Side panel on the quest log** – Select a quest on the left and the panel
  next to it shows how far each group member has got: objective by
  objective, in traffic-light colors. Anyone who does not have the quest, or
  does not have the addon, is noted in grey.
* **Counter in the quest list** – Behind each quest title, how many party
  members have the same quest in their log. Green when all of them are ready
  to turn it in.
* **pfQuest tracker** – Under each tracked quest, one line per member with
  their overall progress (`Thrall 6/8`, `Jaina done`).

## Requirement

Everyone whose progress you want to see needs the addon too.
Without pfQuest everything works except the tracker extension.

## Commands

| Command | Effect |
| --- | --- |
| `/pq status` | Who is broadcasting, how many quests are queued |
| `/pq sync` | Request and send a full sync |
| `/pq log` | Quest log panel on/off |
| `/pq rows` | Counters in the quest list on/off |
| `/pq tracker` | pfQuest tracker lines on/off |
| `/pq self` | Your own progress in the panel on/off |
| `/pq on` / `/pq off` | Sync on/off entirely |
| `/pq debug` | Debug output |

## How it works

Syncs over the addon channel (`SendAddonMessage`, prefix `PQT`) in party and
raid. Only changes are sent; a send queue throttles to one message every
0.3 s so the 1.12 client does not kick you for chat flooding. Messages stay
below 250 bytes (vanilla limit: 255) — long quests are chunked
automatically, and dropped to no objective labels if needed, since the
receiver usually knows the texts from their own quest log anyway.

The quest key is the numeric quest id from the pfQuest database; without
pfQuest a hash of the quest title is used, and the title is sent alongside
so mixed setups still find each other.

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
