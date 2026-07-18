#!/usr/bin/env python3

import http.server
import json
import os
import socketserver
import subprocess
import threading
from html import escape
from urllib.parse import urlparse

MODEL_DIR = os.environ.get("MODEL_DIR", "/models")
PORT = int(os.environ.get("PORT", "8080"))
REFRESH = 2
CONFIG_PATH = "/tmp/progress-config.json"

URLS = [
    ("model",            os.environ.get("MODEL_URL",  "")),
    ("mmproj",           os.environ.get("MMPROJ_URL", "")),
    ("spec-draft-model", os.environ.get("MTP_URL",   "")),
]
HF_TOKEN = os.environ.get("HF_TOKEN", "")


def head_content_length(url):
    if not url:
        return 0
    args = ["curl", "-sIL", "--max-time", "30"]
    if HF_TOKEN:
        args += ["-H", f"Authorization: Bearer {HF_TOKEN}"]
    args += [url]
    try:
        out = subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return 0
    size = 0
    for line in out.splitlines():
        if line.lower().startswith("content-length:"):
            try:
                size = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass
    return size


def build_initial_config():
    return [{
        "label": label,
        "filename": os.path.basename(urlparse(url).path),
        "expected_bytes": 0,
    } for label, url in URLS if url]


URL_BY_LABEL = {label: url for label, url in URLS}


def fetch_sizes(cfg):
    print("=== Determining model sizes (HEAD requests) ===", flush=True)
    for item in cfg:
        item["expected_bytes"] = head_content_length(URL_BY_LABEL[item["label"]])
        print(f"  {item['label']}: {item['filename']} -> {item['expected_bytes']} bytes",
              flush=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, CONFIG_PATH)
    print("=== Sizes cached; progress page now shows totals ===", flush=True)


def fmt_bytes(n):
    f = float(n)
    for u in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if f < 1024:
            return f"{int(f)} {u}" if u == "B" else f"{f:.1f} {u}"
        f /= 1024
    return f"{f:.1f} TiB"


def render(cfg):
    rows = []
    total_dl = 0
    total_exp = 0
    for item in cfg:
        try:
            dl = os.path.getsize(os.path.join(MODEL_DIR, item["filename"]))
        except OSError:
            dl = 0
        exp = item["expected_bytes"]
        total_dl += dl
        total_exp += exp
        pct = (dl / exp * 100) if exp else 0
        rows.append((item, dl, exp, pct))

    overall_pct = (total_dl / total_exp * 100) if total_exp else 0

    def bar(pct, known):
        if not known:
            return "<progress></progress>"
        return f'<progress value="{pct:.1f}" max="100"></progress>'

    body_rows = "\n".join(
        f"""    <div class="file">
      <h2>{escape(item['label'])} &mdash; <code>{escape(item['filename'])}</code></h2>
      {bar(pct, bool(exp))}
      <div class="meta">{escape(fmt_bytes(dl))} / {escape(fmt_bytes(exp)) if exp else '?'} ({pct:.1f}%)</div>
    </div>"""
        for item, dl, exp, pct in rows
    )

    sizes_known = any(item["expected_bytes"] for item in cfg)
    status_msg = ("Downloading model files. This page refreshes every "
                  f"{REFRESH}s.") if sizes_known else (
                  f"Determining model sizes&hellip; download will start "
                  f"shortly. This page refreshes every {REFRESH}s.")

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
    {bar(overall_pct, bool(total_exp))}
    <div class="meta">{escape(fmt_bytes(total_dl))} / {escape(fmt_bytes(total_exp)) if total_exp else '?'} ({overall_pct:.1f}%)</div>
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
            with open(CONFIG_PATH) as f:
                cfg = json.load(f)
            body = render(cfg).encode("utf-8")
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
    cfg = build_initial_config()
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f)
    print(f"=== Serving progress page on 0.0.0.0:{PORT} (HTTP 503) ===",
          flush=True)
    server = ReuseTCPServer(("0.0.0.0", PORT), Handler)
    threading.Thread(target=fetch_sizes, args=(cfg,), daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()