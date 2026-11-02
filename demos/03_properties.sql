/* Spatial Studio demo pack 03 - Properties and accessors */

--#demo Geometry types and dimensions
--#desc STGeometryType() names the type; STDimension() is 0 for points, 1 for curves, 2 for surfaces (-1 when empty).
--#tags STGeometryType, STDimension, InstanceOf
SELECT wkt, [STGeometryType] = g.STGeometryType(), [STDimension] = g.STDimension(),
       [InstanceOf('Curve')] = g.InstanceOf('Curve'), [InstanceOf('Surface')] = g.InstanceOf('Surface'),
       [InstanceOf('MultiSurface')] = g.InstanceOf('MultiSurface')
FROM (VALUES
    ('POINT (0 0)'), ('MULTIPOINT ((0 0), (1 1))'), ('LINESTRING (0 0, 1 1)'), ('CIRCULARSTRING (0 0, 1 1, 2 0)'),
    ('COMPOUNDCURVE ((0 0, 1 0), CIRCULARSTRING (1 0, 2 1, 3 0))'), ('MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))'),
    ('POLYGON ((0 0, 1 0, 1 1, 0 0))'), ('CURVEPOLYGON (CIRCULARSTRING (0 0, 1 1, 2 0, 1 -1, 0 0))'),
    ('MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((2 2, 3 2, 3 3, 2 2)))'), ('GEOMETRYCOLLECTION (POINT (0 0), LINESTRING (0 0, 1 1))'),
    ('POINT EMPTY')) AS v (wkt)
CROSS APPLY (SELECT g = geometry::STGeomFromText(v.wkt, 0)) AS x;

--#demo Walking the points of a line
--#desc STNumPoints, STPointN, STStartPoint and STEndPoint. Every vertex labelled with its index.
--#view plane
--#tags STNumPoints, STPointN, STStartPoint, STEndPoint, STX, STY
DECLARE @l geometry = 'LINESTRING (0 0, 40 30, 80 10, 120 50, 160 20, 200 60)';
SELECT shape = @l, color = '#4e79a7';
SELECT shape = @l.STPointN(g.value), label = CONCAT('STPointN(', g.value, ') = ', @l.STPointN(g.value).STX, ', ', @l.STPointN(g.value).STY), color = '#f28e2b'
FROM GENERATE_SERIES(1, @l.STNumPoints()) AS g;
SELECT shape = @l.STStartPoint().STBuffer(6), label = 'STStartPoint', color = '#59a14f'
UNION ALL SELECT @l.STEndPoint().STBuffer(6), 'STEndPoint', '#e15759';

--#demo Rings: exterior and interior
--#desc A courtyard building is a polygon with a hole. STExteriorRing, STNumInteriorRing and STInteriorRingN pull it apart.
--#view plane
--#tags STExteriorRing, STNumInteriorRing, STInteriorRingN
DECLARE @b geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'Courtyard' ORDER BY BuildingId);
SELECT shape = @b, label = 'polygon', color = '#bab0ac';
SELECT shape = @b.STExteriorRing(), label = 'STExteriorRing()', color = '#4e79a7';
SELECT shape = @b.STInteriorRingN(1), label = CONCAT('STInteriorRingN(1) of ', @b.STNumInteriorRing()), color = '#e15759';

--#demo Collections: STNumGeometries and STGeometryN
--#desc Many countries are MULTIPOLYGONs. Pull Indonesia apart island by island and rank them by area.
--#view map
--#tags STNumGeometries, STGeometryN, STArea, geography
DECLARE @c geography = (SELECT Geog FROM world.Country WHERE Name = 'Indonesia');
SELECT part = g.value, shape = @c.STGeometryN(g.value), areaKm2 = ROUND(@c.STGeometryN(g.value).STArea() / 1e6, 0),
       label = CONCAT('#', g.value), color = CONCAT('hsl(', g.value * 37 % 360, ',60%,55%)')
FROM GENERATE_SERIES(1, @c.STNumGeometries()) AS g
ORDER BY areaKm2 DESC;

--#demo Boundary and envelope
--#desc STBoundary of a polygon is its rings; of a line, its two end points. STEnvelope is the axis-aligned bounding box.
--#view plane
--#tags STBoundary, STEnvelope
DECLARE @p geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'LShape' ORDER BY BuildingId);
DECLARE @l geometry = 'LINESTRING (0 0, 10 8, 20 2)';
SET @l = sx.Translate(@l, @p.STEnvelope().STPointN(1).STX - 30, @p.STEnvelope().STPointN(1).STY);
SELECT shape = @p.STEnvelope(), label = 'STEnvelope()', color = '#f1ce63';
SELECT shape = @p, label = 'polygon', color = '#bab0ac';
SELECT shape = @p.STBoundary(), label = 'STBoundary() of polygon', color = '#4e79a7';
SELECT shape = @l, label = 'line', color = '#888';
SELECT shape = @l.STBoundary(), label = 'STBoundary() of line', color = '#e15759';

--#demo Centroid versus point on surface
--#desc STCentroid is the centre of mass - for a U-shaped building it falls in the courtyard, outside the building.
--#desc STPointOnSurface is guaranteed to be inside. Use it for labels and point-in-polygon tests.
--#view plane
--#tags STCentroid, STPointOnSurface, STContains
DECLARE @u geometry = (SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'UShape' ORDER BY BuildingId);
SELECT shape = @u, color = '#bab0ac';
SELECT shape = @u.STCentroid().STBuffer(0.8), label = CONCAT('STCentroid - inside? ', @u.STContains(@u.STCentroid())), color = '#e15759'
UNION ALL
SELECT @u.STPointOnSurface().STBuffer(0.8), CONCAT('STPointOnSurface - inside? ', @u.STContains(@u.STPointOnSurface())), '#59a14f';

--#demo Area and length
--#desc geometry measures in the units of its coordinates (metres in Sqlford). geography always returns square metres and metres.
--#tags STArea, STLength
SELECT TOP (10) BuildingId, Kind, [area m2] = ROUND(Geom.STArea(), 1), [perimeter m] = ROUND(Geom.STLength(), 1),
       [compactness 4piA/P2] = ROUND(4 * PI() * Geom.STArea() / SQUARE(Geom.STLength()), 3)
FROM town.Building ORDER BY Geom.STArea() DESC;
SELECT TOP (10) Name, [area km2] = ROUND(Geog.STArea() / 1e6, 0), [border length km] = ROUND(Geog.STLength() / 1000, 0)
FROM world.Country ORDER BY Geog.STArea() DESC;

--#demo Simple, closed and ring
--#desc STIsSimple: no self-intersection. STIsClosed: start = end. STIsRing: both.
--#view plane
--#tags STIsSimple, STIsClosed, STIsRing
SELECT name, shape = g, [STIsSimple] = g.STIsSimple(), [STIsClosed] = g.STIsClosed(), [STIsRing] = g.STIsRing(), label = name
FROM (VALUES
    ('open line',      geometry::STGeomFromText('LINESTRING (0 0, 20 10, 40 0)', 0)),
    ('closed ring',    geometry::STGeomFromText('LINESTRING (60 0, 80 0, 80 20, 60 20, 60 0)', 0)),
    ('figure of eight',geometry::STGeomFromText('LINESTRING (100 0, 120 20, 120 0, 100 20, 100 0)', 0)),
    ('self-crossing',  geometry::STGeomFromText('LINESTRING (140 0, 170 20, 170 0, 140 15)', 0))
) AS v (name, g);

--#demo Validity: IsValidDetailed and MakeValid
--#desc A bow-tie polygon crosses itself. SQL Server will store it, but most operations refuse until you call MakeValid().
--#view plane
--#tags STIsValid, IsValidDetailed, MakeValid
DECLARE @bow geometry = geometry::STGeomFromText('POLYGON ((0 0, 40 40, 40 0, 0 40, 0 0))', 0);
SELECT [STIsValid] = @bow.STIsValid(), [IsValidDetailed] = @bow.IsValidDetailed(),
       [MakeValid type] = @bow.MakeValid().STGeometryType(), [MakeValid WKT] = @bow.MakeValid().ToString();
SELECT shape = @bow, label = 'invalid bow-tie', color = '#e15759';
SELECT shape = sx.Translate(@bow.MakeValid(), 60, 0), label = 'MakeValid(): two triangles', color = '#59a14f';

--#demo Describe everything about a shape
--#desc sx.Describe and sx.DescribeGeog run every property method at once.
--#tags sx.Describe, sx.DescribeGeog, MinDbCompatibilityLevel
SELECT * FROM sx.Describe((SELECT TOP (1) Geom FROM town.Building WHERE Kind = 'TShape' ORDER BY BuildingId));
SELECT * FROM sx.DescribeGeog((SELECT Geog FROM world.Country WHERE Name = 'United Kingdom'));

--#demo Compatibility level of a shape
--#desc Curves need compatibility level 110+. MinDbCompatibilityLevel() tells you whether a shape can travel to an older server.
--#tags MinDbCompatibilityLevel
SELECT wkt, [MinDbCompatibilityLevel] = geometry::STGeomFromText(wkt, 0).MinDbCompatibilityLevel()
FROM (VALUES ('POINT (1 1)'), ('POLYGON ((0 0, 1 0, 1 1, 0 0))'), ('CIRCULARSTRING (0 0, 1 1, 2 0)'),
             ('CURVEPOLYGON (CIRCULARSTRING (0 0, 1 1, 2 0, 1 -1, 0 0))')) AS v (wkt);
