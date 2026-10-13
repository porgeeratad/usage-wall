**Language:** English | [ไทย](README.th.md)

# Usage Wall

A pixel-art usage monitor for **Claude Code** on your Mac. A little Clawd lives on a spare screen (or in a window),
walks around while your plan has room, sweats when the weekly limit gets close, and keels over when it runs out.

![Usage Wall: Clawd walking on the wall](docs/demo.gif)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/-Swift-F05138?logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/-Python%20(stdlib)-3776AB?logo=python&logoColor=white)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/porgeeratad)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/porgeeratad)

> Unofficial fan project, not affiliated with or endorsed by Anthropic. See [Disclaimer](#disclaimer).

<table>
<tr>
<td width="50%" align="center">
  <a href="https://ko-fi.com/porgeeratad"><strong>☕ Ko-fi</strong><br /><sub>Buy the pixels a coffee</sub></a>
</td>
<td width="50%" align="center">
  <a href="https://buymeacoffee.com/porgeeratad"><strong>🍪 Buy Me a Coffee</strong><br /><sub>Keep Clawd walking</sub></a>
</td>
</tr>
</table>

---

## What it shows

![The four stages](docs/screenshots/stages.png)

| | Meaning |
|---|---|
| **HP** | what is left of your **weekly** limit (100 − weekly % used) |
| **ST** | what is left of the **5-hour** session limit |
| **MP** | what is left of a model-specific weekly limit, when your plan has one (sign-in mode) |
| **RESET sign** | the day and time the weekly limit resets |
| right panel | time now, and how long until each limit resets |

Clawd's stage follows HP:

| Stage | HP | Clawd |
|---|---|---|
| FULL | 70–100 | red headband, brisk walk, hops |
| MEDIUM | 35–69 | strolls around |
| LOW | 5–34 | half-closed eyes, sweating, drags its feet, battery over its head |
| DEAD | under 5 | flat on its back, legs twitching, its ghost floats nearby |

The scene follows your clock: sun and moon cross the sky, dusk and dawn colours, stars, fireflies and a campfire
at night.

## Requirements

- macOS 14 (Sonoma) or newer. Built for Apple silicon and Intel; tested on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`), used to build the app; they also provide `/usr/bin/python3`
- Claude Code signed in with a **Pro or Max** plan (`claude`, then `/login`). Plan limits exist only for a Pro/Max
  sign-in; API-key-only setups have none to show.

## Install

```sh
git clone https://github.com/porgeeratad/usage-wall.git
cd usage-wall
./install.sh
```

The installer builds the app from source, puts it in `~/Applications/Usage Wall.app`, adds the `usage-wall`
command to `~/.local/bin`, sets Claude Code's status line to feed the wall (only if you have none; see
[Where the numbers come from](#where-the-numbers-come-from)), asks where to show the wall, and starts it at login.

Options:

```sh
./install.sh --display "DELL U2424HE"   # skip the question: a display name, auto, or window
./install.sh --use-signin               # also read usage with your Claude sign-in (see below)
./install.sh --no-statusline            # leave Claude Code's status line alone
./install.sh --no-login                 # do not start at login
```

Update: `git pull && ./install.sh` (your settings are kept).
Uninstall: `./uninstall.sh` (add `--keep-settings` to keep them).

## Choose the display

Click the gauge icon in the menu bar → **Show On**:

- **a dedicated display** (any screen that is not your main one): the wall fills it edge to edge, stays there on
  every Space, never takes focus, and comes back by itself when you plug the display in again
- **your main display** or **Floating Window**: a normal window you can move and resize (it keeps the 3:2 shape);
  **Keep Window on Top** pins it above other windows
- **Automatic**: the smallest extra display if there is one, otherwise the window

The wall never covers the display that has your menu bar, so you can always reach its menu.

From the terminal:

```sh
usage-wall display list             # every display, its size, and how it would be used
usage-wall display set "DELL U2424HE"
usage-wall display set window
```

It was made for the small 3.5" USB-C / HDMI "system monitor" screens (960×640), but any size works: the
page scales to fit. On a 960×640 screen every pixel is sharp.

## Commands

```text
usage-wall status            usage as the wall sees it
usage-wall display [list]    displays and how each would be used
usage-wall display set NAME  NAME | auto | window
usage-wall reload            reload the page
usage-wall open              open the wall in your browser
usage-wall start | stop      start the app / quit it
usage-wall login on|off      start at login, or not
usage-wall signin on|off     also read usage with your Claude sign-in
usage-wall logs | config | version
```

## Settings

`~/Library/Application Support/UsageWall/config.json` (the menu and the commands above edit it for you):

| Key | Default | |
|---|---|---|
| `display` | `"window"` | `"window"`, `"auto"`, or a display's name |
| `displayUUID` | `""` | set with the name; matches the display even if two share a name |
| `port` | `8765` | the local server's port (127.0.0.1 only) |
| `useSignIn` | `false` | also read usage with your Claude sign-in (see below) |
| `pollMinutes` | `10` | how often sign-in mode fetches the usage |
| `keepOnTop` | `false` | window mode only |

After editing the file by hand, run `usage-wall reload`.

## Where the numbers come from

**Status line (default).** After every response, Claude Code runs its status line command and passes it your plan
limits (`rate_limits`). Usage Wall's status line script saves that snapshot for the wall and prints a short
status line (`model | ctx | tokens | $ | 5h % · 7d %`). This is a supported Claude Code feature: no token, no extra
network call. The wall updates while you use Claude Code; when a limit's reset time passes, it counts as 0 % until
you use Claude Code again. The model-specific meter (MP) is not part of this data.

`./install.sh` sets it up when you have no status line yet. If you already have one, pass the same JSON that
Claude Code gives your script on to the wall's script:

```sh
input=$(cat)                                                   # your script probably does this already
printf '%s' "$input" | ~/.local/bin/usage-wall-statusline >/dev/null
```

**Claude sign-in (opt-in).** Menu → **Read Usage with Claude Sign-in…**, `usage-wall signin on`, or
`./install.sh --use-signin`. The wall then also reads your Claude Code sign-in token from the login Keychain and
asks the usage endpoint that Claude Code's own `/usage` command uses, every 10 minutes, so it stays current when you
are not using Claude Code and shows the MP meter. That endpoint is **undocumented**: this is not an official
Anthropic feature, it may stop working at any time, and you use it with your own account at your own risk. macOS may
ask whether `security` can use **"Claude Code-credentials"**; choose **Always Allow**.

## How it works

```text
Usage Wall.app (menu bar)
 ├─ server.py  127.0.0.1:8765, stdlib Python, started by the app and stopped with it
 │    status line snapshot  ← ~/.local/bin/usage-wall-statusline, run by Claude Code after each response
 │    sign-in mode only, every 10 min: token from the login Keychain (/usr/bin/security)
 │                                     → GET https://api.anthropic.com/api/oauth/usage
 └─ WKWebView  web/index.html: two canvases, HUD 240×160 and scene 192×59, scaled to fit
```

## Privacy and security

- By default Usage Wall makes no network calls at all and never touches your sign-in: the numbers come from
  Claude Code's status line.
- In sign-in mode (opt-in) the only network call goes to `api.anthropic.com`, with your own Claude Code sign-in
  token, to read your usage. The token is read from your login Keychain when needed, kept in memory for one
  request, and never written or logged.
- No analytics, no telemetry.
- The local server listens on 127.0.0.1 only, answers only requests addressed to `127.0.0.1`/`localhost` (so a web
  page cannot reach it through DNS rebinding), and its one write action needs a custom header that browsers do
  not let other sites send.
- Everything it stores is in `~/Library/Application Support/UsageWall/` and `~/Library/Logs/UsageWall.log`.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The short version:

| The wall says | Do this |
|---|---|
| "Waiting for Claude Code's status line" | use Claude Code once; if it stays, see [Where the numbers come from](#where-the-numbers-come-from) |
| "Sign in to Claude Code (Pro/Max)" | run `claude` and `/login` (sign-in mode) |
| "Claude sign-in expired" | open Claude Code once; it refreshes the sign-in |
| "Usage API busy. Retrying in …" | nothing; it backs off and retries |
| "Lost contact with the usage server" | `usage-wall start` (or `usage-wall logs`) |

## Development

```sh
python3 server/server.py                 # serve web/ on 127.0.0.1:8765 (reads your real usage)
open "http://127.0.0.1:8765/?weekly=84&hour=22&act=walk"   # preview: any stage, time of day, pose
./app/build.sh                           # build/Usage Wall.app (universal)
```

Preview parameters: `weekly` (% used), `five`, `hour` (may be fractional), `act` (`walk`, `idle`, `hop`).
The pictures live in `art/hero/`; after changing them run `python3 art/embed.py`. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

- Pixel art made with [SpriteCook](https://www.spritecook.ai) (see [art/README.md](art/README.md))
- [Press Start 2P](https://fonts.google.com/specimen/Press+Start+2P) font by CodeMan38, SIL Open Font License
  ([web/fonts/OFL.txt](web/fonts/OFL.txt))
- Clawd is the Claude Code mascot by Anthropic; this is fan art

## Support

If Usage Wall makes your desk a little happier, you can support it:

- ☕ [ko-fi.com/porgeeratad](https://ko-fi.com/porgeeratad)
- 🍪 [buymeacoffee.com/porgeeratad](https://buymeacoffee.com/porgeeratad)

Stars, bug reports and pull requests help too.

## Disclaimer

Usage Wall is an unofficial fan project. It is not affiliated with, endorsed by, or supported by Anthropic.
Claude, Claude Code and Clawd are trademarks of Anthropic, PBC. The usage data comes from an undocumented endpoint
that Claude Code itself uses; it can change or stop working at any time, and you use it with your own account at
your own risk.

## License

Code: [MIT](LICENSE). Pictures: free to use and redistribute as part of Usage Wall and its forks
([art/README.md](art/README.md)). Font: [SIL OFL](web/fonts/OFL.txt).
