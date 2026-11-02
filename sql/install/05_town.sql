/* ==========================================================================
   Spatial Studio - 05 generate "Sqlford", a planar test town (SRID 0, metres)
   10 x 10 blocks of 100 m with 20 m roads, ~800 buildings in ten footprint
   types at random rotations and sizes, a river made of circular arcs, parks
   with curved ponds, points of interest and a SQL Graph road network.
   Everything is deterministic: every install builds the same town.
   ========================================================================== */
USE SpatialStudio;
GO
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'VIX_BuildingShapeAnn_Fourier')
    DROP INDEX VIX_BuildingShapeAnn_Fourier ON town.BuildingShapeAnn;
DELETE town.BuildingShapeAnn; DELETE town.BuildingShape; DELETE town.RoadLink; DELETE town.RoadNode;
DELETE town.POI; DELETE town.Park; DELETE town.River; DELETE town.Road; DELETE town.Building; DELETE town.Block; DELETE town.ShapeTemplate;
GO

/* ---- footprint templates in a unit box (-1..1); first vertex repeated to close the ring ---- */
INSERT town.ShapeTemplate (Kind, Ring, Seq, X, Y) VALUES
('Square',1,1,-1,-1),('Square',1,2,1,-1),('Square',1,3,1,1),('Square',1,4,-1,1),('Square',1,5,-1,-1),
('Rectangle',1,1,-1,-0.5),('Rectangle',1,2,1,-0.5),('Rectangle',1,3,1,0.5),('Rectangle',1,4,-1,0.5),('Rectangle',1,5,-1,-0.5),
('LShape',1,1,-1,-1),('LShape',1,2,1,-1),('LShape',1,3,1,-0.2),('LShape',1,4,-0.2,-0.2),('LShape',1,5,-0.2,1),('LShape',1,6,-1,1),('LShape',1,7,-1,-1),
('TShape',1,1,-0.3,-1),('TShape',1,2,0.3,-1),('TShape',1,3,0.3,0.4),('TShape',1,4,1,0.4),('TShape',1,5,1,1),('TShape',1,6,-1,1),('TShape',1,7,-1,0.4),('TShape',1,8,-0.3,0.4),('TShape',1,9,-0.3,-1),
('UShape',1,1,-1,-1),('UShape',1,2,1,-1),('UShape',1,3,1,1),('UShape',1,4,0.4,1),('UShape',1,5,0.4,-0.4),('UShape',1,6,-0.4,-0.4),('UShape',1,7,-0.4,1),('UShape',1,8,-1,1),('UShape',1,9,-1,-1),
('Plus',1,1,-0.35,-1),('Plus',1,2,0.35,-1),('Plus',1,3,0.35,-0.35),('Plus',1,4,1,-0.35),('Plus',1,5,1,0.35),('Plus',1,6,0.35,0.35),('Plus',1,7,0.35,1),('Plus',1,8,-0.35,1),('Plus',1,9,-0.35,0.35),('Plus',1,10,-1,0.35),('Plus',1,11,-1,-0.35),('Plus',1,12,-0.35,-0.35),('Plus',1,13,-0.35,-1),
('Triangle',1,1,-1,-0.8),('Triangle',1,2,1,-0.8),('Triangle',1,3,0,1),('Triangle',1,4,-1,-0.8),
('Hexagon',1,1,1,0),('Hexagon',1,2,0.5,0.866025),('Hexagon',1,3,-0.5,0.866025),('Hexagon',1,4,-1,0),('Hexagon',1,5,-0.5,-0.866025),('Hexagon',1,6,0.5,-0.866025),('Hexagon',1,7,1,0),
('Courtyard',1,1,-1,-1),('Courtyard',1,2,1,-1),('Courtyard',1,3,1,1),('Courtyard',1,4,-1,1),('Courtyard',1,5,-1,-1),
('Courtyard',2,1,-0.45,-0.45),('Courtyard',2,2,-0.45,0.45),('Courtyard',2,3,0.45,0.45),('Courtyard',2,4,0.45,-0.45),('Courtyard',2,5,-0.45,-0.45);
GO

/* ---- blocks and zoning ---- */
INSERT town.Block (BlockId, Col, Row, ZoneKind, Geom)
SELECT r.value * 10 + c.value + 1, c.value, r.value,
       CASE WHEN h.v < 0.10 THEN 'Park' WHEN h.v < 0.25 THEN 'Commercial' WHEN h.v < 0.35 THEN 'Industrial' ELSE 'Residential' END,
       geometry::STPolyFromText(CONCAT('POLYGON ((', x0, ' ', y0, ', ', x0 + 100, ' ', y0, ', ', x0 + 100, ' ', y0 + 100, ', ', x0, ' ', y0 + 100, ', ', x0, ' ', y0, '))'), 0)
FROM GENERATE_SERIES(0, 9) AS c
CROSS JOIN GENERATE_SERIES(0, 9) AS r
CROSS APPLY (SELECT x0 = c.value * 120 + 10, y0 = r.value * 120 + 10, v = sx.Hash01(c.value, r.value, 1)) AS h;
GO

/* ---- buildings: 3 x 3 slots per non-park block ---- */
DROP TABLE IF EXISTS #b;
SELECT BuildingId = ROW_NUMBER() OVER (ORDER BY p.BlockId, p.si, p.sj), p.*
INTO #b
FROM
(
    SELECT b.BlockId, si = s1.value, sj = s2.value,
           cx   = b.Col * 120 + 10 + 16.667 + s1.value * 33.333 + (sx.Hash01(n.slot, 1, 2) - 0.5) * 4,
           cy   = b.Row * 120 + 10 + 16.667 + s2.value * 33.333 + (sx.Hash01(n.slot, 2, 2) - 0.5) * 4,
           Kind = CHOOSE(1 + CAST(FLOOR(sx.Hash01(n.slot, 3, 2) * 10) AS INT),
                         'Square', 'Rectangle', 'LShape', 'TShape', 'UShape', 'Plus', 'Triangle', 'Hexagon', 'Courtyard', 'Circle'),
           Rotation = ROUND(sx.Hash01(n.slot, 4, 2) * 360, 1),
           Scale    = ROUND(7 + sx.Hash01(n.slot, 5, 2) * 3, 2),
           Floors   = 1 + CAST(FLOOR(sx.Hash01(n.slot, 6, 2) * 12) AS INT),
           Skip     = CASE WHEN sx.Hash01(n.slot, 7, 2) < 0.12 THEN 1 ELSE 0 END
    FROM town.Block AS b
    CROSS JOIN GENERATE_SERIES(0, 2) AS s1
    CROSS JOIN GENERATE_SERIES(0, 2) AS s2
    CROSS APPLY (SELECT slot = b.BlockId * 9 + s1.value * 3 + s2.value) AS n
    WHERE b.ZoneKind <> 'Park'
) AS p
WHERE p.Skip = 0;

-- Rotate + scale + translate each template vertex set-based, then stitch rings and polygons with STRING_AGG
WITH v AS
(
    SELECT b.BuildingId, t.Ring, t.Seq,
           X = b.cx + b.Scale * (t.X * COS(RADIANS(b.Rotation)) - t.Y * SIN(RADIANS(b.Rotation))),
           Y = b.cy + b.Scale * (t.X * SIN(RADIANS(b.Rotation)) + t.Y * COS(RADIANS(b.Rotation)))
    FROM #b AS b
    JOIN town.ShapeTemplate AS t ON t.Kind = b.Kind
),
rings AS
(
    SELECT BuildingId, Ring,
           RingText = '(' + STRING_AGG(CAST(CONCAT(sx.FormatNum(X), ' ', sx.FormatNum(Y)) AS VARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY Seq) + ')'
    FROM v
    GROUP BY BuildingId, Ring
),
polys AS
(
    SELECT BuildingId, Wkt = 'POLYGON (' + STRING_AGG(RingText, ', ') WITHIN GROUP (ORDER BY Ring) + ')'
    FROM rings
    GROUP BY BuildingId
)
INSERT town.Building (BuildingId, BlockId, Kind, Rotation, Scale, Floors, Geom)
SELECT b.BuildingId, b.BlockId, b.Kind, b.Rotation, b.Scale, b.Floors,
       CASE WHEN b.Kind = 'Circle' THEN geometry::Point(b.cx, b.cy, 0).STBuffer(b.Scale)
            ELSE geometry::STGeomFromText(p.Wkt, 0) END
FROM #b AS b
LEFT JOIN polys AS p ON p.BuildingId = b.BuildingId;
GO

/* ---- the River Query: straight reaches joined by circular arcs ---- */
INSERT town.River (RiverId, Name, Geom) VALUES
(1, N'River Query', geometry::STGeomFromText(
 'COMPOUNDCURVE ((-60 300, 200 330), CIRCULARSTRING (200 330, 430 410, 520 640), (520 640, 690 700), CIRCULARSTRING (690 700, 900 690, 1000 900), (1000 900, 1260 1010))', 0));

-- Nobody builds in the river
DELETE b FROM town.Building AS b CROSS JOIN town.River AS r WHERE b.Geom.STDistance(r.Geom) < 14;
GO

/* ---- roads ---- */
INSERT town.Road (RoadId, Name, Geom)
SELECT g.value + 1, CONCAT(N'Street ', g.value), geometry::STLineFromText(CONCAT('LINESTRING (0 ', g.value * 120, ', 1200 ', g.value * 120, ')'), 0)
FROM GENERATE_SERIES(0, 10) AS g
UNION ALL
SELECT g.value + 101, CONCAT(N'Avenue ', g.value), geometry::STLineFromText(CONCAT('LINESTRING (', g.value * 120, ' 0, ', g.value * 120, ' 1200)'), 0)
FROM GENERATE_SERIES(0, 10) AS g;
GO

/* ---- parks with curved ponds (CURVEPOLYGON) ---- */
INSERT town.Park (ParkId, BlockId, Name, Geom, Pond)
SELECT ROW_NUMBER() OVER (ORDER BY b.BlockId), b.BlockId, CONCAT(N'Park ', b.Col, N'-', b.Row), b.Geom,
       geometry::STGeomFromText(CONCAT('CURVEPOLYGON (CIRCULARSTRING (',
            cx - 28, ' ', cy, ', ', cx, ' ', cy + 18, ', ', cx + 28, ' ', cy, ', ', cx, ' ', cy - 18, ', ', cx - 28, ' ', cy, '))'), 0)
FROM town.Block AS b
CROSS APPLY (SELECT cx = b.Col * 120 + 60, cy = b.Row * 120 + 60) AS c
WHERE b.ZoneKind = 'Park';
GO

/* ---- points of interest ---- */
INSERT town.POI (PoiId, Kind, Name, Geom)
SELECT g.value, k.Kind, CONCAT(k.Kind, N' ', g.value),
       geometry::Point(ROUND(5 + sx.Hash01(g.value, 1, 3) * 1190, 1), ROUND(5 + sx.Hash01(g.value, 2, 3) * 1190, 1), 0)
FROM GENERATE_SERIES(1, 80) AS g
CROSS APPLY (SELECT Kind = CHOOSE(1 + g.value % 5, 'School', 'Cafe', 'Pharmacy', 'Bus Stop', 'Library')) AS k;
GO

/* ---- SQL Graph road network ---- */
INSERT town.RoadNode (NodeId, NodeKey, Col, Row, X, Y, Geom)
SELECT r.value * 11 + c.value + 1, CAST(r.value * 11 + c.value + 1 AS VARCHAR(10)), c.value, r.value, c.value * 120, r.value * 120, geometry::Point(c.value * 120, r.value * 120, 0)
FROM GENERATE_SERIES(0, 10) AS c CROSS JOIN GENERATE_SERIES(0, 10) AS r;

DROP TABLE IF EXISTS #links;
SELECT FromId = a.NodeId, ToId = b.NodeId,
       Geom = geometry::STLineFromText(CONCAT('LINESTRING (', a.X, ' ', a.Y, ', ', b.X, ' ', b.Y, ')'), 0),
       CrossesRiver = CAST(0 AS BIT)
INTO #links
FROM town.RoadNode AS a
JOIN town.RoadNode AS b ON (b.Col = a.Col + 1 AND b.Row = a.Row) OR (b.Col = a.Col AND b.Row = a.Row + 1);

UPDATE l SET CrossesRiver = 1 FROM #links AS l CROSS JOIN town.River AS r WHERE l.Geom.STIntersects(r.Geom) = 1;
-- Only some crossings get a bridge; the rest of the road stops at the water
DELETE FROM #links WHERE CrossesRiver = 1 AND sx.Hash01(FromId, ToId, 9) >= 0.3;

INSERT town.RoadLink ($from_id, $to_id, LengthM, IsBridge, Geom)
SELECT a.$node_id, b.$node_id, l.Geom.STLength(), l.CrossesRiver, l.Geom
FROM #links AS l JOIN town.RoadNode AS a ON a.NodeId = l.FromId JOIN town.RoadNode AS b ON b.NodeId = l.ToId
UNION ALL
SELECT b.$node_id, a.$node_id, l.Geom.STLength(), l.CrossesRiver, l.Geom
FROM #links AS l JOIN town.RoadNode AS a ON a.NodeId = l.FromId JOIN town.RoadNode AS b ON b.NodeId = l.ToId;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'SIX_Building_Geom')
    CREATE SPATIAL INDEX SIX_Building_Geom ON town.Building (Geom)
    USING GEOMETRY_AUTO_GRID WITH (BOUNDING_BOX = (-100, -100, 1300, 1300));
GO
DECLARE @nb INT = (SELECT COUNT(*) FROM town.Building),
        @nl INT = (SELECT COUNT(*) FROM town.RoadLink),
        @nbr INT = (SELECT COUNT(*) FROM town.RoadLink WHERE IsBridge = 1) / 2;
PRINT CONCAT('Town built: ', @nb, ' buildings, ', @nl, ' directed road links, ', @nbr, ' bridges');
