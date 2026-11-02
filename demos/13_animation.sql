/* Spatial Studio demo pack 13 - Animation: add a "frame" column and press play */

--#demo Growing buffers
--#desc Rows carry a frame number; the viewer plays them in order. Rows without a frame stay on screen.
--#view plane
--#tags animation, STBuffer, frame
SELECT Geom, color = '#7a5c4f' FROM town.Building WHERE Geom.STDistance(geometry::Point(600, 600, 0)) < 400;
SELECT frame = f.value, shape = p.Geom.STBuffer(f.value * 12), color = '#4e79a7'
FROM town.POI AS p CROSS JOIN GENERATE_SERIES(1, 20) AS f
WHERE p.Kind = 'Library' AND p.Geom.STDistance(geometry::Point(600, 600, 0)) < 400;

--#demo A spinning building
--#desc sx.Spin rotates about the envelope centre: 36 frames, 10 degrees each.
--#view plane
--#tags animation, sx.Spin
DECLARE @b geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'TShape' ORDER BY BuildingId);
SELECT shape = @b.STEnvelope().STBuffer(6), color = '#f1ce63';
SELECT frame = f.value, shape = sx.Spin(@b, f.value * 10), label = CONCAT(f.value * 10, N'°'), color = '#4e79a7'
FROM GENERATE_SERIES(0, 35) AS f;

--#demo Flight: London to Tokyo
--#desc A point moving along the geodesic with a growing trail, built from sx.GreatCircle and STPointN.
--#view map
--#tags animation, sx.GreatCircle, STPointN, geography
DECLARE @a geography = geography::Point(51.4700, -0.4543, 4326), @b geography = geography::Point(35.5494, 139.7798, 4326);
DECLARE @path geography = sx.GreatCircle(@a, @b, 60);
SELECT shape = @path, color = '#cccccc';
SELECT frame = f.value, shape = @path.STPointN(f.value), label = CONCAT(ROUND(@a.STDistance(@path.STPointN(f.value)) / 1000, 0), ' km'), color = '#e15759'
FROM GENERATE_SERIES(1, 61) AS f;
SELECT frame = f.value, shape = sx.GreatCircle(@a, @path.STPointN(f.value), f.value), color = '#e15759'
FROM GENERATE_SERIES(2, 61) AS f;

--#demo Douglas-Peucker on Norway
--#desc Reduce() with a doubling tolerance, one frame per step. Fjords vanish first.
--#view map
--#tags animation, Reduce
DECLARE @n geography = (SELECT Geog FROM world.Country WHERE Name = 'Norway');
SELECT frame = f.value, shape = @n.Reduce(500 * POWER(2, f.value)),
       label = CONCAT('tolerance ', 500 * POWER(2, f.value), ' m, ', @n.Reduce(500 * POWER(2, f.value)).STNumPoints(), ' points'), color = '#4e79a7'
FROM GENERATE_SERIES(0, 8) AS f;

--#demo Morphing between shapes by vector
--#desc Fourier descriptors interpolated from a triangle to a plus; each frame picks the real building closest to the blended vector.
--#view plane
--#tags animation, VECTOR_DISTANCE, vector arithmetic, OPENJSON
DECLARE @from int = (SELECT MIN(BuildingId) FROM town.Building WHERE Kind = 'Triangle');
DECLARE @to int = (SELECT MIN(BuildingId) FROM town.Building WHERE Kind = 'Plus');
WITH a AS (SELECT d = CAST([key] AS int), x = CAST(value AS float) FROM OPENJSON((SELECT CAST(Fourier AS nvarchar(max)) FROM town.BuildingShape WHERE BuildingId = @from))),
     b AS (SELECT d = CAST([key] AS int), x = CAST(value AS float) FROM OPENJSON((SELECT CAST(Fourier AS nvarchar(max)) FROM town.BuildingShape WHERE BuildingId = @to))),
     blends AS (
        SELECT frame = f.value,
               v = CAST('[' + STRING_AGG(CONVERT(varchar(30), CAST(a.x + (b.x - a.x) * f.value / 10.0 AS decimal(12, 6))), ',') WITHIN GROUP (ORDER BY a.d) + ']' AS vector(16))
        FROM a JOIN b ON b.d = a.d CROSS JOIN GENERATE_SERIES(0, 10) AS f
        GROUP BY f.value)
SELECT bl.frame, shape = sx.GalleryPlace(bu.Geom, 0, 1, 0), label = CONCAT(bu.Kind, ' (', bl.frame * 10, '% of the way)'), color = '#4e79a7'
FROM blends AS bl
CROSS APPLY (SELECT TOP (1) s.BuildingId FROM town.BuildingShape s ORDER BY VECTOR_DISTANCE('euclidean', s.Fourier, bl.v)) AS n
JOIN town.Building AS bu ON bu.BuildingId = n.BuildingId;
