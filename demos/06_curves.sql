/* Spatial Studio demo pack 06 - Circular arcs and curves */

--#demo The three curve types
--#desc CIRCULARSTRING: arcs through every three points. COMPOUNDCURVE: lines and arcs joined end to end.
--#desc CURVEPOLYGON: a polygon whose rings can be curves. The viewer draws the true arcs.
--#view plane
--#tags CIRCULARSTRING, COMPOUNDCURVE, CURVEPOLYGON
SELECT shape = geometry::STGeomFromText('CIRCULARSTRING (0 0, 20 20, 40 0, 60 -20, 80 0)', 0), label = 'CIRCULARSTRING', color = '#4e79a7'
UNION ALL
SELECT geometry::STGeomFromText('COMPOUNDCURVE ((100 0, 130 0), CIRCULARSTRING (130 0, 145 15, 130 30), (130 30, 100 30))', 0), 'COMPOUNDCURVE', '#e15759'
UNION ALL
SELECT geometry::STGeomFromText('CURVEPOLYGON (COMPOUNDCURVE (CIRCULARSTRING (170 0, 190 20, 210 0), (210 0, 170 0)), (180 2, 200 2, 190 10, 180 2))', 0), 'CURVEPOLYGON with a hole', '#59a14f';

--#demo Counting and extracting curves
--#desc STNumCurves and STCurveN walk the pieces of a curve; each arc counts as one curve.
--#view plane
--#tags STNumCurves, STCurveN
DECLARE @c geometry = 'COMPOUNDCURVE ((0 0, 30 0), CIRCULARSTRING (30 0, 45 15, 30 30), (30 30, 0 30), CIRCULARSTRING (0 30, -10 15, 0 0))';
SELECT n = g.value, piece = @c.STCurveN(g.value), [type] = @c.STCurveN(g.value).STGeometryType(),
       label = CONCAT('STCurveN(', g.value, ')'), color = CONCAT('hsl(', g.value * 80, ',65%,50%)')
FROM GENERATE_SERIES(1, @c.STNumCurves()) AS g;

--#demo Curves to lines
--#desc STCurveToLine uses a default tolerance; CurveToLineWithTolerance lets you choose. Fewer vertices, more error.
--#view plane
--#tags STCurveToLine, CurveToLineWithTolerance, STNumPoints
DECLARE @circle geometry = 'CIRCULARSTRING (0 0, 50 50, 100 0, 50 -50, 0 0)';
SELECT shape = @circle, label = 'true arc', color = '#bab0ac';
SELECT shape = sx.Translate(@circle.STCurveToLine(), 130, 0), label = CONCAT('STCurveToLine: ', @circle.STCurveToLine().STNumPoints(), ' pts'), color = '#4e79a7'
UNION ALL SELECT sx.Translate(@circle.CurveToLineWithTolerance(2, 0), 260, 0),  CONCAT('tolerance 2: ', @circle.CurveToLineWithTolerance(2, 0).STNumPoints(), ' pts'), '#f28e2b'
UNION ALL SELECT sx.Translate(@circle.CurveToLineWithTolerance(10, 0), 390, 0), CONCAT('tolerance 10: ', @circle.CurveToLineWithTolerance(10, 0).STNumPoints(), ' pts'), '#e15759';

--#demo BufferWithCurves versus STBuffer
--#desc A buffer made of arcs is exact and tiny on disk. STBuffer approximates the arcs with many vertices.
--#view plane
--#tags BufferWithCurves, STBuffer, DATALENGTH
DECLARE @river geometry = (SELECT Geom FROM town.River);
SELECT shape = @river.BufferWithCurves(40), label = 'BufferWithCurves(40)', color = '#a0cbe8';
SELECT shape = @river, color = '#2f7fd0';
SELECT [method] = 'BufferWithCurves(40)', [type] = @river.BufferWithCurves(40).STGeometryType(),
       [points] = @river.BufferWithCurves(40).STNumPoints(), [bytes] = DATALENGTH(@river.BufferWithCurves(40)),
       [area m2] = ROUND(@river.BufferWithCurves(40).STArea(), 0)
UNION ALL
SELECT 'STBuffer(40)', @river.STBuffer(40).STGeometryType(), @river.STBuffer(40).STNumPoints(),
       DATALENGTH(@river.STBuffer(40)), ROUND(@river.STBuffer(40).STArea(), 0);

--#demo A circle that measures itself
--#desc A full circle as a CIRCULARSTRING has exact length 2 pi r; its polygon approximation is a little short.
--#tags CIRCULARSTRING, STLength, CURVEPOLYGON, STArea
DECLARE @r float = 50;
DECLARE @arc geometry = 'CIRCULARSTRING (-50 0, 0 50, 50 0, 0 -50, -50 0)';
DECLARE @disc geometry = 'CURVEPOLYGON (CIRCULARSTRING (-50 0, 0 50, 50 0, 0 -50, -50 0))';
SELECT [2 pi r] = 2 * PI() * @r, [arc STLength] = @arc.STLength(), [lines STLength] = @arc.STCurveToLine().STLength(),
       [pi r2] = PI() * @r * @r, [curve polygon STArea] = @disc.STArea(), [buffered point STArea] = geometry::Point(0, 0, 0).STBuffer(50).STArea();

--#demo Curves on the globe
--#desc geography supports arcs too. A CIRCULARSTRING on the sphere is a small circle, not a great circle.
--#view map
--#tags geography, CIRCULARSTRING, CURVEPOLYGON
SELECT shape = geography::STGeomFromText('CIRCULARSTRING (-10 50, 0 55, 10 50)', 4326), label = 'geography CIRCULARSTRING', color = '#e15759'
UNION ALL
SELECT geography::STGeomFromText('LINESTRING (-10 50, 10 50)', 4326), 'geodesic LINESTRING, same ends', '#4e79a7';

--#demo Ponds: curve polygons in real data
--#desc Every park in Sqlford has a pond stored as a CURVEPOLYGON. Their areas come straight from the arc maths.
--#view plane
--#tags CURVEPOLYGON, STArea
SELECT p.Geom, color = '#8cc084' FROM town.Park AS p;
SELECT p.Pond, label = CONCAT(p.Name, ': ', ROUND(p.Pond.STArea(), 0), ' m2'), color = '#79b8e8', [type] = p.Pond.STGeometryType()
FROM town.Park AS p;
