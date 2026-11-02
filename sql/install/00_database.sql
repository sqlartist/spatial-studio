/* ==========================================================================
   Spatial Studio for SQL Server 2025
   00 - database, compatibility level, preview features, schemas
   Safe to re-run.
   ========================================================================== */
USE master;
GO
IF DB_ID(N'SpatialStudio') IS NULL
    CREATE DATABASE SpatialStudio;
GO
-- 170 = SQL Server 2025: needed for REGEXP_LIKE, and gives us the newest optimiser behaviour
ALTER DATABASE SpatialStudio SET COMPATIBILITY_LEVEL = 170;
GO
ALTER DATABASE SpatialStudio SET RECOVERY SIMPLE;
GO
USE SpatialStudio;
GO
-- VECTOR INDEX (DiskANN) and VECTOR_SEARCH are preview features in SQL Server 2025
BEGIN TRY
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;');
    PRINT 'PREVIEW_FEATURES = ON (vector indexes / VECTOR_SEARCH enabled)';
END TRY
BEGIN CATCH
    PRINT 'Could not enable PREVIEW_FEATURES: ' + ERROR_MESSAGE();
END CATCH;
GO
IF SCHEMA_ID(N'world') IS NULL EXEC (N'CREATE SCHEMA world AUTHORIZATION dbo;');
IF SCHEMA_ID(N'town')  IS NULL EXEC (N'CREATE SCHEMA town  AUTHORIZATION dbo;');
IF SCHEMA_ID(N'sx')    IS NULL EXEC (N'CREATE SCHEMA sx    AUTHORIZATION dbo;');
IF SCHEMA_ID(N'lab')   IS NULL EXEC (N'CREATE SCHEMA lab   AUTHORIZATION dbo;');
GO
PRINT 'Database SpatialStudio ready on ' + @@VERSION;
