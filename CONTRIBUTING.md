# Contributing

Thanks for wanting to help. Bug reports, ideas and pull requests are all welcome.

## Run it from source

```sh
python3 server/server.py                 # 127.0.0.1:8765, serves web/ and reads your real usage
open "http://127.0.0.1:8765/?weekly=84&hour=22&act=walk"
./app/build.sh                           # build/Usage Wall.app; ./install.sh installs it
```

Preview parameters: `weekly` and `five` (percent used), `hour` (0-24, may be fractional), `act` (`walk`, `idle`,
`hop`). The server is Python standard library only and must run on the `/usr/bin/python3` that ships with the
Command Line Tools (3.9): no newer syntax, no packages.

## Where things are

| Path | What |
|---|---|
| `app/UsageWall.swift` | the menu bar app: window/panel, display choice, server process, CLI flags |
| `app/build.sh` | builds the universal app bundle |
| `server/server.py` | local server: Keychain token → usage endpoint → `/api/state` |
| `web/index.html` | the page: HUD canvas 240×160 + scene canvas 192×59, art embedded as data URIs |
| `art/` | the pictures and the two scripts that turn them into the page (see `art/README.md`) |
| `bin/usage-wall` | the terminal command |
| `install.sh`, `uninstall.sh` | install / remove everything |

## Pixel rules

- The scene is one grid: one picture pixel = one scene pixel. Do not scale sprites by fractions.
- New stages are edits of `art/hero/medium.png`, so Clawd keeps the same size, shape and colours.
- Anything drawn on the scene (signs, props) uses the scene's grid too; the sign has its own 5×6 font for that.

## Pull requests

- One change per pull request, with a screenshot or GIF for anything visible.
- `./app/build.sh` must build, `python3 -m py_compile server/server.py` must pass, and `shellcheck` must be clean
  (CI checks all three).
- Do not add network calls, analytics or dependencies without discussing it in an issue first.

By contributing you agree that your contribution is released under the MIT License.
