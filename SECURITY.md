# Security

In sign-in mode (opt-in) Usage Wall reads your Claude Code sign-in token from the login Keychain and sends it to
`api.anthropic.com`, so anything that could leak that token, or let another program or web page drive the local
server, is a security issue.

Please report it privately: **GitHub → Security → Report a vulnerability** on this repository. Do not open a public
issue. You will get an answer within a week.

In scope: the app, `server/server.py` (it listens on 127.0.0.1), `install.sh` / `uninstall.sh`, the status line
script. Out of scope: Anthropic's services themselves (report those to Anthropic).
