/* Spatial Studio demo pack 04 - Spatial relationships (predicates) */

--#demo The predicate matrix
--#desc Eight OGC predicates for eight pairs of shapes. Every pair is drawn side by side; read the grid to see which predicates fire.
--#view plane
--#tags STIntersects, STDisjoint, STTouches, STOverlaps, STWithin, STContains, STCrosses, STEquals
DROP TABLE IF EXISTS #pairs;
CREATE TABLE #pairs (id int, name varchar(40), a geometry, b geometry);
INSERT #pairs VALUES
 (1, 'separate',        'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'POLYGON ((15 0, 25 0, 25 10, 15 10, 15 0))'),
 (2, 'edge touching',   'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'POLYGON ((10 0, 20 0, 20 10, 10 10, 10 0))'),
 (3, 'overlapping',     'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'POLYGON ((5 5, 15 5, 15 15, 5 15, 5 5))'),
 (4, 'b inside a',      'POLYGON ((0 0, 20 0, 20 20, 0 20, 0 0))', 'POLYGON ((5 5, 10 5, 10 10, 5 10, 5 5))'),
 (5, 'identical',       'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'POLYGON ((10 10, 0 10, 0 0, 10 0, 10 10))'),
 (6, 'line crosses',    'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'LINESTRING (-5 5, 15 5)'),
 (7, 'line along edge', 'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 'LINESTRING (0 0, 10 0)'),
 (8, 'lines cross',     'LINESTRING (0 0, 10 10)',                  'LINESTRING (0 10, 10 0)');
SELECT name, [Intersects] = a.STIntersects(b), [Disjoint] = a.STDisjoint(b), [Touches] = a.STTouches(b),
       [Overlaps] = a.STOverlaps(b), [Within] = b.STWithin(a), [Contains] = a.STContains(b),   -- CONTAINS is a reserved word
       [Crosses] = b.STCrosses(a), [Equals] = a.STEquals(b), [DE-9IM] = '(see next demo)'
FROM #pairs ORDER BY id;
-- lay the pairs out on a grid so they can all be seen at once
SELECT shape = sx.Translate(a, ((id - 1) % 4) * 40, -((id - 1) / 4) * 40), label = name, color = '#4e79a7' FROM #pairs;
SELECT shape = sx.Translate(b, ((id - 1) % 4) * 40, -((id - 1) / 4) * 40), color = '#e15759' FROM #pairs;

--#demo STRelate and the DE-9IM
--#desc Every predicate is a pattern over the Dimensionally Extended 9-Intersection Model: interior, boundary and exterior of A versus B.
--#desc STRelate tests any pattern you like. T = intersects, F = empty, * = don't care, 0/1/2 = dimension.
--#tags STRelate, DE-9IM
DECLARE @a geometry = 'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))';
SELECT pattern, meaning, [STRelate(a, b)] = @a.STRelate(b.g, pattern), b = b.g.ToString()
FROM (VALUES
    ('T*****FF*', 'a contains b'),
    ('FF*FF****', 'disjoint'),
    ('FT*******', 'touch: boundaries meet, interiors do not (one of the touch patterns)'),
    ('T*T***T**', 'overlap (areas)'),
    ('1********', 'interiors meet in a line'),
    ('2********', 'interiors meet in an area')
) AS p (pattern, meaning)
CROSS JOIN (VALUES (geometry::STGeomFromText('POLYGON ((2 2, 5 2, 5 5, 2 5, 2 2))', 0)),
                   (geometry::STGeomFromText('POLYGON ((10 0, 20 0, 20 10, 10 10, 10 0))', 0)),
                   (geometry::STGeomFromText('LINESTRING (-5 5, 15 5)', 0))) AS b (g)
ORDER BY pattern;

--#demo Filter() versus STIntersects()
--#desc Filter() answers from the spatial index alone - fast, but it can say yes to near-misses (false positives).
--#desc STIntersects is exact. The difference is the index's slack.
--#view plane
--#tags Filter, STIntersects, spatial index
DECLARE @q geometry = geometry::Point(600, 600, 0).STBuffer(90);
SELECT shape = @q, label = 'query circle', color = '#f28e2b';
SELECT b.Geom, label = CASE WHEN b.Geom.STIntersects(@q) = 1 THEN NULL ELSE 'false positive' END,
       color = CASE WHEN b.Geom.STIntersects(@q) = 1 THEN '#59a14f' ELSE '#e15759' END
FROM town.Building AS b WITH (INDEX (SIX_Building_Geom))
WHERE b.Geom.Filter(@q) = 1;
SELECT [Filter() hits] = (SELECT COUNT(*) FROM town.Building WITH (INDEX (SIX_Building_Geom)) WHERE Geom.Filter(@q) = 1),
       [STIntersects() hits] = (SELECT COUNT(*) FROM town.Building WHERE Geom.STIntersects(@q) = 1);

--#demo Which cities are in the United Kingdom?
--#desc A point-in-polygon query on geography, served by the spatial index on world.City.
--#view map
--#tags STWithin, STIntersects, geography, spatial index
DECLARE @uk geography = (SELECT Geog FROM world.Country WHERE Name = 'United Kingdom');
SELECT shape = @uk, color = '#bab0ac';
SELECT c.Geog, label = CASE WHEN c.Population > 250000 THEN c.Name END, c.Name, c.Population, color = '#e15759'
FROM world.City AS c
WHERE c.Geog.STWithin(@uk) = 1
ORDER BY c.Population DESC;

--#demo Neighbours of France
--#desc STTouches is strict: at 1:110m scale borders rarely share every vertex. A tolerance via STDistance is more forgiving.
--#view map
--#tags STTouches, STDistance, STIntersects, geography
DECLARE @fr geography = (SELECT Geog FROM world.Country WHERE Name = 'France');
SELECT shape = @fr, label = 'France', color = '#4e79a7';
SELECT k.Geog, label = k.Name, [STTouches (flat Geom)] = k.Geom.MakeValid().STTouches(sx.GeogToGeom(@fr).MakeValid()), [STIntersects] = k.Geog.STIntersects(@fr),
       [gap m] = ROUND(k.Geog.STDistance(@fr), 0), color = '#f28e2b'
FROM world.Country AS k
WHERE k.Name <> 'France' AND k.Geog.STDistance(@fr) < 5000;

--#demo Bridges: where roads cross the river
--#desc STCrosses between a LINESTRING and a COMPOUNDCURVE, and STIntersection to get the crossing points.
--#view plane
--#tags STCrosses, STIntersection, COMPOUNDCURVE
DECLARE @river geometry = (SELECT Geom FROM town.River);
SELECT shape = @river, color = '#2f7fd0';
SELECT r.Geom, label = r.Name, color = '#888' FROM town.Road AS r WHERE r.Geom.STCrosses(@river) = 1;
SELECT shape = r.Geom.STIntersection(@river).STBuffer(6), label = r.Name, color = '#e15759'
FROM town.Road AS r WHERE r.Geom.STCrosses(@river) = 1;

--#demo STEquals is spatial, not textual
--#desc Two polygons with different starting vertices and directions are spatially equal even though their WKT differs.
--#tags STEquals
DECLARE @a geometry = 'POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))';
DECLARE @b geometry = 'POLYGON ((10 10, 10 0, 0 0, 0 10, 10 10))';
SELECT [same WKT?] = CASE WHEN @a.ToString() = @b.ToString() THEN 1 ELSE 0 END,
       [STEquals] = @a.STEquals(@b),
       [binary equal?] = CASE WHEN CAST(@a AS varbinary(max)) = CAST(@b AS varbinary(max)) THEN 1 ELSE 0 END;
