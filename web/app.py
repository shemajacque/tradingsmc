"""
SMC Bot Manager - local web control panel for SMC_Bot.mq5.

The EA reads SMC_bot_config.csv from the MT5 common Files folder on every
timer tick (60s) and writes SMC_bot_status.csv back, so this app can change
risk / spread / score settings and switch paper <-> live without recompiling.

Run:
    $env:SMC_WEB_PASSWORD = "choose-a-password"
    python -m uvicorn web.app:app --host 127.0.0.1 --port 8020

Bind to 127.0.0.1 only unless you add TLS and authentication in front.
"""

from __future__ import annotations

import csv
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).resolve().parent.parent
STATIC = Path(__file__).resolve().parent / "static"
REPORTS = ROOT / "data" / "reports"
COMPILE_LOG = ROOT / "data" / "compile_SMC_Bot.log"
DEPLOY = ROOT / "deploy.ps1"

DEFAULT_FILES = Path(
    os.environ.get(
        "SMC_MT5_FILES",
        r"C:\Users\Student\AppData\Roaming\MetaQuotes\Terminal\Common\Files",
    )
)
CONFIG_FILE = DEFAULT_FILES / "SMC_bot_config.csv"
STATUS_FILE = DEFAULT_FILES / "SMC_bot_status.csv"
LOG_FILE = DEFAULT_FILES / "decisions_log.csv"

PASSWORD = os.environ.get("SMC_WEB_PASSWORD", "smc-admin")

DEFAULTS: Dict[str, Any] = {
    "enabled": 1,
    "live": 0,
    "risk_percent": 0.5,
    "max_spread": 30.0,
    "max_trades": 3,
    "score_min": 3,
    "kill_switch": 0,
}

EQUITY_FILE = DEFAULT_FILES / "SMC_bot_equity.csv"

EDITABLE = set(DEFAULTS)
NUMERIC = {"risk_percent", "max_spread", "max_trades", "score_min"}
INTEGER = {"enabled", "live", "max_trades", "score_min", "kill_switch"}

app = FastAPI(title="SMC Bot Manager", version="1.0")
app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")


def _auth(x_password: str | None):
    if x_password != PASSWORD:
        raise HTTPException(status_code=401, detail="invalid password")


def _read_text(path: Path) -> str:
    """MQL5 FILE_CSV writes UTF-16LE with a BOM; detect it explicitly.

    The EA rewrites the status file every 5 s, so tolerate a brief sharing
    violation by retrying a few times.
    """
    import time as _t
    for attempt in range(4):
        try:
            data = path.read_bytes()
            break
        except OSError:
            if attempt == 3:
                return ""
            _t.sleep(0.05)
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8-sig", errors="replace")


def _read_pairs(path: Path) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not path.exists():
        return out
    try:
        text = _read_text(path)
    except OSError:
        return out
    for row in csv.reader(text.splitlines()):
        if len(row) < 2:
            continue
        key = row[0].strip().lower()
        if key in ("key", ""):
            continue
        out[key] = row[1].strip()
    return out


def read_config() -> Dict[str, Any]:
    cfg = dict(DEFAULTS)
    for k, v in _read_pairs(CONFIG_FILE).items():
        if k not in DEFAULTS:
            continue
        try:
            cfg[k] = int(float(v)) if k in INTEGER else float(v)
        except ValueError:
            pass
    if cfg["live"]:
        cfg["live"] = 1
    if cfg["enabled"]:
        cfg["enabled"] = 1
    return cfg


def write_config(cfg: Dict[str, Any]) -> Dict[str, Any]:
    DEFAULT_FILES.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        for k in DEFAULTS:
            v = cfg.get(k, DEFAULTS[k])
            v = int(float(v)) if k in INTEGER else float(v)
            w.writerow([k, v])
    return read_config()


def read_status() -> Dict[str, Any]:
    st = _read_pairs(STATUS_FILE)
    result: Dict[str, Any] = {}
    for k, v in st.items():
        try:
            result[k] = float(v) if "." in v else int(float(v))
        except ValueError:
            result[k] = v
    last = result.get("last_seen")
    result["connected"] = bool(last and (time.time() - float(last)) < 30)
    return result


def read_log(limit: int) -> List[Dict[str, str]]:
    if not LOG_FILE.exists():
        return []
    try:
        rows = list(csv.DictReader(_read_text(LOG_FILE).splitlines()))
    except OSError:
        return []
    return list(reversed(rows[-limit:]))


def read_reports() -> Dict[str, Any]:
    summary: List[Dict[str, str]] = []
    path = REPORTS / "summary.csv"
    if path.exists():
        with open(path, newline="", encoding="utf-8-sig") as fh:
            summary = list(csv.DictReader(fh))
    mc: Dict[str, Any] = {}
    mcpath = REPORTS / "montecarlo.json"
    if mcpath.exists():
        try:
            mc = json.loads(mcpath.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            mc = {}
    files = sorted(p.name for p in REPORTS.glob("*")) if REPORTS.exists() else []
    return {"summary": summary, "montecarlo": mc, "files": files}


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


@app.get("/api/status")
def status():
    return {
        "ea_compiled": (Path(os.environ.get(
            "SMC_TERMINAL",
            r"C:\Users\Student\AppData\Roaming\MetaQuotes\Terminal"
            r"\D0E8209F77C8CF37AD8BF550E51FF075")) /
            "MQL5" / "Experts" / "SMC_Bot" / "SMC_Bot.ex5").exists(),
        "status": read_status(),
        "config": read_config(),
        "files_dir": str(DEFAULT_FILES),
    }


@app.get("/api/config")
def get_config():
    return read_config()


@app.post("/api/config")
def set_config(payload: Dict[str, Any], x_password: str | None = Header(default=None, alias="X-SMC-Password")):
    _auth(x_password)
    unknown = set(payload) - EDITABLE
    if unknown:
        raise HTTPException(status_code=400, detail=f"unknown keys: {sorted(unknown)}")
    cfg = read_config()
    cfg.update(payload)
    return write_config(cfg)


@app.post("/api/config/reset")
def reset_config(x_password: str | None = Header(default=None, alias="X-SMC-Password")):
    _auth(x_password)
    return write_config(dict(DEFAULTS))


@app.get("/api/log")
def log(limit: int = Query(default=100, ge=1, le=2000)):
    return {"rows": read_log(limit)}


@app.get("/api/reports")
def reports():
    return read_reports()


@app.get("/api/equity")
def equity(limit: int = Query(default=300, ge=10, le=5000)):
    """Live equity curve points written by the EA every 5 s."""
    if not EQUITY_FILE.exists():
        return {"points": []}
    try:
        rows = list(csv.reader(_read_text(EQUITY_FILE).splitlines()))
    except OSError:
        return {"points": []}
    points = []
    for row in rows:
        if len(row) < 2:
            continue
        try:
            points.append([int(float(row[0])), float(row[1])])
        except ValueError:
            continue
    return {"points": points[-limit:]}


@app.post("/api/compile")
def compile_ea(x_password: str | None = Header(default=None, alias="X-SMC-Password")):
    _auth(x_password)
    try:
        proc = subprocess.run(
            ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(DEPLOY),
             "-Compile"],
            cwd=str(ROOT), capture_output=True, text=True, timeout=180,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    log_tail = ""
    if COMPILE_LOG.exists():
        lines = COMPILE_LOG.read_text(encoding="utf-16", errors="replace").splitlines()
        log_tail = "\n".join(lines[-20:])
    return {"returncode": proc.returncode,
            "output": proc.stdout[-2000:] + proc.stderr[-2000:],
            "log_tail": log_tail}


@app.get("/api/health")
def health():
    return {"ok": True, "time": time.time()}
