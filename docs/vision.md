# Eldmark: game vision

## Concept

A 3D medieval fantasy MMORPG centered on the war between three realms. Each
player belongs to a realm. Within their own realm they progress through PvE
content; in the central war zone they fight the other two realms for control
of forts and castles.

## The three realms

Chosen setting: **The Broken Crown**. The three peoples were once a single
kingdom, Eld, ruled from the citadel of Aldcor, where the Flame of Eld burned.
When the last king died without an heir, the three bloodlines fought over the
throne; the Flame exploded and the land cracked open (the Rift). The Embers of
Eld, shards of the Flame, still burn in the ruins and grant power to whoever
controls them.

| Realm | Inspiration and landscape | Architecture | Colors and emblem | Capital |
|---|---|---|---|---|
| **Vardheim** (north) | Norse and Anglo-Saxon clans; fjords, pine forests, tundra and glaciers | Longhouses of dark wood, palisades, rough stone towers | Steel gray and ice blue; white wolf | Isenholm |
| **Solmarch** (southwest) | Gothic theocracy; fertile valleys, vineyards, slow rivers | Pale limestone, cathedrals, conical towers of blue slate | White and gold; split radiant sun | Valcorin |
| **Askarra** (southeast) | Forge lords and merchants; red canyons, mesas and volcanic fields | Red sandstone and terracotta, low domes, cities carved into the rock | Crimson and bronze; anvil over a burning crack | Kassar |

The war zone is **Eldrun**: the corpse of the old kingdom, with the ruined
citadel of Aldcor at its center. The details of the zones, fortresses and the
first border zone are in [world.md](world.md).

Each realm has:

- A capital city, plus further towns and villages
- Six zones in all: the capital, four PvE zones (levels 1-10, 10-20, 20-32 and 32-45) and a border zone (45-60). The level cap is 60, reached in about 50 hours with the first character, and shared dungeons for groups of 3-5 open from level 15
- One human people, purely cosmetic: hairstyles, beards, marks and the cut of the outfits, with the same skeleton and no racial stats
- A wall surrounding the whole realm, with gates that open onto the war zone

The sizes of the maps (capital 1 × 1 km, PvE zones 1.5 × 1.5 or 2 × 2 km, border zones 3 × 1.5 km and Eldrun 3 × 3 km) are in the [Scale](world.md#scale) section of world.md.

## Central war zone

A map shared by the three realms, at the center of the world. Each realm
connects to it through the gates of its wall.

- **Forts**: small objectives that are quick to capture.
- **Castles**: large objectives, with walls, gates and several lines of defense.
- Destructible gates and walls, and siege weapons.
- NPC defenders (guards and a fortress lord) who must be defeated to capture the fortress.
- The realm that captures a fortress keeps it until another realm takes it away.
- Controlling fortresses grants rewards to the whole realm: Embers for the realm treasury, which pay automatic blessings and the siege, and, personally, merits, Ember Shards and war ranks. All of it is horizontal: nothing here makes a veteran stronger than a newcomer.
- Vado Gris (from level 10) and Eldrun (from level 20) are normalized: everyone fights at level 60 with their attributes and equipment compressed, so that skill weighs more than hours played.

## Technical decisions that follow from this vision

- **Zone-based world, not continuous.** Each zone is an independent map with its
  own server process. Moving from one to another (for example, crossing the gate
  in the wall) involves a short load. It is simpler, scales better and avoids
  the numerical precision problems of giant maps.
- **Authoritative server** for everything that matters in PvP: movement, damage and
  fortress state. The client never decides outcomes.
- **The war zone is the most demanding map**, with many players at once.
  Each client receives only what is near it, and performance is measured from
  the very beginning.
- **Action combat** (see next section): requires client-side prediction
  and server-side lag compensation from day one.

## Combat

Third-person action combat, New World style:

- Over-the-shoulder camera with a crosshair. The mouse always moves the camera;
  a key frees the cursor to use the interface.
- Light and heavy attacks, block and dodge, managed with stamina.
- No target selection: attacks hit if the weapon's arc or the projectile
  touches the enemy.
- Abilities with cooldowns, tied to the equipped weapon: five per weapon, of which three are carried, plus an ultimate of the chosen specialization on its own key (F, 150 s cooldown).

How it works over the network without the server losing authority:

- **Client-side prediction**: your character moves and attacks instantly on
  your screen; the server confirms and corrects if needed.
- **Interpolation**: other players are displayed slightly in the past
  so that they move smoothly.
- **Lag compensation**: the server keeps a short history of where each player
  was and checks hits by "rewinding" to the moment the attacker saw them.
- **Server-side validation**: stamina, cooldowns, range
  and line of sight. The client only sends intents.
- **Player cap per battle**: action combat is more expensive to
  compute. We need to measure early how many players the war zone can handle
  and design the sieges accordingly.

## Characters and progression

There are no fixed classes. Any weapon can be used, two at once with a quick swap, and the role comes from the weapons and from a **specialization** chosen at level 10 after a role trial:
Vanguard, Linebreaker, Hunter, Healer and Arcanist, with the Sapper joining with the siege. A specialization gives passives by rank and an ultimate; it can be changed later only in a capital, for gold.
Each weapon family has its own mastery and a talent tree, and ten weapons are planned at launch. The design is in [advancement.md](advancement.md), [weapons.md](weapons.md), [items.md](items.md), [npcs.md](npcs.md) and [quests.md](quests.md).

## Community and communication

The realms are at war, so there is no diplomacy: of an enemy you see the body, the side and, when
you aim at them, the name, but their voice never reaches you. Chat, whispers, parties and guilds are only for the same
realm and the server filters by realm before sending; between realms only animations cross (including
taunts) and nothing else. Within a realm there are range-based channels (say, zone, party, raid, guild,
realm), parties of 5, raids for the big battles, pings and tactical markers instead of voice chat,
and a ladder of sanctions. The whole design, with provisional numbers, is in [social.md](social.md).

## First playable goal

Before building the full realms: a small border map with one capturable
fort and two realms facing each other. It is the heart of the game; if that
is fun, the rest is built around it.

## Roadmap

The breakdown into tasks, with dependencies and pending decisions, is in [backlog.md](backlog.md).

1. Character and camera: WASD movement and an over-the-shoulder action camera
2. Networking: dedicated server, multiple players, prediction and interpolation, realm selection ([design](networking.md))
3. Action combat: attacks, block, dodge, stamina, lag compensation, death and respawn
4. First capturable fort on a small border map
5. Accounts, characters and database persistence
6. First realm: capital city, one PvE zone, wall and gate
7. Full war zone: several forts and castles, siege weapons and rewards
8. The three full realms and scaling to multiple servers
