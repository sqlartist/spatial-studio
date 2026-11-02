/* Spatial Studio demo pack 05 - Operations that make new shapes */

--#demo Buffers: out, in, and with tolerance
--#desc STBuffer(d) grows a shape by d; a negative distance shrinks it. BufferWithTolerance trades accuracy for fewer vertices.
--#view plane
--#tags STBuffer, BufferWithTolerance, STNumPoints
DECLARE @b geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'Plus' ORDER BY BuildingId);
SELECT shape = @b.STBuffer(6), label = CONCAT('STBuffer(6): ', @b.STBuffer(6).STNumPoints(), ' pts'), color = '#a0cbe8';
SELECT shape = @b.BufferWithTolerance(6, 1.5, 0), label = CONCAT('BufferWithTolerance(6, 1.5): ', @b.BufferWithTolerance(6, 1.5, 0).STNumPoints(), ' pts'), color = '#4e79a7';
SELECT shape = @b, label = 'original', color = '#bab0ac';
SELECT shape = @b.STBuffer(-1.5), label = 'STBuffer(-1.5)', color = '#e15759';

--#demo A 100 km geodesic buffer
--#desc geography buffers are true distances on the ellipsoid. Near the pole the same buffer looks huge on a Mercator map - it isn't.
--#view map
--#tags STBuffer, geography
SELECT shape = geography::Point(51.6565, -0.3903, 4326).STBuffer(100000), label = 'Watford +100 km', color = '#4e79a7'
UNION ALL
SELECT geography::Point(69.6496, 18.9560, 4326).STBuffer(100000), N'Tromsø +100 km', '#e15759'
UNION ALL
SELECT geography::Point(0.3476, 32.5825, 4326).STBuffer(100000), 'Kampala +100 km', '#59a14f';

--#demo Set operations: intersection, union, difference, symmetric difference
--#desc Two overlapping circles combined four ways, laid out left to right.
--#view plane
--#tags STIntersection, STUnion, STDifference, STSymDifference
DECLARE @a geometry = geometry::Point(0, 0, 0).STBuffer(30);
DECLARE @b geometry = geometry::Point(30, 0, 0).STBuffer(30);
SELECT shape = sx.Translate(@a, 0, 0),   label = 'A and B', color = '#4e79a7' UNION ALL SELECT sx.Translate(@b, 0, 0), NULL, '#e15759';
SELECT shape = sx.Translate(@a.STIntersection(@b), 110, 0), label = 'STIntersection', color = '#59a14f'
UNION ALL SELECT sx.Translate(@a.STUnion(@b), 220, 0),           'STUnion',          '#59a14f'
UNION ALL SELECT sx.Translate(@a.STDifference(@b), 330, 0),      'STDifference',     '#59a14f'
UNION ALL SELECT sx.Translate(@a.STSymDifference(@b), 440, 0),   'STSymDifference',  '#59a14f';

--#demo Convex hull
--#desc STConvexHull of one shape (a T-building) and of a whole set (every school) via the aggregate.
--#view plane
--#tags STConvexHull, ConvexHullAggregate
SELECT shape = geometry::ConvexHullAggregate(Geom), label = 'hull of all schools', color = '#f1ce63' FROM town.POI WHERE Kind = 'School';
SELECT Geom, label = Name, color = '#e15759' FROM town.POI WHERE Kind = 'School';

--#demo Simplifying a coastline with Reduce()
--#desc Reduce() is Douglas-Peucker. Press play: each frame doubles the tolerance on Great Britain (geography, metres).
--#view map
--#tags Reduce, STNumPoints, animation
DECLARE @gb geography = (SELECT Geog FROM world.Country WHERE Name = 'United Kingdom');
SELECT frame = f.value, shape = @gb.Reduce(t.tol),
       label = CONCAT('Reduce(', t.tol, ' m): ', @gb.Reduce(t.tol).STNumPoints(), ' of ', @gb.STNumPoints(), ' points'),
       color = '#4e79a7'
FROM GENERATE_SERIES(0, 7) AS f
CROSS APPLY (SELECT tol = 250 * POWER(2, f.value)) AS t;

--#demo Shortest line between two shapes
--#desc ShortestLineTo returns the actual segment that STDistance measures.
--#view plane
--#tags ShortestLineTo, STDistance
DECLARE @a geometry = (SELECT Geom FROM town.Building WHERE BuildingId = (SELECT MIN(BuildingId) FROM town.Building WHERE Kind = 'Courtyard'));
DECLARE @b geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'Triangle' ORDER BY ABS(Geom.STDistance(@a) - 120));
SELECT shape = @a, color = '#4e79a7' UNION ALL SELECT @b, '#4e79a7';
SELECT shape = @a.ShortestLineTo(@b), label = CONCAT(ROUND(@a.STDistance(@b), 2), ' m'), color = '#e15759';

--#demo Clipping to a window
--#desc STIntersection with a rectangle is a classic map clip. Here every building is clipped to a diagonal strip.
--#view plane
--#tags STIntersection, clipping
DECLARE @strip geometry = 'POLYGON ((0 300, 300 0, 500 0, 0 500, 0 300))';
SELECT shape = @strip, color = '#f1ce63';
SELECT shape = b.Geom.STIntersection(@strip), color = '#4e79a7'
FROM town.Building AS b WHERE b.Geom.STIntersects(@strip) = 1;

--#demo Dissolving a zone into one shape
--#desc STUnion pairwise is slow for many shapes; UnionAggregate dissolves a whole set in one go.
--#view plane
--#tags UnionAggregate, STUnion
SELECT ZoneKind, shape = geometry::UnionAggregate(Geom.STBuffer(10.5)).STBuffer(-0.5), label = ZoneKind,
       color = CASE ZoneKind WHEN 'Park' THEN '#8cc084' WHEN 'Commercial' THEN '#f1ce63' WHEN 'Industrial' THEN '#bab0ac' ELSE '#e8c4b8' END,
       blocks = COUNT(*)
FROM town.Block GROUP BY ZoneKind;
