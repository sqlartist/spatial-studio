# Spatial Studio for SQL Server 2025

A local workbench for SQL Server's `geometry` and `geography` types and the new `VECTOR` type. It comes with 112 runnable demos and a sample database.

You get a browser UI with:

- a T-SQL editor
- a map (MapLibre, with a globe view)
- a flat "plane" canvas
- results grids
- a byte-level inspector for spatial values
- a query-plan viewer
- a self-test that runs every demo against your server

## Quick start (Windows)

1. Install **Python 3.10+** and **ODBC Driver 18 for SQL Server**.
2. Double-click `run.bat`. It installs `fastapi`, `uvicorn` and `pyodbc`, starts the server and opens http://localhost:8765. On Linux or macOS, use `./run.sh`.
3. Click the connection pill (top left) and point it at your instance, for example `localhost` or `.\SQL2025`. Windows authentication is the default. The connection is saved to `config.json`, but never the password.
4. Click **Install sample DB**. This creates the `SpatialStudio` database and takes a few minutes. You need CREATE DATABASE rights. The scripts are also in `sql/install/` (00 to 06) if you'd rather run them in SSMS.
5. Click **Self-test**. It runs every demo and marks each one in the sidebar ✓, ✗ or !.

You can also set the connection through environment variables: `SPATIAL_STUDIO_SERVER`, `SPATIAL_STUDIO_DATABASE`, `SPATIAL_STUDIO_AUTH` (`windows` or `sql`), `SPATIAL_STUDIO_USER`, `SPATIAL_STUDIO_PASSWORD` and `SPATIAL_STUDIO_DRIVER`.

## Using it

- **Run** with `Ctrl+Enter` or `F5`. If text is selected, only the selection runs. `GO` separates batches, as in SSMS.
- **Every spatial column in every result set becomes a layer.** Three column names are styling conventions:
  - `color` takes any CSS colour.
  - `label` is the text drawn on the shape.
  - `frame` turns the result into an animation with a play bar.
- Shapes go to one of two views:
  - **Map**: geography, plus geometry with a geodetic SRID (treated as lon/lat) or SRID 3857 (reprojected for you). Geography edges are drawn as true geodesics, and lines that cross the antimeridian are unwrapped.
  - **Plane**: every other geometry, in its own units. Circular arcs are drawn as arcs.
- **Explain** (`Ctrl+L`) shows the estimated plan as a tree, with spatial-index and vector-index operators highlighted.
- **Inspector**: click any shape cell, or any shape on the map. The tool decodes SQL Server's native serialisation (MS-SSCLRT v1 and v2) field by field: header, points, figures, shapes and segments, with a colour-coded hex dump.
- **Draw**: draw a point, line or polygon on either view. You get `geometry::` or `geography::STGeomFromText(...)` to insert into the editor. In the "Query by sketch" demo, inserting replaces the sketch.
- **Import GeoJSON**: loads a file into a new `lab.*` table. The parsing happens inside SQL Server, through `sx.GeoJsonFeatures`.
- **Export**: download the visible layers as GeoJSON, or the current grid as CSV.

## The demo packs

| Pack | What it covers |
|---|---|
| 01 Getting started | geometry vs geography, the sample data, flat vs round |
| 02 Constructing | every `ST*FromText`/`FromWKB` constructor, `Parse`, `Point()` lat/long trap, WKB, GML, Z/M, EMPTY, the native binary, type conversion |
| 03 Properties | types and dimensions, points, rings, collections, boundary, envelope, centroid vs point-on-surface, area/length, simple/closed/ring, `IsValidDetailed`/`MakeValid`, `MinDbCompatibilityLevel` |
| 04 Relationships | the eight OGC predicates, `STRelate` with DE-9IM patterns, `Filter()` vs `STIntersects`, point-in-polygon, neighbours, crossings, `STEquals` |
| 05 Operations | buffers (planar and geodesic), set operations, convex hull, `Reduce`, `ShortestLineTo`, clipping, dissolve |
| 06 Curves | `CIRCULARSTRING`, `COMPOUNDCURVE`, `CURVEPOLYGON`, `STNumCurves`/`STCurveN`, `STCurveToLine` vs `CurveToLineWithTolerance`, `BufferWithCurves` |
| 07 The round earth | ring orientation and `ReorientObject`, `FULLGLOBE`, great circles, the antimeridian, geodesic-edged polygons, the Greenland problem, SRIDs, ellipsoid vs sphere, polar polygons |
| 08 Aggregates | `UnionAggregate`, `CollectionAggregate`, `EnvelopeAggregate`, `ConvexHullAggregate` |
| 09 Indexing & performance | tessellation views, a grid visualiser, `sp_help_spatial_*_index`, index-friendly k-NN, an index-vs-scan benchmark, columnstore as a spatial pre-filter, custom grids, Hilbert ordering |
| 10 sx library | affine transforms, Web Mercator, GeoJSON out (`JSON_OBJECT`/`JSON_ARRAYAGG`) and in (recursive `OPENJSON`), the native `json` type, geohash, Hilbert curves, square/hex grids, hexbin choropleth, Voronoi, bearings and destinations |
| 11 Analysis | choropleths, radius joins, nearest neighbour, distance matrix, corridor search, flood risk, coverage, **routing with SQL Graph `SHORTEST_PATH`**, reachability |
| 12 Vector search | `VECTOR` basics, the globe as a vector space, k-NN two ways, DiskANN `VECTOR_SEARCH`, **shape search with Fourier descriptors computed in T-SQL**, shape recognition accuracy, query by sketch, hybrid spatial + vector search, k-means in T-SQL, ANN recall |
| 13 Animation | growing buffers, rotation, a flight along a geodesic, progressive simplification, morphing through vector space |
| 14 Toon | **Brian in "The Ball"**: a 20-second cut-out cartoon rendered by SQL Server - puppet rig, keyframes, motion paths, felt-tip boil, and a scene of your own to direct |

## What makes it different

- **Shapes as vectors.** Every building footprint gets three descriptors, all computed in pure T-SQL:
  - a 32-ray radial signature;
  - a rotation-invariant Fourier descriptor (the |DFT| of that signature);
  - a size-aware morphology vector.

  They're stored as `VECTOR(32)`, `VECTOR(16)` and `VECTOR(6)`. That makes "find buildings shaped like this", "...within 300 m of here" and "draw a shape and search for it" plain SQL, using `VECTOR_DISTANCE`, a DiskANN index and the spatial index together.
- **The globe as a vector space.** Cities are also stored as unit vectors, where cosine distance is the great-circle angle. That lets the DiskANN index answer nearest-city queries, and the demos compare the result with the spatial index.
- **SQL Graph routing** over a geometry road network, where only some crossings have bridges.
- **The `sx` library**, written in T-SQL. It covers things SQL Server doesn't have built in:
  - affine transforms
  - Web Mercator conversion
  - geography to and from geometry
  - GeoJSON in and out
  - geohash
  - Hilbert keys
  - square and hex grids
  - Voronoi half-planes
  - bearing and destination
  - densified great circles
  - describe-everything functions
- **A binary inspector** that shows exactly how SQL Server stores a shape.

## Toon: cut-out animation in SQL Server

`sql/install/07_cartoon.sql` adds a small animation system in the `toon` schema, in the spirit of the card cut-outs of 1970s children's TV:

- `toon.Part`: each character is a set of geometry parts (arcs welcome), each pinned to a parent part at a pivot.
- `toon.Key`: the performance, one row per keyframe. Channels are `angle`, `dx`, `dy`, `sx` (flip), `osc` (swing, cycling with the part's period), `bob` (hop) and `vis`. Each key eases in `smooth`, `linear` or `step`.
- `toon.Render`: interpolates the keys for every frame, composes the affine matrices down each puppet with a recursive CTE, moves the shapes with `sx.Affine` and adds a felt-tip "boil" with `sx.Jitter`. It either stores frames in `toon.Frame` or returns them straight to the viewer.

The viewer understands three extra columns for cartoons: `opacity` (0-1), `linewidth` (pixels, 0 for none) and `fontsize`. The animation bar has 12 and 24 fps settings.

## The sample data

- `world.Country`: 177 countries from Natural Earth 1:110m (public domain), stored as `geography` with a flat lon/lat `geometry` copy.
- `world.City`: 24,323 GeoNames cities with population of 15,000 or more ([CC BY 4.0](https://www.geonames.org/)). Each row has `geography` and a `VECTOR(3)` unit vector, and is assigned a country by a spatial join.
- `town.*`: *Sqlford*, a 1.2 km town generated deterministically in T-SQL (`05_town.sql`). It has:
  - blocks and zoning
  - about 800 buildings in ten footprint types
  - a river made of circular arcs
  - parks with curve-polygon ponds
  - points of interest
  - a SQL Graph road network
- The map basemap is © OpenStreetMap contributors. The "Offline outlines" basemap needs no internet.

## Layout

```
app/server.py          FastAPI + pyodbc: runs batches, decodes spatial columns, explain, install, self-test, import
app/sqlspatial.py      MS-SSCLRT decoder -> WKT, display geometry (arcs + geodesics densified), inspector fields
app/static/            the UI (plain JS, vendored MapLibre GL 5 and CodeMirror 5, no build step)
sql/install/00..06     database, schema, sx library, world data, town, vectors and indexes
demos/*.sql            demo packs; each demo starts with "--#demo", plus optional --#desc / --#view / --#tags
tools/build_world_data.py   regenerates 03_world_data.sql from the npm open-data packages
tests/                 decoder unit tests (pytest) and a mock server for UI testing without SQL Server
```

To add your own demos, drop a `.sql` file into `demos/` in the same `--#demo` format. It appears in the sidebar on reload.

## Notes and limits

- This was built without access to a SQL Server 2025 instance, so none of the T-SQL has actually been run. The decoder and UI are tested against a mock server, and the T-SQL has been reviewed by hand. **Run Self-test first.** If a demo fails, the error is in the notes column.
- `VECTOR INDEX` and `VECTOR_SEARCH` are preview features in SQL Server 2025. The installer turns on `PREVIEW_FEATURES`. In the preview, a table with a vector index is read-only, which is why the indexed vectors live in copy tables (`world.CityVec`, `town.BuildingShapeAnn`). The `VECTOR_SEARCH` demos catch their own errors and fall back to an explanation if your build doesn't support them.
- Geometry vs geography detection:
  - The first result set of each batch is described with `sp_describe_first_result_set`.
  - For later result sets, the tool uses the column name (`geom…`/`geog…`) and the SRID. If one is misplaced, rename the column.
- Result sets are capped at 5,000 rows by default (the *Max rows* box).
