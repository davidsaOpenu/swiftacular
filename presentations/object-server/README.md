# The Swift Object Backend — Presentation

A [Marp](https://marp.app/) slide deck about the Swift object server's disk file
interface. Slides live in `slides.md`; most diagrams are written in
[D2](https://d2lang.com/) (under `graphs/`) and compiled to SVG at build time.

## Requirements

- **Node.js 18 or later** and **npm** — check with `node -v`.
- **A browser must be installed on the machine** — Google Chrome, Chromium, or
  Microsoft Edge, or Mozilla Firefox. Marp launches it to produce
  the PDF. **This is a hard dependency:** without a browser the diagram step
  still runs, but the PDF export fails with `No suitable browser found`. See
  [Browser dependency](#browser-dependency) below for versions and CI notes.

Marp and the D2 compiler install locally as project dependencies, so no global
installs are needed.

## Quick start

```bash
npm install      # install marp-cli, the D2 compiler, and rimraf
npm run build    # render diagrams, then export slides.pdf
```

The result is **`slides.pdf`** in the project root. (A browser must already be
installed — see below.)

## Scripts

| Command                 | What it does                                                         |
| ----------------------- | ------------------------------------------------------------------- |
| `npm run render-graphs` | Compiles every `graphs/*.d2` file to a matching `graphs/*.svg`.     |
| `npm run build`         | Runs `render-graphs` (via the `prebuild` hook), then exports the PDF. |
| `npm run watch`         | Starts Marp in watch mode with live preview in the browser.         |
| `npm run clean`         | Removes generated files: `graphs/*.svg`, `slides.pdf`, `slides.html`. |

Because `prebuild` chains the diagram step to `build`, **`npm run build` is the
only command you need** for a clean, from-scratch build.

## Browser dependency

Marp renders the deck by driving a real browser through
[`puppeteer-core`](https://pptr.dev/), which does **not** bundle its own
browser — so one has to be installed and discoverable.

**Versions**

- **Chrome / Chromium / Edge:** no meaningful minimum. These are
  driven over the Chrome DevTools Protocol, which has been stable for years — any
  current stable release works. Just install the latest.
- **Firefox:** works only from **version 129 or newer** (Marp drives it via
  WebDriver BiDi, which is production-ready from Firefox 129). Marp also
  considers Firefox PDF output early-stage, so its rendering may differ slightly
  from Chrome. Prefer a Chromium browser unless you specifically need Firefox.

## Editing the slides

- **Content** lives in `slides.md`. Each `---` starts a new slide; the front
  matter at the top sets the theme, title, and per-slide font size.
- **Diagrams** live in `graphs/*.d2`. Edit the `.d2` source, then rerun
  `npm run render-graphs` (or just `npm run build`) to regenerate the SVG.
- **Static images** (the title photo and the hand-drawn class tree) live in
  `images/`. These are committed directly and are not generated.
- For fast iteration, run `npm run watch` and edit `slides.md` — the preview
  reloads on save. Note that `watch` does **not** recompile `.d2` files, so
  rerun `npm run render-graphs` after changing a diagram.

## Project layout

```
object-server/
├── slides.md            # the deck (Marp markdown)
├── render.mjs           # compiles graphs/*.d2 -> graphs/*.svg
├── package.json         # scripts and dependencies
├── graphs/              # D2 diagram sources; SVGs are generated here
│   └── slide3.d2 ...
├── images/              # static, committed assets
│   ├── classtree.svg    # hand-authored class diagram
│   └── swift.jpg        # title image
└── README.md
```

## Troubleshooting

- **`No suitable browser found`** — install Chrome, Chromium, or Edge (or
  Firefox 129+), or point Marp at an existing binary with `BROWSER_PATH` (or
  `--browser-path`), e.g. `BROWSER_PATH=/path/to/chrome npm run build`.
