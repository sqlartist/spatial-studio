"""
Spatial Studio for SQL Server 2025 - local web server.

    python -m uvicorn app.server:app --port 8765        (or just run run.bat / run.sh)

Talks to SQL Server through pyodbc, decodes spatial columns itself (see sqlspatial.py)
and serves the browser UI from app/static.
"""
from __future__ import annotations

import datetime as dt
import decimal
import json
import os
import pathlib
import re
import threading
import time
import uuid
import xml.etree.ElementTree as ET

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sqlspatial as sp  # noqa: E402

try:
    import pyodbc
except ImportError:  # the UI still loads and explains what's missing
    pyodbc = None

ROOT = pathlib.Path(__file__).resolve().parents[1]
STATIC = ROOT / "app" / "static"
DEMOS = ROOT / "demos"
INSTALL = ROOT / "sql" / "install"
CONFIG_FILE = ROOT / "config.json"

MAX_ROWS_DEFAULT = 5000
MAX_HEX_BYTES_TOTAL = 4_000_000

app = FastAPI(title="Spatial Studio")
app.mount("/static", StaticFiles(directory=STATIC), name="static")

# ------------------------------------------------------------------ connection config
_config_lock = threading.Lock()
_password: str | None = os.environ.get("SPATIAL_STUDIO_PASSWORD")


def _default_config():
    cfg = {
        "server": os.environ.get("SPATIAL_STUDIO_SERVER", "localhost"),
        "database": os.environ.get("SPATIAL_STUDIO_DATABASE", "SpatialStudio"),
        "auth": os.environ.get("SPATIAL_STUDIO_AUTH", "windows"),   # windows | sql
        "user": os.environ.get("SPATIAL_STUDIO_USER", ""),
        "driver": os.environ.get("SPATIAL_STUDIO_DRIVER", ""),
        "trustServerCertificate": True,
        "encrypt": "optional",
    }
    if CONFIG_FILE.exists():
        try:
            cfg.update(json.loads(CONFIG_FILE.read_text()))
        except Exception:
            pass
    return cfg


CONFIG = _default_config()


def pick_driver():
    if CONFIG.get("driver"):
        return CONFIG["driver"]
    if pyodbc is None:
        return None
    names = pyodbc.drivers()
    for pref in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server", "SQL Server Native Client 11.0", "SQL Server"):
        if pref in names:
            return pref
    for n in names:
        if "SQL Server" in n:
            return n
    return None


def conn_string(database: str | None):
    drv = pick_driver()
    if not drv:
        raise RuntimeError("No SQL Server ODBC driver found. Install 'ODBC Driver 18 for SQL Server'.")
    parts = [f"DRIVER={{{drv}}}", f"SERVER={CONFIG['server']}", "APP=Spatial Studio"]
    if database:
        parts.append(f"DATABASE={database}")
    if CONFIG.get("auth") == "sql":
        parts.append(f"UID={CONFIG.get('user', '')}")
        parts.append(f"PWD={{{(_password or '').replace('}', '}}')}}}")
    else:
        parts.append("Trusted_Connection=yes")
    if "18" in drv or "17" in drv:
        parts.append(f"Encrypt={CONFIG.get('encrypt', 'optional')}")
        if CONFIG.get("trustServerCertificate", True):
            parts.append("TrustServerCertificate=yes")
    return ";".join(parts)


def _passthrough(v):
    return v


def connect(database: str | None = "__default__"):
    if pyodbc is None:
        raise RuntimeError("pyodbc is not installed: pip install pyodbc")
    db = CONFIG["database"] if database == "__default__" else database
    cn = pyodbc.connect(conn_string(db), autocommit=True, timeout=10)
    # Spatial (CLR UDT = -151) and other exotic SQL types come back as raw bytes for us to decode.
    for t in range(-160, -149):
        try:
            cn.add_output_converter(t, _passthrough)
        except Exception:
            pass
    cn.timeout = 0
    return cn


# ------------------------------------------------------------------ batches
GO_RE = re.compile(r"^\s*GO\s*(\d+)?\s*(--.*)?$", re.IGNORECASE)


def split_batches(script: str):
    """Split on GO lines, like SSMS. Returns [(start_line, text, repeat)]."""
    batches, buf, start, in_block_comment = [], [], 1, False
    for n, line in enumerate(script.splitlines(), start=1):
        stripped = line.strip()
        if not in_block_comment and GO_RE.match(line):
            text = "\n".join(buf)
            if text.strip():
                rep = int(GO_RE.match(line).group(1) or 1)
                batches.append((start, text, rep))
            buf, start = [], n + 1
            continue
        # cheap block comment tracking so "GO" inside /* */ isn't a separator
        if "/*" in stripped and "*/" not in stripped.split("/*", 1)[1]:
            in_block_comment = True
        elif in_block_comment and "*/" in stripped:
            in_block_comment = False
        buf.append(line)
    text = "\n".join(buf)
    if text.strip():
        batches.append((start, text, 1))
    return batches


# ------------------------------------------------------------------ value conversion
def json_cell(v):
    if v is None or isinstance(v, (bool, int, str)):
        return v
    if isinstance(v, float):
        return v if v == v and v not in (float("inf"), float("-inf")) else str(v)
    if isinstance(v, decimal.Decimal):
        return float(v) if abs(v) < 1e15 else str(v)
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, (bytes, bytearray, memoryview)):
        b = bytes(v)
        return "0x" + b[:256].hex().upper() + ("..." if len(b) > 256 else "")
    return str(v)


def _kind_from_name(name: str):
    n = (name or "").lower()
    if "geog" in n:
        return "geography"
    if "geom" in n:
        return "geometry"
    return "unknown"


def describe_first(cur, batch: str):
    """Ask SQL Server for the declared types of the first result set (geometry vs geography)."""
    try:
        cur.execute("EXEC sys.sp_describe_first_result_set @tsql = ?", batch)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
        i_name, i_type = cols.index("name"), cols.index("system_type_name")
        return [(r[i_name], (r[i_type] or "").lower()) for r in rows]
    except Exception:
        return None


def build_result_set(cur, max_rows: int, declared, hex_budget):
    cols = [d[0] or f"(column {i + 1})" for i, d in enumerate(cur.description)]
    rows = cur.fetchmany(max_rows + 1)
    truncated = len(rows) > max_rows
    rows = rows[:max_rows]
    declared_kinds = {}
    if declared and len(declared) == len(cols):
        for i, (_, t) in enumerate(declared):
            if t in ("geometry", "geography"):
                declared_kinds[i] = t

    columns = [{"name": c, "spatial": False} for c in cols]
    out_rows = [[None] * len(cols) for _ in rows]
    features = []
    for ci, c in enumerate(cols):
        values = [r[ci] for r in rows]
        is_bytes = [isinstance(v, (bytes, bytearray, memoryview)) for v in values if v is not None]
        parsed = None
        if is_bytes and all(is_bytes):
            try:
                parsed = [sp.parse(bytes(v)) if v is not None else None for v in values]
                if any(p is not None and any(f[2] == "trailing" for f in p.fields) for p in parsed):
                    parsed = None
            except Exception:
                parsed = None
        if parsed is None:
            for ri, v in enumerate(values):
                out_rows[ri][ci] = json_cell(v)
            continue
        kind = declared_kinds.get(ci) or _kind_from_name(c)
        srids = {p.srid for p in parsed if p is not None}
        if kind == "unknown" and any(abs(x) > 90.0000001 for p in parsed if p for x in p.xs):
            kind = "geometry"  # geography's first ordinate is latitude; this can't be geography
        mode = sp.choose_mode(kind, next(iter(srids)) if srids else 0)
        columns[ci].update(spatial=True, kind=kind, mode=mode, srids=sorted(srids))
        for ri, p in enumerate(parsed):
            if p is None:
                out_rows[ri][ci] = None
                continue
            raw = bytes(values[ri])
            pm = sp.choose_mode(kind, p.srid)
            parts = sp.display_parts(p, pm)
            wkt_short = sp.to_wkt(p, pm == "geography", 400)
            cell = {"$sp": True, "type": p.root_type, "srid": p.srid, "wkt": wkt_short, "mode": pm, "bytes": len(raw)}
            if hex_budget[0] + len(raw) <= MAX_HEX_BYTES_TOTAL:
                cell["hex"] = raw.hex()
                hex_budget[0] += len(raw)
            out_rows[ri][ci] = cell
            features.append({"row": ri, "col": ci, "mode": pm, "parts": parts, "bbox": sp.bbox(parts)})
    return {"columns": columns, "rows": out_rows, "rowCount": len(out_rows), "truncated": truncated, "features": features}


def _drain_messages(cur, sink, batch_no):
    try:
        for _, text in getattr(cur, "messages", None) or []:
            text = re.sub(r"^\[[^\]]*\]\[[^\]]*\]\[[^\]]*\]", "", str(text)).strip()
            sink.append({"batch": batch_no, "kind": "info", "text": text})
    except Exception:
        pass


_running = {}
_running_lock = threading.Lock()


def run_script(script: str, max_rows: int = MAX_ROWS_DEFAULT, describe: bool = True, collect: bool = True,
               database: str | None = "__default__"):
    started = time.perf_counter()
    result = {"resultSets": [], "messages": [], "errors": [], "batches": 0}
    hex_budget = [0]
    run_id = uuid.uuid4().hex
    try:
        cn = connect(database)
    except Exception as e:
        result["errors"].append({"batch": 0, "line": 0, "text": clean_error(e)})
        result["elapsedMs"] = int((time.perf_counter() - started) * 1000)
        return result
    try:
        cur = cn.cursor()
        with _running_lock:
            _running[run_id] = cur
        for bi, (line, text, rep) in enumerate(split_batches(script), start=1):
            result["batches"] += 1
            declared = describe_first(cur, text) if (describe and collect) else None
            for _ in range(rep):
                t0 = time.perf_counter()
                try:
                    cur.execute(text)
                    while True:
                        _drain_messages(cur, result["messages"], bi)
                        if cur.description:
                            if collect:
                                rs = build_result_set(cur, max_rows, declared, hex_budget)
                                declared = None  # only the first result set of a batch matches sp_describe_first_result_set
                                rs["batch"] = bi
                                result["resultSets"].append(rs)
                            else:
                                cur.fetchall()
                        elif cur.rowcount is not None and cur.rowcount >= 0:
                            result["messages"].append({"batch": bi, "kind": "rows", "text": f"({cur.rowcount} row{'s' if cur.rowcount != 1 else ''} affected)"})
                        if not cur.nextset():
                            break
                    _drain_messages(cur, result["messages"], bi)
                except Exception as e:
                    _drain_messages(cur, result["messages"], bi)
                    msg = clean_error(e)
                    lm = re.search(r"[Ll]ine (\d+)", msg)
                    err_line = line - 1 + int(lm.group(1)) if lm else line
                    result["errors"].append({"batch": bi, "line": err_line, "text": msg})
                    result["messages"].append({"batch": bi, "kind": "error", "text": f"Batch {bi} (script line {err_line}): {msg}"})
                result["messages"].append({"batch": bi, "kind": "time",
                                           "text": f"Batch {bi} finished in {int((time.perf_counter() - t0) * 1000)} ms"})
    finally:
        with _running_lock:
            _running.pop(run_id, None)
        try:
            cn.close()
        except Exception:
            pass
    result["elapsedMs"] = int((time.perf_counter() - started) * 1000)
    return result


def clean_error(e: Exception) -> str:
    text = str(e.args[1]) if getattr(e, "args", None) and len(e.args) > 1 else str(e)
    text = re.sub(r"\[[^\]]*\]\[[^\]]*\]\[[^\]]*\]", "", text)
    text = re.sub(r"\s*\(\d+\)\s*\(SQLExecDirectW\)", "", text)
    text = re.sub(r"\s*\(SQLExecDirectW\)", "", text)
    return text.strip()


# ------------------------------------------------------------------ demos
def load_demos():
    packs = []
    for f in sorted(DEMOS.glob("*.sql")):
        text = f.read_text(encoding="utf-8")
        title = re.sub(r"^\d+_", "", f.stem).replace("_", " ").title()
        m = re.search(r"demo pack \d+ - (.+?)(?:\s*\*/)?$", text, re.MULTILINE)
        if m:
            title = m.group(1).strip()
        demos = []
        chunks = re.split(r"(?m)^--#demo\s+", text)
        for ci, chunk in enumerate(chunks[1:], start=1):
            lines = chunk.splitlines()
            demo = {"id": f"{f.stem}#{ci}", "pack": title, "title": lines[0].strip(), "desc": [], "view": None, "tags": []}
            body = []
            for ln in lines[1:]:
                if ln.startswith("--#desc"):
                    demo["desc"].append(ln[7:].strip())
                elif ln.startswith("--#view"):
                    demo["view"] = ln[7:].strip()
                elif ln.startswith("--#tags"):
                    demo["tags"] = [t.strip() for t in ln[7:].split(",") if t.strip()]
                else:
                    body.append(ln)
            demo["desc"] = " ".join(demo["desc"])
            header = f"-- {demo['title']}\n" + (f"-- {demo['desc']}\n" if demo["desc"] else "")
            demo["sql"] = header + "\n".join(body).strip() + "\n"
            demos.append(demo)
        packs.append({"file": f.name, "title": title, "demos": demos})
    return packs


# ------------------------------------------------------------------ explain
NS = {"p": "http://schemas.microsoft.com/sqlserver/2004/07/showplan"}


def summarise_plan(xml_text: str):
    root = ET.fromstring(xml_text)
    stmts = []
    for st in root.iter("{%s}StmtSimple" % NS["p"]):
        rel = st.find(".//p:QueryPlan/p:RelOp", NS)
        stmts.append({
            "text": (st.get("StatementText") or "").strip()[:400],
            "cost": float(st.get("StatementSubTreeCost") or 0),
            "rows": float(st.get("StatementEstRows") or 0),
            "plan": _relop(rel) if rel is not None else None,
        })
    return stmts


def _relop(el):
    node = {
        "op": el.get("PhysicalOp"), "logical": el.get("LogicalOp"),
        "rows": float(el.get("EstimateRows") or 0), "cost": float(el.get("EstimatedTotalSubtreeCost") or 0),
        "parallel": el.get("Parallel") == "1", "object": None, "children": [],
    }
    obj = None
    for child in el:
        tag = child.tag.split("}")[1]
        if tag in ("IndexScan", "TableScan"):
            o = child.find("p:Object", NS)
            if o is not None:
                obj = o
    if obj is not None:
        node["object"] = ".".join(x.strip("[]") for x in (obj.get("Schema"), obj.get("Table"), obj.get("Index")) if x)
    for sub in el.iter("{%s}RelOp" % NS["p"]):
        if sub is el:
            continue
        # only direct RelOp descendants (not grandchildren)
        parent_relop = _closest_relop_parent(el, sub)
        if parent_relop is el:
            node["children"].append(_relop(sub))
    idx = (node["object"] or "").upper()
    node["spatial"] = "SIX_" in idx or "SPATIAL" in (node["op"] or "").upper() or "EXTENDED_INDEX" in idx
    node["vector"] = "VIX_" in idx or "VECTOR" in (node["op"] or "").upper()
    return node


def _closest_relop_parent(top, target):
    # walk down from top keeping the nearest RelOp ancestor
    stack = [(top, top)]
    while stack:
        el, nearest = stack.pop()
        for c in el:
            if c is target:
                return nearest
            stack.append((c, c if c.tag.endswith("RelOp") else nearest))
    return None


# ------------------------------------------------------------------ API models
class RunRequest(BaseModel):
    sql: str
    maxRows: int | None = MAX_ROWS_DEFAULT


class ConnectRequest(BaseModel):
    server: str
    database: str = "SpatialStudio"
    auth: str = "windows"
    user: str = ""
    password: str | None = None
    driver: str = ""
    trustServerCertificate: bool = True
    encrypt: str = "optional"
    remember: bool = True


class InspectRequest(BaseModel):
    hex: str
    kind: str = "unknown"


class ImportRequest(BaseModel):
    table: str
    srid: int = 4326
    geography: bool = True
    geojson: str


# ------------------------------------------------------------------ routes
@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


@app.get("/api/status")
def status():
    info = {"config": {k: v for k, v in CONFIG.items()}, "pyodbc": pyodbc is not None,
            "drivers": pyodbc.drivers() if pyodbc else [], "driver": pick_driver() if pyodbc else None,
            "connected": False, "installed": False}
    try:
        cn = connect(None)
        cur = cn.cursor()
        cur.execute("SELECT @@VERSION, SERVERPROPERTY('ProductVersion'), SERVERPROPERTY('Edition'), DB_ID(?)", CONFIG["database"])
        ver, pv, ed, dbid = cur.fetchone()
        info.update(connected=True, version=ver.splitlines()[0], productVersion=pv, edition=ed, databaseExists=dbid is not None)
        try:
            info["is2025"] = int(str(pv).split(".")[0]) >= 17
        except Exception:
            info["is2025"] = None
        if dbid is not None:
            cur.execute(f"SELECT COUNT(*) FROM [{CONFIG['database']}].sys.tables t JOIN [{CONFIG['database']}].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = 'town' AND t.name = 'Building'")
            has_table = cur.fetchone()[0] > 0
            if has_table:
                cur.execute(f"SELECT COUNT(*) FROM [{CONFIG['database']}].town.BuildingShape")
                info["installed"] = cur.fetchone()[0] > 0
        cn.close()
    except Exception as e:
        info["error"] = clean_error(e)
    return info


@app.post("/api/connect")
def set_connection(req: ConnectRequest):
    global _password
    with _config_lock:
        CONFIG.update(server=req.server, database=req.database or "SpatialStudio", auth=req.auth, user=req.user,
                      driver=req.driver, trustServerCertificate=req.trustServerCertificate, encrypt=req.encrypt)
        if req.password is not None:
            _password = req.password
        if req.remember:
            CONFIG_FILE.write_text(json.dumps(CONFIG, indent=2))   # never the password
    return status()


@app.get("/api/demos")
def demos():
    return load_demos()


@app.post("/api/run")
def run(req: RunRequest):
    return JSONResponse(run_script(req.sql, max(1, min(req.maxRows or MAX_ROWS_DEFAULT, 50000))))


@app.post("/api/cancel")
def cancel():
    n = 0
    with _running_lock:
        for cur in list(_running.values()):
            try:
                cur.cancel()
                n += 1
            except Exception:
                pass
    return {"cancelled": n}


@app.post("/api/explain")
def explain(req: RunRequest):
    out = {"statements": [], "errors": []}
    try:
        cn = connect()
    except Exception as e:
        return {"statements": [], "errors": [clean_error(e)]}
    cur = cn.cursor()
    try:
        cur.execute("SET SHOWPLAN_XML ON")
        for bi, (line, text, _) in enumerate(split_batches(req.sql), start=1):
            try:
                cur.execute(text)
                while True:
                    if cur.description:
                        for row in cur.fetchall():
                            out["statements"].extend(summarise_plan(row[0]))
                    if not cur.nextset():
                        break
            except Exception as e:
                out["errors"].append(f"Batch {bi}: {clean_error(e)}")
    finally:
        try:
            cur.execute("SET SHOWPLAN_XML OFF")
        except Exception:
            pass
        cn.close()
    return out


@app.post("/api/inspect")
def inspect(req: InspectRequest):
    h = req.hex.strip()
    if h.lower().startswith("0x"):
        h = h[2:]
    try:
        return sp.inspect(bytes.fromhex(re.sub(r"\s+", "", h)), req.kind)
    except Exception as e:
        raise HTTPException(400, f"Could not decode: {e}")


def _ndjson(gen):
    for item in gen:
        yield json.dumps(item) + "\n"


@app.post("/api/install")
def install():
    def gen():
        files = sorted(INSTALL.glob("*.sql"))
        yield {"kind": "start", "files": [f.name for f in files]}
        for f in files:
            t0 = time.perf_counter()
            yield {"kind": "file", "file": f.name}
            res = run_script(f.read_text(encoding="utf-8"), describe=False, collect=False, database=None)
            for m in res["messages"]:
                if m["kind"] in ("info", "error"):
                    yield {"kind": m["kind"], "file": f.name, "text": m["text"]}
            yield {"kind": "done", "file": f.name, "ms": int((time.perf_counter() - t0) * 1000), "errors": len(res["errors"])}
        yield {"kind": "finished"}
    return StreamingResponse(_ndjson(gen()), media_type="application/x-ndjson")


@app.post("/api/selftest")
def selftest():
    def gen():
        packs = load_demos()
        total = sum(len(p["demos"]) for p in packs)
        yield {"kind": "start", "total": total}
        for p in packs:
            for d in p["demos"]:
                t0 = time.perf_counter()
                res = run_script(d["sql"], describe=False, collect=True, max_rows=200)
                ms = int((time.perf_counter() - t0) * 1000)
                errs = [e["text"] for e in res["errors"]]
                # demos that catch their own errors return a column saying so
                for rs in res["resultSets"]:
                    for c in rs["columns"]:
                        if c["name"] in ("VECTOR_SEARCH unavailable",):
                            errs.append("handled: " + str(rs["rows"][0][rs["columns"].index(c)] if rs["rows"] else ""))
                yield {"kind": "demo", "id": d["id"], "pack": p["title"], "title": d["title"], "ok": not res["errors"],
                       "warning": bool(errs) and not res["errors"], "ms": ms, "errors": errs[:3],
                       "resultSets": len(res["resultSets"])}
        yield {"kind": "finished"}
    return StreamingResponse(_ndjson(gen()), media_type="application/x-ndjson")


@app.post("/api/import-geojson")
def import_geojson(req: ImportRequest):
    name = re.sub(r"[^A-Za-z0-9_]", "_", req.table.strip()) or "Imported"
    try:
        json.loads(req.geojson)
    except Exception as e:
        raise HTTPException(400, f"Not valid JSON: {e}")
    srid = int(req.srid)
    geog_col = (", Geog = sx.GeomToGeog(f.Geom)" if req.geography else "")
    sql = f"""
SET NOCOUNT ON;
DROP TABLE IF EXISTS lab.[{name}];
DECLARE @doc nvarchar(max) = ?;
IF JSON_VALUE(@doc, '$.type') <> 'FeatureCollection'
    SET @doc = CASE WHEN JSON_VALUE(@doc, '$.type') = 'Feature'
                    THEN CONCAT('{{"type":"FeatureCollection","features":[', @doc, ']}}')
                    ELSE CONCAT('{{"type":"FeatureCollection","features":[{{"type":"Feature","properties":{{}},"geometry":', @doc, '}}]}}') END;
SELECT FeatureId = f.FeatureIndex + 1, Properties = CAST(f.Properties AS nvarchar(max)), Geom = f.Geom{geog_col}
INTO lab.[{name}]
FROM sx.GeoJsonFeatures(@doc, {srid}) AS f;
ALTER TABLE lab.[{name}] ALTER COLUMN FeatureId int NOT NULL;
ALTER TABLE lab.[{name}] ADD CONSTRAINT [PK_{name}] PRIMARY KEY (FeatureId);
SELECT COUNT(*) FROM lab.[{name}];
"""
    try:
        cn = connect()
        cur = cn.cursor()
        cur.execute(sql, req.geojson)
        while cur.description is None and cur.nextset():
            pass
        n = cur.fetchone()[0]
        cn.close()
    except Exception as e:
        raise HTTPException(400, clean_error(e))
    col = "Geog" if req.geography else "Geom"
    return {"table": f"lab.{name}", "rows": n,
            "query": f"SELECT FeatureId, Properties, {col}, label = JSON_VALUE(Properties, '$.name')\nFROM lab.[{name}];\n"}
