/* Spatial Studio demo pack 09 - Spatial indexes and performance */

--#demo The spatial indexes in this database
--#desc sys.spatial_indexes and sys.spatial_index_tessellations show the grid scheme, bounding box, grid densities and cells per object.
--#tags sys.spatial_indexes, sys.spatial_index_tessellations
SELECT [table] = OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id), i.name, t.tessellation_scheme,
       t.bounding_box_xmin, t.bounding_box_ymin, t.bounding_box_xmax, t.bounding_box_ymax,
       t.level_1_grid_desc, t.level_2_grid_desc, t.level_3_grid_desc, t.level_4_grid_desc, t.cells_per_object
FROM sys.spatial_indexes AS i
JOIN sys.spatial_index_tessellations AS t ON t.object_id = i.object_id AND t.index_id = i.index_id;

--#demo How a grid index sees a building
--#desc An illustration of the multi-level grid: the bounding box is cut 8 x 8 (level 1), and each touched cell is cut 8 x 8 again (level 2).
--#desc The index stores the cells a shape touches, so a query first compares cells, then checks the real geometry.
--#view plane
--#tags GEOMETRY_GRID, tessellation, BOUNDING_BOX
DECLARE @b geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'LShape' ORDER BY Geom.STDistance(geometry::Point(610, 610, 0)));
DECLARE @s1 float = 1400 / 8.0;
SELECT g.Geom, color = '#e8e4dc' FROM sx.SquareGrid(-100, -100, 1300, 1300, @s1, 0) AS g;
SELECT g.Geom, label = CONCAT('L1 cell ', g.Col, ',', g.Row), color = '#f1ce63'
FROM sx.SquareGrid(-100, -100, 1300, 1300, @s1, 0) AS g WHERE g.Geom.STIntersects(@b) = 1;
SELECT l2.Geom, color = '#f28e2b'
FROM sx.SquareGrid(-100, -100, 1300, 1300, @s1, 0) AS g
CROSS APPLY sx.SquareGrid(g.Geom.STEnvelope().STPointN(1).STX, g.Geom.STEnvelope().STPointN(1).STY,
                          g.Geom.STEnvelope().STPointN(3).STX, g.Geom.STEnvelope().STPointN(3).STY, @s1 / 8, 0) AS l2
WHERE g.Geom.STIntersects(@b) = 1 AND l2.Geom.STIntersects(@b) = 1;
SELECT shape = @b, label = 'the building', color = '#4e79a7';

--#demo Ask the index about a query: sp_help_spatial_geometry_index
--#desc Returns the index's own statistics for a sample query window: primary filter efficiency, cells, rows output by each level.
--#tags sp_help_spatial_geometry_index
DECLARE @qs geometry = geometry::Point(600, 600, 0).STBuffer(100);
EXEC sp_help_spatial_geometry_index @tabname = 'town.Building', @indexname = 'SIX_Building_Geom', @verboseoutput = 1, @query_sample = @qs;

--#demo Ask the index about a query: sp_help_spatial_geography_index
--#desc The same for geography: a 50 km circle round Watford against the 24,000-city index.
--#tags sp_help_spatial_geography_index
DECLARE @qs geography = geography::Point(51.6565, -0.3903, 4326).STBuffer(50000);
EXEC sp_help_spatial_geography_index @tabname = 'world.City', @indexname = 'SIX_City_Geog', @verboseoutput = 1, @query_sample = @qs;

--#demo Nearest neighbours the index-friendly way
--#desc TOP + ORDER BY STDistance + a NOT NULL (or range) filter lets the optimiser use the spatial index for k-NN.
--#desc Press Explain to see the plan: look for the Spatial Index Seek on SIX_City_Geog.
--#view map
--#tags nearest neighbour, STDistance, TOP, ORDER BY, spatial index
DECLARE @here geography = geography::Point(51.6565, -0.3903, 4326);  -- Watford
SELECT TOP (15) c.Name, c.Population, [km] = ROUND(c.Geog.STDistance(@here) / 1000, 1), c.Geog, label = c.Name, color = '#e15759'
FROM world.City AS c
WHERE c.Geog.STDistance(@here) IS NOT NULL
ORDER BY c.Geog.STDistance(@here);
SELECT shape = @here, label = 'Watford', color = '#222';

--#demo Index versus scan: a benchmark
--#desc Builds lab.RandomPoints (500,000 points, once) and times windows from tiny to huge, with and without the spatial index.
--#desc Small windows love the index; huge windows are cheaper as a plain scan. Messages show the logical reads too.
--#tags spatial index, benchmark, SET STATISTICS IO, index hint
IF OBJECT_ID('lab.RandomPoints') IS NULL
BEGIN
    CREATE TABLE lab.RandomPoints (Id int NOT NULL CONSTRAINT PK_RandomPoints PRIMARY KEY, X float NOT NULL, Y float NOT NULL, Geom geometry NOT NULL);
    INSERT lab.RandomPoints (Id, X, Y, Geom)
    SELECT g.value, p.x, p.y, geometry::Point(p.x, p.y, 0)
    FROM GENERATE_SERIES(1, 500000) AS g
    CROSS APPLY (SELECT x = sx.Hash01(g.value, 1, 11) * 10000, y = sx.Hash01(g.value, 2, 11) * 10000) AS p;
    CREATE SPATIAL INDEX SIX_RandomPoints ON lab.RandomPoints (Geom)
        USING GEOMETRY_AUTO_GRID WITH (BOUNDING_BOX = (0, 0, 10000, 10000));
END;
DROP TABLE IF EXISTS #r;
CREATE TABLE #r ([window % of area] float, [rows] int, [with index ms] int, [scan ms] int);
DECLARE @pct float, @w geometry, @t datetime2, @n int, @msIdx int, @msScan int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM (VALUES (0.01), (0.1), (1.0), (10.0), (50.0)) AS t (v);
OPEN c; FETCH NEXT FROM c INTO @pct;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @w = geometry::Point(5000, 5000, 0).STBuffer(SQRT(@pct / 100 * 1e8 / PI()));
    SET @t = SYSDATETIME();
    SELECT @n = COUNT(*) FROM lab.RandomPoints WITH (INDEX (SIX_RandomPoints)) WHERE Geom.STIntersects(@w) = 1;
    SET @msIdx = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
    SET @t = SYSDATETIME();
    SELECT @n = COUNT(*) FROM lab.RandomPoints WITH (INDEX (PK_RandomPoints)) WHERE Geom.STIntersects(@w) = 1;
    SET @msScan = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
    INSERT #r VALUES (@pct, @n, @msIdx, @msScan);
    FETCH NEXT FROM c INTO @pct;
END
CLOSE c; DEALLOCATE c;
SELECT * FROM #r ORDER BY 1;

--#demo Columnstore as a spatial pre-filter
--#desc geometry can't live in a columnstore, but its X and Y can. Batch-mode bounding-box filtering on a columnstore, then an exact
--#desc STIntersects on the survivors, can beat a spatial index for big windows. A pattern worth knowing for analytics.
--#tags columnstore, batch mode, bounding box, STIntersects
IF OBJECT_ID('lab.RandomPoints') IS NULL
    THROW 50000, 'Run "Index versus scan: a benchmark" first - it builds lab.RandomPoints.', 1;
IF OBJECT_ID('lab.RandomPointsCS') IS NULL
BEGIN
    SELECT Id, X, Y INTO lab.RandomPointsCS FROM lab.RandomPoints;
    CREATE CLUSTERED COLUMNSTORE INDEX CCI_RandomPointsCS ON lab.RandomPointsCS;
END;
DECLARE @r float = 3000, @cx float = 5000, @cy float = 5000;
DECLARE @w geometry = geometry::Point(@cx, @cy, 0).STBuffer(@r);
DECLARE @t datetime2, @a int, @b int, @c int, @ta int, @tb int, @tc int;
SET @t = SYSDATETIME();
SELECT @a = COUNT(*) FROM lab.RandomPoints WITH (INDEX (SIX_RandomPoints)) WHERE Geom.STIntersects(@w) = 1;
SET @ta = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
-- exact circle test on plain numbers, all in batch mode
SELECT @b = COUNT(*) FROM lab.RandomPointsCS WHERE X BETWEEN @cx - @r AND @cx + @r AND Y BETWEEN @cy - @r AND @cy + @r
                                               AND (X - @cx) * (X - @cx) + (Y - @cy) * (Y - @cy) <= @r * @r;
SET @tb = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
-- bbox on columnstore, then the true geometry test for arbitrary shapes
SELECT @c = COUNT(*) FROM lab.RandomPointsCS AS cs JOIN lab.RandomPoints AS p ON p.Id = cs.Id
WHERE cs.X BETWEEN @cx - @r AND @cx + @r AND cs.Y BETWEEN @cy - @r AND @cy + @r AND p.Geom.STIntersects(@w) = 1;
SET @tc = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SELECT approach = 'spatial index + STIntersects', [rows] = @a, ms = @ta
UNION ALL SELECT 'columnstore, maths only', @b, @tb
UNION ALL SELECT 'columnstore bbox, then STIntersects', @c, @tc;
-- (the polygonal buffer is slightly smaller than the true circle, so the maths-only count can be a touch higher)

--#demo A custom grid: GEOMETRY_GRID with explicit levels
--#desc Build your own index with chosen grid densities and cells per object, then compare it with the auto grid via sp_help.
--#tags CREATE SPATIAL INDEX, GEOMETRY_GRID, GRIDS, CELLS_PER_OBJECT
DROP TABLE IF EXISTS lab.BuildingCopy;
SELECT BuildingId, Geom INTO lab.BuildingCopy FROM town.Building;
ALTER TABLE lab.BuildingCopy ADD CONSTRAINT PK_BuildingCopy PRIMARY KEY (BuildingId);
CREATE SPATIAL INDEX SIX_BuildingCopy ON lab.BuildingCopy (Geom)
    USING GEOMETRY_GRID
    WITH (BOUNDING_BOX = (-100, -100, 1300, 1300),
          GRIDS = (LEVEL_1 = LOW, LEVEL_2 = MEDIUM, LEVEL_3 = HIGH, LEVEL_4 = HIGH),
          CELLS_PER_OBJECT = 32);
SELECT i.name, t.tessellation_scheme, t.level_1_grid_desc, t.level_2_grid_desc, t.level_3_grid_desc, t.level_4_grid_desc, t.cells_per_object
FROM sys.spatial_indexes i JOIN sys.spatial_index_tessellations t ON t.object_id = i.object_id AND t.index_id = i.index_id
WHERE i.object_id = OBJECT_ID('lab.BuildingCopy');

--#demo Hilbert-ordered storage
--#desc Clustering rows by a Hilbert key puts nearby things on nearby pages. Here the POIs are joined in Hilbert order - the path never jumps far.
--#view plane
--#tags sx.HilbertKey, clustering, space-filling curve
WITH k AS (
    SELECT PoiId, Geom, h = sx.HilbertKey(CAST(Geom.STX / 1200 * 255 AS int), CAST(Geom.STY / 1200 * 255 AS int), 8)
    FROM town.POI)
SELECT shape = geometry::STGeomFromText('LINESTRING (' + STRING_AGG(CAST(CONCAT(sx.FormatNum(Geom.STX), ' ', sx.FormatNum(Geom.STY)) AS varchar(max)), ', ')
                                        WITHIN GROUP (ORDER BY h) + ')', 0), label = 'POIs visited in Hilbert order', color = '#e15759'
FROM k;
SELECT Geom, color = '#222' FROM town.POI;
