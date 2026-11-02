/* ==========================================================================
   Spatial Studio - 06 shape vectors (computed in T-SQL) and DiskANN indexes
   ========================================================================== */
USE SpatialStudio;
GO
SET NOCOUNT ON;
DELETE town.BuildingShape;
DECLARE @t0 DATETIME2 = SYSDATETIME();
INSERT town.BuildingShape (BuildingId, Radial, Fourier, Morph)
SELECT b.BuildingId,
       CAST(sx.RadialSignature(b.Geom, 32) AS VECTOR(32)),
       CAST(sx.FourierDescriptor(b.Geom)   AS VECTOR(16)),
       CAST(sx.MorphVector(b.Geom)         AS VECTOR(6))
FROM town.Building AS b;
PRINT CONCAT('Shape vectors for ', @@ROWCOUNT, ' buildings in ', DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), ' ms');
GO
DELETE town.BuildingShapeAnn;
INSERT town.BuildingShapeAnn (BuildingId, Fourier) SELECT BuildingId, Fourier FROM town.BuildingShape;
GO
-- DiskANN vector indexes (preview in SQL Server 2025). Tables become read-only once indexed.
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'VIX_CityVec_UnitVec')
        EXEC (N'CREATE VECTOR INDEX VIX_CityVec_UnitVec ON world.CityVec (UnitVec) WITH (METRIC = ''cosine'', TYPE = ''diskann'');');
    PRINT 'Vector index VIX_CityVec_UnitVec ready';
END TRY
BEGIN CATCH
    PRINT 'Vector index on world.CityVec not created: ' + ERROR_MESSAGE();
END CATCH;
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'VIX_BuildingShapeAnn_Fourier')
        EXEC (N'CREATE VECTOR INDEX VIX_BuildingShapeAnn_Fourier ON town.BuildingShapeAnn (Fourier) WITH (METRIC = ''cosine'', TYPE = ''diskann'');');
    PRINT 'Vector index VIX_BuildingShapeAnn_Fourier ready';
END TRY
BEGIN CATCH
    PRINT 'Vector index on town.BuildingShapeAnn not created: ' + ERROR_MESSAGE();
END CATCH;
GO
PRINT 'Spatial Studio install complete.';
