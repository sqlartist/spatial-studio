/* ==========================================================================
   Spatial Studio - 04 turn the staged world data into proper spatial tables
   ========================================================================== */
USE SpatialStudio;
GO
SET NOCOUNT ON;
TRUNCATE TABLE world.Country;
DECLARE @id INT, @name NVARCHAR(100), @iso INT, @wkt NVARCHAR(MAX), @g GEOGRAPHY, @ok INT = 0, @bad INT = 0;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT CountryId, Name, IsoN3, Wkt FROM world.CountryStage ORDER BY CountryId;
OPEN cur;
FETCH NEXT FROM cur INTO @id, @name, @iso, @wkt;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @g = geography::STGeomFromText(@wkt, 4326).MakeValid();
        -- If the ring order made the polygon "the rest of the world", flip it
        IF @g.EnvelopeAngle() > 90 SET @g = @g.ReorientObject();
        INSERT world.Country (CountryId, Name, IsoN3, Geog, Geom, AreaKm2)
        VALUES (@id, @name, @iso, @g, sx.GeogToGeom(@g), @g.STArea() / 1e6);
        SET @ok += 1;
    END TRY
    BEGIN CATCH
        SET @bad += 1;
        PRINT CONCAT('Skipped ', @name, ': ', ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM cur INTO @id, @name, @iso, @wkt;
END
CLOSE cur; DEALLOCATE cur;
PRINT CONCAT('Countries loaded: ', @ok, ' (skipped ', @bad, ')');
GO

TRUNCATE TABLE world.City;
INSERT world.City (CityId, Name, CountryCode, Population, Lat, Lon, FeatureCode, Geog, UnitVec)
SELECT CityId, Name, CountryCode, Population, Lat, Lon, FeatureCode,
       geography::Point(Lat, Lon, 4326),                      -- note: Point(latitude, longitude, srid)
       CAST(sx.UnitVector(Lat, Lon) AS VECTOR(3))
FROM (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY CityId ORDER BY Population DESC) FROM world.CityStage) AS s
WHERE s.rn = 1;
PRINT CONCAT('Cities loaded: ', @@ROWCOUNT);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'SIX_Country_Geog')
    CREATE SPATIAL INDEX SIX_Country_Geog ON world.Country (Geog) USING GEOGRAPHY_AUTO_GRID;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'SIX_City_Geog')
    CREATE SPATIAL INDEX SIX_City_Geog ON world.City (Geog) USING GEOGRAPHY_AUTO_GRID;
GO

-- Spatial join: which country polygon contains each city? (1:110m coastlines are coarse, so some coastal cities miss)
UPDATE c
SET CountryId = (SELECT TOP (1) k.CountryId FROM world.Country AS k WHERE k.Geog.STIntersects(c.Geog) = 1)
FROM world.City AS c;
DECLARE @matched INT = (SELECT COUNT(*) FROM world.City WHERE CountryId IS NOT NULL);
PRINT CONCAT('Cities matched to a country polygon: ', @matched);
GO

TRUNCATE TABLE world.CityVec;
INSERT world.CityVec (CityId, UnitVec) SELECT CityId, UnitVec FROM world.City;
GO
