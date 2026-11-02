/* Spatial Studio demo pack 10 - The sx extension library (pure T-SQL) */

--#demo Affine transforms: rotate, scale, translate
--#desc SQL Server has no transform methods, so sx rewrites the coordinates inside the WKT set-based (STRING_SPLIT with ordinals + STRING_AGG).
--#view plane
--#tags sx.Rotate, sx.Spin, sx.Scale, sx.Translate, sx.Affine
DECLARE @t geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'TShape' ORDER BY BuildingId);
SET @t = sx.Translate(@t, -sx.EnvelopeCentre(@t).STX, -sx.EnvelopeCentre(@t).STY);    -- move to the origin
SELECT shape = @t, label = 'original', color = '#bab0ac'
UNION ALL SELECT sx.Translate(@t, 40, 0),                 'Translate(40, 0)', '#4e79a7'
UNION ALL SELECT sx.Translate(sx.Spin(@t, 45), 80, 0),    'Spin 45', '#f28e2b'
UNION ALL SELECT sx.Translate(sx.Scale(@t, 1.6, 0.6), 130, 0), 'Scale(1.6, 0.6)', '#59a14f'
UNION ALL SELECT sx.Translate(sx.Affine(@t, 1, 0.6, 0, 0, 1, 0), 180, 0), 'shear', '#e15759';

--#demo Projecting to Web Mercator
--#desc sx.ToWebMercator turns geography into EPSG:3857 geometry (metres) - what slippy maps use. The viewer reprojects SRID 3857 back for display.
--#view map
--#tags sx.ToWebMercator, sx.FromWebMercator, EPSG:3857
DECLARE @gb geography = (SELECT Geog FROM world.Country WHERE Name = 'United Kingdom');
DECLARE @m geometry = sx.ToWebMercator(@gb);
SELECT shape = @m, label = 'as EPSG:3857 geometry', color = '#4e79a7';
SELECT [SRID] = @m.STSrid, [first vertex (m)] = @m.STPointN(1).ToString(),
       [round trip first vertex] = sx.FromWebMercator(@m).STPointN(1).ToString(),
       [original first vertex] = @gb.STPointN(1).ToString();

--#demo GeoJSON out
--#desc sx.ToGeoJSON / sx.GeogToGeoJSON turn shapes into GeoJSON geometries. JSON_OBJECT and JSON_ARRAYAGG (SQL Server 2025) build a FeatureCollection.
--#tags sx.GeogToGeoJSON, JSON_OBJECT, JSON_ARRAYAGG, GeoJSON
SELECT TOP (3) Name, geojson = sx.GeogToGeoJSON(Geog) FROM world.City ORDER BY Population DESC;
SELECT FeatureCollection = JSON_OBJECT(
          'type': 'FeatureCollection',
          'features': JSON_ARRAYAGG(JSON_OBJECT(
              'type': 'Feature',
              'properties': JSON_OBJECT('name': Name, 'population': Population),
              'geometry': JSON_QUERY(sx.GeogToGeoJSON(Geog)))))
FROM (SELECT TOP (10) Name, Population, Geog FROM world.City ORDER BY Population DESC) AS t;

--#demo GeoJSON in
--#desc sx.FromGeoJSON walks the coordinate arrays recursively with OPENJSON; sx.GeoJsonFeatures shreds a FeatureCollection into rows.
--#desc Or use the Import GeoJSON button in the toolbar to load a file into a table.
--#view plane
--#tags sx.FromGeoJSON, sx.GeoJsonFeatures, sx.CoordsToWkt, OPENJSON
DECLARE @fc nvarchar(max) = N'{
  "type": "FeatureCollection",
  "features": [
    {"type": "Feature", "properties": {"name": "plot A"}, "geometry": {"type": "Polygon", "coordinates": [[[0,0],[40,0],[40,25],[0,25],[0,0]]]}},
    {"type": "Feature", "properties": {"name": "path"},   "geometry": {"type": "LineString", "coordinates": [[-10,-10],[20,12.5],[60,40]]}},
    {"type": "Feature", "properties": {"name": "wells"},  "geometry": {"type": "MultiPoint", "coordinates": [[10,10],[30,15],[50,30]]}},
    {"type": "Feature", "properties": {"name": "donut"},  "geometry": {"type": "Polygon", "coordinates": [[[60,0],[90,0],[90,25],[60,25],[60,0]],[[70,8],[80,8],[80,17],[70,17],[70,8]]]}}
  ]}';
SELECT FeatureIndex, name = JSON_VALUE(Properties, '$.name'), Geom, label = JSON_VALUE(Properties, '$.name'), wkt = Geom.ToString()
FROM sx.GeoJsonFeatures(@fc, 0);

--#demo Storing GeoJSON in the native json type
--#desc SQL Server 2025 has a real json data type. Keep the GeoJSON document and the indexed geography side by side.
--#tags json data type, sx.GeogToGeoJSON, JSON_VALUE
DROP TABLE IF EXISTS lab.CountryDoc;
CREATE TABLE lab.CountryDoc (CountryId int PRIMARY KEY, Doc json NOT NULL);
INSERT lab.CountryDoc (CountryId, Doc)
SELECT CountryId, JSON_OBJECT('type': 'Feature', 'properties': JSON_OBJECT('name': Name, 'areaKm2': ROUND(AreaKm2, 0)),
                              'geometry': JSON_QUERY(sx.GeogToGeoJSON(Geog)))
FROM world.Country WHERE Name IN ('Iceland', 'Ireland', 'Portugal', 'New Zealand');
SELECT CountryId, name = JSON_VALUE(Doc, '$.properties.name'), areaKm2 = JSON_VALUE(Doc, '$.properties.areaKm2'),
       [geometry type] = JSON_VALUE(Doc, '$.geometry.type'), [bytes] = DATALENGTH(Doc)
FROM lab.CountryDoc;

--#demo Geohash cells
--#desc sx.Geohash encodes lat/long as a base-32 string; nearby places share prefixes, so LIKE 'gcpsv%' is a crude proximity search.
--#desc sx.GeohashCell draws the cell. (Its edges are geodesics, so wide cells bulge slightly from true parallels.)
--#view map
--#tags sx.Geohash, sx.GeohashCell, LIKE
DECLARE @h varchar(12) = sx.Geohash(51.6565, -0.3903, 4);
SELECT [Watford geohash (9)] = sx.Geohash(51.6565, -0.3903, 9), [prefix used] = @h;
SELECT shape = sx.GeohashCell(@h), label = @h, color = '#f1ce63';
SELECT shape = sx.GeohashCell(LEFT(@h, 3)), label = LEFT(@h, 3), color = '#a0cbe8';
SELECT c.Geog, label = CASE WHEN c.Population > 100000 THEN c.Name END, c.Name, gh = sx.Geohash(c.Lat, c.Lon, 6), color = '#e15759'
FROM world.City AS c
WHERE c.Lat BETWEEN 50 AND 53 AND c.Lon BETWEEN -2 AND 1 AND sx.Geohash(c.Lat, c.Lon, 4) = @h;

--#demo Draw a Hilbert curve
--#desc sx.HilbertKey maps a cell to its position on the curve; joining cell centres in key order draws the curve itself.
--#view plane
--#tags sx.HilbertKey, STRING_AGG
DECLARE @order int = 5, @n int = 32;
WITH cells AS (
    SELECT x = a.value, y = b.value, h = sx.HilbertKey(a.value, b.value, @order)
    FROM GENERATE_SERIES(0, @n - 1) AS a CROSS JOIN GENERATE_SERIES(0, @n - 1) AS b)
SELECT shape = geometry::STGeomFromText('LINESTRING (' + STRING_AGG(CAST(CONCAT(x * 10 + 5, ' ', y * 10 + 5) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY h) + ')', 0),
       label = CONCAT('Hilbert order ', @order), color = '#4e79a7'
FROM cells;

--#demo Square and hex grids
--#desc sx.SquareGrid and sx.HexGrid generate tessellations as table-valued functions - the starting point for binning.
--#view plane
--#tags sx.SquareGrid, sx.HexGrid
SELECT Geom, color = '#a0cbe8' FROM sx.SquareGrid(0, 0, 300, 300, 50, 0);
SELECT Geom = sx.Translate(Geom, 350, 0), color = '#f1ce63' FROM sx.HexGrid(0, 0, 300, 300, 30, 0);

--#demo Hexbin: city density across Europe
--#desc Hexagons built in Web Mercator metres (so they look regular on the map), converted to geography, then joined to cities.
--#view map
--#tags sx.HexGrid, sx.FromWebMercator, sx.ToWebMercator, spatial join, choropleth
DECLARE @sw geometry = sx.ToWebMercator(geography::Point(35, -11, 4326)), @ne geometry = sx.ToWebMercator(geography::Point(62, 32, 4326));
DROP TABLE IF EXISTS #hex;
CREATE TABLE #hex (HexId int PRIMARY KEY, Geog geography NOT NULL);
INSERT #hex SELECT h.HexId, sx.FromWebMercator(h.Geom) FROM sx.HexGrid(@sw.STX, @sw.STY, @ne.STX, @ne.STY, 90000, 3857) AS h;
-- one spatial-index seek on world.City per hexagon
SELECT h.Geog, n.cities, n.people, label = CASE WHEN n.cities >= 40 THEN CAST(n.cities AS varchar(10)) END,
       color = CONCAT('hsl(', 220 - LEAST(n.cities, 80) * 2.7, ',75%,55%)')
FROM #hex AS h
CROSS APPLY (SELECT cities = COUNT(*), people = SUM(CAST(c.Population AS bigint))
             FROM world.City AS c WHERE c.Geog.STIntersects(h.Geog) = 1) AS n
WHERE n.cities > 0;

--#demo Voronoi catchments for schools
--#desc Each school's catchment is the town minus the union of the half-planes closer to every other school. Set-based Voronoi in T-SQL.
--#view plane
--#tags sx.HalfPlane, UnionAggregate, STDifference, Voronoi
DECLARE @town geometry = 'POLYGON ((0 0, 1200 0, 1200 1200, 0 1200, 0 0))';
WITH s AS (SELECT PoiId, Name, Geom FROM town.POI WHERE Kind = 'School')
SELECT a.PoiId, shape = @town.STDifference(geometry::UnionAggregate(sx.HalfPlane(a.Geom.STX, a.Geom.STY, b.Geom.STX, b.Geom.STY, 5000, 0))),
       label = a.Name, color = CONCAT('hsl(', a.PoiId * 47 % 360, ',55%,72%)')
FROM s AS a JOIN s AS b ON b.PoiId <> a.PoiId
GROUP BY a.PoiId, a.Name;
SELECT Geom, color = '#222' FROM town.POI WHERE Kind = 'School';

--#demo Compass rose: destinations and bearings
--#desc sx.Destination walks a distance on a bearing over the sphere; 1,500 km every 30 degrees from Watford.
--#view map
--#tags sx.Destination, sx.Bearing, sx.GreatCircle
DECLARE @o geography = geography::Point(51.6565, -0.3903, 4326);
SELECT shape = sx.GreatCircle(@o, sx.Destination(@o, b.value, 1500000), 16), label = CONCAT(b.value, N'°'), color = '#4e79a7',
       [check: sx.Bearing to it] = ROUND(sx.Bearing(@o, sx.Destination(@o, b.value, 1500000)), 3),
       [check: km] = ROUND(@o.STDistance(sx.Destination(@o, b.value, 1500000)) / 1000, 1)
FROM GENERATE_SERIES(0, 330, 30) AS b;
