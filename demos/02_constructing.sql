/* Spatial Studio demo pack 02 - Constructing shapes and moving between formats */

--#demo Every OGC constructor
--#desc The type-specific static constructors refuse the wrong type, while STGeomFromText takes anything.
--#view plane
--#tags STGeomFromText, STPointFromText, STLineFromText, STPolyFromText, STMPointFromText, STMLineFromText, STMPolyFromText, STGeomCollFromText
SELECT method = 'STPointFromText',    shape = geometry::STPointFromText('POINT (10 10)', 0),                                            label = 'STPointFromText'
UNION ALL SELECT 'STLineFromText',    geometry::STLineFromText('LINESTRING (30 0, 60 20, 90 0)', 0),                                    'STLineFromText'
UNION ALL SELECT 'STPolyFromText',    geometry::STPolyFromText('POLYGON ((110 0, 150 0, 150 30, 110 30, 110 0))', 0),                   'STPolyFromText'
UNION ALL SELECT 'STMPointFromText',  geometry::STMPointFromText('MULTIPOINT ((0 50), (10 60), (20 50))', 0),                           'STMPointFromText'
UNION ALL SELECT 'STMLineFromText',   geometry::STMLineFromText('MULTILINESTRING ((40 50, 70 60), (40 60, 70 70))', 0),                 'STMLineFromText'
UNION ALL SELECT 'STMPolyFromText',   geometry::STMPolyFromText('MULTIPOLYGON (((90 50, 110 50, 100 70, 90 50)), ((115 50, 135 50, 125 70, 115 50)))', 0), 'STMPolyFromText'
UNION ALL SELECT 'STGeomCollFromText',geometry::STGeomCollFromText('GEOMETRYCOLLECTION (POINT (160 60), LINESTRING (150 40, 170 40), POLYGON ((150 70, 170 70, 160 85, 150 70)))', 0), 'STGeomCollFromText';

--#demo Wrong constructor, clear error
--#desc STLineFromText only accepts a LINESTRING. TRY...CATCH shows the error SQL Server raises.
--#tags STLineFromText, error handling
BEGIN TRY
    SELECT geometry::STLineFromText('POINT (1 1)', 0);
END TRY
BEGIN CATCH
    SELECT [error number] = ERROR_NUMBER(), [message] = ERROR_MESSAGE();
END CATCH;

--#demo Parse and implicit conversion
--#desc Parse() assumes SRID 0 for geometry and 4326 for geography. A string assigned to a spatial variable is parsed implicitly.
--#tags Parse, implicit conversion, STSrid
DECLARE @a geometry  = 'POINT (3 4)';                 -- implicit Parse
DECLARE @b geography = 'POINT (-0.39 51.66)';         -- WKT is always X Y, so longitude first
SELECT [geometry::Parse SRID]  = geometry::Parse('POINT (1 2)').STSrid,
       [geography::Parse SRID] = geography::Parse('POINT (1 2)').STSrid,
       [implicit geometry]     = @a.ToString(),
       [implicit geography]    = @b.ToString(),
       [Lat]  = @b.Lat, [Long] = @b.Long;

--#demo Point(): the latitude-first trap
--#desc geometry::Point(x, y, srid) but geography::Point(lat, long, srid). WKT, by contrast, is always "x y" i.e. "long lat".
--#desc Swap them and Watford lands in the Indian Ocean.
--#view map
--#tags Point, Lat, Long
SELECT shape = geography::Point(51.6565, -0.3903, 4326), label = 'geography::Point(51.6565, -0.3903) - right', color = '#59a14f'
UNION ALL
SELECT geography::Point(-0.3903, 51.6565, 4326), 'geography::Point(-0.3903, 51.6565) - swapped', '#e15759';

--#demo Well-Known Binary round trip
--#desc STAsBinary() produces OGC WKB; STGeomFromWKB() and the typed WKB constructors read it back.
--#tags STAsBinary, STGeomFromWKB, STPointFromWKB, STLineFromWKB, STPolyFromWKB
DECLARE @g geometry = geometry::STGeomFromText('POLYGON ((0 0, 10 0, 10 10, 0 10, 0 0))', 0);
DECLARE @wkb varbinary(max) = @g.STAsBinary();
SELECT [WKB] = @wkb,
       [bytes] = DATALENGTH(@wkb),
       [back to geometry] = geometry::STGeomFromWKB(@wkb, 0).ToString(),
       [STPolyFromWKB equal?] = geometry::STPolyFromWKB(@wkb, 0).STEquals(@g),
       [point via STPointFromWKB] = geometry::STPointFromWKB(geometry::Point(5, 5, 0).STAsBinary(), 0).ToString(),
       [line via STLineFromWKB] = geometry::STLineFromWKB(geometry::STGeomFromText('LINESTRING (0 0, 5 5)', 0).STAsBinary(), 0).ToString();

--#demo GML in and out
--#desc AsGml() writes Geography Markup Language 3.1.1; GeomFromGml() reads it.
--#tags AsGml, GeomFromGml
DECLARE @g geography = geography::Point(51.6565, -0.3903, 4326);
DECLARE @gml xml = @g.AsGml();
SELECT [AsGml] = @gml,
       [GeomFromGml] = geography::GeomFromGml(@gml, 4326).ToString(),
       [polygon as GML] = geometry::STGeomFromText('POLYGON ((0 0, 3 0, 3 3, 0 0))', 0).AsGml();

--#demo Z and M values
--#desc Points can carry an elevation (Z) and a measure (M). Spatial operations ignore them, but they are stored and returned.
--#desc STAsText drops them; AsTextZM keeps them.
--#tags Z, M, HasZ, HasM, AsTextZM, STAsText
DECLARE @l geometry = geometry::STGeomFromText('LINESTRING (0 0 100 0, 50 0 120 5, 100 20 90 12)', 0);
SELECT [STAsText] = @l.STAsText(), [AsTextZM] = @l.AsTextZM(), [HasZ] = @l.HasZ, [HasM] = @l.HasM;
SELECT n = g.value, X = @l.STPointN(g.value).STX, Y = @l.STPointN(g.value).STY,
       Z = @l.STPointN(g.value).Z, M = @l.STPointN(g.value).M
FROM GENERATE_SERIES(1, 3) AS g;

--#demo The native binary format
--#desc SQL Server stores spatial values in its own serialisation (MS-SSCLRT), not WKB. CAST to varbinary shows the raw bytes.
--#desc Tip: click any shape cell in the results grid and open the Inspector tab to see these bytes decoded field by field.
--#tags serialization, varbinary, DATALENGTH
DECLARE @p geometry = geometry::Point(1, 2, 0);
DECLARE @c geography = geography::Point(51.5, -0.1, 4326);
SELECT what = 'geometry::Point(1, 2, 0)', native = CAST(@p AS varbinary(max)), [native bytes] = DATALENGTH(@p),
       wkb = @p.STAsBinary(), [wkb bytes] = DATALENGTH(@p.STAsBinary()), shape = @p
UNION ALL
SELECT 'geography::Point(51.5, -0.1, 4326)', CAST(@c AS varbinary(max)), DATALENGTH(@c), @c.STAsBinary(), DATALENGTH(@c.STAsBinary()), NULL;

--#demo Empty shapes
--#desc Every type has an EMPTY form. They are valid, have no points, and STIsEmpty() says so.
--#tags EMPTY, STIsEmpty, STNumPoints
SELECT wkt, [STIsEmpty] = g.STIsEmpty(), [STNumPoints] = g.STNumPoints(), [STGeometryType] = g.STGeometryType(), [STIsValid] = g.STIsValid()
FROM (VALUES ('POINT EMPTY'), ('LINESTRING EMPTY'), ('POLYGON EMPTY'), ('GEOMETRYCOLLECTION EMPTY'), ('CIRCULARSTRING EMPTY')) AS v (wkt)
CROSS APPLY (SELECT g = geometry::STGeomFromText(v.wkt, 0)) AS x;

--#demo ToString, STAsText and AsTextZM
--#desc ToString() is the same as AsTextZM(): it keeps Z and M. STAsText() is strict 2D OGC text.
--#tags ToString, STAsText, AsTextZM
DECLARE @g geometry = 'POINT (1 2 3 4)';
SELECT [ToString] = @g.ToString(), [STAsText] = @g.STAsText(), [AsTextZM] = @g.AsTextZM();

--#demo geometry to geography and back
--#desc There's no CAST between the types. Going via WKB works; sx.GeomToGeog also fixes ring orientation and validity.
--#view map
--#tags STAsBinary, STGeomFromWKB, MakeValid, ReorientObject, sx.GeomToGeog, sx.GeogToGeom
DECLARE @flat geometry = geometry::STGeomFromText('POLYGON ((-10 40, 30 40, 30 60, -10 60, -10 40))', 4326);
SELECT shape = sx.GeomToGeog(@flat), label = 'as geography: top edge follows a great circle', color = '#4e79a7';
SELECT geom = @flat, label = 'original geometry', color = '#e15759';
SELECT [geometry area (deg2)] = @flat.STArea(), [geography area (km2)] = sx.GeomToGeog(@flat).STArea() / 1e6,
       [round trip equal?] = sx.GeogToGeom(sx.GeomToGeog(@flat)).STEquals(@flat);
