/* Spatial Studio demo pack 01 - Getting started
   Format: each demo starts with "--#demo <title>". Optional header lines:
     --#desc  <text>        description (repeatable)
     --#view  map|plane     preferred viewer
     --#tags  a, b, c       the SQL Server features it shows
   Result-set conventions the viewer understands:
     label  -> text drawn on the shape        color -> CSS colour for that row
     frame  -> animation frame number          Every result set becomes a layer.  */

--#demo Hello, geometry
--#desc geometry is the flat, Cartesian type: X and Y in whatever units you like, straight lines, planar maths.
--#desc Three shapes from Well-Known Text (WKT). Each result set becomes a layer; the label and color columns style it.
--#view plane
--#tags geometry, STGeomFromText, WKT
SELECT shape = geometry::STGeomFromText('POLYGON ((0 0, 100 0, 100 60, 0 60, 0 0))', 0), label = 'POLYGON', color = '#4e79a7'
UNION ALL
SELECT geometry::STGeomFromText('LINESTRING (-20 -20, 40 90, 130 30)', 0), 'LINESTRING', '#e15759'
UNION ALL
SELECT geometry::STGeomFromText('POINT (50 30)', 0), 'POINT', '#f28e2b';

--#demo Hello, geography
--#desc geography is the round-earth type: latitude/longitude on the WGS84 ellipsoid, distances in metres, edges are geodesics.
--#desc Note geography::Point takes LATITUDE first. The line from London to New York bows north because it is the shortest path on the globe.
--#view map
--#tags geography, Point, STDistance, STLength
DECLARE @london  geography = geography::Point(51.5074, -0.1278, 4326);
DECLARE @watford geography = geography::Point(51.6565, -0.3903, 4326);
DECLARE @newyork geography = geography::Point(40.7128, -74.0060, 4326);
SELECT place = @london, label = 'London', color = '#e15759'
UNION ALL SELECT @watford, 'Watford', '#f28e2b'
UNION ALL SELECT @newyork, 'New York', '#4e79a7';
SELECT route = geography::STLineFromText('LINESTRING (-0.1278 51.5074, -74.0060 40.7128)', 4326),
       label = CONCAT(FORMAT(@london.STDistance(@newyork) / 1000, 'N0'), ' km'),
       color = '#59a14f';
SELECT [London to Watford (km)] = @london.STDistance(@watford) / 1000,
       [London to New York (km)] = @london.STDistance(@newyork) / 1000;

--#demo What's in the database
--#desc Row counts for the sample data: real countries and cities, plus the procedurally generated town of Sqlford.
--#tags metadata
SELECT [table] = CONCAT(s.name, '.', t.name), [rows] = SUM(p.rows),
       [spatial columns] = (SELECT STRING_AGG(c.name, ', ') FROM sys.columns c
                            WHERE c.object_id = t.object_id AND TYPE_NAME(c.user_type_id) IN ('geometry', 'geography')),
       [vector columns] = (SELECT STRING_AGG(c.name, ', ') FROM sys.columns c
                           WHERE c.object_id = t.object_id AND TYPE_NAME(c.user_type_id) = 'vector')
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name IN ('world', 'town')
GROUP BY s.name, t.name, t.object_id
ORDER BY 1;

--#demo The town of Sqlford
--#desc A 1.2 km square town generated entirely in T-SQL: zoned blocks, roads, a river built from circular arcs,
--#desc parks with curved ponds and ~800 buildings in ten footprint types at random rotations. Units are metres, SRID 0.
--#view plane
--#tags geometry, COMPOUNDCURVE, CURVEPOLYGON, layers
SELECT Geom, label = ZoneKind,
       color = CASE ZoneKind WHEN 'Park' THEN '#8cc084' WHEN 'Commercial' THEN '#f1ce63' WHEN 'Industrial' THEN '#bab0ac' ELSE '#e8e4dc' END
FROM town.Block;
SELECT Geom, color = '#9a9a9a' FROM town.Road;
SELECT Pond, color = '#79b8e8' FROM town.Park;
SELECT Geom, label = Name, color = '#2f7fd0' FROM town.River;
SELECT Geom, color = '#7a5c4f' FROM town.Building;

--#demo The world
--#desc 177 countries from Natural Earth (1:110m) and the 60 largest cities from GeoNames.
--#desc Try the globe toggle on the map toolbar.
--#view map
--#tags geography, world data
SELECT Geog, label = Name, color = CONCAT('hsl(', (CountryId * 47) % 360, ',45%,60%)') FROM world.Country;
SELECT TOP (60) Geog, label = Name, color = '#222' FROM world.City ORDER BY Population DESC;

--#demo Flat versus round in one picture
--#desc The same two coordinates as geometry (flat lon/lat, straight in degree space) and geography (ellipsoid, geodesic).
--#desc Compare the lengths: geometry measures in degrees, geography in metres.
--#view map
--#tags geometry, geography, STLength
DECLARE @wkt varchar(100) = 'LINESTRING (-0.1278 51.5074, 139.6917 35.6895)';
SELECT geom = geometry::STGeomFromText(@wkt, 4326), label = 'geometry: straight in lon/lat', color = '#e15759';
SELECT geog = geography::STGeomFromText(@wkt, 4326), label = 'geography: geodesic over Siberia', color = '#4e79a7';
SELECT [geometry STLength (degrees)] = geometry::STGeomFromText(@wkt, 4326).STLength(),
       [geography STLength (km)] = geography::STGeomFromText(@wkt, 4326).STLength() / 1000;
