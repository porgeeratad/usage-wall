# Troubleshooting

Logs: `usage-wall logs` (or `~/Library/Logs/UsageWall.log`). Current numbers: `usage-wall status`.

## The wall says "Waiting for Claude Code's status line"

Usage Wall gets its numbers from Claude Code's status line by default, and nothing has arrived yet.

- Use Claude Code once (any prompt). The numbers appear after its next response.
- `cat ~/.claude/settings.json`: the `statusLine` command should be the full path of
  `~/.local/bin/usage-wall-statusline` (e.g. `/Users/you/.local/bin/usage-wall-statusline`), or your own script
  should pass its input on to it (README → Where the numbers come from).
- Plan limits are only in the status line data for a Pro or Max sign-in.
- Want numbers without using Claude Code? Turn on sign-in mode: `usage-wall signin on`.

## The wall says "Sign in to Claude Code (Pro/Max)" (sign-in mode)

The app found no Claude Code sign-in in your login Keychain (item **Claude Code-credentials**). Run `claude`, then
`/login`, and sign in with a Pro or Max plan. The wall picks it up within a minute (or menu → Refresh Usage Now).

## macOS keeps asking about "Claude Code-credentials" (sign-in mode)

The server reads the sign-in with `/usr/bin/security`. When macOS asks, choose **Always Allow**; **Allow** works
only once. If you chose **Deny**, run this once in Terminal and allow it:

```sh
security find-generic-password -s "Claude Code-credentials" -w >/dev/null
```

## "Claude sign-in expired" (sign-in mode)

The usage endpoint answered 401/403. Open Claude Code once (any command); it refreshes its sign-in. The wall checks
again every 5 minutes, or right away with menu → Refresh Usage Now.

## "Usage API busy. Retrying in …" (sign-in mode)

The endpoint answered 429. The app waits (doubling up to an hour) and tries again by itself. Refresh Usage Now is
refused while it waits, so pressing it cannot make it worse.

## "Lost contact with the usage server"

The page cannot reach its local server. `usage-wall start`, or menu → Reload. If the log says the port is used by
another program, set another `port` in `~/Library/Application Support/UsageWall/config.json` and run
`usage-wall reload`.

## The wall is on the wrong screen, or I cannot see it

- Menu bar gauge icon → **Show On** → pick a display or **Floating Window**.
- `usage-wall display list`, then `usage-wall display set window`.
- A display you picked that is unplugged keeps the wall hidden until it comes back; pick another one meanwhile.

The wall never covers the display with your menu bar, so the menu is always reachable. If something still goes
wrong, `usage-wall stop` quits it, and so does:

```sh
launchctl bootout gui/$(id -u)/io.github.porgeeratad.usagewall
```

## Pixels look uneven

The page scales in whole device-pixel steps, so on a window of an odd size there is a black border instead of
blurry pixels. On a 960×640 display (or 1920×1280) it is pixel-exact.

## Build fails

`./install.sh` needs the Xcode Command Line Tools (`xcode-select --install`). If you have several Xcode versions,
`xcode-select -p` shows which one `swiftc` comes from.

## Start over

```sh
./uninstall.sh && ./install.sh
```
