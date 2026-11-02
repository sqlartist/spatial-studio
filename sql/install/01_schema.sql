/* ==========================================================================
   Spatial Studio - 01 schema
   world.* : real data (Natural Earth countries, GeoNames cities) - geography
   town.*  : a procedurally generated planar town (metres, SRID 0) - geometry
   lab.*   : scratch space the demos create and drop
   ========================================================================== */
USE SpatialStudio;
GO
DROP TABLE IF EXISTS town.BuildingShapeAnn, town.BuildingShape, town.RoadLink, town.RoadNode,
                     town.POI, town.Park, town.River, town.Road, town.Building, town.Block, town.ShapeTemplate;
DROP TABLE IF EXISTS world.CityVec, world.City, world.CityStage, world.Country, world.CountryStage;
GO

/* ---------------- world ---------------- */
CREATE TABLE world.CountryStage
(
    CountryId INT           NOT NULL PRIMARY KEY,
    Name      NVARCHAR(100) NOT NULL,
    IsoN3     INT           NULL,
    Wkt       NVARCHAR(MAX) NOT NULL
);

CREATE TABLE world.Country
(
    CountryId INT           NOT NULL CONSTRAINT PK_Country PRIMARY KEY CLUSTERED,
    Name      NVARCHAR(100) NOT NULL,
    IsoN3     INT           NULL,
    Geog      GEOGRAPHY     NOT NULL,   -- ellipsoidal, WGS84 (SRID 4326)
    Geom      GEOMETRY      NULL,       -- the same shape as flat lon/lat (SRID 4326) for comparison demos
    AreaKm2   FLOAT         NULL,
    LoadNote  NVARCHAR(200) NULL
);

CREATE TABLE world.CityStage
(
    CityId      INT           NOT NULL,
    Name        NVARCHAR(200) NOT NULL,
    CountryCode CHAR(2)       NULL,
    Population  INT           NULL,
    Lon         FLOAT         NOT NULL,
    Lat         FLOAT         NOT NULL,
    FeatureCode VARCHAR(10)   NULL
);

CREATE TABLE world.City
(
    CityId      INT           NOT NULL CONSTRAINT PK_City PRIMARY KEY CLUSTERED,
    Name        NVARCHAR(200) NOT NULL,
    CountryCode CHAR(2)       NULL,
    Population  INT           NULL,
    Lat         FLOAT         NOT NULL,
    Lon         FLOAT         NOT NULL,
    FeatureCode VARCHAR(10)   NULL,
    Geog        GEOGRAPHY     NOT NULL,
    CountryId   INT           NULL,
    UnitVec     VECTOR(3)     NULL      -- the city as a point on the unit sphere: cosine distance = great-circle angle
);
CREATE INDEX IX_City_Name ON world.City (Name) INCLUDE (Population);
CREATE INDEX IX_City_Population ON world.City (Population DESC);

-- A copy of the unit vectors for the DiskANN vector index (tables with a vector index are read-only in the 2025 preview)
CREATE TABLE world.CityVec
(
    CityId  INT       NOT NULL CONSTRAINT PK_CityVec PRIMARY KEY CLUSTERED,
    UnitVec VECTOR(3) NOT NULL
);

/* ---------------- town ---------------- */
CREATE TABLE town.ShapeTemplate
(
    Kind VARCHAR(20) NOT NULL,
    Ring TINYINT     NOT NULL,   -- 1 = exterior, 2+ = holes
    Seq  INT         NOT NULL,
    X    FLOAT       NOT NULL,
    Y    FLOAT       NOT NULL,
    CONSTRAINT PK_ShapeTemplate PRIMARY KEY (Kind, Ring, Seq)
);

CREATE TABLE town.Block
(
    BlockId  INT         NOT NULL CONSTRAINT PK_Block PRIMARY KEY CLUSTERED,
    Col      INT         NOT NULL,
    Row      INT         NOT NULL,
    ZoneKind VARCHAR(20) NOT NULL,
    Geom     GEOMETRY    NOT NULL
);

CREATE TABLE town.Building
(
    BuildingId INT         NOT NULL CONSTRAINT PK_Building PRIMARY KEY CLUSTERED,
    BlockId    INT         NOT NULL,
    Kind       VARCHAR(20) NOT NULL,   -- the template it was generated from: ground truth for the shape-recognition demos
    Rotation   FLOAT       NOT NULL,
    Scale      FLOAT       NOT NULL,
    Floors     INT         NOT NULL,
    Geom       GEOMETRY    NOT NULL
);

CREATE TABLE town.Road
(
    RoadId INT          NOT NULL CONSTRAINT PK_Road PRIMARY KEY CLUSTERED,
    Name   NVARCHAR(50) NOT NULL,
    Geom   GEOMETRY     NOT NULL
);

CREATE TABLE town.River
(
    RiverId INT          NOT NULL CONSTRAINT PK_River PRIMARY KEY CLUSTERED,
    Name    NVARCHAR(50) NOT NULL,
    Geom    GEOMETRY     NOT NULL      -- a COMPOUNDCURVE with circular arcs
);

CREATE TABLE town.Park
(
    ParkId  INT          NOT NULL CONSTRAINT PK_Park PRIMARY KEY CLUSTERED,
    BlockId INT          NOT NULL,
    Name    NVARCHAR(50) NOT NULL,
    Geom    GEOMETRY     NOT NULL,
    Pond    GEOMETRY     NULL          -- a CURVEPOLYGON
);

CREATE TABLE town.POI
(
    PoiId INT          NOT NULL CONSTRAINT PK_POI PRIMARY KEY CLUSTERED,
    Kind  VARCHAR(20)  NOT NULL,
    Name  NVARCHAR(60) NOT NULL,
    Geom  GEOMETRY     NOT NULL
);

-- SQL Graph road network: junctions are nodes, road segments are edges (both directions)
CREATE TABLE town.RoadNode
(
    NodeId  INT         NOT NULL PRIMARY KEY,
    NodeKey VARCHAR(10) NOT NULL,   -- NodeId as text, for STRING_AGG ... WITHIN GROUP (GRAPH PATH)
    Col    INT      NOT NULL,
    Row    INT      NOT NULL,
    X      FLOAT    NOT NULL,
    Y      FLOAT    NOT NULL,
    Geom   GEOMETRY NOT NULL
) AS NODE;

CREATE TABLE town.RoadLink
(
    LengthM  FLOAT    NOT NULL,
    IsBridge BIT      NOT NULL,
    Geom     GEOMETRY NOT NULL
) AS EDGE;

-- Shape descriptors computed in T-SQL (see sx.RadialSignature / sx.FourierDescriptor / sx.MorphVector)
CREATE TABLE town.BuildingShape
(
    BuildingId INT        NOT NULL CONSTRAINT PK_BuildingShape PRIMARY KEY CLUSTERED,
    Radial     VECTOR(32) NOT NULL,
    Fourier    VECTOR(16) NOT NULL,
    Morph      VECTOR(6)  NOT NULL
);

CREATE TABLE town.BuildingShapeAnn
(
    BuildingId INT        NOT NULL CONSTRAINT PK_BuildingShapeAnn PRIMARY KEY CLUSTERED,
    Fourier    VECTOR(16) NOT NULL
);
GO
PRINT 'Schema created';
