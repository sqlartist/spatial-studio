"""
Runs the real FastAPI app against a fake pyodbc connection so the UI can be exercised without SQL Server.
    python tests/mock_server.py   -> http://127.0.0.1:8799
"""
import math, struct, sys, pathlib, json
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))
import server  # noqa: E402
from shapely.geometry import Point, LineString, Polygon, MultiPolygon, shape  # noqa: E402
from shapely import affinity  # noqa: E402


def enc(g, srid=0, geography=False):
    pts, figs, shapes = [], [], []

    def P(c):
        x, y = c[0], c[1]
        pts.append((y, x) if geography else (x, y))

    def add(geom, parent):
        idx = len(shapes)
        t = geom.geom_type
        code = {"Point": 1, "LineString": 2, "Polygon": 3, "MultiPoint": 4, "MultiLineString": 5, "MultiPolygon": 6, "GeometryCollection": 7}[t]
        shapes.append([parent, len(figs), code])
        if t == "Point":
            figs.append((1, len(pts))); P(geom.coords[0])
        elif t == "LineString":
            figs.append((1, len(pts))); [P(c) for c in geom.coords]
        elif t == "Polygon":
            figs.append((2, len(pts))); [P(c) for c in geom.exterior.coords]
            for r in geom.interiors:
                figs.append((0, len(pts))); [P(c) for c in r.coords]
        else:
            for sub in geom.geoms:
                add(sub, idx)
    add(g, -1)
    b = struct.pack("<iBBi", srid, 1, 0x04, len(pts)) + b"".join(struct.pack("<dd", *p) for p in pts)
    b += struct.pack("<i", len(figs)) + b"".join(struct.pack("<Bi", a, o) for a, o in figs)
    b += struct.pack("<i", len(shapes)) + b"".join(struct.pack("<iiB", *s) for s in shapes)
    return b


countries = json.loads((ROOT / "app/static/data/countries110.geojson").read_text())["features"]


def toon_rows():
    sys.path.insert(0, "/tmp/claude-0")
    import preview as pv
    rows = []
    for t in range(0, 241):
        for z, (c, n) in sorted([(pv.parts[k]["z"], k) for k in pv.parts if k[0] in pv.cast]):
            M, v = pv.world(c, n, t)
            if v <= 0.5:
                continue
            a, b, cc, d, e, f = M
            rings = [[(a * x + b * y + cc, d * x + e * y + f) for x, y in r] for r in pv.parts[(c, n)]["rings"]]
            polys = [Polygon(r) for r in rings if len(r) > 3]
            g = polys[0] if len(polys) == 1 else MultiPolygon(polys)
            lab = pv.labels.get((c, n), (None, None))
            rows.append((t, enc(g), pv.parts[(c, n)]["color"], lab[0], lab[1], 1.6, 1.0))
    return rows


def canned(sql):
    sets = []
    if "toon.Frame" in sql:
        sets.append((["frame", "shape", "color", "label", "fontsize", "linewidth", "opacity"], toon_rows()))
        return sets
    if "frame" in sql.lower():
        rows = [(f, enc(Point(600, 600).buffer(f * 15)), "#4e79a7") for f in range(1, 11)]
        sets.append((["frame", "shape", "color"], rows))
        sets.append((["Geom", "color"], [(enc(Polygon([(400, 400), (800, 400), (800, 800), (400, 800)])), "#e8e4dc")]))
        return sets
    if "world" in sql.lower() or "geography" in sql.lower():
        rows = []
        for i, f in enumerate(countries[:60]):
            g = shape(f["geometry"])
            from shapely.geometry.polygon import orient
            g = orient(g, 1.0) if g.geom_type == "Polygon" else MultiPolygon([orient(x, 1.0) for x in g.geoms])
            rows.append((f["properties"]["name"], enc(g, 4326, True), f["properties"]["name"], f"hsl({i * 47 % 360},45%,60%)"))
        sets.append((["Name", "Geog", "label", "color"], rows))
        line = LineString([(-0.13, 51.5), (139.7, 35.7)])
        sets.append((["route", "label"], [(enc(line, 4326, True), "London to Tokyo (geodesic)")]))
        sets.append((["km"], [(9560.4,)]))
        return sets
    rows = []
    kinds = ["Square", "LShape", "Plus", "Triangle"]
    templ = {
        "Square": Polygon([(-1, -1), (1, -1), (1, 1), (-1, 1)]),
        "LShape": Polygon([(-1, -1), (1, -1), (1, -0.2), (-0.2, -0.2), (-0.2, 1), (-1, 1)]),
        "Plus": Polygon([(-.35, -1), (.35, -1), (.35, -.35), (1, -.35), (1, .35), (.35, .35), (.35, 1), (-.35, 1), (-.35, .35), (-1, .35), (-1, -.35), (-.35, -.35)]),
        "Triangle": Polygon([(-1, -.8), (1, -.8), (0, 1)]),
    }
    n = 0
    for bx in range(4):
        for by in range(4):
            for i in range(3):
                for j in range(3):
                    k = kinds[(bx + by + i + j) % 4]
                    g = affinity.scale(templ[k], 9, 9, origin=(0, 0))
                    g = affinity.rotate(g, (n * 37) % 360, origin=(0, 0))
                    g = affinity.translate(g, bx * 120 + 27 + i * 33, by * 120 + 27 + j * 33)
                    n += 1
                    rows.append((n, k, enc(g), k if n % 7 == 0 else None, "#7a5c4f"))
    sets.append((["BuildingId", "Kind", "Geom", "label", "color"], rows))
    courtyard = Polygon([(0, 0), (40, 0), (40, 40), (0, 40)], [[(10, 10), (10, 30), (30, 30), (30, 10)]])
    sets.append((["shape", "label", "color"], [(enc(affinity.translate(courtyard, 520, 40)), "courtyard", "#e15759")]))
    sets.append((["What", "Value"], [("rows", 144), ("ok", True)]))
    return sets


class FakeCursor:
    def __init__(self):
        self.sets, self.i, self.description, self.messages, self.rowcount = [], 0, None, [], -1

    def execute(self, sql, *params):
        if "sp_describe_first_result_set" in sql:
            self.sets = [(["name", "system_type_name"], [])]
        elif "@@VERSION" in sql:
            self.sets = [(["v", "pv", "ed", "db"], [("Microsoft SQL Server 2025 (RTM) - 17.0.1000.7 (MOCK)", "17.0.1000.7", "Developer Edition", 5)])]
        elif "COUNT(*)" in sql and "sys.tables" in sql or "BuildingShape" in sql and "COUNT" in sql:
            self.sets = [(["n"], [(1,)])]
        elif "RAISERROR" in sql or "boom" in sql:
            raise Exception("42000", "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Incorrect syntax near 'boom'. (102) (SQLExecDirectW)")
        else:
            self.sets = canned(sql)
            self.messages = [("[01000]", "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]mock PRINT message")]
        self.i = 0
        self._load()
        return self

    def _load(self):
        cols, rows = self.sets[self.i]
        self.description = [(c, object, None, None, None, None, True) for c in cols]
        self._rows = list(rows)

    def fetchone(self):
        return self._rows.pop(0) if self._rows else None

    def fetchall(self):
        r, self._rows = self._rows, []
        return r

    def fetchmany(self, n):
        r, self._rows = self._rows[:n], self._rows[n:]
        return r

    def nextset(self):
        self.messages = []
        self.i += 1
        if self.i >= len(self.sets):
            self.description = None
            return False
        self._load()
        return True

    def cancel(self):
        pass


class FakeConn:
    def cursor(self):
        return FakeCursor()

    def close(self):
        pass


server.connect = lambda database="__default__": FakeConn()
server.pyodbc = type("P", (), {"drivers": staticmethod(lambda: ["ODBC Driver 18 for SQL Server (mock)"])})
server.pick_driver = lambda: "ODBC Driver 18 for SQL Server (mock)"

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(server.app, host="127.0.0.1", port=8799, log_level="warning")
