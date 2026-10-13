#!/usr/bin/env python3
"""usage-wall: tiny local server behind the usage wall page. Started by the app (Usage Wall.app) as a child.

- GET /            -> web/index.html (960x640 page, scales to any window)
- GET /api/state   -> merged usage snapshot
- GET /api/health  -> {"ok": true, "app": "usage-wall"}
- POST /api/refresh-> poll the usage endpoint now (sign-in mode; needs header X-Usage-Wall: 1; refused while backing off)

Sources
  statusline.json  written by bin/usage-wall-statusline on every Claude Code response, from the rate_limits that
                   Claude Code itself passes to its status line. The default, and the only source unless
  oauth.json       USAGE_WALL_SIGNIN=1 (the app's "Read Usage with Claude Sign-in", off by default): then also
                   written here every POLL_SEC from https://api.anthropic.com/api/oauth/usage, an undocumented
                   endpoint (the one `/usage` uses), with Claude Code's token read from the Keychain, never logged.
Windows whose reset time has passed count as 0 % until new data comes (the status line only updates while
Claude Code is in use).
Binds 127.0.0.1 only and answers only Host 127.0.0.1/localhost:PORT (no DNS rebinding); POST needs a custom
header, so another web page cannot make it hammer the upstream (a cross-origin custom header needs a preflight
this server never grants). stdlib only. With USAGE_WALL_PARENT_WATCH=1 it exits when its stdin closes, i.e. when the
app that started it quits or crashes.
"""
import errno, json, os, subprocess, sys, threading, time, urllib.request, urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.environ.get("USAGE_WALL_WEB") or os.path.join(HERE, "..", "web")
PORT = int(os.environ.get("USAGE_WALL_PORT", "8765"))
STATE = os.path.expanduser(os.environ.get("USAGE_WALL_STATE", "~/Library/Application Support/UsageWall/state"))
SIGNIN = os.environ.get("USAGE_WALL_SIGNIN") == "1"
POLL_SEC = int(os.environ.get("USAGE_WALL_POLL_SEC", "600"))
# sign-in mode polls, so 30 min without news means trouble; status-line data is simply as old as your last prompt
STALE_SEC = int(os.environ.get("USAGE_WALL_STALE_SEC", "1800" if SIGNIN else "18000"))
WEEK = 7 * 86400
UA = os.environ.get("USAGE_WALL_UA")
VERSION = os.environ.get("USAGE_WALL_VERSION", "dev")
MIN_REFRESH_SEC = 60      # a manual refresh at most once a minute
SIGNIN_RETRY_SEC = 60     # no sign-in in the Keychain: look again soon (local only, no network)
EXPIRED_RETRY_SEC = 300   # 401/403: the user fixes it by opening Claude Code; check every 5 min, no growing backoff
OAUTH_URL = "https://api.anthropic.com/api/oauth/usage"

os.makedirs(STATE, exist_ok=True)
_lock = threading.Lock()
_backoff = POLL_SEC
_last_poll = 0.0
_retry_after = 0.0        # epoch before which no upstream call is made (after an HTTP error)


def log(*a):
    print(datetime.now().strftime("%F %T"), "usage-wall:", *a, flush=True)


def write_json(name, obj):
    tmp = os.path.join(STATE, f".{name}.{os.getpid()}.tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, os.path.join(STATE, name))


def read_json(name):
    try:
        with open(os.path.join(STATE, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def to_epoch(v):
    """resets_at: statusline gives epoch seconds, oauth gives ISO-8601."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


_ua = None


def user_agent():
    """usage-wall/<version>, plus the installed Claude Code version when there is one (looked up once)."""
    global _ua
    if UA:
        return UA
    if _ua is None:
        _ua = f"usage-wall/{VERSION} ({claude_version()})"
    return _ua


def claude_version():
    for exe in ("claude", os.path.expanduser("~/.local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        try:
            out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=10).stdout.split()
            if out and out[0][:1].isdigit():
                return "claude-code/" + out[0]
        except (OSError, subprocess.SubprocessError):
            continue
    return "claude-code/unknown"


def keychain_token():
    # a locked Keychain can leave `security` waiting on a dialog: give up after 30 s instead of holding the lock
    raw = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, check=True, timeout=30).stdout.strip()
    c = json.loads(raw)["claudeAiOauth"]
    return c["accessToken"], c.get("subscriptionType"), c.get("expiresAt")


def poll_oauth():
    """One fetch of the usage endpoint -> oauth.json. Returns True on success."""
    global _backoff, _last_poll, _retry_after
    _last_poll = time.time()
    try:
        tok, sub, exp = keychain_token()
    except Exception as e:  # noqa: BLE001 - keychain locked / item missing
        why = "locked" if isinstance(e, subprocess.TimeoutExpired) else type(e).__name__
        write_json("oauth.json", {"ts": time.time(), "error": f"keychain: {why}"})
        log("keychain read failed:", type(e).__name__)
        _backoff, _retry_after = min(POLL_SEC, SIGNIN_RETRY_SEC), 0.0
        return False
    req = urllib.request.Request(OAUTH_URL, headers={
        "Authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20", "User-Agent": user_agent()})
    del tok
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):      # sign-in expired: not the server's fault, keep checking and allow Refresh
            _backoff, _retry_after = min(POLL_SEC, EXPIRED_RETRY_SEC), 0.0
        else:                         # 429 / 5xx: back off, doubling up to an hour, and refuse manual refreshes
            _backoff = min(_backoff * 2, 3600)
            _retry_after = time.time() + _backoff
        write_json("oauth.json", {**(read_json("oauth.json") or {}), "error": f"HTTP {e.code}", "error_ts": time.time(),
                                  "retry_at": _retry_after or None})
        log(f"HTTP {e.code} from usage endpoint; backoff {_backoff}s")
        return False
    except Exception as e:  # noqa: BLE001
        write_json("oauth.json", {**(read_json("oauth.json") or {}), "error": type(e).__name__, "error_ts": time.time()})
        log("usage fetch failed:", type(e).__name__)
        return False
    _backoff = POLL_SEC
    _retry_after = 0.0
    scoped = [l for l in (d.get("limits") or []) if l.get("kind") == "weekly_scoped"]
    write_json("oauth.json", {
        "ts": time.time(),
        "subscription": sub,
        "token_expires_at": (exp or 0) / 1000 if exp else None,
        "five_hour": d.get("five_hour"),
        "seven_day": d.get("seven_day"),
        "limits": d.get("limits"),
        "scoped": [{"name": ((l.get("scope") or {}).get("model") or {}).get("display_name"),
                    "percent": l.get("percent"), "severity": l.get("severity"),
                    "resets_at": l.get("resets_at"), "is_active": l.get("is_active")} for l in scoped],
    })
    log("oauth ok: 5h=%s%% 7d=%s%%" % ((d.get("five_hour") or {}).get("utilization"),
                                       (d.get("seven_day") or {}).get("utilization")))
    return True


def poller():
    while True:
        with _lock:
            poll_oauth()
        time.sleep(_backoff)


def window(name, sl, oa):
    """Pick the freshest record for a window (five_hour / seven_day)."""
    cands = []
    if sl and sl.get(name):
        w = sl[name]
        cands.append({"percent": w.get("used_percentage"), "resets_at": to_epoch(w.get("resets_at")),
                      "ts": sl.get("ts"), "source": "statusline"})
    if oa and oa.get(name):
        w = oa[name]
        cands.append({"percent": w.get("utilization"), "resets_at": to_epoch(w.get("resets_at")),
                      "ts": oa.get("ts"), "source": "oauth"})
    cands = [c for c in cands if c["percent"] is not None and c["ts"]]
    if not cands:
        return None
    best = max(cands, key=lambda c: c["ts"])
    now = time.time()
    if best["resets_at"] and now >= best["resets_at"]:   # the window reset since this was read: nothing used yet
        nxt = None
        if name == "seven_day":                           # weekly resets keep their weekday and time
            nxt = best["resets_at"] + WEEK * (int((now - best["resets_at"]) // WEEK) + 1)
        best = {**best, "percent": 0.0, "resets_at": nxt, "rolled": True}
    # severity from the oauth limits[] if it has one for this window
    for l in (oa or {}).get("limits") or []:
        if (name == "five_hour" and l.get("kind") == "session") or (name == "seven_day" and l.get("kind") == "weekly_all"):
            best["severity"] = l.get("severity")
    return best


def state():
    sl, oa = read_json("statusline.json"), (read_json("oauth.json") if SIGNIN else None)
    now = time.time()
    fh, sd = window("five_hour", sl, oa), window("seven_day", sl, oa)
    tss = [x["ts"] for x in (fh, sd) if x]
    updated = max(tss) if tss else None
    scoped = []
    for s in (oa or {}).get("scoped") or []:
        scoped.append({**s, "resets_at": to_epoch(s.get("resets_at"))})
    return {
        "now": now,
        "mode": "signin" if SIGNIN else "statusline",
        "updated_at": updated,
        "stale": (updated is None) or (now - updated > STALE_SEC),
        "five_hour": fh, "seven_day": sd, "scoped": scoped,
        "subscription": (oa or {}).get("subscription"),
        "model": (sl or {}).get("model"),
        "oauth_error": (oa or {}).get("error"),
        "retry_at": (oa or {}).get("retry_at") if (oa or {}).get("error") else None,
    }


class H(BaseHTTPRequestHandler):
    def _host_ok(self):
        return self.headers.get("Host", "") in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if ctype.startswith("text") else ""))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._host_ok():
            return self._send(421, {"error": "wrong host"})
        p = self.path.split("?")[0]
        if p in ("/", "/index.html"):
            with open(os.path.join(WEB, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html")
        if p.startswith("/fonts/") and "/" not in p[7:] and p.endswith(".ttf"):
            fp = os.path.join(WEB, "fonts", p[7:])
            if os.path.isfile(fp):
                with open(fp, "rb") as f:
                    return self._send(200, f.read(), "font/ttf")
        if p == "/api/state":
            return self._send(200, state())
        if p == "/api/health":
            return self._send(200, {"ok": True, "app": "usage-wall"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok():
            return self._send(421, {"error": "wrong host"})
        if self.path.split("?")[0] == "/api/refresh":
            if self.headers.get("X-Usage-Wall") != "1":
                return self._send(403, {"error": "missing X-Usage-Wall header"})
            if not SIGNIN:
                return self._send(200, {"ok": False, "disabled": "sign-in mode is off"})
            now = time.time()
            wait = max(_retry_after - now, _last_poll + MIN_REFRESH_SEC - now)
            if wait > 0:
                return self._send(200, {"ok": False, "retry_in": round(wait)})
            with _lock:
                ok = poll_oauth()
            return self._send(200, {"ok": ok})
        return self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # quiet access log
        if "/api/state" not in (args[0] if args else ""):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def watch_parent():
    """stdin is a pipe from the app; EOF = the app is gone, so is this server."""
    try:
        while sys.stdin.buffer.read(1):
            pass
    finally:
        log("parent gone - exiting")
        os._exit(0)


if __name__ == "__main__":
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    except OSError as e:
        if e.errno == errno.EADDRINUSE:   # 75 tells the app not to restart: another program has the port
            log(f"port {PORT} is in use by another program - set another \"port\" in config.json")
            os._exit(75)
        raise
    if os.environ.get("USAGE_WALL_PARENT_WATCH") == "1":   # after the bind: exiting above must not race this thread
        threading.Thread(target=watch_parent, daemon=True).start()
    if SIGNIN:
        threading.Thread(target=poller, daemon=True).start()
    log(f"listening on http://127.0.0.1:{PORT} state={STATE} "
        + (f"sign-in mode, poll={POLL_SEC}s" if SIGNIN else "status-line mode (no sign-in use)"))
    srv.serve_forever()
