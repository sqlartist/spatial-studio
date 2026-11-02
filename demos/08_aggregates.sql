/* Spatial Studio demo pack 08 - Spatial aggregates */

--#demo The four aggregates side by side
--#desc UnionAggregate merges, CollectionAggregate just bags shapes together, EnvelopeAggregate boxes them, ConvexHullAggregate wraps them.
--#view plane
--#tags UnionAggregate, CollectionAggregate, EnvelopeAggregate, ConvexHullAggregate
DROP TABLE IF EXISTS #c;
SELECT Geom = geometry::Point(x, y, 0).STBuffer(r) INTO #c
FROM (VALUES (0, 0, 12), (18, 4, 10), (30, -8, 9), (8, 20, 7), (40, 15, 6)) AS v (x, y, r);
SELECT shape = sx.Translate(geometry::UnionAggregate(Geom), 0, 0),        label = 'UnionAggregate',      color = '#4e79a7' FROM #c;
SELECT shape = sx.Translate(geometry::CollectionAggregate(Geom), 90, 0),  label = 'CollectionAggregate', color = '#f28e2b',
       [type] = geometry::CollectionAggregate(Geom).STGeometryType() FROM #c;
SELECT shape = sx.Translate(geometry::EnvelopeAggregate(Geom), 0, -70),   label = 'EnvelopeAggregate',   color = '#59a14f' FROM #c;
SELECT shape = sx.Translate(geometry::ConvexHullAggregate(Geom), 90, -70),label = 'ConvexHullAggregate', color = '#e15759' FROM #c;
SELECT shape = sx.Translate(Geom, 0, -70), color = '#ffffff' FROM #c
UNION ALL SELECT sx.Translate(Geom, 90, -70), '#ffffff' FROM #c;

--#demo Dissolve countries into a region
--#desc geography::UnionAggregate stitches neighbouring countries into one shape: here, every country whose centre lies in a box over Europe.
--#view map
--#tags UnionAggregate, geography, EnvelopeCenter
SELECT shape = geography::UnionAggregate(Geog), label = 'Europe-ish', color = '#4e79a7', countries = COUNT(*)
FROM world.Country
WHERE Geog.EnvelopeCenter().Long BETWEEN -11 AND 32 AND Geog.EnvelopeCenter().Lat BETWEEN 35 AND 71 AND Name NOT IN ('Russia');

--#demo Per-group convex hulls
--#desc ConvexHullAggregate with GROUP BY: one hull for each kind of point of interest.
--#view plane
--#tags ConvexHullAggregate, GROUP BY
SELECT Kind, shape = geometry::ConvexHullAggregate(Geom), label = Kind, n = COUNT(*),
       color = CASE Kind WHEN 'School' THEN '#4e79a7' WHEN 'Cafe' THEN '#f28e2b' WHEN 'Pharmacy' THEN '#e15759' WHEN 'Bus Stop' THEN '#59a14f' ELSE '#b07aa1' END
FROM town.POI GROUP BY Kind;

--#demo Bounding box of a country's cities
--#desc geography::EnvelopeAggregate returns a bounding polygon on the globe; compare it with the country itself.
--#view map
--#tags EnvelopeAggregate, geography
DECLARE @id int = (SELECT CountryId FROM world.Country WHERE Name = 'Japan');
SELECT shape = geography::EnvelopeAggregate(Geog), label = 'EnvelopeAggregate of cities', color = '#f1ce63' FROM world.City WHERE CountryId = @id;
SELECT Geog, color = '#4e79a7' FROM world.Country WHERE CountryId = @id;
SELECT Geog, color = '#e15759' FROM world.City WHERE CountryId = @id AND Population > 300000;

--#demo Footprint per block
--#desc UnionAggregate of every building in a block, then the share of the block that is built on - a choropleth from aggregates.
--#view plane
--#tags UnionAggregate, STArea, choropleth
SELECT bl.Geom, label = CONCAT(ROUND(100 * f.built / bl.Geom.STArea(), 0), '%'),
       color = CONCAT('hsl(20,70%,', 95 - ROUND(250 * ISNULL(f.built, 0) / bl.Geom.STArea(), 0), '%)')
FROM town.Block AS bl
OUTER APPLY (SELECT built = geometry::UnionAggregate(b.Geom).STArea() FROM town.Building AS b WHERE b.BlockId = bl.BlockId) AS f;
