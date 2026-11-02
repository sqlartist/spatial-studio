/* Spatial Studio demo pack 11 - Spatial analysis recipes */

--#demo Choropleth: cities per country
--#desc A spatial join (done at install) aggregated per country and coloured by count. The colour is computed in SQL.
--#view map
--#tags spatial join, GROUP BY, choropleth
WITH n AS (SELECT CountryId, cities = COUNT(*), people = SUM(CAST(Population AS bigint)) FROM world.City GROUP BY CountryId)
SELECT k.Name, k.Geog, n.cities, n.people, label = CASE WHEN n.cities > 400 THEN k.Name END,
       color = CONCAT('hsl(', 210 - LEAST(LOG10(ISNULL(n.cities, 1)) * 60, 210), ',70%,55%)')
FROM world.Country AS k LEFT JOIN n ON n.CountryId = k.CountryId
ORDER BY n.cities DESC;

--#demo The most crowded 100 km circles
--#desc For each of the 150 biggest cities, total the population of every city within 100 km - a radius join served by the spatial index.
--#view map
--#tags STDistance, CROSS APPLY, spatial index
SELECT TOP (25) c.Name, c.CountryCode, [people within 100 km] = s.people, [cities within 100 km] = s.n,
       shape = c.Geog.STBuffer(100000), label = c.Name, color = '#e15759'
FROM (SELECT TOP (150) * FROM world.City ORDER BY Population DESC) AS c
CROSS APPLY (SELECT people = SUM(CAST(o.Population AS bigint)), n = COUNT(*)
             FROM world.City AS o WHERE o.Geog.STDistance(c.Geog) <= 100000) AS s
ORDER BY s.people DESC;

--#demo Nearest big city to each country's centre
--#desc EnvelopeCenter of every country, then CROSS APPLY TOP (1) ... ORDER BY STDistance for the closest city of a million or more.
--#view map
--#tags EnvelopeCenter, nearest neighbour, CROSS APPLY, ShortestLineTo
SELECT k.Name, [nearest million city] = n.Name, [km] = ROUND(n.d / 1000, 0),
       shape = geography::STLineFromText(CONCAT('LINESTRING (', k.Geog.EnvelopeCenter().Long, ' ', k.Geog.EnvelopeCenter().Lat, ', ', n.Lon, ' ', n.Lat, ')'), 4326),
       color = '#4e79a7'
FROM world.Country AS k
CROSS APPLY (SELECT TOP (1) c.Name, c.Lat, c.Lon, d = c.Geog.STDistance(k.Geog.EnvelopeCenter())
             FROM world.City AS c WHERE c.Population >= 1000000 AND c.Geog.STDistance(k.Geog.EnvelopeCenter()) IS NOT NULL
             ORDER BY c.Geog.STDistance(k.Geog.EnvelopeCenter())) AS n
WHERE k.AreaKm2 > 300000;

--#demo Distance matrix
--#desc Every pair of eight capitals in kilometres, pivoted.
--#tags STDistance, PIVOT
WITH caps AS (
    SELECT * FROM (VALUES ('London', 51.5074, -0.1278), ('Paris', 48.8566, 2.3522), ('Berlin', 52.52, 13.405),
                          ('Madrid', 40.4168, -3.7038), ('Rome', 41.9028, 12.4964), ('Moscow', 55.7558, 37.6173),
                          ('Cairo', 30.0444, 31.2357), ('New York', 40.7128, -74.006)) AS v (name, lat, lon)),
d AS (
    SELECT [from] = a.name, [to] = b.name,
           km = CAST(ROUND(geography::Point(a.lat, a.lon, 4326).STDistance(geography::Point(b.lat, b.lon, 4326)) / 1000, 0) AS int)
    FROM caps a CROSS JOIN caps b)
SELECT * FROM d PIVOT (MAX(km) FOR [to] IN ([London], [Paris], [Berlin], [Madrid], [Rome], [Moscow], [Cairo], [New York])) AS p;

--#demo Corridor search
--#desc Cities within 25 km of a straight (geodesic) line from London to Glasgow: buffer the line, intersect with the index.
--#view map
--#tags STBuffer, STIntersects, corridor
DECLARE @line geography = geography::STLineFromText('LINESTRING (-0.1278 51.5074, -4.2518 55.8642)', 4326);
DECLARE @corridor geography = @line.STBuffer(25000);
SELECT shape = @corridor, color = '#f1ce63';
SELECT shape = @line, color = '#e15759';
SELECT c.Name, c.Population, [km from line] = ROUND(c.Geog.STDistance(@line) / 1000, 1), c.Geog,
       label = CASE WHEN c.Population > 60000 THEN c.Name END, color = '#4e79a7'
FROM world.City AS c WHERE c.Geog.STIntersects(@corridor) = 1
ORDER BY c.Population DESC;

--#demo Flood risk along the river
--#desc Buildings within 45 m of the River Query, using an exact curved buffer. Taller buildings house more people.
--#view plane
--#tags BufferWithCurves, STIntersects, risk analysis
DECLARE @zone geometry = (SELECT Geom.BufferWithCurves(45) FROM town.River);
SELECT shape = @zone, color = '#a0cbe8';
SELECT Geom, color = '#2f7fd0' FROM town.River;
SELECT b.BuildingId, b.Kind, b.Floors, [est. residents] = b.Floors * CAST(ROUND(b.Geom.STArea() / 30, 0) AS int),
       b.Geom, color = CASE WHEN b.Floors >= 8 THEN '#e15759' ELSE '#f28e2b' END
FROM town.Building AS b WHERE b.Geom.STIntersects(@zone) = 1
ORDER BY b.Floors DESC;
SELECT [buildings at risk] = COUNT(*), [floors at risk] = SUM(Floors) FROM town.Building WHERE Geom.STIntersects(@zone) = 1;

--#demo Bus stop coverage
--#desc Which buildings are more than 150 m from any bus stop? NOT EXISTS with STDistance, served by the building index.
--#view plane
--#tags STDistance, NOT EXISTS, coverage
SELECT shape = Geom.STBuffer(150), color = '#d4e8c4' FROM town.POI WHERE Kind = 'Bus Stop';
SELECT b.Geom, color = CASE WHEN EXISTS (SELECT 1 FROM town.POI p WHERE p.Kind = 'Bus Stop' AND p.Geom.STDistance(b.Geom) <= 150)
                            THEN '#59a14f' ELSE '#e15759' END
FROM town.Building AS b;
SELECT Geom, label = Name, color = '#222' FROM town.POI WHERE Kind = 'Bus Stop';
SELECT [buildings] = COUNT(*),
       [served] = SUM(x.served)
FROM town.Building AS b
CROSS APPLY (SELECT served = CASE WHEN EXISTS (SELECT 1 FROM town.POI p WHERE p.Kind = 'Bus Stop' AND p.Geom.STDistance(b.Geom) <= 150) THEN 1 ELSE 0 END) AS x;

--#demo Routing with SQL Graph
--#desc The road network is a SQL Graph (NODE and EDGE tables). SHORTEST_PATH finds the fewest-segment route from the south-west corner
--#desc to the north-east corner; only some roads have bridges, so the route must find one. The node list becomes a LINESTRING.
--#view plane
--#tags SQL Graph, MATCH, SHORTEST_PATH, STRING_AGG WITHIN GROUP (GRAPH PATH)
DECLARE @from int = 1, @to int = 121;
DECLARE @path varchar(max), @hops int;
SELECT @path = q.path, @hops = q.hops
FROM (
    SELECT path = STRING_AGG(n2.NodeKey, ',') WITHIN GROUP (GRAPH PATH),
           lastNode = LAST_VALUE(n2.NodeId) WITHIN GROUP (GRAPH PATH),
           hops = COUNT(n2.NodeId) WITHIN GROUP (GRAPH PATH)
    FROM town.RoadNode AS n1, town.RoadLink FOR PATH AS l, town.RoadNode FOR PATH AS n2
    WHERE MATCH(SHORTEST_PATH(n1(-(l)->n2)+)) AND n1.NodeId = @from
) AS q
WHERE q.lastNode = @to;
SELECT Geom, color = '#2f7fd0' FROM town.River;
SELECT l.Geom, color = CASE WHEN l.IsBridge = 1 THEN '#f28e2b' ELSE '#cccccc' END FROM town.RoadLink AS l;
WITH seq AS (
    SELECT ord = 0, NodeId = @from
    UNION ALL
    SELECT CAST(s.ordinal AS int), CAST(s.value AS int) FROM STRING_SPLIT(@path, ',', 1) AS s)
SELECT shape = geometry::STGeomFromText('LINESTRING (' + STRING_AGG(CAST(CONCAT(n.X, ' ', n.Y) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY seq.ord) + ')', 0),
       label = CONCAT(@hops, ' segments, ', @hops * 120, ' m'), color = '#e15759'
FROM seq JOIN town.RoadNode AS n ON n.NodeId = seq.NodeId;
SELECT [route] = @path, [segments] = @hops;

--#demo How far can you get in N junctions?
--#desc SHORTEST_PATH to every junction, keeping those within 10 steps. Press play: each frame adds the junctions reachable in one more step.
--#desc (A bounded quantifier in curly braces would also work, but ODBC drivers read curly braces as escape sequences - so we filter on the hop count instead.)
--#view plane
--#tags SQL Graph, SHORTEST_PATH, animation
DECLARE @start int = 61;  -- the middle of town
SELECT Geom, color = '#2f7fd0' FROM town.River;
SELECT l.Geom, color = '#dddddd' FROM town.RoadLink AS l;
DROP TABLE IF EXISTS #reach;
SELECT q.NodeId, q.hops INTO #reach
FROM (
    SELECT NodeId = LAST_VALUE(n2.NodeId) WITHIN GROUP (GRAPH PATH), hops = COUNT(n2.NodeId) WITHIN GROUP (GRAPH PATH)
    FROM town.RoadNode AS n1, town.RoadLink FOR PATH AS l, town.RoadNode FOR PATH AS n2
    WHERE MATCH(SHORTEST_PATH(n1(-(l)->n2)+)) AND n1.NodeId = @start
) AS q
WHERE q.hops <= 10;
SELECT frame = f.value, shape = n.Geom.STBuffer(9), color = CONCAT('hsl(', r.hops * 30, ',75%,50%)')
FROM #reach AS r JOIN town.RoadNode AS n ON n.NodeId = r.NodeId
JOIN GENERATE_SERIES(1, 10) AS f ON r.hops <= f.value;

--#demo Which zone am I in?
--#desc A point-in-polygon lookup for a handful of points, returning the block, its zone and the nearest school.
--#view plane
--#tags STContains, nearest neighbour, CROSS APPLY
SELECT Geom, color = '#e8e4dc' FROM town.Block;
WITH pts AS (SELECT * FROM (VALUES (1, 130.0, 410.0), (2, 700.0, 250.0), (3, 1010.0, 1100.0), (4, 333.0, 888.0)) AS v (id, x, y))
SELECT pts.id, shape = geometry::Point(pts.x, pts.y, 0).STBuffer(8), b.ZoneKind, [block] = b.BlockId, [nearest school] = s.Name, [m] = ROUND(s.d, 0),
       label = CONCAT('#', pts.id, ' ', ISNULL(b.ZoneKind, 'road'), ', ', s.Name), color = '#e15759'
FROM pts
OUTER APPLY (SELECT TOP (1) BlockId, ZoneKind FROM town.Block WHERE Geom.STContains(geometry::Point(pts.x, pts.y, 0)) = 1) AS b
CROSS APPLY (SELECT TOP (1) Name, d = Geom.STDistance(geometry::Point(pts.x, pts.y, 0)) FROM town.POI WHERE Kind = 'School'
             ORDER BY Geom.STDistance(geometry::Point(pts.x, pts.y, 0))) AS s;
