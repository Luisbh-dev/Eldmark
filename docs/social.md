# Eldmark: social design

What players can say and do to each other: what crosses the border between realms and what does not,
chat channels and ranges, parties and warbands, commands, rate limits, logs and sanctions. This is the
SOC-02 document: SOC-03 to SOC-40 of the [backlog](backlog.md) implement it, and it is the source of the
constants in [networking.md](networking.md) (reliable channel 3) and of the text of the rules (`docs/normas.md`, SOC-18).
For the world and the realms, see [world.md](world.md); for the vision, [vision.md](vision.md).

Every figure in this document (ranges, rates, retention periods, sanction durations) is
**provisional**: it was set overnight to unblock phases 3 and 4 and will be tuned with real playtests.
The name rules are already implemented (SOC-01, `NameRules`) and are only recalled here.

## 0. Decisions

Made overnight, following the backlog's recommendation (provisional; to be reviewed). All four came from the
"Decisiones pendientes" (pending decisions) of [backlog.md](backlog.md) and now live under "Decisiones tomadas" (decisions made).

| Question | Decision |
|---|---|
| What is visible of enemy players, and what can the realms communicate to each other? | Of the enemy only the color and emblem of their side are visible; their name appears only while aiming at them with the reticle, and always in the combat log and on the death screen. No chat, no whispers, no parties across realms, and the server filters it (section 1) |
| Are emotes visible across realms? | Only the animation: taunting the enemy is part of PvP and, without text, it is no communication channel (section 6) |
| Maximum party size? | 5, consistent with the 3-5 player dungeons of world.md and with frames that stay readable in combat; large battles are covered by warbands (section 3) |
| Built-in voice chat? | No voice until after launch: it is expensive and hard to moderate, and Discord already covers it; pings and markers (SOC-10) handle tactics inside the game (section 7) |

The two that were still pending were decided in phase 5 ([platform.md](platform.md) §0,
provisional, overnight): "ignore" applies to **the account**, silently, and the server also filters the
public channels (section 10); the chat log is kept **30 days**, whispers included, and **one year** for what is
copied into a report (section 8), with a legal review (GDPR) before the public tests.

## 1. What crosses between realms

The realms are at war and there is no diplomacy: what crosses the border is the enemy's **image** (how they
look, how they move, what they do to the world), never their **voice**. The server enforces it;
the client cannot ask for something the server does not send.

| What | Crosses between realms? | How |
|---|---|---|
| Appearance, position and animations | Yes | It is the game: you see the enemy, their tabards and their emblem |
| Side color and emblem | Yes | Always visible (also on the nameplate) |
| Character name | Only when aimed at | The enemy's nameplate shows the name while the reticle points at it (a few seconds of grace after looking away), and it always appears in the combat log and on the death screen ("Te ha derrotado X", "X has defeated you") |
| Enemy guild, level and equipment | No | Only an ally's are visible. Inspecting an enemy (SOC-29) returns no equipment, attributes, guild or level; only what is already visible and, from phase 8, their war rank |
| Enemy health | Yes, on their nameplate | When aimed at or after damaging them (combat decision in combate.md) |
| Chat (say, zone and the other channels) | No | The server **never** sends a client text from another realm |
| Whispers | No | Whispering an enemy answers "no está conectado" (is not online), without revealing that they exist |
| Parties, warbands, guilds, friends, mail, trade | No | Same realm only |
| Emotes | Animation only | Section 6 |
| Pings and tactical markers | No | Only to your own party and warband (SOC-10) |
| System messages | Those that affect both sides | "X ha capturado el fuerte" (X has captured the fort) is seen by everyone involved; the server composes the text |
| Names | Yes | A name is unique across the whole world, in any realm (SOC-13, the `NameRules` comparison key): it identifies a single character, so it can be reported and remembered |

Details that follow from this:

- **Shared zone.** In Eldrun, the Vado Gris and the borders, players of several realms share the
  same process. The "zone" channel and "say" only deliver within the sender's realm; the
  `ChatRouter` filters by realm when building the recipient list, not when displaying.
- **The Hollow** (neutral) does not talk: it has no chat; its NPC announcements are system messages.
- **Ignore and report** work with enemies (you can report someone who insults you with an emote or
  with an offensive name); ignoring an enemy has no practical effect because they cannot write to you.

## 2. Channels and ranges

Chat message: up to **255 characters** and 768 B (SOC-03, reliable channel 3, types `0x40` onwards),
with sender and recipient by name. The text is sanitized on the server before it is delivered (section 5).
With no command in front, the text goes to the **active channel**, which defaults to "say" and changes when
you type a channel command without text (`/g` leaves the party channel active).

| Channel | Command | Range | Phase |
|---|---|---|---|
| Say | `/d` · `/decir` | Same realm, within 30 m of the sender | 4 (SOC-04) |
| Zone | `/z` · `/zona` | The whole realm present in that zone and that instance (channel) | 4 |
| Whisper | `/s name text` · `/susurrar` | One character of the same realm; in phase 4 within the process, from phase 6 in any zone (SOC-20) | 4 · 6 |
| Reply | `/r text` · `/responder` | The last person you talked with | 4 |
| Party | `/g` · `/grupo` | The party members, wherever they are | 4 (SOC-06) |
| Warband | `/b` · `/banda` | The warband members | 7 (SOC-30) |
| Guild | `/gr` · `/gremio` | The guild members | 6 (SOC-25) |
| Officers | `/o` · `/oficiales` | The guild officers | 6 |
| Realm | `/reino` | The whole connected realm, at a slow rate | 6 (SOC-21) |
| Trade | `/comercio` | The whole connected realm, at a slow rate | 6 |
| Newcomers | `/novatos` | The whole connected realm that has joined the channel | 6 |
| System | (S→C only) | The recipient; server notices (`NOTICE`) and game notices | 4 |
| GM | `/gm …` | Moderation roles (SOC-14); visible tag | 5 |

- **Zone and instances.** A capital or a PvE zone with several instances ("channels", world.md) has one zone
  channel per instance. Eldrun is not split: there "zone" is the entire realm within Eldrun.
- **Eldrun and noise.** In Eldrun with hundreds of players, "zone" is still per realm; war
  events do not go through the player chat but through the realm's war channel (SOC-32).
- **Name of the help channel.** SOC-05 uses `/ayuda` to list the commands; the new players' question channel,
  which SOC-21 calls "ayuda" (help), is called **"novatos"** (newcomers) so they do not clash.
- **Colors.** Each channel has its own color, and the system and the GMs an unmistakable one; text from
  other players is displayed without interpreting BBCode (SOC-05).

## 3. Parties and warbands

| Concept | Value | Notes |
|---|---|---|
| Maximum party size | **5** (`PARTY_MAX_SIZE`) | A shared constant; dungeons of 3-5 |
| Who can party up | Same realm only | An invitation to an enemy is rejected on the server (SOC-06) |
| Invitation | Expires after **60 s**; at most 5 pending per sender | Accept and decline from the keyboard |
| Leader | The first one; the next oldest inherits on leaving | Can kick and change leader |
| Shared state | Health, stamina and position of each member at 2 Hz, even outside the interest radius (SOC-06, SOC-09) | |
| XP and credit sharing | Members within **100 m** (SOC-23); loot is personal (PRG-21) | |
| Reconnection | **5 min** of grace keeping the spot (SOC-22) | |
| War warband | Up to **4 parties (20 players)** in the first version; the final cap is set by TEC-34 with Eldrun's measured capacity | Leader and assistants, `/banda`, compact frames, pings to the whole warband (SOC-30) |
| Open warbands | Anyone in the realm joins with one click or by approaching the fortress they are attacking (SOC-31) | Phase 7 |

The party is 5 and not 6 or 8 because party frames have to stay readable while the eyes are on an
action combat with no target selection; for more people there is the warband.

## 4. Commands in Spanish

Commands start with `/` and are recognized regardless of case and accents
(`/Susurrar`, `/susurrar` and `/SUSURRAR` are equivalent; the comparison key is that of `NameRules`).
A player name as an argument is also case- and accent-insensitive and takes no quotes (names
have no spaces). An unknown command answers "Comando desconocido. Escribe /ayuda." (Unknown command. Type /ayuda.)
and a player without a role who types `/gm` gets the same: it does not reveal that it exists.

| Group | Commands |
|---|---|
| Channels | `/d` `/z` `/s` `/r` `/g` `/b` `/gr` `/o` `/reino` `/comercio` `/novatos` (and their long names from section 2) |
| Party | `/invitar name` · `/salir` · `/expulsar name` · `/lider name` |
| Guild | `/ginvitar name` · `/gsalir` · `/gexpulsar name` · `/gascender name` |
| Social | `/amigo name` · `/ignorar name` · `/designorar name` · `/ausente [text]` · `/ocupado` |
| Emotes | `/saludar` · `/reverencia` · `/burla` · `/animar` · `/sentarse` · `/señalar` (SOC-11) |
| Help and complaints | `/ayuda [command]` · `/reportar name` · `/peticion text` (SOC-17, SOC-36) |
| Moderation | `/gm …` (role only; SOC-14) |

Every command that changes a state (invite, leave, report) goes through the server, which validates and
answers with a system message; the client never assumes the result. Those that depend on a specific
player without typing their name (invite, whisper, inspect, ignore, report) also come
from the **social menu** on the player under the crosshair, at 20 m at most (SOC-07).

## 5. Rate limits and sanitizing

They are applied on the server, per connection, with the token-bucket `RateLimiter` that already exists
([networking.md](networking.md), section 12); from phase 5, per character (12.7). When something is dropped, the player
gets a system notice ("Hablas demasiado rápido", "You talk too fast", at most one per second) and, so that pressing
Enter too many times does not get anyone kicked, the **first ten drops in every 10 s are free**; after that
each drop counts as a peer warning toward the kick (50 warnings in 600 ticks: networking.md section
12), so sustained flooding does get kicked (12.2).

| Action | Rate | Burst | Notes |
|---|---|---|---|
| Say, zone, party, warband, guild | 1 message/s | 5 | A message identical to the previous one within the last 10 s is dropped |
| Whisper | 1 message/s | 3 | And at most 5 new recipients per minute (SOC-38); repeating the text is only dropped if it goes to the same recipient |
| Realm | 1 message every 10 s | 1 | SOC-21 |
| Trade | 1 message every 15 s | 1 | |
| Newcomers | 1 message every 5 s | 2 | |
| Invitations (party, guild, friend) | 1 every 2 s | 3 | And at most 5 pending |
| Emotes | 1 every 2 s | 2 | Moving, attacking or taking damage cancels it |
| Pings | 1 every 2 s | 3 | At 300 m at most; they last 6 s (SOC-10) |
| Inspect | 1 every 2 s | 3 | At 20 m, allies only (SOC-29) |
| Reports | 1 per target every 10 min | 10 per hour | SOC-17 |
| Requests to a GM | 1 open at a time | | SOC-36 |

Before delivering a message, the server **sanitizes** it: it strips control characters and everything
invisible (format, direction marks, fillers, unassigned, private use), BBCode sequences
(`[…]`), combining marks with no letter and those beyond four over the same letter, repeated spaces and
leading/trailing ones, and anything beyond five code points in a single grapheme, and it rejects empty text or text beyond 255 characters (details in 12.2). On public channels it also blocks links (SOC-27). The client has an
optional language filter, on by default, with editable lists in Spanish and English. A character
with less than 2 h played cannot use `/reino`, `/comercio` or mail attachments (SOC-38).

## 6. Emotes

An emote is an animation with or without text ("Ana saluda", "Ana waves"). It is replicated to everyone who sees the
character, the enemy too: taunting is part of PvP. **The emote text is only received by the
character's own realm and within 30 m**; the enemy sees the animation without words and cannot use it to communicate.
Moving, attacking, taking damage or dying cancels the emote. Emotes never give a mechanical advantage.

## 7. Voice and pings

There is no built-in voice chat: it is expensive, hard to moderate and Discord already covers that need (SOC-40 leaves
an optional presence integration). Tactical coordination inside the game is covered by
**pings** (attack, defend, danger, regroup) and up to 4 persistent leader markers, which the
party or warband sees in the world, on the compass and on the minimap (SOC-10), with a rate limit and not visible
to the enemy.

## 8. Logs and retention (decided in phase 5: platform.md §0 and §11)

| What | What is stored | How long |
|---|---|---|
| Chat | Channel, sender's `character_id`, recipient (whispers), zone and instance, text and UTC time (SOC-15), **whispers included**; for a party message the party is not stored (platform.md §9.2) | 30 days |
| Fragments linked to a report | The context attached to the report (SOC-17, `report_evidence`) | 1 year after the report is closed; an unclosed one is considered closed after a year |
| GM command audit | Who, when, zone, target and arguments (SOC-14) | 1 year in `audit_log`; the copy kept in the character's ledger (actor, note and arguments of the GM operations) follows the ledger's retention (platform.md §11.1) |
| Sanctions | Type, reason, author, expiry and linked reports | As long as the account exists; when it is purged, with no reason and 1 more year |
| Names of deleted characters | Reserved so that nobody inherits them | The 7 days in which they can be restored plus 30 more; test ones, only the 7 (SOC-13, platform.md §4.4) |

The figures and how they are applied are those of platform.md §11.1, which prevails. A sanction does not store chat of its own:
only what was copied into a report is kept.

Whispers are stored because without them a harassment report cannot be handled. Access is limited to
moderators with a role, with a log of every query (platform.md §9.1: the CLI requires `--actor` and each
read leaves its row in the audit). Before opening public tests, retention
and consent must go through a legal review (GDPR); these figures may change then.

## 9. Sanctions and rules

The full rules and the screen that is accepted when creating the account belong to SOC-18
(`docs/normas.md`). The scale is **progressive** and always carries a reason, author, expiry and the
linked reports:

| Step | Sanction | Effect |
|---|---|---|
| 1 | Warning | System message and a note on the account; no mechanical effect |
| 2 | Mute | No access to any chat channel except the system ones; 1 h, 24 h or 7 days |
| 3 | Temporary suspension | The account cannot log in; 1, 3, 7 or 30 days, with the reason and the end date in the rejection |
| 4 | Permanent ban | Account closed; no refund |
| Aside | Forced rename | Offensive name or impersonation: the player is forced to choose another on login |

| Offense | First time | Repeat offense |
|---|---|---|
| Offensive language, spam | Warning or 1 h mute | 24 h or 7-day mute |
| Harassment, threats, discrimination | 7-day mute or 3-day suspension | 30-day suspension or ban |
| Offensive name or impersonation | Forced rename | 7-day suspension |
| Cheating, bots, exploiting bugs | 7 to 30-day suspension | Ban |
| Buying or selling accounts, items or gold for real money | 30-day suspension | Ban |

A serious sanction may skip steps; repeat offenses count within 90 days. Every sanction has
an appeal route (a request, handled by a different moderator within 7 days). A provisional automatic mute
after several reports from different players stays pending human
review (SOC-38).

## 10. Ignored players, friends and guilds

- **Friends:** up to 100, same realm, by accepted request (SOC-24).
- **Ignored:** up to 100. Ignoring applies to **the account** (decided in phase 5, platform.md §0),
  silently and without revealing which other characters it shares, because harassment with alternate characters is
  the most frequent case. The server drops whispers, invitations and mail from the ignored player, and also removes them
  from the recipients of the public channels: the client cannot hide them, because it does not know which
  characters share an account (SOC-16, platform.md §9.3).
- **Guilds:** same realm, with 5 ranks and bit-based permissions; an ally's guild name
  appears on their nameplate, an enemy's does not (SOC-25, section 1).

## 11. Where it is implemented

| Phase | Piece |
|---|---|
| 4 | Chat protocol (SOC-03), `ChatRouter` on the zone server with say, zone, whisper and system (SOC-04), chat window and commands (SOC-05), parties (SOC-06 to SOC-09), social menu (SOC-07), pings (SOC-10) |
| 5 | Unique names (SOC-13), GM roles and audit (SOC-14), persistent log (SOC-15), ignored players, reports and sanctions (SOC-16 to SOC-18) |
| 6 | Emotes (SOC-11), cross-zone whispers and realm channels, trade and newcomers (SOC-20, SOC-21), cross-zone parties (SOC-22), friends, guilds, filter, mail and inspection (SOC-24 to SOC-29) |
| 7 | War warbands (SOC-30), looking for group (SOC-31), war channel (SOC-32), heraldry and guild fortresses (SOC-33 to SOC-35) |
| 8 | Requests to a GM, moderation panel, anti-spam and scaling (SOC-36 to SOC-39) |

Whoever implements a piece must respect the realm filter from section 1 on the server, even if the
client "no longer shows" what it should not: the acceptance test of SOC-04 is that a client from another
realm receives no packet with the text, not merely that it does not draw it.

## 12. Implementation (phase 4)

What was done of SOC-03 to SOC-08 in phase 4, with the byte formats, the decisions that
were made while implementing it and what remains. The figures are still provisional (section 0).

### 12.1 Chat messages (SOC-03)

The protocol goes up to **version 5** (`NetProtocol.PROTOCOL_VERSION`). The types start at `0x40`,
on reliable channel 3 ([networking.md](networking.md), section 2); no packet exceeds 1200 B. Everything is
little-endian and strings are UTF-8 (no null byte) with their length in front, like the rest of the
protocol.

**CHAT_SEND** (`0x40`, C→S): what the player wants to say.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x40` |
| 1 | u8 | channel | `ChatChannel.Id`; 7 (system) is not sent by a client |
| 2 | u8 | recipient_len | bytes of the recipient (≤ 48; ≤ 24 characters); only in a whisper, and mandatory there |
| 3 | u16 | text_len | bytes of the text (≤ 768) |
| 5 | n B | recipient | the name as the player typed it |
| 5 + n | m B | text | ≤ 255 characters |

**CHAT_MESSAGE** (`0x41`, S→C): an already sanitized message, delivered only to whoever should see it.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | type | `0x41` |
| 1 | u8 | channel | `ChatChannel.Id` |
| 2 | u8 | sender_realm | sender's realm (0 for the system) |
| 3 | u32 | tick | server tick at delivery |
| 7 | u8 | sender_len | 0 if and only if the channel is the system one |
| 8 | u8 | recipient_len | only in a whisper (and mandatory there) |
| 9 | u16 | text_len | ≤ 768 |
| 11 | n B | sender | canonical name of the sender |
| 11 + n | m B | recipient | canonical name of the recipient |
| 11 + n + m | k B | text | ≤ 255 characters |

Maximum sizes: 821 B for CHAT_SEND and 875 B for CHAT_MESSAGE.

Channels (`ChatChannel.Id`, never reordered): `0` say, `1` zone, `2` whisper, `3` party, `4` warband, `5`
guild, `6` realm, `7` system, `8` GM. In phase 4 the server delivers say, zone, whisper, party and
system; the others answer "Ese canal aún no está disponible" (That channel is not available yet). Since protocol 7 (phase 5, platform.md §9 and
§19.12), `8` carries the commands handled by the server: the client sends `/gm …`, `/ignorar`, `/designorar` and
`/reportar` as they are, without the slash, and the reply arrives through the system channel.

`decode` returns `null` (and logs no engine error) if the size does not match the lengths,
if the channel does not exist, if a client sends the system one, if a whisper has no recipient or any
other channel has one, if any text is not valid UTF-8 or contains a null byte, if the recipient exceeds
24 characters or the text exceeds 255 characters or 768 B. A CHAT_MESSAGE also requires a sender on every
channel except the system one and a recipient only in the whisper. A mandatory name that reads as empty
is also `null`: `get_string_from_utf8` skips a BOM (`EF BB BF`) at the start, so those three bytes
alone would pass the length check and come out as "". Empty text does decode: it is the
server that drops it when sanitizing. `encode` trims to the limits without splitting any character.

### 12.2 Routing on the zone server (SOC-04)

Everything social lives in `scripts/server/social/`; `ZoneServer` only creates a `SocialService`, hands it the
messages of types `0x40` to `0x4F` (`handle_packet`) and lends it three functions (the list of peers in the
world, sending over the reliable channel and the warning counter). The rest is:

| Piece | What it does |
|---|---|
| `SocialService` | Gathers the chat router and, when they exist, the parties; it is the only thing `ZoneServer` knows about |
| `ChatRouter` | Sanitizes, applies the rates and delivers; the result of each message is in `ChatRouter.Result` |
| `ChatPeerState` | Token buckets, last text, recent drops and counters of each connection; hangs off `ServerPeer.chat` |
| `SocialPeers` | Lookup of players in the world by name (`NameRules` key) and by realm |

**Recipients.** The list is built already filtered by realm; it is never filtered when displaying.

| Channel | Who receives it |
|---|---|
| Say | Those of the same realm within 30 m in 3D of the sender, the sender included |
| Zone | Everyone of the same realm in the process, the sender included |
| Whisper | The recipient and, as a copy, the sender |
| Party | The members of their party (which the router filters again by realm) |

**Whisper.** It is looked up by the comparison key (lowercase and without accents: `peña` finds `Peña`).
If nobody with that name is in the world *or* they are in the other realm, the answer is identical: the
system message ""X" no está conectado." ("X" is not online), with what the player typed and not the canonical name from the other side.
Whispering yourself is rejected ("No puedes susurrarte a ti mismo.", You cannot whisper yourself).

**Reply (`/r`).** The client resolves it: it remembers who it last talked with (whoever whispered it or
whom it whispered) and sends a whisper to that name. The server does not store "the last interlocutor": a whisper to
a name that is no longer there gets the usual answer, and so the protocol needs no other channel.

**Rates** (`RateLimiter` per connection, in ticks; the transport buckets, which come first, do not change). Each
CHAT_SEND first spends a token from its bucket, **before sanitizing** or answering anything: sanitizing is not free,
and text that ends up empty, or a channel with no service, also costs its token. (Previously it sanitized first and
text that ended up empty went free: 127 levels of brackets cost 0.6 ms of main thread per message,
without spending rate or adding warnings.)

| Bucket | Rate | Burst |
|---|---|---|
| Talking (say, zone, party; warband and guild when they exist; also the channels with no service) | 1/s | 5 |
| Whisper | 1/s | 3 |
| New whisper recipients | 5/min | 5 |
| Repetition | text equal to the last accepted within 600 ticks (10 s) **and to the same place** is dropped: the public channels share the check (the same phrase by zone and by say is a repeat) and in a whisper the recipient counts ("ok" to Bea and then to Eva reaches both) | |

A recent interlocutor (someone who whispered you, or whom you whispered, in the last 5 min) does not count
as a new recipient, so replying to six strangers in a row does not spend from the bucket. That dictionary is
pruned on both sides of each whisper: someone who only receives whispers also does not accumulate everyone who
wrote to them. What is dropped, by rate or by repetition:

- warns the player through the system channel, "Hablas demasiado rápido." or "Ya has enviado ese mensaje." (You already sent that message.), at
  most one warning per second;
- and, after the first ten drops of every 600 ticks (`ChatPeerState.FLOOD_FREE_DISCARDS`, in a ring
  with the ticks of the last ten), each one adds a peer warning (`exceso de mensajes de chat`, excess chat messages). Pressing
  Enter too many times adds nothing; sustained flooding does: through the transport's reliable bucket (10 per
  second without warnings), a client sending 6 messages per second or more reaches the 50 warnings and is kicked
  (in about 13 s; at 10 per second, in 7 s). Below that it is not kicked, but the bucket already leaves the others at 1
  message per second. Before, it added one in every five drops, which at 10 per second is about 20 warnings per
  window: flooding never got kicked.

**Sanitizing** (`ChatText`, shared; the client applies the same before sending). In this order:

1. Strips controls (C0, DEL, C1), all invisible formatting (Unicode category Cf: zero width, direction
   marks such as U+200E or U+061C, the soft hyphen, the U+E0000… tags), line and paragraph
   separators, private use, noncharacters and unassigned code points, default ignorables (hangul
   fillers, the grapheme joiner, variation selectors except U+FE0F, which requests the color emoji) and
   U+FFFC and U+FFFD. The tab, line breaks, Unicode spaces and the braille blank (U+2800)
   become a space.
2. Strips BBCode and stray brackets in a single linear pass (each "]" takes everything since the last
   open "["), with the same result as repeatedly stripping the innermost pair.
3. Strips combining marks (category M) with no letter before them and those beyond four in a row over a
   letter (`ChatText.MAX_MARKS_PER_BASE`).
4. Collapses repeated spaces and strips leading and trailing ones.
5. Keeps each grapheme (what looks like a single character, PCRE2's `\X`) to its first five code points
   (`ChatText.MAX_CODE_POINTS_PER_GRAPHEME`: the letter and its four marks). It bounds what attaches to the
   previous letter without being category M: the Thai "ำ" (U+0E33) and the Lao one (U+0EB3), the vowels and finals of
   old hangul and skin tones. It only walks the text grapheme by grapheme if there are five or more consecutive code points
   above U+02FF (nothing that combines is below), so accented Spanish never pays that step.

The categories come from the engine's Unicode tables (PCRE2 `RegEx` with `\p{…}`), which are the same on
the client and the server. **Finding:** a letter with about 250 assorted marks on top fits in 255 characters and hangs
Godot 4.7.2's text layout for whoever receives it (reproduced with `TextLine` and the default font:
with 253 marks it ends in milliseconds; with 254, it does not); the cap of four prevents it and, along the way, the "zalgo"
that filled the whole box. The review's verification found the same with 128 "ำ" (U+0E33, category
Lo and not M) after a Thai consonant: hence step 5, which bounds any grapheme and not only marks. Measured cost: 5 µs for normal 255-character ASCII text and 40 to 65 µs the worst
case (before, 210 to 600 µs).

**Other outcomes.** A malformed CHAT_SEND, one with the system channel, or from someone not yet in the
world, adds a warning. Empty text after sanitizing is dropped without warning anyone (it already spent its token: an
honest client never sends it, because it sanitizes before sending). Warband, guild and realm answer
"Ese canal aún no está disponible."; GM answers "Comando desconocido. Escribe /ayuda." so as not to reveal that it
exists. A nonexistent party answers "No estás en un grupo." (You are not in a party).

**Report.** `write_report` includes `social.chat` with the messages processed, the copies delivered and
how many ended in each outcome.

**Tests.** `test_chat_text` (sanitizing, with code point tables: invisibles, spaces, visibles and marks;
"zalgo", long graphemes without marks (Thai, Lao, old hangul, skin tones), BBCode compared with the previous method on random texts and an idempotence fuzz),
`test_chat_router` (30, no network: range, realm filter, sanitizing, rates before sanitizing, free drops and
kick for flooding through the transport bucket, repetition per recipient, whispers),
`test_chat_loopback` (8, with real ENet: two bots of one realm and one of the other; the one from the other realm receives
no CHAT_MESSAGE and no packet whose bytes contain the others' text, on the four channels and
with the enemy 3 m from the sender).

### 12.3 Chat box and commands (SOC-05)

`scripts/client/chat/` (client only); the box hangs off the networked `HUD`, bottom left, below the
death screen. A server-less preview for trying it by hand or taking screenshots is at
`scenes/tests/chat_preview.tscn`:

```
godot --path . res://scenes/tests/chat_preview.tscn
xvfb-run -a godot --path . res://scenes/tests/chat_preview.tscn --resolution 1600x900 -- --shots=/ruta/absoluta/build/chat
```

(`--headless` does not work for screenshots: the dummy renderer does not draw. With `xvfb-run`, Mesa llvmpipe does.)
The demo screenshot with messages from all channels, the open line with a half-typed command and the
whispers tab is [screenshots/chat_demo.png](screenshots/chat_demo.png).

| Piece | What it does |
|---|---|
| `ChatBox` | Tabs, log and line; open, close, send, fade |
| `ChatCommandParser` | Decides whether the line is text or a command and which one (pure, text only) |
| `ChatLog` | Last 200 lines with what is needed to draw and filter them |
| `ChatStyle` | Color of each channel and composition of a line ("Ana te susurra: …", "Ana whispers to you: …") |
| `ChatInputHistory` | History of what was sent, 50 lines, for up and down arrows |

**Keys.** Enter (action `chat_open`, also the numpad Enter) opens the line; typing `/` opens it
already with the slash (the character is checked, not the key, so it works on any layout); Esc closes it without
sending; Enter sends and closes; up and down arrows walk the history. A click outside the box (left,
right or middle button; the wheel does not) closes it without sending: in Godot 4.7 a click where there is no control
does not take focus away from the text field, so `ChatBox._input` handles it by comparing the point with the panel. That
click continues on its way (if it lands on another window, it is for that window) and does not attack, because `LocalPlayerController` suppresses
mouse buttons pressed with the cursor free until they are released; the next click is already the game's. Losing focus
because another control takes it also closes it; switching system windows does not (on return you keep
typing). It does not open if another window (settings, map, death screen) holds the cursor.

**Line cap.** `ChatBox.MAX_INPUT_CHARS` (286) fits the longest text the server accepts (255) behind
the longest form of a command with name and text, `/susurrar ` with a 16-letter name, plus 4 of
slack; the test checks it with all the forms of `ChatCommandParser.COMMANDS`. If more than fits is still pasted or
typed, the box warns once each time it opens ("El mensaje es demasiado largo...", The message is too long...) instead of
trimming silently.

**Suspended input.** While the line is open the box asks the camera for the free cursor
(`CameraRig.set_ui_cursor_release`, like the windows), so the camera does not rotate and clicks do not attack, and it
suspends game input in `LocalPlayerController.set_input_blocked`: device input comes out
neutral (no movement or buttons) even if W is typed. **Finding:** the UI windows (settings F10,
map) only released the cursor, not movement: it was possible to keep walking with W when opening them. That is not
good enough for typing, so the block is a new per-requester mechanism (instance id), like the cursor one;
windows can request it whenever wanted.

**Phase 4 commands** (case- and accent-insensitive; `/ayuda` lists them from the
`ChatCommandParser.COMMANDS` table):

| Command | Effect |
|---|---|
| `/d` `/decir` `[text]` | Say. With text it sends it there without changing the active channel; without text, it makes it active |
| `/z` `/zona` `[text]` | Zone (same) |
| `/g` `/grupo` `[text]` | Party (same) |
| `/s` `/susurrar` `name [text]` | Whisper. Without text it leaves "susurro a nombre" (whisper to name) as the active channel; without a name, "Uso: /s nombre [texto]" (Usage) |
| `/r` `/responder` `[text]` | Whisper to the last interlocutor (copy of an own whisper or received whisper) |
| `/ayuda` `[command]` | The list of commands or the detail of one |
| `/invitar` `/salir` `/expulsar` `/lider` | Parties (handed to `ChatBox.party_handler`; see 12.5) |

Any other (`/b`, `/gr`, `/reino`, `/gm`, `/amigo`...) answers "Comando desconocido. Escribe /ayuda.",
also those of future phases: it does not warn that they exist. Names of more than 16 letters cannot exist
(`NameRules`) and are rejected locally.

**What is shown.** Tabs All ("Todo"), Say ("Decir"), Zone ("Zona"), Party ("Grupo"), Whispers ("Susurros") and System ("Sistema"). Each channel has its own color (the
system one pale yellow; the GMs, cyan) and the sender's name goes in their realm's color. Server
NOTICEs come out on the system channel, like local notices (help, command errors).
**Other players' text is drawn with `RichTextLabel.add_text`**: BBCode is never interpreted, even if the
server lets it through (the test passes `[b]`, `[color]`, `[url]`, `[img]` and `[font_size]` and checks that it shows
literally). When closed, the box fades 8 s after the last message (2 s fade) and comes back with the
next one; when open, it does not fade.

**Decisions.** `/r` is resolved by the client (12.2); Enter closes the line on sending (like New World), and to
keep talking on a channel there is the active channel; the text is sanitized on the client with `ChatText` before
sending (the server sanitizes it again) and empty text after sanitizing is not sent.

**Pending for the user.** Channel colors, box dimensions (560 x 236, bottom left),
fade times and the text of the notices are provisional (ART-12); also whether the box should
dim with the death screen (it does not today) and which key should open chat in the controls menu.

### 12.4 Parties: protocol and server (SOC-06)

Eight new types, `0x48` to `0x4F`, on reliable channel 3 (handled by the `SocialService`, which already had the
`0x40`-`0x4F` range). `NetProtocol.PARTY_MAX_SIZE` (5) is the shared constant for the member cap; the
remaining rules are in `PartyRules` (shared).

| Type | Message | Direction | Format |
|---|---|---|---|
| `0x48` | PARTY_INVITE | C→S | `u8 type, u8 name_len` + name (UTF-8, 1 to 48 B and 24 characters) |
| `0x49` | PARTY_RESPONSE | C→S | `u8 type, u8 accept (0 or 1), u8 name_len` + name of the inviter |
| `0x4A` | PARTY_LEAVE | C→S | `u8 type` (1 B) |
| `0x4B` | PARTY_KICK | C→S | as PARTY_INVITE |
| `0x4C` | PARTY_LEADER | C→S | as PARTY_INVITE |
| `0x4D` | PARTY_INVITATION | S→C | `u8 type, u8 state (0 new, 1 expired, 2 cancelled), u32 tick, u8 name_len` + canonical name; with `state` 0, `tick` is when it expires |
| `0x4E` | PARTY_ROSTER | S→C | `u8 type, u8 count (0 to 5), u8 leader_index` and, per member, `u16 net_id, u8 name_len` + name (≤ 258 B); `count` 0 = "you are no longer in a party" |
| `0x4F` | PARTY_STATUS | S→C | `u8 type, u8 count` and, per member, `u16 net_id, u8 health_q, u8 stamina_q, u8 status, f32 x, f32 y, f32 z` (17 B per member, ≤ 87 B) |

`health_q` is the snapshots' quantized health (0 dead, 1 to 255 alive), `stamina_q` the stamina in 255
steps and `status` the bits `STATUS_IN_COMBAT`, `STATUS_PROTECTED` and `STATUS_DEAD` (and, since protocol 6,
`STATUS_DOWNED`: the member is knocked down, [abilities.md 5.2](abilities.md#52-estado-snapshot-y-registro)). `decode` returns `null` if the
size does not match, there are more than 5 members, a net id repeats, the leader is not in the list, a name is
empty (also if it is only a UTF-8 BOM, which reads as empty) or is not valid UTF-8, a status bit is unknown
or a position is not finite.

**Rules** (`PartyManager`, in `scripts/server/social/`):

- A party has 5 members at most and is **same-realm only**. Inviting an enemy, or someone who does not exist, answers
  the same as a whisper ("no está conectado"), does not notify the invitee and leaves no invitation.
- Any member can invite; only the leader kicks (`/expulsar`) and hands over command (`/lider`). The first
  to invite creates the party when the invitee accepts, and is its leader.
- An invitation expires after 3600 ticks (60 s); each player can have at most 5 sent at once. When
  accepting one, the accepter's other pending invitations are cancelled and, if that creates the party, so are those
  of the inviter, who has just joined it: nobody in a party has pending invitations (nor
  takes up one of the 5 slots of whoever invited them). Inviting has its own bucket (1 every 2 s, burst of 3): what is dropped
  warns ("Invitas demasiado rápido.", at most once per second) and, after the first ten drops
  of every 10 s, each one adds a peer warning, as in chat (12.2).
- If the leader leaves or disconnects, the next oldest inherits command; a party left with one member
  is dissolved. Accepting an invitation to a party that filled up in the meantime answers "El grupo está completo." (The party is full).
- Each result reaches the player as a message on the chat's system channel; the interface additionally receives
  PARTY_INVITATION and PARTY_ROSTER when they change.
- **2 Hz status.** Every 30 ticks (`PartyRules.STATUS_INTERVAL_TICKS`) the server sends a PARTY_STATUS to each
  member with the health, stamina, status bits and position of everyone, wherever they are: it does not go
  through the snapshots' interest policy, so a member at 250 m and outside the interest radius still
  shows up (the test uses a 100 m policy and a member at 210 m). Each party sends it on its tick of the
  interval, when `(tick + party id) % 30 == 0` (`PartyManager.is_status_tick`), like the snapshots by
  `net_id` parity: the cost is spread over the 30 ticks instead of falling entirely on one (with 100 parties of
  5 it was 3 to 4.6 ms in a single tick, every 30).
- Chat's party channel (`/g`): the members, wherever each one is; the router filters again by
  realm whoever the `PartyManager` hands it.

**Out of scope for phase 4** (SOC-22): the party does not survive a disconnection or cross zones; the server
stores nothing. When someone disconnects, they leave the party.

**Tests.** `test_party_messages` (hand-written formats, corrupt, truncated at every length, and fuzz),
`test_party_manager` (no network: all flows, caps, enemy, inherited leader, inviter's invitations
cancelled when the party forms, invite rate, 2 Hz status staggered per party, party channel) and `test_party_loopback` (with ENet and bots: invite, accept, decline, expire, kick, hand over command,
leave and disconnect, the invitation to an enemy rejected without them noticing, and a member's status outside
the interest radius).

### 12.5 Party interface (SOC-08)

`scripts/client/party/`; the networked `HUD` mounts it on the left of the screen, below the death
screen.

| Piece | What it does |
|---|---|
| `PartyState` | What the client knows about the party: members in arrival order, leader, 2 Hz status and invitations (the oldest in view). It is fed by `NetClient` and exposed by `NetClient.get_party()` |
| `PartyFrames` and `PartyFrame` | One frame per member: name in the realm color, drawn leader crown, health, stamina and distance from 30 m; dimmed if more than 100 m away, dead or with no data yet |
| `PartyInvitePrompt` | "Ana te invita a su grupo" (Ana invites you to her party), the seconds left and the real accept (Y) and decline (N) keys with their glyph; removes what has expired per tick. If the reply cannot be sent (the session is closing), the invitation and the prompt stay |
| `PartyHud` | Gathers the two and translates `/invitar`, `/salir`, `/expulsar` and `/lider` from the chat box into requests (`NetClient.send_party_*`) |
| `Nameplates.set_party` | Party members carry their name in the party color (channel blue) instead of their realm's |

New keys in `InputBindings`: `party_accept` (Y), `party_decline` (N) and `social_menu` (G; it was T until
phase 4, which gives T to the stamina potion: [abilities.md 11.7](abilities.md#117-h4--cliente)); all
provisional (pending for the user, like the dimensions and the frame colors). Y and N only respond
with the prompt in view and **with no other interface piece holding the cursor** (`CameraRig.is_ui_holding_cursor`:
the social menu, the map, the settings, the chat line), so that a letter pressed in a window does not accept or
decline by accident. The exception is the death screen (the HUD requests the cursor for it and is given as an allowed
requester): it uses no letters, and waiting to respawn is a good time to accept; with the map open
on top, they do not respond either.

The backlog demo (four bots grouped with the local player) is in `test_party_hud`
(`test_a_party_of_five_shows_the_right_frames`): it checks names, order, single crown, health, stamina,
distance, dimming for distance, death and missing data, and that the frames follow the list.

### 12.6 Social menu on the player under the crosshair (SOC-07)

Only the first origin of the actions: the `social_menu` key (G; T until phase 4) casts a ray from the camera against the
capsule of each remote player being drawn (like the nameplates' one) and takes the closest along
the ray at **20 m or less from the local player** (not from the camera, which sits behind). **Only visible
allies count** (`SocialTarget.is_social_target` and the occlusion of `SocialTarget.find`): a player of the own
realm, alive, with a person's name and with no wall or structure between the camera and their head, with the same test
that hides their nameplate (`Nameplates.is_head_hidden`: ray against `HitShapes.LINE_OF_SIGHT_MASK` cut 0.4 m before
the head). The rest are ignored, even if they are in front of an ally. With it a small window opens
(`SocialMenu`, a `UIWindow`: it releases the cursor, works with keyboard or mouse and Esc closes it) with the
applicable actions. The first button has focus and Enter presses it; Space does not, because it is jump and the window does not suspend
game input (UI-47): `InputBindings` removes it from `ui_accept` (phase 4 review, client):

| Target | Options |
|---|---|
| Ally | Invite to party (if not already in the party and the party is not full) and Whisper |
| Party member, or full party | Whisper only |
| Enemy, dead, fake player, someone behind a wall, nobody | The menu does not open and the chat always warns the same: "Apunta a un jugador de tu reino (a 20 m o menos) para ver sus acciones." (Aim at a player of your realm, within 20 m, to see their actions.) |

**Why a single notice and the occlusion.** Before, the ray did not look at walls and an enemy gave a different notice
from "nobody": pressing T against a wall or the fort's door told you whether there was an enemy right behind, at 20 m or
less, whom their nameplate hides on purpose. Now aiming at an enemy (visible or not), at a wall with someone behind or
at the void gives exactly the same, and a covered ally does not open the menu either. The server still sends the position
of enemies behind walls (interest goes by distance, [networking.md](networking.md) section 11), so a modified client
already has it; this only prevents the honest client from showing it.

**Fake players.** The player bodies the server creates without a connection (`ZoneServer.add_fake_player`: the
load tests and, with `--max-realm-diff`, the filler for the short side from GUE-42) cannot receive invitations or
whispers: the server answers "no está conectado". The ENTITY_SPAWN does not distinguish them, but their name
(`ZoneServer.FAKE_NAME_FORMAT`, "Bot-01") does not satisfy `NameRules` (hyphen and digits), and a person's always
satisfies it because `ServerAuth` requires it in the HELLO; hence the menu does not open with a name that does not satisfy it
(`test_zone_server` checks that no fake one satisfies it). If `NameRules` were ever tightened and an
old name stopped satisfying it, that player would be left with no menu: then a "no social actions" bit
in the ENTITY_SPAWN would be advisable. The body that stays in the world after logging out in combat (GUE-41) carries a person's name and does offer actions; the server answers
"no está conectado", which is true.

**Invite** sends PARTY_INVITE; **whisper** closes the menu and opens the chat line with `/s name ` already typed.
When inspect, add friend, ignore and report exist, they will come from `SocialTarget.options_for` (a pure
function) without showing, with an enemy, the ones that do not apply.

**Pending in SOC-07:** the second origin, a name clicked in the chat with the free cursor (the names in the
chat lines are not clickable yet), and the options that depend on later phases.

**Tests.** `test_social_menu`: the ray (20 m from the player and not from the camera, NPCs, enemies, dead and
fake ones ignored, the closest wins, a wall covers), the options, the menu with an ally, with an enemy and with a
fake, and the HUD key with the same notice for a visible enemy, an enemy or an ally behind a wall, a
fake and nobody.

### 12.7 Phase 4 decisions and pending items

**Decisions made while implementing** (all provisional, revisable with real tests):

- **Protocol.** `PROTOCOL_VERSION` goes up to 5 with a single history line ("chat y grupos", chat and parties). If merging another
  branch also bumps it, whoever merges renumbers it; the tests only require `>= 4` and `>= 5` in the places
  that depend on these messages.
- **The new messages are received by all clients.** `NetClient` decodes CHAT_MESSAGE and the PARTY_*
  (S→C) and emits signals; the lightweight `--bots` bots (`SwarmBot`), which the server treats as players
  (they get their realm's "zone" and "say", can be whispered and can be invited), decode them and
  discard them: they do not answer, and an invitation expires on its own. They count them in `chat_messages_seen` and
  `party_messages_seen` of the swarm report, and only those that fail to decode add to `malformed_packets`, the
  figure the load tests require to be 0. Tests: `test_bot_swarm`
  (`test_chat_and_party_messages_reach_a_bot_without_counting_as_malformed`, with ENet: a client of the same
  realm talks on the zone, whispers the bot and invites it; and
  `test_party_roster_and_status_are_discarded_and_broken_ones_count_as_malformed`, no network).
- **One social service, not a change in every piece.** `SocialService` is the only thing `ZoneServer` sees (types
  `0x40`-`0x4F`, one step per tick and the removal of each player); each peer's rate state hangs off
  `ServerPeer.chat`. In the tick order (`ZoneServer` header, which is the authority) the removal
  (`on_peer_left`: leaves its party and its invitations are cancelled) goes in the removals step, and the social step
  (`SocialService.step`: invitations expire and PARTY_STATUS goes out) goes after the additions and before the
  history, with its own `social` section in the metrics. Incoming messages are handled in the poll and
  count in the `net` section.
- **`/r` is resolved by the client** and the server does not store "the last interlocutor" (12.2).
- **Same text for the enemy and for nobody.** Whispering or inviting someone from another realm answers
  "no está conectado" with what the player typed, does not spend from the new-recipients bucket and sends nothing to the other
  side.
- **Any member can invite; only the leader kicks and hands over command.** The cap of 5 pending is per
  inviter, and on accepting the accepter's others are cancelled and, if the party is new, the inviter's.
- **Rate goes before work.** Each CHAT_SEND spends its token before sanitizing or answering; the first ten
  drops of every 10 s are free and the following ones add one warning each (chat and invitations).
- **Party state outside interest.** A dedicated 2 Hz message to each member with health, stamina, status and
  position; it does not go through the snapshots. The frame dims beyond 100 m.
- **Enter closes the line on sending**, with an active channel for continuing to talk on a channel. A click outside the box
  also closes it, without sending and without attacking (12.3).
- **The social menu only sees visible allies** and gives a single notice when there is nobody to offer it to, whether aimed at an
  enemy, a wall or the void; fake players are recognized by their name, which does not satisfy `NameRules` (12.6).
- **Y and N wait for any other window to close**, except the death screen, from which an invitation
  can be answered (12.5).
- **A party does not survive a disconnection** (SOC-22 will change that with the 5 min of grace).

**Known limitations of phase 4** (accepted until phase 5; also documented in
[networking.md](networking.md), section 12):

- **Rates are per connection.** `ChatPeerState` is born full with each `ServerPeer`: whoever leaves and re-enters
  recovers the bursts, the 5 new whisper recipients and the drop window, just like the transport buckets and
  warnings (finding S6 of networking.md). Storing the state by name would not fix it, because in
  phase 4 the client chooses its name on every connection (`DevAuthProvider`). From phase 5 it will be stored per
  character or account (the ticket's) during the 5 min of `KNOWN_RECIPIENT_TICKS` after the removal, and
  re-attached on re-entering.
- **The HELLO tells whether a name is online.** `ServerAuth` rejects with `REJECT NAME` a name that someone in the zone
  already carries, from any realm (so that whispers are not ambiguous); since the client chooses the
  name in the HELLO, opening another connection with a player's name tells whether they are in the zone and, if the whisper
  also answers "no está conectado", that they are from the other realm. It is accepted for now because it adds nothing to a
  larger hole in the same phase: the client also chooses its realm, so it can enter the enemy's and
  whisper them or read their zone directly. Checking uniqueness only within the realm would not plug it (the probe
  would declare the enemy's realm) and would break the unique-names rule of section 1; a cooldown after
  several `REJECT NAME` would only slow it, and would punish whoever reconnects while their previous session or their body
  (GUE-41) still holds the name. It is closed in phase 5 (SOC-13, TEC-24): the name and realm come from the
  ticket's character, the HELLO field is ignored and uniqueness is guaranteed by the database when creating the
  character; against those connected only the duplicate session of the same character remains, whose answer only its
  owner sees. Test planned then: `test_hello_cannot_probe_an_enemy_name` (with ENet, a HELLO with another
  character's ticket and the name of a connected enemy receives no `NAME`). **Closed in phase 5** (platform.md P4, its §19.8): with
  `--platform`, `ServerAuth` does not look at the HELLO's name or realm and the test is in
  `tests/test_zone_server_platform.gd` (without platform, in development, `REJECT NAME` remains as in phase 4).

**Pending for the user** (provisional, awaiting ART-12 and playtesting): the colors of each channel,
the dimensions and fade of the chat box, the look and position of the frames and of the invitation
notice, the text of the notices and the new keys (Enter and `/` for chat, Y and N to answer an
invitation, G for the player menu). Also, whether the chat box should dim with the death screen (it does not
today).

**Pending to implement:**

- SOC-07: the menu from a name clicked in chat with the free cursor and the actions of later phases
  (inspect, friend, ignore, report).
- SOC-09 and SOC-10: party members on the compass, minimap and map (they already receive their positions at 2 Hz in
  `PartyState`) and tactical pings and markers.
- SOC-15, SOC-16, SOC-17 and SOC-27: persistent log, ignored players, reports and language filter.
- SOC-21 and SOC-22: more channels (realm, trade, newcomers) and cross-zone parties with reconnection.
- UI-47: the UI windows do not suspend movement either (finding from SOC-05).
