# MobHPBars

HP bars over monsters for Final Fantasy XI (Ashita v4).

- A slim HP bar with the mob's name and HP % above every nearby monster
- Debuff icons under the bar, 6 per row (the bar lifts to make room for extra rows)
- A pale trail in the thin lower bar shows recently lost HP, then drains away
- Soft glow and a bobbing arrow on your target; the glow turns red on mobs you or your party have engaged, and stays red when you target something else
- Different metal colours for elites (gold) and NMs/bosses (crimson, larger, red bar)
- Bar height adjusts to each mob's size, with per-mob overrides you can share between characters
- Hides the game's own monster names while loaded
- Two styles: `sleek` (default) and `gold`

## Install

1. Copy this folder to `Ashita/addons/MobHPBars` (it must contain `MobHPBars.lua` and the `assets` folder).
2. In game: `/addon load MobHPBars`

## First run

Type `/np debug`. A green dot should sit at your character's feet. If it doesn't, cycle `/np axis` until it does, then turn debug off with `/np debug`.

## Commands

All commands work with `/np` or `/mobhpbars`.

| Command | What it does |
| --- | --- |
| `/np` | Show help |
| `/np style sleek` / `/np style gold` | Switch bar style |
| `/np size <n>` / `/np width <n>` | Height / width of the current style's bar, in px |
| `/np scale <n>` | Target plate scale |
| `/np height <n>` | Base height above the mob, in yalms |
| `/np auto` / `/np sizefactor <n>` | Automatic height by mob size / how strongly size raises the bar |
| `/np mobheight <n>` | Fix the height for every mob with your target's name (no number clears it) |
| `/np export` / `/np import [merge]` | Save / load heights via `shared_heights.txt` to share between characters |
| `/np distance <n>` | Max distance to show bars |
| `/np hp` | Toggle HP % text |
| `/np icons <n>` / `/np perrow <n>` | Debuff icon size / icons per row |
| `/np glow <n>` / `/np pulse` / `/np arrow` | Target glow size (0 = off) / glow pulse / target arrow |
| `/np elite <name>` / `/np boss <name>` | Toggle a mob name as elite / NM |
| `/np gamenames` | Toggle hiding the game's own monster names |
| `/np players` | Toggle bars over players |
| `/np claim` | Colour bars by claim (yellow / red / grey) |
| `/np status` | Diagnostics (camera, entity counts, target hitbox and height) |
| `/np debug` / `/np axis` | Calibration dot / cycle the world axis mode |
| `/np clear` | Clear all tracked debuffs |

## Notes

- Everything is drawn client-side. The addon sends nothing to the server.
- Hiding monster names edits the client's copy of incoming entity packets. Check your server's rules on addons before using it; `/np gamenames` turns it off.
- Mob levels are only known after you `/check` a mob, so "Lv" appears, and elites are detected, from `/check` results or your own `/np elite` list.
- Debuffs are removed when the game reports them wearing off, when a held mob (Bind, Sleep, Stun, Petrify, Terror) moves or acts, or when the mob dies or despawns.

Author: Laudout
