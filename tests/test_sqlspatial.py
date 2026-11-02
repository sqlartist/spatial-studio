"""Unit tests for the MS-SSCLRT decoder. Run: python -m pytest tests -q"""
import struct, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "app"))
import sqlspatial as sp


def enc(srid, version, props, pts, figures, shapes, segments=None, z=None, m=None):
    b = struct.pack("<iBB", srid, version, props)
    if not (props & 0x08 or props & 0x10):
        b += struct.pack("<i", len(pts))
    for x, y in pts:
        b += struct.pack("<dd", x, y)
    if z:
        b += b"".join(struct.pack("<d", v) for v in z)
    if m:
        b += b"".join(struct.pack("<d", v) for v in m)
    if props & 0x08 or props & 0x10:
        return b
    b += struct.pack("<i", len(figures)) + b"".join(struct.pack("<Bi", a, o) for a, o in figures)
    b += struct.pack("<i", len(shapes)) + b"".join(struct.pack("<iiB", p, f, t) for p, f, t in shapes)
    if version == 2:
        segments = segments or []
        b += struct.pack("<i", len(segments)) + bytes(segments)
    return b


def test_known_point_hex():
    # geometry::Point(1, 2, 0) as SQL Server serialises it
    raw = bytes.fromhex("00000000010C000000000000F03F0000000000000040")
    s = sp.parse(raw)
    assert s.srid == 0 and s.version == 1 and sp.to_wkt(s, False) == "POINT (1 2)"


def test_geography_point_axis_order():
    raw = enc(4326, 1, 0x0C, [(51.5, -0.1)], [], [])
    s = sp.parse(raw)
    assert sp.to_wkt(s, True) == "POINT (-0.1 51.5)"
    assert sp.display_parts(s, "geography")["points"] == [[-0.1, 51.5]]
    assert sp.choose_mode("unknown", 4326) == "geography"


def test_polygon_with_hole():
    pts = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0), (2, 2), (2, 4), (4, 4), (2, 2)]
    raw = enc(0, 1, 0x04, pts, [(2, 0), (0, 5)], [(-1, 0, 3)])
    s = sp.parse(raw)
    assert sp.to_wkt(s, False) == "POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0), (2 2, 2 4, 4 4, 2 2))"
    assert len(sp.display_parts(s, "plane")["polys"][0]) == 2


def test_multipolygon_and_collection():
    pts = [(0, 0), (1, 0), (1, 1), (0, 0), (5, 5), (6, 5), (6, 6), (5, 5)]
    raw = enc(0, 1, 0x04, pts, [(2, 0), (2, 4)], [(-1, 0, 6), (0, 0, 3), (0, 1, 3)])
    s = sp.parse(raw)
    assert sp.to_wkt(s, False) == "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((5 5, 6 5, 6 6, 5 5)))"
    pts = [(0, 0), (1, 1), (2, 2)]
    raw = enc(0, 1, 0x04, pts, [(1, 0), (1, 1)], [(-1, 0, 7), (0, 0, 1), (0, 1, 2)])
    assert sp.to_wkt(sp.parse(raw), False) == "GEOMETRYCOLLECTION (POINT (0 0), LINESTRING (1 1, 2 2))"


def test_multipoint():
    raw = enc(0, 1, 0x04, [(0, 0), (1, 1)], [(1, 0), (1, 1)], [(-1, 0, 4), (0, 0, 1), (0, 1, 1)])
    assert sp.to_wkt(sp.parse(raw), False) == "MULTIPOINT ((0 0), (1 1))"


def test_empty_collection():
    raw = enc(0, 1, 0x04, [], [], [(-1, -1, 7)])
    assert sp.to_wkt(sp.parse(raw), False) == "GEOMETRYCOLLECTION EMPTY"


def test_circularstring_and_compound():
    raw = enc(0, 2, 0x04, [(0, 0), (1, 1), (2, 0)], [(2, 0)], [(-1, 0, 8)], [])
    s = sp.parse(raw)
    assert sp.to_wkt(s, False) == "CIRCULARSTRING (0 0, 1 1, 2 0)"
    line = sp.display_parts(s, "plane")["lines"][0]
    assert len(line) > 10 and abs(max(p[1] for p in line) - 1) < 1e-2
    # COMPOUNDCURVE ((0 0, 3 0), CIRCULARSTRING (3 0, 4 1, 5 0), (5 0, 6 0))
    raw = enc(0, 2, 0x04, [(0, 0), (3, 0), (4, 1), (5, 0), (6, 0)], [(3, 0)], [(-1, 0, 9)], [2, 1, 0])
    assert sp.to_wkt(sp.parse(raw), False) == "COMPOUNDCURVE ((0 0, 3 0), CIRCULARSTRING (3 0, 4 1, 5 0), (5 0, 6 0))"


def test_curvepolygon_full_circle():
    raw = enc(0, 2, 0x04, [(-1, 0), (0, 1), (1, 0), (0, -1), (-1, 0)], [(2, 0)], [(-1, 0, 10)], [])
    s = sp.parse(raw)
    assert sp.to_wkt(s, False) == "CURVEPOLYGON (CIRCULARSTRING (-1 0, 0 1, 1 0, 0 -1, -1 0))"
    ring = sp.display_parts(s, "plane")["polys"][0][0]
    assert all(abs((x * x + y * y) ** 0.5 - 1) < 1e-3 for x, y in ring)


def test_zm_and_inspect():
    raw = enc(0, 1, 0x07, [(0, 0), (1, 1)], [(1, 0)], [(-1, 0, 2)], z=[10, 20], m=[1, 2])
    s = sp.parse(raw)
    assert sp.to_wkt(s, False) == "LINESTRING (0 0 10 1, 1 1 20 2)"
    info = sp.inspect(raw, "geometry")
    assert info["type"] == "LineString" and info["fields"][0]["field"] == "SRID"


def test_fullglobe_and_geodesic_densify():
    raw = enc(4326, 2, 0x24, [], [], [(-1, -1, 11)], [])
    s = sp.parse(raw)
    assert sp.to_wkt(s, True) == "FULLGLOBE"
    assert sp.display_parts(s, "geography")["polys"]
    raw = enc(4326, 1, 0x14, [(51.5, -0.13), (35.7, 139.7)], [], [])
    line = sp.display_parts(sp.parse(raw), "geography")["lines"][0]
    assert len(line) > 20 and max(p[1] for p in line) > 60   # the geodesic swings far north over Siberia


def test_antimeridian_unwrap():
    raw = enc(4326, 1, 0x14, [(35.7, 139.7), (37.8, -122.4)], [], [])
    line = sp.display_parts(sp.parse(raw), "geography")["lines"][0]
    assert all(abs(b[0] - a[0]) < 180 for a, b in zip(line, line[1:]))
