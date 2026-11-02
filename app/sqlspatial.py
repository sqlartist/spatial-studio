"""
Decoder for SQL Server's native geometry/geography serialisation (MS-SSCLRT, versions 1 and 2).

pyodbc hands spatial columns back as raw bytes. This module turns those bytes into
  * an exact WKT string (curves included)
  * display parts (points / lines / polygons) in viewer coordinates, with arcs and
    long geodesic edges densified so they draw truthfully
  * an annotated field-by-field breakdown for the binary Inspector
"""
from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field

SHAPE_TYPES = {
    0: "Unknown", 1: "Point", 2: "LineString", 3: "Polygon", 4: "MultiPoint", 5: "MultiLineString",
    6: "MultiPolygon", 7: "GeometryCollection", 8: "CircularString", 9: "CompoundCurve",
    10: "CurvePolygon", 11: "FullGlobe",
}
FIG_V1 = {0: "InteriorRing", 1: "Stroke", 2: "ExteriorRing"}
FIG_V2 = {0: "Point", 1: "Line", 2: "Arc", 3: "CompositeCurve"}
SEG = {0: "Line", 1: "Arc", 2: "FirstLine", 3: "FirstArc"}

# SRIDs that geography accepts are (almost all) 4120-4999 plus 104001; treat geometry with these as lon/lat too
def is_geodetic_srid(srid: int) -> bool:
    return 4000 <= srid <= 4999 or srid == 104001


class SpatialParseError(ValueError):
    pass


@dataclass
class Spatial:
    srid: int
    version: int
    props: int
    xs: list = field(default_factory=list)   # first stored ordinate (geography: latitude)
    ys: list = field(default_factory=list)   # second stored ordinate (geography: longitude)
    zs: list | None = None
    ms: list | None = None
    figures: list = field(default_factory=list)   # (attribute, pointOffset)
    shapes: list = field(default_factory=list)    # (parentOffset, figureOffset, type)
    segments: list = field(default_factory=list)
    fields: list = field(default_factory=list)    # (offset, length, group, label, value)

    @property
    def has_z(self): return bool(self.props & 0x01)
    @property
    def has_m(self): return bool(self.props & 0x02)
    @property
    def is_valid_flag(self): return bool(self.props & 0x04)
    @property
    def larger_than_hemisphere(self): return bool(self.props & 0x20)
    @property
    def root_type(self): return SHAPE_TYPES.get(self.shapes[0][2], "?") if self.shapes else "?"


def parse(buf: bytes) -> Spatial:
    if buf is None or len(buf) < 6:
        raise SpatialParseError("too short to be a spatial value")
    b = bytes(buf)
    pos = 0
    fields = []

    def take(fmt, group, label, describe=None):
        nonlocal pos
        size = struct.calcsize(fmt)
        if pos + size > len(b):
            raise SpatialParseError(f"unexpected end of data reading {label}")
        val = struct.unpack_from(fmt, b, pos)
        val = val[0] if len(val) == 1 else val
        fields.append((pos, size, group, label, describe(val) if describe else val))
        pos += size
        return val

    srid = take("<i", "header", "SRID")
    version = take("<B", "header", "Version")
    if version not in (1, 2):
        raise SpatialParseError(f"unknown serialisation version {version}")
    props = take("<B", "header", "Properties", lambda p: f"0x{p:02X} " + describe_props(p))
    s = Spatial(srid=srid, version=version, props=props, fields=fields)

    single_point = bool(props & 0x08)
    single_line = bool(props & 0x10)
    if single_point:
        npts = 1
    elif single_line:
        npts = 2
    else:
        npts = take("<i", "counts", "NumberOfPoints")
    for i in range(npts):
        x = take("<d", "points", f"Point[{i}] x")
        y = take("<d", "points", f"Point[{i}] y")
        s.xs.append(x)
        s.ys.append(y)
    if props & 0x01:
        s.zs = [take("<d", "z", f"Z[{i}]") for i in range(npts)]
    if props & 0x02:
        s.ms = [take("<d", "m", f"M[{i}]") for i in range(npts)]

    if single_point:
        s.figures = [(1, 0)]
        s.shapes = [(-1, 0, 1)]
    elif single_line:
        s.figures = [(1, 0)]
        s.shapes = [(-1, 0, 2)]
    else:
        nfig = take("<i", "counts", "NumberOfFigures")
        for i in range(nfig):
            fmap = FIG_V1 if version == 1 else FIG_V2
            attr = take("<B", "figures", f"Figure[{i}] attribute", lambda a, fm=fmap: f"{a} {fm.get(a, '?')}")
            # the value stored in fields is a description string; keep the raw byte separately
            attr_raw = b[pos - 1]
            off = take("<i", "figures", f"Figure[{i}] point offset")
            s.figures.append((attr_raw, off))
        nshape = take("<i", "counts", "NumberOfShapes")
        for i in range(nshape):
            parent = take("<i", "shapes", f"Shape[{i}] parent")
            fo = take("<i", "shapes", f"Shape[{i}] figure offset")
            take("<B", "shapes", f"Shape[{i}] type", lambda t: f"{t} {SHAPE_TYPES.get(t, '?')}")
            s.shapes.append((parent, fo, b[pos - 1]))
        if version == 2 and pos < len(b):
            nseg = take("<i", "counts", "NumberOfSegments")
            for i in range(nseg):
                take("<B", "segments", f"Segment[{i}]", lambda t: f"{t} {SEG.get(t, '?')}")
                s.segments.append(b[pos - 1])
    if pos != len(b):
        fields.append((pos, len(b) - pos, "trailing", "unparsed trailing bytes", len(b) - pos))
    return s


def describe_props(p: int) -> str:
    names = []
    for bit, name in ((0x01, "HasZ"), (0x02, "HasM"), (0x04, "IsValid"), (0x08, "SinglePoint"),
                      (0x10, "SingleLineSegment"), (0x20, "LargerThanHemisphere")):
        if p & bit:
            names.append(name)
    return "(" + ", ".join(names) + ")" if names else "(none)"


# ------------------------------------------------------------------ structure helpers
def _children(s: Spatial, i: int):
    return [j for j, sh in enumerate(s.shapes) if sh[0] == i]


def _shape_figure_range(s: Spatial, i: int):
    """Figures belonging to leaf shape i: from its offset to the next shape (in pre-order) that owns figures."""
    fo = s.shapes[i][1]
    if fo < 0:
        return range(0)
    end = len(s.figures)
    for j in range(i + 1, len(s.shapes)):
        if s.shapes[j][1] >= 0:
            end = s.shapes[j][1]
            break
    return range(fo, end)


def _is_leaf(s, i):
    return s.shapes[i][2] not in (4, 5, 6, 7)


def _figure_point_range(s: Spatial, f: int):
    start = s.figures[f][1]
    end = s.figures[f + 1][1] if f + 1 < len(s.figures) else len(s.xs)
    return range(start, end)


def _composite_segments(s: Spatial):
    """Map composite figure index -> list of segment kinds ('L' or 'A')."""
    out = {}
    groups = []
    for seg in s.segments:
        if seg in (2, 3) or not groups:
            groups.append([])
        groups[-1].append("A" if seg in (1, 3) else "L")
    gi = 0
    for f, (attr, _) in enumerate(s.figures):
        if s.version == 2 and attr == 3:
            out[f] = groups[gi] if gi < len(groups) else []
            gi += 1
    return out


def _pieces(s: Spatial, f: int, comp):
    """Split a figure into ('L'|'A', [point indices]) pieces in drawing order."""
    pts = list(_figure_point_range(s, f))
    attr = s.figures[f][0]
    if s.version == 1 or attr in (0, 1):
        return [("L", pts)]
    if attr == 2:
        return [("A", pts)]
    # composite
    pieces = []
    k = 0
    for kind in comp.get(f, []):
        n = 2 if kind == "A" else 1
        seg = pts[k:k + n + 1]
        if pieces and pieces[-1][0] == kind:
            pieces[-1][1].extend(seg[1:])
        else:
            pieces.append((kind, seg))
        k += n
    return pieces


# ------------------------------------------------------------------ WKT
def _num(v: float) -> str:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "NULL"
    if float(v).is_integer() and abs(v) < 1e15:
        return str(int(v))
    return format(v, ".15g")


def to_wkt(s: Spatial, geography: bool, max_len: int | None = None) -> str:
    comp = _composite_segments(s)

    def coord(i):
        x, y = (s.ys[i], s.xs[i]) if geography else (s.xs[i], s.ys[i])
        parts = [_num(x), _num(y)]
        if s.has_z or s.has_m:
            z = s.zs[i] if s.zs else None
            if s.has_z or s.has_m:
                parts.append(_num(z) if s.has_z else "NULL")
            if s.has_m:
                parts.append(_num(s.ms[i]))
            while parts and parts[-1] == "NULL" and len(parts) > 2:
                parts.pop()
        return " ".join(parts)

    def plist(idx):
        return "(" + ", ".join(coord(i) for i in idx) + ")"

    def figure_text(f, curve_context: bool):
        pieces = _pieces(s, f, comp)
        attr = s.figures[f][0]
        if s.version == 2 and attr == 2:
            return "CIRCULARSTRING " + plist(pieces[0][1])
        if s.version == 2 and attr == 3:
            return "COMPOUNDCURVE (" + ", ".join(
                ("CIRCULARSTRING " + plist(p) if k == "A" else plist(p)) for k, p in pieces) + ")"
        return plist(pieces[0][1])

    def shape(i):
        t = s.shapes[i][2]
        name = SHAPE_TYPES.get(t, "Unknown").upper()
        if t == 11:
            return "FULLGLOBE"
        figs = list(_shape_figure_range(s, i))
        if t in (4, 5, 6, 7):
            kids = _children(s, i)
            if not kids:
                return name + " EMPTY"
            if t == 7:
                return name + " (" + ", ".join(shape(k) for k in kids) + ")"
            inner = []
            for k in kids:
                txt = shape(k)
                inner.append(txt[txt.index("("):] if "(" in txt else "EMPTY")
            return name + " (" + ", ".join(inner) + ")"
        if not figs:
            return name + " EMPTY"
        if t == 1:
            return "POINT " + plist(_figure_point_range(s, figs[0]))
        if t == 2:
            return "LINESTRING " + plist(_figure_point_range(s, figs[0]))
        if t == 8:
            return "CIRCULARSTRING " + plist(_figure_point_range(s, figs[0]))
        if t == 9:
            txt = figure_text(figs[0], True)
            return txt if txt.startswith("COMPOUNDCURVE") else "COMPOUNDCURVE (" + txt + ")"
        if t == 3:
            return "POLYGON (" + ", ".join(plist(_figure_point_range(s, f)) for f in figs) + ")"
        if t == 10:
            return "CURVEPOLYGON (" + ", ".join(figure_text(f, True) for f in figs) + ")"
        return name

    if not s.shapes:
        return "GEOMETRYCOLLECTION EMPTY"
    txt = shape(0)
    if max_len and len(txt) > max_len:
        return txt[:max_len] + " ..."
    return txt


# ------------------------------------------------------------------ display geometry
def _arc_points(p0, p1, p2, max_step_deg=4.0):
    (x0, y0), (x1, y1), (x2, y2) = p0, p1, p2
    if p0 == p2:  # a closed arc is a full circle; p1 is the opposite side
        ux, uy = (x0 + x1) / 2, (y0 + y1) / 2
        r = math.hypot(x0 - ux, y0 - uy)
        a0 = math.atan2(y0 - uy, x0 - ux)
        n = int(360 / max_step_deg)
        return [(ux + r * math.cos(a0 + 2 * math.pi * k / n), uy + r * math.sin(a0 + 2 * math.pi * k / n)) for k in range(n + 1)]
    d = 2 * (x0 * (y1 - y2) + x1 * (y2 - y0) + x2 * (y0 - y1))
    if abs(d) < 1e-12:
        return [p0, p2]
    ux = ((x0 * x0 + y0 * y0) * (y1 - y2) + (x1 * x1 + y1 * y1) * (y2 - y0) + (x2 * x2 + y2 * y2) * (y0 - y1)) / d
    uy = ((x0 * x0 + y0 * y0) * (x2 - x1) + (x1 * x1 + y1 * y1) * (x0 - x2) + (x2 * x2 + y2 * y2) * (x1 - x0)) / d
    r = math.hypot(x0 - ux, y0 - uy)
    a0 = math.atan2(y0 - uy, x0 - ux)
    a1 = math.atan2(y1 - uy, x1 - ux)
    a2 = math.atan2(y2 - uy, x2 - ux)
    tau = 2 * math.pi
    ccw_to_end = (a2 - a0) % tau
    ccw_to_mid = (a1 - a0) % tau
    if ccw_to_mid <= ccw_to_end:
        sweep = ccw_to_end
    else:
        sweep = ccw_to_end - tau
    n = max(2, int(abs(math.degrees(sweep)) / max_step_deg))
    return [(ux + r * math.cos(a0 + sweep * k / n), uy + r * math.sin(a0 + sweep * k / n)) for k in range(n + 1)]


def _slerp_densify(pts, max_deg=1.5):
    """Insert great-circle points between (lon, lat) pairs further apart than max_deg."""
    if len(pts) < 2:
        return pts
    out = [pts[0]]
    for (lon1, lat1), (lon2, lat2) in zip(pts, pts[1:]):
        p1, l1, p2, l2 = map(math.radians, (lat1, lon1, lat2, lon2))
        a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin((l2 - l1) / 2) ** 2
        dist = 2 * math.asin(min(1.0, math.sqrt(a)))
        n = int(math.degrees(dist) / max_deg)
        if n > 1 and dist > 1e-9 and abs(math.pi - dist) > 1e-6:
            for k in range(1, n):
                f = k / n
                A = math.sin((1 - f) * dist) / math.sin(dist)
                B = math.sin(f * dist) / math.sin(dist)
                x = A * math.cos(p1) * math.cos(l1) + B * math.cos(p2) * math.cos(l2)
                y = A * math.cos(p1) * math.sin(l1) + B * math.cos(p2) * math.sin(l2)
                z = A * math.sin(p1) + B * math.sin(p2)
                out.append((math.degrees(math.atan2(y, x)), math.degrees(math.atan2(z, math.hypot(x, y)))))
        out.append((lon2, lat2))
    return out


def _unwrap(pts):
    if not pts:
        return pts
    out = [pts[0]]
    for lon, lat in pts[1:]:
        prev = out[-1][0]
        while lon - prev > 180:
            lon -= 360
        while lon - prev < -180:
            lon += 360
        out.append((lon, lat))
    return out


def _signed_area(ring):
    a = 0.0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        a += x1 * y2 - x2 * y1
    return a / 2


def _inv_merc(x, y):
    lon = math.degrees(x / 6378137.0)
    lat = math.degrees(2 * math.atan(math.exp(y / 6378137.0)) - math.pi / 2)
    return lon, lat


def display_parts(s: Spatial, mode: str):
    """
    mode: 'geography' (stored lat,long -> lon,lat, geodesic edges),
          'lonlat'    (geometry x=lon y=lat),
          'merc'      (geometry in EPSG:3857 metres),
          'plane'     (raw x, y)
    Returns dict(points=[[x,y]], lines=[[[x,y],...]], polys=[[ring,...]]) in display coordinates.
    """
    comp = _composite_segments(s)
    geo = mode == "geography"

    def xy(i):
        if geo:
            return (s.ys[i], s.xs[i])
        if mode == "merc":
            return _inv_merc(s.xs[i], s.ys[i])
        return (s.xs[i], s.ys[i])

    def figure_path(f):
        out = []
        for kind, idx in _pieces(s, f, comp):
            p = [xy(i) for i in idx]
            if kind == "A":
                seg = []
                for k in range(0, len(p) - 2, 2):
                    arc = _arc_points(p[k], p[k + 1], p[k + 2])
                    seg.extend(arc if not seg else arc[1:])
                p = seg
            elif geo:
                p = _slerp_densify(p)
            out.extend(p if not out else p[1:])
        if geo or mode == "lonlat" or mode == "merc":
            out = _unwrap(out)
        return out

    res = {"points": [], "lines": [], "polys": []}

    def close_polar(ring):
        # a ring that walks all the way round the globe: close it over the pole it encloses
        span = ring[-1][0] - ring[0][0]
        if abs(span) > 300:
            pole = 85.0 if span > 0 else -85.0
            ring = ring + [(ring[-1][0], pole), (ring[0][0], pole), ring[0]]
        return ring

    def walk(i):
        t = s.shapes[i][2]
        if t == 11:
            res["polys"].append([[(-180, -85), (180, -85), (180, 85), (-180, 85), (-180, -85)]])
            return
        if t in (4, 5, 6, 7):
            for k in _children(s, i):
                walk(k)
            return
        figs = list(_shape_figure_range(s, i))
        if not figs:
            return
        if t == 1:
            res["points"].append(xy(_figure_point_range(s, figs[0])[0]))
        elif t in (2, 8, 9):
            res["lines"].append(figure_path(figs[0]))
        elif t in (3, 10):
            rings = [figure_path(f) for f in figs]
            if geo and rings:
                rings = [close_polar(r) for r in rings]
                ext = rings[0]
                # geography exteriors run anticlockwise; a clockwise exterior means "everything outside this"
                if abs(ext[-1][0] - ext[0][0]) < 1 and _signed_area(ext[:-1]) < 0:
                    rings = [[(-180, -85), (180, -85), (180, 85), (-180, 85), (-180, -85)]] + rings
            res["polys"].append(rings)

    if s.shapes:
        walk(0)
    # round to keep payloads small
    rnd = 7 if mode != "plane" else 4

    def r(p):
        return [round(p[0], rnd), round(p[1], rnd)]

    return {
        "points": [r(p) for p in res["points"]],
        "lines": [[r(p) for p in line] for line in res["lines"]],
        "polys": [[[r(p) for p in ring] for ring in poly] for poly in res["polys"]],
    }


def bbox(parts):
    xs, ys = [], []
    for p in parts["points"]:
        xs.append(p[0]); ys.append(p[1])
    for line in parts["lines"]:
        for p in line:
            xs.append(p[0]); ys.append(p[1])
    for poly in parts["polys"]:
        for ring in poly:
            for p in ring:
                xs.append(p[0]); ys.append(p[1])
    if not xs:
        return None
    return [min(xs), min(ys), max(xs), max(ys)]


def choose_mode(kind: str, srid: int) -> str:
    """kind: 'geography' | 'geometry' | 'unknown'."""
    if kind == "geography":
        return "geography"
    if kind == "geometry":
        if srid == 3857 or srid == 900913:
            return "merc"
        if is_geodetic_srid(srid):
            return "lonlat"
        return "plane"
    # unknown: geodetic SRID is overwhelmingly geography
    if srid == 3857:
        return "merc"
    return "geography" if is_geodetic_srid(srid) else "plane"


def inspect(buf: bytes, kind: str = "unknown"):
    s = parse(buf)
    geo = choose_mode(kind, s.srid) == "geography"
    rows = []
    for off, size, group, label, value in s.fields:
        if geo and label.startswith("Point[") and label.endswith(" x"):
            label = label[:-2] + " latitude"
        elif geo and label.startswith("Point[") and label.endswith(" y"):
            label = label[:-2] + " longitude"
        rows.append({"offset": off, "length": size, "group": group, "field": label,
                     "value": value if not isinstance(value, float) else repr(value),
                     "hex": bytes(buf[off:off + size]).hex(" ").upper()})
    return {
        "srid": s.srid, "version": s.version, "properties": describe_props(s.props),
        "type": s.root_type, "points": len(s.xs), "figures": len(s.figures), "shapes": len(s.shapes),
        "segments": len(s.segments), "bytes": len(buf), "wkt": to_wkt(s, geo, 20000),
        "interpretedAs": "geography" if geo else "geometry", "fields": rows,
    }
