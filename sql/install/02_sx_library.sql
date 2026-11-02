/* ==========================================================================
   Spatial Studio - 02 the "sx" spatial extension library (pure T-SQL)
   Things SQL Server's geometry/geography types don't give you out of the box:
     number formatting, coordinate rewriting (affine / Web Mercator / axis swap),
     geography<->geometry, GeoJSON in and out (OPENJSON / JSON functions),
     bearings, destinations, great circles, geohash, Hilbert keys,
     square & hex grids, Voronoi half-planes, shape descriptors for vector search.
   ========================================================================== */
USE SpatialStudio;
GO

/* ---------- small helpers ---------- */
CREATE OR ALTER FUNCTION sx.FormatNum (@f FLOAT)
RETURNS VARCHAR(50)
WITH SCHEMABINDING
AS
BEGIN
    IF @f IS NULL RETURN NULL;
    DECLARE @s VARCHAR(50) = CONVERT(VARCHAR(50), CAST(ROUND(@f, 9) AS DECIMAL(38, 9)));
    SET @s = LEFT(@s, LEN(@s) - PATINDEX('%[^0]%', REVERSE(@s)) + 1);   -- trim trailing zeros
    IF RIGHT(@s, 1) = '.' SET @s = LEFT(@s, LEN(@s) - 1);
    IF @s = '-0' SET @s = '0';
    RETURN @s;
END;
GO

-- Deterministic pseudo-random number in [0,1) - the old GLSL hash. Same inputs, same town, every install.
CREATE OR ALTER FUNCTION sx.Hash01 (@a FLOAT, @b FLOAT, @salt FLOAT)
RETURNS FLOAT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @x FLOAT = SIN(@a * 12.9898 + @b * 78.233 + @salt * 37.719) * 43758.5453;
    RETURN @x - FLOOR(@x);
END;
GO

CREATE OR ALTER FUNCTION sx.EnvelopeCentre (@g GEOMETRY)
RETURNS GEOMETRY
AS
BEGIN
    IF @g IS NULL OR @g.STIsEmpty() = 1 RETURN NULL;
    DECLARE @e GEOMETRY = @g.STEnvelope();
    DECLARE @p1 GEOMETRY = @e.STPointN(1), @p2 GEOMETRY = @e.STPointN(@e.STNumPoints() / 2 + 1);
    RETURN geometry::Point((@p1.STX + @p2.STX) / 2, (@p1.STY + @p2.STY) / 2, @g.STSrid);
END;
GO

/* ---------- coordinate rewriting ----------
   Splits WKT on commas (each piece holds exactly one coordinate), rewrites the X/Y of every
   coordinate set-based, and stitches it back together. Z and M ride along untouched.
   @mode 0 = affine  x' = a*x + b*y + c ; y' = d*x + e*y + f
         1 = lon/lat degrees -> Web Mercator metres (EPSG:3857)
         2 = Web Mercator metres -> lon/lat degrees
         3 = swap X and Y                                                       */
CREATE OR ALTER FUNCTION sx.TransformWkt
(
    @wkt NVARCHAR(MAX), @mode TINYINT,
    @a FLOAT, @b FLOAT, @c FLOAT, @d FLOAT, @e FLOAT, @f FLOAT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out NVARCHAR(MAX);
    SELECT @out = STRING_AGG(CAST(p.Piece AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY s.ordinal)
    FROM STRING_SPLIT(@wkt, N',', 1) AS s
    CROSS APPLY (SELECT L = DATALENGTH(s.value) / 2, lp = CHARINDEX(N'(', REVERSE(s.value))) AS a
    CROSS APPLY (SELECT Prefix = CASE WHEN a.lp = 0 THEN CAST(N'' AS NVARCHAR(MAX)) ELSE LEFT(s.value, a.L - a.lp + 1) END) AS b
    CROSS APPLY (SELECT Rest = SUBSTRING(s.value, DATALENGTH(b.Prefix) / 2 + 1, a.L)) AS c
    CROSS APPLY (SELECT rp = CHARINDEX(N')', c.Rest)) AS d
    CROSS APPLY (SELECT Coord  = CASE WHEN d.rp = 0 THEN c.Rest ELSE LEFT(c.Rest, d.rp - 1) END,
                        Suffix = CASE WHEN d.rp = 0 THEN N'' ELSE SUBSTRING(c.Rest, d.rp, a.L) END) AS e
    CROSS APPLY (SELECT Lead = CASE WHEN LEFT(e.Coord, 1) = N' ' THEN N' ' ELSE N'' END,
                        Ct   = LTRIM(RTRIM(e.Coord))) AS f
    CROSS APPLY (SELECT sp1 = CHARINDEX(N' ', f.Ct)) AS g
    CROSS APPLY (SELECT Xs     = CASE WHEN g.sp1 > 0 THEN LEFT(f.Ct, g.sp1 - 1) END,
                        AfterX = CASE WHEN g.sp1 > 0 THEN SUBSTRING(f.Ct, g.sp1 + 1, a.L) END) AS h
    CROSS APPLY (SELECT sp2 = CHARINDEX(N' ', h.AfterX)) AS i
    CROSS APPLY (SELECT Ys    = CASE WHEN i.sp2 > 0 THEN LEFT(h.AfterX, i.sp2 - 1) ELSE h.AfterX END,
                        Extra = CASE WHEN i.sp2 > 0 THEN SUBSTRING(h.AfterX, i.sp2, a.L) ELSE N'' END) AS j
    CROSS APPLY (SELECT X = TRY_CAST(h.Xs AS FLOAT), Y = TRY_CAST(j.Ys AS FLOAT)) AS k
    CROSS APPLY (SELECT YClamp = CASE WHEN k.Y > 85.0511287798 THEN 85.0511287798
                                      WHEN k.Y < -85.0511287798 THEN -85.0511287798 ELSE k.Y END) AS kc
    CROSS APPLY (SELECT
        NX = CASE @mode WHEN 0 THEN @a * k.X + @b * k.Y + @c
                        WHEN 1 THEN RADIANS(k.X) * 6378137.0
                        WHEN 2 THEN DEGREES(k.X / 6378137.0)
                        WHEN 3 THEN k.Y END,
        NY = CASE @mode WHEN 0 THEN @d * k.X + @e * k.Y + @f
                        WHEN 1 THEN LOG(TAN(PI() / 4 + RADIANS(kc.YClamp) / 2)) * 6378137.0
                        WHEN 2 THEN DEGREES(2 * ATAN(EXP(k.Y / 6378137.0)) - PI() / 2)
                        WHEN 3 THEN k.X END) AS m
    CROSS APPLY (SELECT Piece = CASE WHEN k.X IS NULL OR k.Y IS NULL THEN s.value
                                     ELSE b.Prefix + f.Lead + sx.FormatNum(m.NX) + N' ' + sx.FormatNum(m.NY) + j.Extra + e.Suffix END) AS p;
    RETURN @out;
END;
GO

CREATE OR ALTER FUNCTION sx.Affine (@g GEOMETRY, @a FLOAT, @b FLOAT, @c FLOAT, @d FLOAT, @e FLOAT, @f FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    IF @g IS NULL OR @g.STIsEmpty() = 1 RETURN @g;
    RETURN geometry::STGeomFromText(sx.TransformWkt(@g.AsTextZM(), 0, @a, @b, @c, @d, @e, @f), @g.STSrid);
END;
GO

CREATE OR ALTER FUNCTION sx.Translate (@g GEOMETRY, @dx FLOAT, @dy FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    RETURN sx.Affine(@g, 1, 0, @dx, 0, 1, @dy);
END;
GO

-- Rotate anticlockwise by @deg about (@ox, @oy)
CREATE OR ALTER FUNCTION sx.Rotate (@g GEOMETRY, @deg FLOAT, @ox FLOAT, @oy FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @c FLOAT = COS(RADIANS(@deg)), @s FLOAT = SIN(RADIANS(@deg));
    RETURN sx.Affine(@g, @c, -@s, @ox - @ox * @c + @oy * @s,
                         @s,  @c, @oy - @ox * @s - @oy * @c);
END;
GO

-- Rotate about the centre of the envelope
CREATE OR ALTER FUNCTION sx.Spin (@g GEOMETRY, @deg FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @o GEOMETRY = sx.EnvelopeCentre(@g);
    RETURN sx.Rotate(@g, @deg, @o.STX, @o.STY);
END;
GO

-- Scale about the centre of the envelope
CREATE OR ALTER FUNCTION sx.Scale (@g GEOMETRY, @sx FLOAT, @sy FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @o GEOMETRY = sx.EnvelopeCentre(@g);
    RETURN sx.Affine(@g, @sx, 0, @o.STX - @sx * @o.STX, 0, @sy, @o.STY - @sy * @o.STY);
END;
GO

-- Move a shape so its envelope centre sits in cell @slot of a gallery grid (used to line up search results)
CREATE OR ALTER FUNCTION sx.GalleryPlace (@g GEOMETRY, @slot INT, @cols INT, @spacing FLOAT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @o GEOMETRY = sx.EnvelopeCentre(@g);
    RETURN sx.Translate(@g, -@o.STX + (@slot % @cols) * @spacing, -@o.STY - (@slot / @cols) * @spacing);
END;
GO

/* ---------- geography <-> geometry, Web Mercator ---------- */
CREATE OR ALTER FUNCTION sx.GeogToGeom (@g GEOGRAPHY)
RETURNS GEOMETRY
AS
BEGIN
    IF @g IS NULL OR @g.STGeometryType() = N'FullGlobe' RETURN NULL;
    -- WKB is always (x = longitude, y = latitude), so this is a straight re-read as flat lon/lat
    RETURN geometry::STGeomFromWKB(@g.STCurveToLine().STAsBinary(), @g.STSrid);
END;
GO

CREATE OR ALTER FUNCTION sx.GeomToGeog (@g GEOMETRY)
RETURNS GEOGRAPHY
AS
BEGIN
    IF @g IS NULL RETURN NULL;
    DECLARE @srid INT = CASE WHEN @g.STSrid IN (0, 3857) THEN 4326 ELSE @g.STSrid END;
    DECLARE @r GEOGRAPHY = geography::STGeomFromWKB(@g.MakeValid().STCurveToLine().STAsBinary(), @srid).MakeValid();
    -- A ring drawn clockwise is "everything except this" on the sphere; flip it back
    IF @r.EnvelopeAngle() > 90 SET @r = @r.ReorientObject();
    RETURN @r;
END;
GO

CREATE OR ALTER FUNCTION sx.ToWebMercator (@g GEOGRAPHY)
RETURNS GEOMETRY
AS
BEGIN
    IF @g IS NULL OR @g.STGeometryType() = N'FullGlobe' RETURN NULL;
    RETURN geometry::STGeomFromText(sx.TransformWkt(@g.STCurveToLine().STAsText(), 1, 0, 0, 0, 0, 0, 0), 3857);
END;
GO

CREATE OR ALTER FUNCTION sx.FromWebMercator (@g GEOMETRY)
RETURNS GEOGRAPHY
AS
BEGIN
    IF @g IS NULL RETURN NULL;
    DECLARE @r GEOGRAPHY = geography::STGeomFromText(sx.TransformWkt(@g.STCurveToLine().STAsText(), 2, 0, 0, 0, 0, 0, 0), 4326).MakeValid();
    IF @r.EnvelopeAngle() > 90 SET @r = @r.ReorientObject();
    RETURN @r;
END;
GO

/* ---------- spherical helpers (mean Earth radius 6,371,008.8 m) ---------- */
CREATE OR ALTER FUNCTION sx.Bearing (@from GEOGRAPHY, @to GEOGRAPHY)
RETURNS FLOAT
AS
BEGIN
    DECLARE @p1 FLOAT = RADIANS(@from.Lat), @p2 FLOAT = RADIANS(@to.Lat), @dl FLOAT = RADIANS(@to.Long - @from.Long);
    DECLARE @deg FLOAT = DEGREES(ATN2(SIN(@dl) * COS(@p2), COS(@p1) * SIN(@p2) - SIN(@p1) * COS(@p2) * COS(@dl)));
    RETURN @deg + 360 - 360 * FLOOR((@deg + 360) / 360);
END;
GO

CREATE OR ALTER FUNCTION sx.Destination (@from GEOGRAPHY, @bearingDeg FLOAT, @distanceM FLOAT)
RETURNS GEOGRAPHY
AS
BEGIN
    DECLARE @d FLOAT = @distanceM / 6371008.8, @t FLOAT = RADIANS(@bearingDeg),
            @p1 FLOAT = RADIANS(@from.Lat), @l1 FLOAT = RADIANS(@from.Long);
    DECLARE @p2 FLOAT = ASIN(SIN(@p1) * COS(@d) + COS(@p1) * SIN(@d) * COS(@t));
    DECLARE @l2 FLOAT = @l1 + ATN2(SIN(@t) * SIN(@d) * COS(@p1), COS(@d) - SIN(@p1) * SIN(@p2));
    DECLARE @lon FLOAT = DEGREES(@l2);
    SET @lon = @lon + 540 - 360 * FLOOR((@lon + 540) / 360) - 180;   -- normalise to [-180, 180)
    RETURN geography::Point(DEGREES(@p2), @lon, @from.STSrid);
END;
GO

-- Densified great circle (slerp). SQL Server geography edges are already geodesics;
-- this is for exporting to flat systems or animating along the path.
CREATE OR ALTER FUNCTION sx.GreatCircle (@a GEOGRAPHY, @b GEOGRAPHY, @segments INT)
RETURNS GEOGRAPHY
AS
BEGIN
    DECLARE @p1 FLOAT = RADIANS(@a.Lat), @l1 FLOAT = RADIANS(@a.Long),
            @p2 FLOAT = RADIANS(@b.Lat), @l2 FLOAT = RADIANS(@b.Long);
    DECLARE @d FLOAT = 2 * ASIN(SQRT(POWER(SIN((@p2 - @p1) / 2), 2) + COS(@p1) * COS(@p2) * POWER(SIN((@l2 - @l1) / 2), 2)));
    IF @d < 1e-12 RETURN @a;
    DECLARE @wkt NVARCHAR(MAX);
    SELECT @wkt = N'LINESTRING (' + STRING_AGG(CAST(sx.FormatNum(DEGREES(ATN2(q.y, q.x))) + ' '
                    + sx.FormatNum(DEGREES(ATN2(q.z, SQRT(q.x * q.x + q.y * q.y)))) AS NVARCHAR(MAX)), N', ')
                    WITHIN GROUP (ORDER BY g.value) + N')'
    FROM GENERATE_SERIES(0, @segments) AS g
    CROSS APPLY (SELECT f = CAST(g.value AS FLOAT) / @segments) AS t
    CROSS APPLY (SELECT A = SIN((1 - t.f) * @d) / SIN(@d), B = SIN(t.f * @d) / SIN(@d)) AS w
    CROSS APPLY (SELECT x = w.A * COS(@p1) * COS(@l1) + w.B * COS(@p2) * COS(@l2),
                        y = w.A * COS(@p1) * SIN(@l1) + w.B * COS(@p2) * SIN(@l2),
                        z = w.A * SIN(@p1) + w.B * SIN(@p2)) AS q;
    RETURN geography::STLineFromText(@wkt, @a.STSrid);
END;
GO

-- A point on the unit sphere as a JSON array, ready to CAST AS VECTOR(3)
CREATE OR ALTER FUNCTION sx.UnitVector (@lat FLOAT, @lon FLOAT)
RETURNS VARCHAR(100)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CONCAT('[',
        CONVERT(VARCHAR(30), CAST(COS(RADIANS(@lat)) * COS(RADIANS(@lon)) AS DECIMAL(12, 9))), ',',
        CONVERT(VARCHAR(30), CAST(COS(RADIANS(@lat)) * SIN(RADIANS(@lon)) AS DECIMAL(12, 9))), ',',
        CONVERT(VARCHAR(30), CAST(SIN(RADIANS(@lat)) AS DECIMAL(12, 9))), ']');
END;
GO

-- Cosine distance between unit vectors -> great-circle kilometres on a sphere
CREATE OR ALTER FUNCTION sx.CosineToKm (@cosineDistance FLOAT)
RETURNS FLOAT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @c FLOAT = 1 - @cosineDistance;
    IF @c > 1 SET @c = 1;
    IF @c < -1 SET @c = -1;
    RETURN ACOS(@c) * 6371.0088;
END;
GO

/* ---------- geohash & Hilbert ---------- */
CREATE OR ALTER FUNCTION sx.Geohash (@lat FLOAT, @lon FLOAT, @precision INT)
RETURNS VARCHAR(12)
AS
BEGIN
    DECLARE @b32 CHAR(32) = '0123456789bcdefghjkmnpqrstuvwxyz';
    DECLARE @latMin FLOAT = -90, @latMax FLOAT = 90, @lonMin FLOAT = -180, @lonMax FLOAT = 180,
            @hash VARCHAR(12) = '', @bit INT = 0, @ch INT = 0, @even BIT = 1, @mid FLOAT;
    IF @precision > 12 SET @precision = 12;
    WHILE LEN(@hash) < @precision
    BEGIN
        IF @even = 1
        BEGIN
            SET @mid = (@lonMin + @lonMax) / 2;
            IF @lon >= @mid BEGIN SET @ch = @ch * 2 + 1; SET @lonMin = @mid; END
            ELSE BEGIN SET @ch = @ch * 2; SET @lonMax = @mid; END
        END
        ELSE
        BEGIN
            SET @mid = (@latMin + @latMax) / 2;
            IF @lat >= @mid BEGIN SET @ch = @ch * 2 + 1; SET @latMin = @mid; END
            ELSE BEGIN SET @ch = @ch * 2; SET @latMax = @mid; END
        END
        SET @even = CASE WHEN @even = 1 THEN 0 ELSE 1 END;
        SET @bit += 1;
        IF @bit = 5
        BEGIN
            SET @hash += SUBSTRING(@b32, @ch + 1, 1);
            SET @bit = 0; SET @ch = 0;
        END
    END
    RETURN @hash;
END;
GO

CREATE OR ALTER FUNCTION sx.GeohashCell (@hash VARCHAR(12))
RETURNS GEOGRAPHY
AS
BEGIN
    DECLARE @b32 CHAR(32) = '0123456789bcdefghjkmnpqrstuvwxyz';
    DECLARE @latMin FLOAT = -90, @latMax FLOAT = 90, @lonMin FLOAT = -180, @lonMax FLOAT = 180,
            @i INT = 1, @n INT, @b INT, @even BIT = 1;
    WHILE @i <= LEN(@hash)
    BEGIN
        SET @n = CHARINDEX(SUBSTRING(@hash, @i, 1), @b32) - 1;
        SET @b = 4;
        WHILE @b >= 0
        BEGIN
            IF @even = 1
            BEGIN
                IF (@n / POWER(2, @b)) % 2 = 1 SET @lonMin = (@lonMin + @lonMax) / 2;
                ELSE SET @lonMax = (@lonMin + @lonMax) / 2;
            END
            ELSE
            BEGIN
                IF (@n / POWER(2, @b)) % 2 = 1 SET @latMin = (@latMin + @latMax) / 2;
                ELSE SET @latMax = (@latMin + @latMax) / 2;
            END
            SET @even = CASE WHEN @even = 1 THEN 0 ELSE 1 END;
            SET @b -= 1;
        END
        SET @i += 1;
    END
    -- anticlockwise ring = the inside is on the left, which is what geography expects
    RETURN geography::STPolyFromText(CONCAT('POLYGON ((',
        sx.FormatNum(@lonMin), ' ', sx.FormatNum(@latMin), ', ', sx.FormatNum(@lonMax), ' ', sx.FormatNum(@latMin), ', ',
        sx.FormatNum(@lonMax), ' ', sx.FormatNum(@latMax), ', ', sx.FormatNum(@lonMin), ' ', sx.FormatNum(@latMax), ', ',
        sx.FormatNum(@lonMin), ' ', sx.FormatNum(@latMin), '))'), 4326);
END;
GO

-- Position of (x, y) along a Hilbert curve filling a 2^order x 2^order grid
CREATE OR ALTER FUNCTION sx.HilbertKey (@x INT, @y INT, @order INT)
RETURNS BIGINT
AS
BEGIN
    DECLARE @n BIGINT = POWER(CAST(2 AS BIGINT), @order), @s BIGINT, @d BIGINT = 0,
            @rx BIGINT, @ry BIGINT, @t BIGINT, @hx BIGINT = @x, @hy BIGINT = @y;
    SET @s = @n / 2;
    WHILE @s > 0
    BEGIN
        SET @rx = CASE WHEN (@hx & @s) > 0 THEN 1 ELSE 0 END;
        SET @ry = CASE WHEN (@hy & @s) > 0 THEN 1 ELSE 0 END;
        SET @d += @s * @s * ((3 * @rx) ^ @ry);
        IF @ry = 0
        BEGIN
            IF @rx = 1 BEGIN SET @hx = @n - 1 - @hx; SET @hy = @n - 1 - @hy; END
            SET @t = @hx; SET @hx = @hy; SET @hy = @t;
        END
        SET @s /= 2;
    END
    RETURN @d;
END;
GO

/* ---------- grids ---------- */
CREATE OR ALTER FUNCTION sx.SquareGrid (@minX FLOAT, @minY FLOAT, @maxX FLOAT, @maxY FLOAT, @size FLOAT, @srid INT)
RETURNS TABLE
AS
RETURN
    SELECT CellId = r.value * 100000 + c.value, Col = c.value, Row = r.value,
           Geom = geometry::STPolyFromText(CONCAT('POLYGON ((',
                    v.x0, ' ', v.y0, ', ', v.x1, ' ', v.y0, ', ', v.x1, ' ', v.y1, ', ', v.x0, ' ', v.y1, ', ', v.x0, ' ', v.y0, '))'), @srid)
    FROM GENERATE_SERIES(0, CAST(CEILING((@maxX - @minX) / @size) AS INT) - 1) AS c
    CROSS JOIN GENERATE_SERIES(0, CAST(CEILING((@maxY - @minY) / @size) AS INT) - 1) AS r
    CROSS APPLY (SELECT x0 = sx.FormatNum(@minX + c.value * @size), x1 = sx.FormatNum(@minX + (c.value + 1) * @size),
                        y0 = sx.FormatNum(@minY + r.value * @size), y1 = sx.FormatNum(@minY + (r.value + 1) * @size)) AS v;
GO

-- Flat-topped hexagons, @size = centre-to-corner distance
CREATE OR ALTER FUNCTION sx.HexGrid (@minX FLOAT, @minY FLOAT, @maxX FLOAT, @maxY FLOAT, @size FLOAT, @srid INT)
RETURNS TABLE
AS
RETURN
    SELECT x.HexId, x.Col, x.Row, x.cx, x.cy,
           Geom = geometry::STPolyFromText(N'POLYGON (' + N'(' + STRING_AGG(CAST(x.pt AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY x.vi) + N'))', @srid)
    FROM
    (
        SELECT HexId = r.value * 100000 + c.value, Col = c.value, Row = r.value, ctr.cx, ctr.cy, vi = v.value,
               pt = CONCAT(sx.FormatNum(ctr.cx + @size * COS(RADIANS(CAST(60 * (v.value % 6) AS FLOAT)))), ' ',
                           sx.FormatNum(ctr.cy + @size * SIN(RADIANS(CAST(60 * (v.value % 6) AS FLOAT)))))
        FROM GENERATE_SERIES(0, CAST(CEILING((@maxX - @minX) / (1.5 * @size)) AS INT)) AS c
        CROSS JOIN GENERATE_SERIES(0, CAST(CEILING((@maxY - @minY) / (SQRT(3.0) * @size)) AS INT)) AS r
        CROSS APPLY (SELECT cx = @minX + c.value * 1.5 * @size,
                            cy = @minY + r.value * SQRT(3.0) * @size + CASE WHEN c.value % 2 = 1 THEN SQRT(3.0) / 2 * @size ELSE 0 END) AS ctr
        CROSS JOIN GENERATE_SERIES(0, 6) AS v
    ) AS x
    GROUP BY x.HexId, x.Col, x.Row, x.cx, x.cy;
GO

-- The half of the plane closer to T than to S (clipped to a square of side 2L). Union these and subtract -> Voronoi.
CREATE OR ALTER FUNCTION sx.HalfPlane (@sx FLOAT, @sy FLOAT, @tx FLOAT, @ty FLOAT, @L FLOAT, @srid INT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @len FLOAT = SQRT(SQUARE(@tx - @sx) + SQUARE(@ty - @sy));
    IF @len = 0 RETURN NULL;
    DECLARE @dx FLOAT = (@tx - @sx) / @len, @dy FLOAT = (@ty - @sy) / @len,
            @mx FLOAT = (@sx + @tx) / 2,   @my FLOAT = (@sy + @ty) / 2;
    DECLARE @px FLOAT = -@dy, @py FLOAT = @dx;
    RETURN geometry::STPolyFromText(CONCAT('POLYGON ((',
        sx.FormatNum(@mx + @px * @L), ' ', sx.FormatNum(@my + @py * @L), ', ',
        sx.FormatNum(@mx + @px * @L + @dx * @L), ' ', sx.FormatNum(@my + @py * @L + @dy * @L), ', ',
        sx.FormatNum(@mx - @px * @L + @dx * @L), ' ', sx.FormatNum(@my - @py * @L + @dy * @L), ', ',
        sx.FormatNum(@mx - @px * @L), ' ', sx.FormatNum(@my - @py * @L), ', ',
        sx.FormatNum(@mx + @px * @L), ' ', sx.FormatNum(@my + @py * @L), '))'), @srid);
END;
GO

/* ---------- GeoJSON ---------- */
-- Simple (non-collection, linear) WKT -> GeoJSON geometry. WKT brackets map 1:1 onto GeoJSON arrays,
-- except that points carry one extra level in WKT, which we drop.
CREATE OR ALTER FUNCTION sx.WktToGeoJSON (@wkt NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @wkt IS NULL OR CHARINDEX(N'EMPTY', @wkt) > 0 RETURN NULL;
    DECLARE @type NVARCHAR(40) = UPPER(LTRIM(RTRIM(LEFT(@wkt, CHARINDEX(N'(', @wkt + N'(') - 1))));
    DECLARE @geoType NVARCHAR(30) = CASE @type
        WHEN N'POINT' THEN N'Point' WHEN N'LINESTRING' THEN N'LineString' WHEN N'POLYGON' THEN N'Polygon'
        WHEN N'MULTIPOINT' THEN N'MultiPoint' WHEN N'MULTILINESTRING' THEN N'MultiLineString'
        WHEN N'MULTIPOLYGON' THEN N'MultiPolygon' END;
    IF @geoType IS NULL RETURN NULL;
    DECLARE @drop INT = CASE WHEN @geoType IN (N'Point', N'MultiPoint') THEN 1 ELSE 0 END;
    DECLARE @body NVARCHAR(MAX) = SUBSTRING(@wkt, CHARINDEX(N'(', @wkt), DATALENGTH(@wkt) / 2);
    DECLARE @coords NVARCHAR(MAX);
    SELECT @coords = STRING_AGG(CAST(REPLICATE(N'[', b.nOpen - @drop) + N'[' + e.Xs + N',' + f.Ys + N']'
                                     + REPLICATE(N']', b.nClose - @drop) AS NVARCHAR(MAX)), N',')
                     WITHIN GROUP (ORDER BY s.ordinal)
    FROM STRING_SPLIT(@body, N',', 1) AS s
    CROSS APPLY (SELECT t = LTRIM(RTRIM(s.value))) AS a
    CROSS APPLY (SELECT nOpen  = LEN(a.t) - LEN(REPLACE(a.t, N'(', N'')),
                        nClose = LEN(a.t) - LEN(REPLACE(a.t, N')', N''))) AS b
    CROSS APPLY (SELECT core = LTRIM(RTRIM(REPLACE(REPLACE(a.t, N'(', N''), N')', N'')))) AS c
    CROSS APPLY (SELECT sp = CHARINDEX(N' ', c.core + N' ')) AS d
    CROSS APPLY (SELECT Xs = LEFT(c.core, d.sp - 1), Rest = LTRIM(SUBSTRING(c.core, d.sp + 1, 4000))) AS e
    CROSS APPLY (SELECT Ys = LEFT(e.Rest, CHARINDEX(N' ', e.Rest + N' ') - 1)) AS f;
    RETURN N'{"type":"' + @geoType + N'","coordinates":' + @coords + N'}';
END;
GO

CREATE OR ALTER FUNCTION sx.ToGeoJSON (@g GEOMETRY)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @g IS NULL RETURN NULL;
    IF @g.STIsEmpty() = 1 RETURN N'{"type":"GeometryCollection","geometries":[]}';
    DECLARE @t NVARCHAR(40) = @g.STGeometryType();
    IF @t IN (N'CircularString', N'CompoundCurve', N'CurvePolygon')
    BEGIN
        SET @g = @g.STCurveToLine();
        SET @t = @g.STGeometryType();
    END
    IF @t = N'GeometryCollection'
        RETURN N'{"type":"GeometryCollection","geometries":['
             + (SELECT STRING_AGG(sx.ToGeoJSON(@g.STGeometryN(n.value)), N',') WITHIN GROUP (ORDER BY n.value)
                FROM GENERATE_SERIES(1, @g.STNumGeometries()) AS n) + N']}';
    RETURN sx.WktToGeoJSON(@g.STAsText());
END;
GO

-- geography WKT is already (longitude latitude), exactly the order GeoJSON wants
CREATE OR ALTER FUNCTION sx.GeogToGeoJSON (@g GEOGRAPHY)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    IF @g IS NULL OR @g.STGeometryType() = N'FullGlobe' RETURN NULL;
    IF @g.STIsEmpty() = 1 RETURN N'{"type":"GeometryCollection","geometries":[]}';
    DECLARE @t NVARCHAR(40) = @g.STGeometryType();
    IF @t IN (N'CircularString', N'CompoundCurve', N'CurvePolygon')
    BEGIN
        SET @g = @g.STCurveToLine();
        SET @t = @g.STGeometryType();
    END
    IF @t = N'GeometryCollection'
        RETURN N'{"type":"GeometryCollection","geometries":['
             + (SELECT STRING_AGG(sx.GeogToGeoJSON(@g.STGeometryN(n.value)), N',') WITHIN GROUP (ORDER BY n.value)
                FROM GENERATE_SERIES(1, @g.STNumGeometries()) AS n) + N']}';
    RETURN sx.WktToGeoJSON(@g.STAsText());
END;
GO

-- A GeoJSON coordinates array -> WKT body. @depth: 1 = list of positions, 2 = list of rings/lines, 3 = list of polygons.
-- Walks the JSON with OPENJSON, so it has no size limit (REGEXP_REPLACE refuses NVARCHAR(MAX) in SQL Server 2025).
CREATE OR ALTER FUNCTION sx.CoordsToWkt (@coords NVARCHAR(MAX), @depth INT, @wrapPoints BIT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out NVARCHAR(MAX);
    IF @depth <= 1
        SELECT @out = N'(' + STRING_AGG(CAST(
                          CASE WHEN @wrapPoints = 1 THEN N'(' ELSE N'' END
                          + JSON_VALUE(j.value, '$[0]') + N' ' + JSON_VALUE(j.value, '$[1]')
                          + CASE WHEN @wrapPoints = 1 THEN N')' ELSE N'' END AS NVARCHAR(MAX)), N', ')
                          WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) + N')'
        FROM OPENJSON(@coords) AS j;
    ELSE
        SELECT @out = N'(' + STRING_AGG(sx.CoordsToWkt(j.value, @depth - 1, @wrapPoints), N', ')
                          WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) + N')'
        FROM OPENJSON(@coords) AS j;
    RETURN @out;
END;
GO

-- GeoJSON geometry (or Feature) -> geometry
CREATE OR ALTER FUNCTION sx.FromGeoJSON (@json NVARCHAR(MAX), @srid INT)
RETURNS GEOMETRY
AS
BEGIN
    DECLARE @type NVARCHAR(40) = JSON_VALUE(@json, '$.type');
    IF @type = N'Feature'
        RETURN sx.FromGeoJSON(JSON_QUERY(@json, '$.geometry'), @srid);
    IF @type = N'GeometryCollection'
    BEGIN
        DECLARE @parts NVARCHAR(MAX);
        SELECT @parts = STRING_AGG(CAST(x.g.AsTextZM() AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY CAST(j.[key] AS INT))
        FROM OPENJSON(@json, '$.geometries') AS j
        CROSS APPLY (SELECT g = sx.FromGeoJSON(j.value, @srid)) AS x;
        RETURN geometry::STGeomFromText(ISNULL(N'GEOMETRYCOLLECTION (' + @parts + N')', N'GEOMETRYCOLLECTION EMPTY'), @srid);
    END
    DECLARE @c NVARCHAR(MAX) = JSON_QUERY(@json, '$.coordinates');
    IF @c IS NULL OR @type IS NULL RETURN NULL;
    DECLARE @wkt NVARCHAR(MAX) = CASE @type
        WHEN N'Point'           THEN N'POINT (' + JSON_VALUE(@c, '$[0]') + N' ' + JSON_VALUE(@c, '$[1]') + N')'
        WHEN N'LineString'      THEN N'LINESTRING '      + sx.CoordsToWkt(@c, 1, 0)
        WHEN N'MultiPoint'      THEN N'MULTIPOINT '      + sx.CoordsToWkt(@c, 1, 1)
        WHEN N'Polygon'         THEN N'POLYGON '         + sx.CoordsToWkt(@c, 2, 0)
        WHEN N'MultiLineString' THEN N'MULTILINESTRING ' + sx.CoordsToWkt(@c, 2, 0)
        WHEN N'MultiPolygon'    THEN N'MULTIPOLYGON '    + sx.CoordsToWkt(@c, 3, 0)
    END;
    RETURN geometry::STGeomFromText(@wkt, @srid);
END;
GO

-- Shred a FeatureCollection into rows
CREATE OR ALTER FUNCTION sx.GeoJsonFeatures (@featureCollection NVARCHAR(MAX), @srid INT)
RETURNS TABLE
AS
RETURN
    SELECT FeatureIndex = CAST(f.[key] AS INT),
           Properties   = JSON_QUERY(f.value, '$.properties'),
           Geom         = sx.FromGeoJSON(JSON_QUERY(f.value, '$.geometry'), @srid)
    FROM OPENJSON(@featureCollection, '$.features') AS f;
GO

/* ---------- describe-everything helpers ---------- */
CREATE OR ALTER FUNCTION sx.Describe (@g GEOMETRY)
RETURNS TABLE
AS
RETURN
    SELECT v.Property, v.Value
    FROM (VALUES
        (1,  N'STGeometryType()',           CAST(@g.STGeometryType() AS NVARCHAR(4000))),
        (2,  N'STDimension()',              CAST(@g.STDimension() AS NVARCHAR(4000))),
        (3,  N'STSrid',                     CAST(@g.STSrid AS NVARCHAR(4000))),
        (4,  N'STIsValid()',                CAST(@g.STIsValid() AS NVARCHAR(4000))),
        (5,  N'IsValidDetailed()',          @g.IsValidDetailed()),
        (6,  N'STIsEmpty()',                CAST(@g.STIsEmpty() AS NVARCHAR(4000))),
        (7,  N'STIsSimple()',               CASE WHEN @g.STIsValid() = 1 THEN CAST(@g.STIsSimple() AS NVARCHAR(4000)) END),
        (8,  N'STIsClosed()',               CASE WHEN @g.STIsValid() = 1 THEN CAST(@g.STIsClosed() AS NVARCHAR(4000)) END),
        (9,  N'STNumPoints()',              CAST(@g.STNumPoints() AS NVARCHAR(4000))),
        (10, N'STNumGeometries()',          CAST(@g.STNumGeometries() AS NVARCHAR(4000))),
        (11, N'STArea()',                   CAST(@g.STArea() AS NVARCHAR(4000))),
        (12, N'STLength()',                 CAST(@g.STLength() AS NVARCHAR(4000))),
        (13, N'HasZ / HasM',                CONCAT(@g.HasZ, N' / ', @g.HasM)),
        (14, N'STEnvelope()',               @g.STEnvelope().ToString()),
        (15, N'STCentroid()',               CASE WHEN @g.STIsValid() = 1 THEN @g.STCentroid().ToString() END),
        (16, N'STPointOnSurface()',         CASE WHEN @g.STIsValid() = 1 THEN @g.STPointOnSurface().ToString() END),
        (17, N'MinDbCompatibilityLevel()',  CAST(@g.MinDbCompatibilityLevel() AS NVARCHAR(4000))),
        (18, N'AsTextZM()',                 LEFT(@g.AsTextZM(), 4000))
    ) AS v (Ord, Property, Value);
GO

CREATE OR ALTER FUNCTION sx.DescribeGeog (@g GEOGRAPHY)
RETURNS TABLE
AS
RETURN
    SELECT v.Property, v.Value
    FROM (VALUES
        (1,  N'STGeometryType()',           CAST(@g.STGeometryType() AS NVARCHAR(4000))),
        (2,  N'STDimension()',              CAST(@g.STDimension() AS NVARCHAR(4000))),
        (3,  N'STSrid',                     CAST(@g.STSrid AS NVARCHAR(4000))),
        (4,  N'STIsValid()',                CAST(@g.STIsValid() AS NVARCHAR(4000))),
        (5,  N'IsValidDetailed()',          @g.IsValidDetailed()),
        (6,  N'STNumPoints()',              CAST(@g.STNumPoints() AS NVARCHAR(4000))),
        (7,  N'NumRings()',                 CAST(@g.NumRings() AS NVARCHAR(4000))),
        (8,  N'STArea() m2',                CAST(@g.STArea() AS NVARCHAR(4000))),
        (9,  N'STLength() m',               CAST(@g.STLength() AS NVARCHAR(4000))),
        (10, N'EnvelopeCenter()',           @g.EnvelopeCenter().ToString()),
        (11, N'EnvelopeAngle() degrees',    CAST(@g.EnvelopeAngle() AS NVARCHAR(4000))),
        (12, N'HasZ / HasM',                CONCAT(@g.HasZ, N' / ', @g.HasM)),
        (13, N'MinDbCompatibilityLevel()',  CAST(@g.MinDbCompatibilityLevel() AS NVARCHAR(4000))),
        (14, N'AsTextZM()',                 LEFT(@g.AsTextZM(), 4000))
    ) AS v (Ord, Property, Value);
GO

/* ---------- shape descriptors for vector search ----------
   Radial signature: fire @n rays from the centroid and measure how much of each ray lies inside
   the shape. Normalised by the longest ray, so it is scale-invariant.
   Fourier descriptor: |DFT| of the 32-ray signature. Rotating the shape cyclically shifts the
   signature, which only changes the phase - the magnitudes stay put. Rotation-invariant.       */
CREATE OR ALTER FUNCTION sx.RadialSignature (@g GEOMETRY, @n INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @c GEOMETRY = @g.STCentroid();
    IF @c IS NULL SET @c = sx.EnvelopeCentre(@g);
    DECLARE @e GEOMETRY = @g.STEnvelope();
    DECLARE @R FLOAT = 2 * @e.STPointN(1).STDistance(@e.STPointN(@e.STNumPoints() / 2 + 1)) + 1;
    DECLARE @out NVARCHAR(MAX);
    WITH r AS
    (
        SELECT k = s.value,
               len = geometry::STLineFromText(CONCAT('LINESTRING (',
                        sx.FormatNum(@c.STX), ' ', sx.FormatNum(@c.STY), ', ',
                        sx.FormatNum(@c.STX + @R * COS(2 * PI() * s.value / @n)), ' ',
                        sx.FormatNum(@c.STY + @R * SIN(2 * PI() * s.value / @n)), ')'), @g.STSrid)
                     .STIntersection(@g).STLength()
        FROM GENERATE_SERIES(0, @n - 1) AS s
    )
    SELECT @out = '[' + STRING_AGG(CONVERT(VARCHAR(30), CAST(ISNULL(r.len / NULLIF(m.mx, 0), 0) AS DECIMAL(12, 6))), ',')
                        WITHIN GROUP (ORDER BY r.k) + ']'
    FROM r CROSS JOIN (SELECT mx = MAX(len) FROM r) AS m;
    RETURN @out;
END;
GO

CREATE OR ALTER FUNCTION sx.FourierDescriptor (@g GEOMETRY)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out NVARCHAR(MAX);
    WITH r AS
    (
        SELECT k = CAST(j.[key] AS INT), len = CAST(j.value AS FLOAT)
        FROM OPENJSON(sx.RadialSignature(@g, 32)) AS j
    ),
    f AS
    (
        SELECT m = h.value,
               re = SUM(r.len * COS(2 * PI() * h.value * r.k / 32.0)),
               im = SUM(r.len * SIN(2 * PI() * h.value * r.k / 32.0))
        FROM r CROSS JOIN GENERATE_SERIES(1, 16) AS h
        GROUP BY h.value
    )
    SELECT @out = '[' + STRING_AGG(CONVERT(VARCHAR(30), CAST(ISNULL(SQRT(f.re * f.re + f.im * f.im) / NULLIF(t.tot, 0), 0) AS DECIMAL(12, 6))), ',')
                        WITHIN GROUP (ORDER BY f.m) + ']'
    FROM f CROSS JOIN (SELECT tot = SUM(len) FROM r) AS t;
    RETURN @out;
END;
GO

-- Size & form: [log area, compactness, solidity, holes, vertex density, log perimeter] - scale-aware, unlike Fourier
CREATE OR ALTER FUNCTION sx.MorphVector (@g GEOMETRY)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @A FLOAT = @g.STArea(), @P FLOAT = @g.STLength();
    IF @A IS NULL OR @A <= 0 OR @P <= 0 RETURN '[0,0,0,0,0,0]';
    DECLARE @hull FLOAT = @g.STConvexHull().STArea();
    DECLARE @holes INT = ISNULL(CASE WHEN @g.STGeometryType() = N'Polygon' THEN @g.STNumInteriorRing() END, 0);
    RETURN CONCAT('[',
        CONVERT(VARCHAR(30), CAST(LOG10(@A) / 4 AS DECIMAL(12, 6))), ',',
        CONVERT(VARCHAR(30), CAST(4 * PI() * @A / (@P * @P) AS DECIMAL(12, 6))), ',',
        CONVERT(VARCHAR(30), CAST(@A / NULLIF(@hull, 0) AS DECIMAL(12, 6))), ',',
        @holes, ',',
        CONVERT(VARCHAR(30), CAST(@g.STNumPoints() / 40.0 AS DECIMAL(12, 6))), ',',
        CONVERT(VARCHAR(30), CAST(LOG10(@P) / 3 AS DECIMAL(12, 6))), ']');
END;
GO
PRINT 'sx library installed';
