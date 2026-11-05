# Eldmark website

The website of [Eldmark](https://github.com/Luisbh-dev/Eldmark), an open-source medieval-fantasy
MMORPG made with Godot 4. A single static page in plain HTML, CSS and JavaScript: no framework, no
build step, no external requests (fonts, images, video and sounds are all local).

The site is developed inside the main repository, in its `web/` folder, and mirrored to
[Eldmark-website](https://github.com/Luisbh-dev/Eldmark-website) with `git subtree` (see
[Publishing](#publishing)). Change it in the main repository, not in the mirror.

## Run it

Any static file server works. From this folder (the root of Eldmark-website, or `web/` in the main
repository):

```bash
python -m http.server 8137
```

Then open <http://localhost:8137>. Opening `index.html` straight from disk also works (all the
scripts are classic scripts, not modules), although some browsers block the sounds from `file://`.

## What is on the page

| Section | What it does | Files |
|---|---|---|
| Hero | Flythrough of the Vado Gris, the Broken Crown cracking into three shards, embers that follow the realm you pledge to | `js/embers.js`, `js/main.js` |
| Legend | Scroll-driven telling of the Broken Crown: the Flame of Eld weakens, bursts and leaves its Embers | `js/legend.js` |
| Realms | Three banners; pledging to one re-themes the whole site (`--accent`), plays its horn and changes the hero particles | `js/main.js`, `js/core.js` |
| War | Interactive map of Eldrun with a live simulation of the Ember Lines rules (adjacency, isolation, Aldcor) | `js/war-map.js`, `css/war-map.css` |
| Combat | Trial of the Parry: a one-button duel with the game's real numbers (6-tick parry window, 500 ms cooldown, 0.6 s stagger) | `js/parry.js` |
| Under the hood | Netcode lab: prediction, interpolation and lag compensation made visible, with latency and loss sliders | `js/netcode.js`, `css/netcode.css` |
| Chronicle | Before/after slider, gallery with lightbox, Devlog #0 | `js/main.js` |
| Roadmap, open source, footer | Braziers that light up as you read, a typed terminal with copy, credits | `js/main.js` |

There is also an old secret in the footer.

## How the code is organized

- `js/core.js` is loaded first and synchronously. It defines `window.Eldmark`: language and realm
  state with change events, the string table (`addStrings`, `t`, `applyI18n`), sound (off until the
  visitor turns it on), `reducedMotion`, and two helpers (`whenVisible`, `fitCanvas`).
- `js/i18n.js` harvests the English text from the HTML (`data-i18n`, `data-i18n-html`,
  `data-i18n-attr`) and adds the Spanish. The interactive modules register their own strings.
- Every interactive module is an IIFE that mounts into one element, prefixes its CSS classes
  (`wm-`, `nc-`, `pt-`), pauses when it is off screen or the tab is hidden, and respects
  `prefers-reduced-motion`.
- `css/tokens.css` holds the design tokens (colors per realm, fonts, easing). The other stylesheets
  only read them.

Code style follows the rest of the project: tabs, English identifiers and comments.

## Assets

Everything in `web/assets/` is a normal git blob, like every other binary in the repo (see `.gitattributes`), so the site
works from a plain checkout and on GitHub Pages. Keep it small: images as WebP around 1600 px wide,
video as short H.264 loops without audio.

- `img/`, `video/`: in-game captures of the Vado Gris (CC BY 4.0, like the rest of the project's
  original assets).
- `icons/`, `sfx/`: copies of the game's own icons and sound effects (CC BY 4.0).
- `fonts/`: Latin subsets of Cinzel, IM Fell English SC and Noto Sans (SIL OFL 1.1, licenses next
  to them).

## Publishing

The page is ready for GitHub Pages or any static host: this folder is the site root (`.nojekyll`
tells GitHub Pages to serve it as is). The links to the game's code point to
`github.com/Luisbh-dev/Eldmark`, so they only work once that repository is public.

To update the mirror after committing changes to `web/` in the main repository, run this from the
main repository's root:

```bash
git subtree push --prefix=web https://github.com/Luisbh-dev/Eldmark-website main
```

The `.gdignore` file only matters inside the main repository, where it keeps Godot from importing
the site.

## License

- Code (HTML, CSS, JavaScript): MIT, see [LICENSE](LICENSE).
- Images, video, icons and sounds made by the Eldmark project: CC BY 4.0
  (credit: Eldmark contributors, https://github.com/Luisbh-dev/Eldmark).
- Fonts in `assets/fonts/`: SIL Open Font License 1.1, each with its `OFL-*.txt`.

The full licensing notes are in the main repository's
[LICENSE-ASSETS.md](https://github.com/Luisbh-dev/Eldmark/blob/main/LICENSE-ASSETS.md).
