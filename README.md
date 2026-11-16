# AI Village

A small Godot 4 3D village where each of my n8n AI agents is an RPG villager showing live status.
v1 is **watch mode**: see at a glance who is fine, who is working, and who failed.

| Villager | Agent | Building |
|---|---|---|
| Paladin (Knight) | 01 Inbox Sorter | barracks |
| Bard (Ranger) | 02 Daily Planner | tavern |
| Mage | 06 Deep Research | wizard tower |
| Sage (Rogue) | 07 Ask Notes | windmill |
| Cleric (Barbarian) | 08 Error Alert + 17 Catch-up | healer church |
| You, hooded assassin | the Guild Master | castle |

States: **ok** (strolls near its building), **working** (work animation), **failed** (walks the ring road to the church and lies down until a run passes), **no runs yet**, **no signal** (feed down, everyone greys out).

## How it works
1. n8n workflow "19 Village Status" asks the n8n API for each agent's last run.
2. It answers on `http://127.0.0.1:5678/webhook/village-status` (local only: requests through a proxy get 404).
3. The game polls that URL every 10 s (`scripts/village.gd`) and each villager (`scripts/villager.gd`) reacts.

The game holds no keys, tokens or personal data. The n8n API key lives only in n8n.

## Talk (v3)
The game posts `{agent, message, history}` to `http://127.0.0.1:5678/webhook/village-talk` (n8n "21 Village Talk").
The villager answers from real facts (its state, last run, failed node and error message), using Claude Haiku with a local qwen3 fallback.
Answers take about 5-30 s. Villagers only suggest fixes, they never change anything.

## Jobs (v2)
The game posts `{agent, input, job, confirm}` to `http://127.0.0.1:5678/webhook/village-job` (n8n "22 Village Jobs"). Only five jobs exist; nothing else can be started from the game.
Villagers also greet you first and chat with each other (code-written lines from real status, no AI cost).

## Run
Open the folder in Godot 4.7 (Import > select `project.godot`) and press **F5**. Or:
```
Godot_v4.7.2-stable_win64.exe --path C:\Projects\ai-village
```

## Controls
- **Tab** or the top-right button: walk mode / monitor mode
- **T** (walk mode, next to a villager): talk. Esc leaves the chat. "What went wrong?" asks a failed villager for its error and fix steps
- **WASD / arrows**: walk (walk mode)
- **Right-drag or Q/E**: turn the camera. **Wheel**: zoom. **R**: slow turntable
- **Job button** (orange, in the chat): give the villager its job: Paladin sorts the inbox, Bard re-plans today (press twice), Mage researches the topic in the box, Sage answers the question in the box
- **Mark done** (green): type what you finished, the villager ticks the matching task in your notes (n8n "16 Done")
- **Demo failure** button or **F9**: pretend one agent failed (cycles sorter, planner, deep, ask, off). Only the reply is faked
- **F5**: refresh now

## Command line (after `--`)
`--feed=<url>` `--talk=<agent>:<message>` `--mode=walk|monitor` `--demo=<key>` `--demo-off-after=<s>` `--yaw=<deg>` `--shot=<file.png> --shot-after=<s>` (screenshot and quit, used for testing)

## Folders
- `scripts/` 3D village (main scene `main.tscn`)
- `legacy_2d/` first 2D version (Kenney art), kept for reference
- `assets/kaykit/`, `assets/tiny-*/` art packs with their license files

## Credits
3D art: [KayKit](https://kaylousberg.itch.io) by Kay Lousberg: Adventurers, Character Animations, Medieval Hexagon (CC0).
2D art: [Kenney](https://kenney.nl) Tiny Town and Tiny Dungeon (CC0).
