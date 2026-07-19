#!/usr/bin/env python3

import http.server
import json
import os
import socketserver
import threading
import time
import urllib.request
from html import escape
from urllib.parse import urlparse

MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
PORT = int(os.environ.get("PORT", "8080"))
ARIA2_RPC_URL = os.environ.get("ARIA2_RPC_URL", "http://127.0.0.1:6800/jsonrpc")
REFRESH = 10
POLL_INTERVAL = 10.0

URLS = [
    ("model",            os.environ.get("MODEL_URL",  "")),
    ("mmproj",           os.environ.get("MMPROJ_URL", "")),
    ("spec-draft-model", os.environ.get("MTP_URL",   "")),
]


def build_initial_items():
    return [{
        "label": label,
        "filename": os.path.basename(urlparse(url).path),
        "expected_bytes": 0,
        "downloaded_bytes": 0,
    } for label, url in URLS if url]


_STATE_LOCK = threading.Lock()
_STATE = {
    "items": build_initial_items(),
    "total_speed": 0,
    "last_update": 0.0,
}


def rpc(method, *args):
    try:
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": "progress",
            "method": f"aria2.{method}",
            "params": list(args),
        }).encode("utf-8")
        req = urllib.request.Request(
            ARIA2_RPC_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=1) as resp:
            return json.load(resp).get("result")
    except Exception:
        return None


def poll_aria2():
    first_logged = [False]
    while True:
        active = rpc("tellActive")
        if active is None:
            time.sleep(POLL_INTERVAL)
            continue
        waiting = rpc("tellWaiting", 0, 100) or []
        stopped = rpc("tellStopped", 0, 100) or []

        by_filename = {}
        total_speed = 0
        for dl in active + waiting:
            total_speed += int(dl.get("downloadSpeed", 0) or 0)
            for f in dl.get("files", []):
                fn = os.path.basename(f.get("path", ""))
                if fn:
                    by_filename[fn] = {
                        "expected": int(f.get("length", 0) or 0),
                        "downloaded": int(f.get("completedLength", 0) or 0),
                    }
        for dl in stopped:
            for f in dl.get("files", []):
                fn = os.path.basename(f.get("path", ""))
                if fn and fn not in by_filename:
                    by_filename[fn] = {
                        "expected": int(f.get("length", 0) or 0),
                        "downloaded": int(f.get("completedLength", 0) or 0),
                    }

        with _STATE_LOCK:
            for item in _STATE["items"]:
                info = by_filename.get(item["filename"], {})
                item["expected_bytes"] = info.get("expected", 0)
                item["downloaded_bytes"] = info.get("downloaded", 0)
            _STATE["total_speed"] = total_speed
            _STATE["last_update"] = time.time()
            if not first_logged[0]:
                print(f"=== Connected to aria2c RPC ({ARIA2_RPC_URL}) ===",
                      flush=True)
                first_logged[0] = True

        time.sleep(POLL_INTERVAL)


def fmt_bytes(n):
    f = float(n)
    for u in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if f < 1024:
            return f"{int(f)} {u}" if u == "B" else f"{f:.1f} {u}"
        f /= 1024
    return f"{f:.1f} TiB"


def fmt_speed(bps):
    if bps <= 0:
        return ""
    return f"{fmt_bytes(bps)}/s"


def fmt_eta(seconds):
    if seconds is None or seconds <= 0 or seconds == float("inf"):
        return ""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60:02d}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60:02d}m"


def meta_line(dl, exp, pct, speed):
    base = (f"{escape(fmt_bytes(dl))} / "
            f"{escape(fmt_bytes(exp)) if exp else '?'} "
            f"({pct:.1f}%)")
    extras = []
    if speed > 0 and exp and dl < exp:
        extras.append(escape(fmt_speed(speed)))
        eta = fmt_eta((exp - dl) / speed)
        if eta:
            extras.append(f"ETA {escape(eta)}")
    if extras:
        base += " &middot; " + " &middot; ".join(extras)
    return f'<div class="meta">{base}</div>'


def render():
    with _STATE_LOCK:
        items = [dict(i) for i in _STATE["items"]]
        last_update = _STATE["last_update"]
        total_speed = _STATE["total_speed"]

    rows = []
    total_dl = 0
    total_exp = 0
    all_done = True

    for item in items:
        exp = item["expected_bytes"]
        dl = item["downloaded_bytes"]
        if exp == 0:
            pct = 0
            known = False
        else:
            pct = min(dl / exp * 100, 100)
            known = True
        complete = bool(exp) and dl >= exp
        if not complete:
            all_done = False
        rows.append((item, dl, exp, pct, known, complete))
        total_dl += dl
        total_exp += exp

    if total_exp == 0:
        overall_pct = 0
        overall_known = False
    else:
        overall_pct = min(total_dl / total_exp * 100, 100)
        overall_known = True

    rpc_age = (time.time() - last_update) if last_update > 0 else float("inf")
    if rpc_age > 5:
        status_msg = "Waiting for downloader&hellip;"
    elif all_done and total_exp > 0:
        status_msg = "Downloads complete; llama-server starting&hellip;"
    else:
        status_msg = (f"Downloading model files. "
                      f"Page refreshes every {REFRESH}s.")

    def bar(pct, known, complete=False):
        if not known:
            return "<progress></progress>"
        cls = ' class="complete"' if complete else ''
        return f'<progress{cls} value="{pct:.1f}" max="100"></progress>'

    body_rows = "\n".join(
        f"""    <div class="file">
      <h2>{escape(item['label'])} &mdash; <code>{escape(item['filename'])}</code></h2>
      {bar(pct, known, complete)}
      {meta_line(dl, exp, pct, total_speed)}
    </div>"""
        for item, dl, exp, pct, known, complete in rows
    )

    overall_meta = (f"{escape(fmt_bytes(total_dl))} / "
                    f"{escape(fmt_bytes(total_exp)) if total_exp else '?'} "
                    f"({overall_pct:.1f}%)")
    if total_speed > 0 and total_exp and total_dl < total_exp:
        eta = fmt_eta((total_exp - total_dl) / total_speed)
        parts = [escape(fmt_speed(total_speed))]
        if eta:
            parts.append(f"ETA {escape(eta)}")
        overall_meta += " &middot; " + " &middot; ".join(parts)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="{REFRESH}">
<title>llama-server &mdash; downloading models</title>
<style>
  body {{ font-family: system-ui, -apple-system, sans-serif; max-width: 720px;
          margin: 2em auto; padding: 0 1em; color: #222; }}
  h1 {{ font-size: 1.4em; margin-bottom: 0.25em; }}
  .status {{ padding: 0.5em 0.75em; background: #fff3cd; border-radius: 4px;
             margin-bottom: 1.5em; }}
  .file {{ margin: 1.5em 0; }}
  .file h2 {{ font-size: 1em; margin: 0 0 0.4em 0; font-weight: 600; }}
  .file code {{ font-weight: normal; color: #555; }}
  progress {{ width: 100%; height: 1.2em; }}
  progress.complete {{ accent-color: #22c55e; }}
  progress.complete::-webkit-progress-value {{ background-color: #22c55e; }}
  progress.complete::-moz-progress-bar {{ background-color: #22c55e; }}
  .meta {{ color: #666; font-size: 0.85em; margin-top: 0.3em; }}
  .overall {{ margin-top: 2em; padding-top: 1em; border-top: 1px solid #ddd; }}
  footer {{ color: #999; font-size: 0.8em; margin-top: 2em; }}
</style>
</head>
<body>
  <h1>Setting up llama-server&hellip;</h1>
  <div class="status">{status_msg}</div>
{body_rows}
  <div class="overall">
    <strong>Overall:</strong>
    {bar(overall_pct, overall_known)}
    <div class="meta">{overall_meta}</div>
  </div>
  <footer>HTTP 503 Service Unavailable &middot; Retry-After: {REFRESH}</footer>
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass

    def do_GET(self):
        try:
            body = render().encode("utf-8")
        except Exception as e:
            body = f"Progress server error: {e}".encode("utf-8")
        self.send_response(503)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Retry-After", str(REFRESH))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class ReuseTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    print(f"=== Serving progress page on 0.0.0.0:{PORT} (HTTP 503) ===",
          flush=True)
    print(f"=== Polling aria2c RPC at {ARIA2_RPC_URL} every {POLL_INTERVAL}s ===",
          flush=True)
    server = ReuseTCPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=poll_aria2, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()