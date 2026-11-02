/* Spatial Studio demo pack 12 - Vector search meets spatial (SQL Server 2025 VECTOR) */

--#demo VECTOR basics
--#desc The VECTOR(n) type stores float32 arrays. VECTOR_DISTANCE (cosine, euclidean, dot), VECTOR_NORM, VECTOR_NORMALIZE and VECTORPROPERTY.
--#tags VECTOR, VECTOR_DISTANCE, VECTOR_NORM, VECTOR_NORMALIZE, VECTORPROPERTY
DECLARE @a vector(3) = '[1, 0, 0]';
DECLARE @b vector(3) = '[0.7071068, 0.7071068, 0]';
DECLARE @c vector(3) = '[3, 4, 12]';
SELECT [cosine a,b]    = VECTOR_DISTANCE('cosine', @a, @b),
       [euclidean a,b] = VECTOR_DISTANCE('euclidean', @a, @b),
       [dot a,b (negated)] = VECTOR_DISTANCE('dot', @a, @b),
       [norm2 c]   = VECTOR_NORM(@c, 'norm2'),
       [norm1 c]   = VECTOR_NORM(@c, 'norm1'),
       [norminf c] = VECTOR_NORM(@c, 'norminf'),
       [normalize c] = CAST(VECTOR_NORMALIZE(@c, 'norm2') AS nvarchar(max)),
       [dimensions] = VECTORPROPERTY(@c, 'Dimensions'),
       [base type]  = VECTORPROPERTY(@c, 'BaseType'),
       [as JSON]    = CAST(@c AS nvarchar(max));

--#demo The globe as a vector space
--#desc Every city is stored as a point on the unit sphere (x, y, z). The cosine distance between two such vectors is 1 - cos(angle),
--#desc so ACOS(1 - d) x Earth radius is the great-circle distance. Compare with geography.STDistance (ellipsoid) - and note float32 limits at short range.
--#tags VECTOR_DISTANCE, cosine, sx.CosineToKm, sx.UnitVector, STDistance
DECLARE @w int = (SELECT TOP (1) CityId FROM world.City WHERE Name = 'Watford' AND CountryCode = 'GB');
SELECT b.Name, b.CountryCode,
       [geography km (ellipsoid)] = ROUND(a.Geog.STDistance(b.Geog) / 1000, 3),
       [vector km (sphere, float32)] = ROUND(sx.CosineToKm(VECTOR_DISTANCE('cosine', a.UnitVec, b.UnitVec)), 3),
       [cosine distance] = VECTOR_DISTANCE('cosine', a.UnitVec, b.UnitVec)
FROM world.City AS a
CROSS JOIN world.City AS b
WHERE a.CityId = @w AND b.Name IN ('Hemel Hempstead', 'London', 'Birmingham', 'Paris', 'New York City', 'Sydney', 'Auckland')
ORDER BY a.Geog.STDistance(b.Geog);

--#demo k-NN two ways: spatial index versus VECTOR_DISTANCE
--#desc The ten nearest cities to Watford by geography.STDistance (spatial index) and by exact cosine distance on the unit vectors.
--#desc Same answer, two completely different engines.
--#view map
--#tags nearest neighbour, VECTOR_DISTANCE, STDistance, spatial index
DECLARE @here geography, @q vector(3);
SELECT TOP (1) @here = Geog, @q = UnitVec FROM world.City WHERE Name = 'Watford' AND CountryCode = 'GB';
DECLARE @t datetime2 = SYSDATETIME(), @ms1 int, @ms2 int;
DROP TABLE IF EXISTS #knnS, #knnV;
SELECT TOP (10) CityId, Name, km = Geog.STDistance(@here) / 1000 INTO #knnS FROM world.City
WHERE Geog.STDistance(@here) IS NOT NULL ORDER BY Geog.STDistance(@here);
SET @ms1 = DATEDIFF(MILLISECOND, @t, SYSDATETIME()); SET @t = SYSDATETIME();
SELECT TOP (10) CityId, Name, km = sx.CosineToKm(VECTOR_DISTANCE('cosine', UnitVec, @q)) INTO #knnV FROM world.City
ORDER BY VECTOR_DISTANCE('cosine', UnitVec, @q);
SET @ms2 = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SELECT [rank] = ROW_NUMBER() OVER (ORDER BY s.km), [spatial index] = s.Name, [km] = ROUND(s.km, 2),
       [vector exact] = v.Name, [vector km] = ROUND(v.km, 2)
FROM (SELECT *, r = ROW_NUMBER() OVER (ORDER BY km) FROM #knnS) AS s
FULL JOIN (SELECT *, r = ROW_NUMBER() OVER (ORDER BY km) FROM #knnV) AS v ON v.r = s.r;
SELECT [spatial index ms] = @ms1, [vector scan ms] = @ms2;
SELECT c.Geog, label = c.Name, color = '#e15759' FROM #knnS JOIN world.City c ON c.CityId = #knnS.CityId;

--#demo Approximate search with a DiskANN vector index
--#desc VECTOR_SEARCH uses the DiskANN index on world.CityVec (a preview feature: PREVIEW_FEATURES must be ON).
--#desc It returns the nearest neighbours approximately but very fast at scale. Falls back to an explanation if the preview isn't available.
--#view map
--#tags VECTOR_SEARCH, CREATE VECTOR INDEX, DiskANN, PREVIEW_FEATURES
DECLARE @q vector(3) = (SELECT TOP (1) UnitVec FROM world.City WHERE Name = 'Watford' AND CountryCode = 'GB');
BEGIN TRY
    EXEC sp_executesql N'
        SELECT c.Name, c.Population, [cosine distance] = s.distance, [km] = ROUND(sx.CosineToKm(s.distance), 2),
               c.Geog, label = c.Name, color = ''#4e79a7''
        FROM VECTOR_SEARCH(TABLE = world.CityVec AS v, COLUMN = UnitVec, SIMILAR_TO = @q, METRIC = ''cosine'', TOP_N = 15) AS s
        JOIN world.City AS c ON c.CityId = v.CityId
        ORDER BY s.distance;', N'@q vector(3)', @q = @q;
END TRY
BEGIN CATCH
    SELECT [VECTOR_SEARCH unavailable] = ERROR_MESSAGE(),
           [check] = 'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON; then re-run install step 06',
           [vector indexes present] = (SELECT COUNT(*) FROM sys.indexes WHERE type_desc LIKE '%VECTOR%');
END CATCH;

--#demo Shape search: find buildings shaped like this one
--#desc Each footprint has a 16-number Fourier descriptor computed in T-SQL (rays from the centroid, then a DFT).
--#desc It ignores position, size and rotation. The query L-shape is first; the best matches follow, lined up in a gallery.
--#view plane
--#tags VECTOR_DISTANCE, shape descriptor, sx.FourierDescriptor, sx.GalleryPlace
DECLARE @id int = (SELECT MIN(BuildingId) FROM town.Building WHERE Kind = 'LShape');
DECLARE @q vector(16) = (SELECT Fourier FROM town.BuildingShape WHERE BuildingId = @id);
WITH r AS (
    SELECT TOP (24) b.BuildingId, b.Kind, b.Geom, d = VECTOR_DISTANCE('cosine', s.Fourier, @q)
    FROM town.BuildingShape AS s JOIN town.Building AS b ON b.BuildingId = s.BuildingId
    ORDER BY d)
SELECT [rank] = ROW_NUMBER() OVER (ORDER BY d) - 1, BuildingId, Kind, [cosine distance] = ROUND(d, 5),
       shape = sx.GalleryPlace(Geom, CAST(ROW_NUMBER() OVER (ORDER BY d) - 1 AS int), 6, 40),
       label = CASE WHEN BuildingId = @id THEN 'QUERY' ELSE CONCAT(Kind, ' ', FORMAT(d, 'N4')) END,
       color = CASE WHEN BuildingId = @id THEN '#e15759' WHEN Kind = 'LShape' THEN '#59a14f' ELSE '#f28e2b' END
FROM r;

--#demo Shape recognition: how good are the descriptors?
--#desc Leave-one-out 5-nearest-neighbour classification of every building, using three descriptors.
--#desc The rotation-invariant Fourier vectors should win; the raw radial signature is confused by rotation. (Takes a few seconds.)
--#tags VECTOR_DISTANCE, k-NN classification, Fourier, Radial, Morph
DROP TABLE IF EXISTS #shp, #pred;
SELECT b.BuildingId, b.Kind, x.Radial, x.Fourier, x.Morph INTO #shp
FROM town.Building b JOIN town.BuildingShape x ON x.BuildingId = b.BuildingId;
SELECT a.BuildingId, a.Kind,
       fourier = (SELECT TOP (1) k.Kind FROM (SELECT TOP (5) o.Kind, d = VECTOR_DISTANCE('cosine', o.Fourier, a.Fourier) FROM #shp o WHERE o.BuildingId <> a.BuildingId ORDER BY d) k GROUP BY k.Kind ORDER BY COUNT(*) DESC, MIN(k.d)),
       radial  = (SELECT TOP (1) k.Kind FROM (SELECT TOP (5) o.Kind, d = VECTOR_DISTANCE('cosine', o.Radial, a.Radial) FROM #shp o WHERE o.BuildingId <> a.BuildingId ORDER BY d) k GROUP BY k.Kind ORDER BY COUNT(*) DESC, MIN(k.d)),
       morph   = (SELECT TOP (1) k.Kind FROM (SELECT TOP (5) o.Kind, d = VECTOR_DISTANCE('euclidean', o.Morph, a.Morph) FROM #shp o WHERE o.BuildingId <> a.BuildingId ORDER BY d) k GROUP BY k.Kind ORDER BY COUNT(*) DESC, MIN(k.d))
INTO #pred
FROM #shp AS a;
SELECT Kind = ISNULL(Kind, '(all)'), buildings = COUNT(*),
       [Fourier %] = CAST(100.0 * SUM(CASE WHEN fourier = Kind THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5, 1)),
       [Radial %]  = CAST(100.0 * SUM(CASE WHEN radial  = Kind THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5, 1)),
       [Morph %]   = CAST(100.0 * SUM(CASE WHEN morph   = Kind THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5, 1))
FROM #pred
GROUP BY ROLLUP (Kind)
ORDER BY GROUPING(Kind), Kind;
SELECT [true type] = Kind, [Fourier said] = fourier, [times] = COUNT(*)
FROM #pred WHERE fourier <> Kind GROUP BY Kind, fourier ORDER BY COUNT(*) DESC;

--#demo Query by sketch
--#desc Draw any polygon with the Draw tool (or edit the WKT below), and the shape engine finds the closest footprints in town.
--#desc The sketch's descriptor is computed on the fly with sx.FourierDescriptor - scale and rotation don't matter.
--#view plane
--#tags sx.FourierDescriptor, VECTOR_DISTANCE, query by example
DECLARE @sketch geometry = 'POLYGON ((0 0, 60 0, 60 20, 20 20, 20 50, 60 50, 60 70, 0 70, 0 0))';   -- a fat letter C
DECLARE @q vector(16) = CAST(sx.FourierDescriptor(@sketch) AS vector(16));
SELECT shape = sx.GalleryPlace(sx.Scale(@sketch, 20.0 / 70, 20.0 / 70), 0, 6, 40), label = 'SKETCH', color = '#e15759';
SELECT TOP (17) b.BuildingId, b.Kind, d = VECTOR_DISTANCE('cosine', s.Fourier, @q),
       shape = sx.GalleryPlace(b.Geom, CAST(ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, @q)) AS int), 6, 40),
       label = CONCAT(b.Kind, ' ', FORMAT(VECTOR_DISTANCE('cosine', s.Fourier, @q), 'N4')), color = '#4e79a7'
FROM town.BuildingShape AS s JOIN town.Building AS b ON b.BuildingId = s.BuildingId
ORDER BY d;

--#demo Hybrid search: near here AND shaped like that
--#desc The real power move: a spatial predicate (within 300 m of the town centre, via the spatial index) combined with
--#desc vector ranking (looks like a courtyard block). Matches are shown where they actually stand.
--#view plane
--#tags hybrid search, STDistance, VECTOR_DISTANCE, spatial index
DECLARE @centre geometry = geometry::Point(600, 600, 0);
DECLARE @q vector(16) = (SELECT TOP (1) s.Fourier FROM town.BuildingShape s JOIN town.Building b ON b.BuildingId = s.BuildingId WHERE b.Kind = 'Courtyard' ORDER BY b.BuildingId);
SELECT shape = @centre.STBuffer(300), color = '#f1ce63';
SELECT b.Geom, color = '#d0ccc8' FROM town.Building AS b WHERE b.Geom.STDistance(@centre) <= 300;
SELECT TOP (8) b.BuildingId, b.Kind, [m from centre] = ROUND(b.Geom.STDistance(@centre), 0),
       [shape distance] = ROUND(VECTOR_DISTANCE('cosine', s.Fourier, @q), 5),
       b.Geom, label = CONCAT('#', ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, @q))), color = '#e15759'
FROM town.Building AS b
JOIN town.BuildingShape AS s ON s.BuildingId = b.BuildingId
WHERE b.Geom.STDistance(@centre) <= 300
ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, @q);

--#demo Same query, different idea of "similar"
--#desc Fourier descriptors judge form regardless of size. The Morph vector (log area, compactness, solidity, holes, vertices, perimeter)
--#desc cares about size too. Left gallery: Fourier. Right gallery: Morph (euclidean).
--#view plane
--#tags VECTOR_DISTANCE, cosine, euclidean, sx.MorphVector
DECLARE @id int = (SELECT TOP (1) BuildingId FROM town.Building WHERE Kind = 'Plus' ORDER BY Scale DESC);
DECLARE @f vector(16), @m vector(6);
SELECT @f = Fourier, @m = Morph FROM town.BuildingShape WHERE BuildingId = @id;
SELECT TOP (12) shape = sx.GalleryPlace(b.Geom, CAST(ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, @f)) - 1 AS int), 3, 40),
       label = CONCAT('F: ', b.Kind), color = '#4e79a7'
FROM town.BuildingShape s JOIN town.Building b ON b.BuildingId = s.BuildingId ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, @f);
SELECT TOP (12) shape = sx.Translate(sx.GalleryPlace(b.Geom, CAST(ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('euclidean', s.Morph, @m)) - 1 AS int), 3, 40), 160, 0),
       label = CONCAT('M: ', b.Kind, ' ', ROUND(b.Geom.STArea(), 0), 'm2'), color = '#f28e2b'
FROM town.BuildingShape s JOIN town.Building b ON b.BuildingId = s.BuildingId ORDER BY VECTOR_DISTANCE('euclidean', s.Morph, @m);

--#demo K-means clustering of shapes, in T-SQL
--#desc Unsupervised: ten clusters of Fourier vectors, no labels used. Vectors are averaged by casting to JSON, OPENJSON per dimension,
--#desc AVG, and STRING_AGG back into a VECTOR. Then see how well the clusters line up with the true footprint types.
--#view plane
--#tags k-means, VECTOR_DISTANCE, VECTOR to JSON, OPENJSON, STRING_AGG
SET NOCOUNT ON;
DECLARE @k int = 10, @iter int = 0;
DROP TABLE IF EXISTS #cent, #assign;
CREATE TABLE #cent (c int PRIMARY KEY, v vector(16));
CREATE TABLE #assign (BuildingId int PRIMARY KEY, c int);
INSERT #cent SELECT TOP (@k) ROW_NUMBER() OVER (ORDER BY sx.Hash01(BuildingId, 5, 5)), Fourier
FROM town.BuildingShape ORDER BY sx.Hash01(BuildingId, 5, 5);
WHILE @iter < 15
BEGIN
    TRUNCATE TABLE #assign;
    INSERT #assign (BuildingId, c)
    SELECT s.BuildingId, n.c
    FROM town.BuildingShape AS s
    CROSS APPLY (SELECT TOP (1) c FROM #cent ORDER BY VECTOR_DISTANCE('euclidean', s.Fourier, #cent.v)) AS n;

    WITH dims AS (
        SELECT a.c, d = CAST(j.[key] AS int), m = AVG(CAST(j.value AS float))
        FROM #assign AS a
        JOIN town.BuildingShape AS s ON s.BuildingId = a.BuildingId
        CROSS APPLY OPENJSON(CAST(s.Fourier AS nvarchar(max))) AS j
        GROUP BY a.c, CAST(j.[key] AS int)),
    vecs AS (
        SELECT c, v = '[' + STRING_AGG(CONVERT(varchar(30), CAST(m AS decimal(12, 6))), ',') WITHIN GROUP (ORDER BY d) + ']'
        FROM dims GROUP BY c)
    UPDATE ce SET v = CAST(vecs.v AS vector(16)) FROM #cent AS ce JOIN vecs ON vecs.c = ce.c;
    SET @iter += 1;
END
SELECT b.Geom, label = CONCAT('k', a.c), color = CONCAT('hsl(', a.c * 36, ',70%,50%)')
FROM #assign a JOIN town.Building b ON b.BuildingId = a.BuildingId;
SELECT cluster = a.c, size = COUNT(*),
       [main type] = (SELECT TOP (1) b2.Kind FROM #assign a2 JOIN town.Building b2 ON b2.BuildingId = a2.BuildingId WHERE a2.c = a.c GROUP BY b2.Kind ORDER BY COUNT(*) DESC),
       [purity %] = CAST(100.0 * (SELECT TOP (1) COUNT(*) FROM #assign a2 JOIN town.Building b2 ON b2.BuildingId = a2.BuildingId WHERE a2.c = a.c GROUP BY b2.Kind ORDER BY COUNT(*) DESC) / COUNT(*) AS decimal(5, 1))
FROM #assign a GROUP BY a.c ORDER BY a.c;

--#demo Approximate versus exact: recall of the shape index
--#desc For 20 query buildings, compare VECTOR_SEARCH (DiskANN on town.BuildingShapeAnn) with exact VECTOR_DISTANCE top-10. Recall@10 = overlap / 10.
--#tags VECTOR_SEARCH, DiskANN, recall, VECTOR_DISTANCE
-- One VECTOR_SEARCH per query with a plain variable: the CROSS APPLY form (outer reference into
-- VECTOR_SEARCH) can kill the session on current preview builds, so we loop instead.
SET NOCOUNT ON;
DROP TABLE IF EXISTS #q, #exact, #approx;
SELECT TOP (20) BuildingId, Fourier INTO #q FROM town.BuildingShape ORDER BY sx.Hash01(BuildingId, 8, 8);
CREATE TABLE #exact (QueryId int, BuildingId int);
CREATE TABLE #approx (QueryId int, BuildingId int);
INSERT #exact
SELECT q.BuildingId, e.BuildingId
FROM #q AS q CROSS APPLY (SELECT TOP (10) s.BuildingId FROM town.BuildingShape s ORDER BY VECTOR_DISTANCE('cosine', s.Fourier, q.Fourier)) AS e;
DECLARE @id int, @v vector(16), @err nvarchar(4000);
DECLARE qc CURSOR LOCAL FAST_FORWARD FOR SELECT BuildingId, Fourier FROM #q;
OPEN qc; FETCH NEXT FROM qc INTO @id, @v;
WHILE @@FETCH_STATUS = 0 AND @err IS NULL
BEGIN
    BEGIN TRY
        INSERT #approx (QueryId, BuildingId)
        EXEC sp_executesql N'
            SELECT @id, t.BuildingId
            FROM VECTOR_SEARCH(TABLE = town.BuildingShapeAnn AS t, COLUMN = Fourier, SIMILAR_TO = @v, METRIC = ''cosine'', TOP_N = 10) AS vs;',
            N'@id int, @v vector(16)', @id = @id, @v = @v;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM qc INTO @id, @v;
END
CLOSE qc; DEALLOCATE qc;
IF @err IS NOT NULL
    SELECT [VECTOR_SEARCH unavailable] = @err,
           [note] = 'Vector indexes need SQL Server 2025 with PREVIEW_FEATURES = ON.';
ELSE
    SELECT [queries] = COUNT(DISTINCT e.QueryId),
           [mean recall@10] = CAST(AVG(CASE WHEN a.BuildingId IS NULL THEN 0.0 ELSE 1.0 END) AS decimal(5, 3)),
           [exact pairs] = COUNT(*), [found by DiskANN] = COUNT(a.BuildingId)
    FROM #exact AS e
    LEFT JOIN #approx AS a ON a.QueryId = e.QueryId AND a.BuildingId = e.BuildingId;

--#demo Vectors are JSON on the way in and out
--#desc A VECTOR casts to and from a JSON array string. Here: a stored shape vector, its norm, its normalised form and its size on disk.
--#tags VECTOR, CAST, VECTOR_NORM, VECTOR_NORMALIZE, DATALENGTH
SELECT TOP (5) b.BuildingId, b.Kind,
       [Fourier as JSON] = CAST(s.Fourier AS nvarchar(max)),
       [norm2] = VECTOR_NORM(s.Fourier, 'norm2'),
       [normalised] = CAST(VECTOR_NORMALIZE(s.Fourier, 'norm2') AS nvarchar(max)),
       [bytes] = DATALENGTH(s.Fourier),
       [dimensions] = VECTORPROPERTY(s.Fourier, 'Dimensions')
FROM town.BuildingShape s JOIN town.Building b ON b.BuildingId = s.BuildingId
ORDER BY b.BuildingId;
