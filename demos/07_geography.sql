/* Spatial Studio demo pack 07 - The round earth: geography's special behaviour */

--#demo Ring orientation: the inside-out polygon
--#desc On a sphere a ring splits the world in two, so direction matters: the inside is on your LEFT as you walk the ring.
--#desc Draw a square clockwise and you get the whole world minus a square. EnvelopeAngle() gives it away; ReorientObject() fixes it.
--#view map
--#tags ring orientation, EnvelopeAngle, ReorientObject, STArea
DECLARE @ccw geography = geography::STGeomFromText('POLYGON ((-5 50, 5 50, 5 56, -5 56, -5 50))', 4326);
DECLARE @cw  geography = geography::STGeomFromText('POLYGON ((-5 50, -5 56, 5 56, 5 50, -5 50))', 4326);
SELECT ring = 'anticlockwise', [area km2] = @ccw.STArea() / 1e6, [EnvelopeAngle] = @ccw.EnvelopeAngle()
UNION ALL
SELECT 'clockwise', @cw.STArea() / 1e6, @cw.EnvelopeAngle()
UNION ALL
SELECT 'clockwise.ReorientObject()', @cw.ReorientObject().STArea() / 1e6, @cw.ReorientObject().EnvelopeAngle();
SELECT shape = @ccw, label = 'anticlockwise square', color = '#59a14f';

--#demo FULLGLOBE and everything-except
--#desc FULLGLOBE is the whole Earth. Subtract a country and you get the rest of the world as one polygon.
--#view map
--#tags FULLGLOBE, STDifference, STArea
DECLARE @globe geography = geography::STGeomFromText('FULLGLOBE', 4326);
DECLARE @br geography = (SELECT Geog FROM world.Country WHERE Name = 'Brazil');
SELECT [Earth surface km2] = @globe.STArea() / 1e6, [Brazil km2] = @br.STArea() / 1e6,
       [rest of the world km2] = @globe.STDifference(@br).STArea() / 1e6,
       [rest EnvelopeAngle] = @globe.STDifference(@br).EnvelopeAngle();
SELECT shape = @br, label = 'Brazil', color = '#59a14f';

--#demo Great circles, bearings and destinations
--#desc The geodesic from London to Los Angeles passes over Greenland. The initial bearing is north-west, the final one south-west.
--#view map
--#tags geography, STLength, sx.Bearing, sx.Destination, sx.GreatCircle
DECLARE @lon geography = geography::Point(51.4700, -0.4543, 4326);   -- Heathrow
DECLARE @lax geography = geography::Point(33.9416, -118.4085, 4326); -- LAX
DECLARE @path geography = sx.GreatCircle(@lon, @lax, 64);
SELECT shape = @path, label = CONCAT(ROUND(@lon.STDistance(@lax) / 1000, 0), ' km'), color = '#e15759';
SELECT shape = @lon, label = CONCAT('LHR, initial bearing ', ROUND(sx.Bearing(@lon, @lax), 1), N'°'), color = '#222'
UNION ALL SELECT @lax, CONCAT('LAX, arriving on bearing ', ROUND(sx.Bearing(@path.STPointN(64), @lax), 1), N'°'), '#222';
SELECT shape = sx.Destination(@lon, sx.Bearing(@lon, @lax), d.value * 1000000.0), label = CONCAT(d.value * 1000, ' km'), color = '#f28e2b'
FROM GENERATE_SERIES(1, 8) AS d;

--#demo Crossing the antimeridian
--#desc Tokyo to San Francisco crosses longitude 180. geography doesn't care; the viewer unwraps longitudes so the line doesn't streak across the map.
--#view map
--#tags geography, antimeridian
SELECT shape = geography::STLineFromText('LINESTRING (139.6917 35.6895, -122.4194 37.7749)', 4326), label = 'Tokyo to San Francisco', color = '#4e79a7';
SELECT [km] = geography::STLineFromText('LINESTRING (139.6917 35.6895, -122.4194 37.7749)', 4326).STLength() / 1000;

--#demo Big triangles have curved edges
--#desc A geography polygon's edges are geodesics, so a London - New York - Cairo triangle bulges on a flat map.
--#desc The same coordinates as flat geometry give straight edges and a different area.
--#view map
--#tags geography, geometry, STArea, geodesic edges
DECLARE @wkt varchar(200) = 'POLYGON ((-0.1278 51.5074, 31.2357 30.0444, -74.0060 40.7128, -0.1278 51.5074))';
DECLARE @tri geography = geography::STGeomFromText(@wkt, 4326);
IF @tri.EnvelopeAngle() > 90 SET @tri = @tri.ReorientObject();
SELECT shape = @tri, label = 'geography', color = '#4e79a7';
SELECT geom = geometry::STGeomFromText(@wkt, 4326), label = 'geometry', color = '#e15759';
SELECT [geography area km2] = @tri.STArea() / 1e6;

--#demo The Greenland problem
--#desc On a Web Mercator map Greenland looks like Africa. geography.STArea knows Africa's countries are ~14x bigger.
--#desc sx.ToWebMercator projects to EPSG:3857 metres so you can see how badly the flat area lies.
--#view map
--#tags STArea, sx.ToWebMercator, projection
SELECT Name, [true area km2] = ROUND(Geog.STArea() / 1e6, 0),
       [Web Mercator 'area' km2] = ROUND(sx.ToWebMercator(Geog).STArea() / 1e6, 0),
       [inflation x] = ROUND(sx.ToWebMercator(Geog).STArea() / Geog.STArea(), 1)
FROM world.Country WHERE Name IN ('Greenland', 'Dem. Rep. Congo', 'Algeria', 'Sudan', 'Libya', 'Brazil', 'United Kingdom', 'Indonesia')
ORDER BY [true area km2] DESC;
SELECT Geog, label = Name, color = CASE WHEN Name = 'Greenland' THEN '#e15759' ELSE '#4e79a7' END
FROM world.Country WHERE Name IN ('Greenland', 'Dem. Rep. Congo', 'Algeria');

--#demo Spatial reference systems
--#desc geography needs a geodetic SRID from sys.spatial_reference_systems. 104001 is the unit sphere; 4326 is WGS84.
--#tags sys.spatial_reference_systems, STSrid, 104001
SELECT spatial_reference_id, authority_name, unit_of_measure, unit_conversion_factor, LEFT(well_known_text, 120) AS wkt_start
FROM sys.spatial_reference_systems
WHERE spatial_reference_id IN (4326, 4258, 4269, 4277, 104001)
ORDER BY spatial_reference_id;
SELECT [SRIDs available] = COUNT(*) FROM sys.spatial_reference_systems;

--#demo Mixing SRIDs returns NULL
--#desc Operations between instances with different SRIDs don't error, they quietly return NULL. A classic bug.
--#tags STSrid, STDistance, NULL
DECLARE @a geography = geography::Point(51.5, -0.1, 4326);
DECLARE @b geography = geography::Point(48.9, 2.35, 4258);   -- ETRS89: practically identical in Europe
SELECT [4326 to 4258 STDistance] = @a.STDistance(@b),
       [same SRID STDistance m] = @a.STDistance(geography::Point(48.9, 2.35, 4326));

--#demo Ellipsoid versus sphere
--#desc geography uses the WGS84 ellipsoid. Compare with the haversine formula on a sphere and with SRID 104001 (unit sphere).
--#tags STDistance, 104001, haversine
WITH pairs AS (
    SELECT a = 'London', alat = 51.5074, alon = -0.1278, b = 'Sydney', blat = -33.8688, blon = 151.2093
    UNION ALL SELECT 'Quito', -0.1807, -78.4678, 'Singapore', 1.3521, 103.8198
    UNION ALL SELECT 'Reykjavik', 64.1466, -21.9426, 'Anchorage', 61.2181, -149.9003)
SELECT a, b,
       [WGS84 ellipsoid km] = geography::Point(alat, alon, 4326).STDistance(geography::Point(blat, blon, 4326)) / 1000,
       [unit sphere x 6371 km] = geography::Point(alat, alon, 104001).STDistance(geography::Point(blat, blon, 104001)) * 6371.0088,
       [haversine km] = 2 * 6371.0088 * ASIN(SQRT(POWER(SIN(RADIANS(CAST(blat - alat AS float)) / 2), 2)
                         + COS(RADIANS(CAST(alat AS float))) * COS(RADIANS(CAST(blat AS float))) * POWER(SIN(RADIANS(CAST(blon - alon AS float)) / 2), 2)))
FROM pairs;

--#demo A polygon around the North Pole
--#desc Easy in geography: a ring of points at 75 degrees north contains the pole. Impossible to say in flat lon/lat.
--#view map
--#tags geography, polar, STIntersects
DECLARE @wkt nvarchar(max) = (SELECT 'POLYGON ((' + STRING_AGG(CAST(CONCAT((g.value % 12) * 30 - 180, ' 75') AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY g.value) + '))'
                              FROM GENERATE_SERIES(0, 12) AS g);
DECLARE @arctic geography = geography::STGeomFromText(@wkt, 4326);
IF @arctic.EnvelopeAngle() > 90 SET @arctic = @arctic.ReorientObject();
SELECT shape = @arctic, label = 'north of ~75N (edges are geodesics!)', color = '#4e79a7',
       [contains North Pole] = @arctic.STIntersects(geography::Point(90, 0, 4326)),
       [area km2] = @arctic.STArea() / 1e6;
