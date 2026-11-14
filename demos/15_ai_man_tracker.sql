/* Spatial Studio demo pack 15 - The AI Man Tracker */

--#demo The AI Man's December
--#desc Every scheme of his month on the globe, joined in date order. Geography edges are great circles, so the hops bend.
--#desc The same data drives the web page (web/ai-man-tracker.html).
--#view map
--#tags tracker.Escapade, STRING_AGG, geography LINESTRING
SELECT shape = geography::STGeomFromText('LINESTRING (' +
           STRING_AGG(CAST(CONCAT(Geog.Long, ' ', Geog.Lat) AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY [Day]) + ')', 4326),
       label = 'his December', color = '#ffd36b'
FROM tracker.Escapade WHERE [Day] <> 24;
SELECT [Day], Place, Title, Geog,
       label = CONCAT(CASE WHEN [Day] = 0 THEN '30 Nov' ELSE CONCAT([Day], ' Dec') END, ': ', Title),
       color = CASE WHEN Brian = 1 THEN '#d8924a' ELSE '#c9d2de' END
FROM tracker.Escapade WHERE [Day] <> 24
ORDER BY [Day];

--#demo His mileage
--#desc LAG gets the previous day's position and STDistance measures the hop on the WGS84 ellipsoid. A running SUM gives his air miles.
--#tags STDistance, LAG, window functions
WITH hops AS (
    SELECT [Day], Place, Title, Geog, prev = LAG(Geog) OVER (ORDER BY [Day])
    FROM tracker.Escapade WHERE [Day] <> 24)
SELECT [Day], Place, Title,
       [hop km] = CAST(ISNULL(Geog.STDistance(prev), 0) / 1000 AS decimal(9, 0)),
       [total km] = CAST(SUM(ISNULL(Geog.STDistance(prev), 0)) OVER (ORDER BY [Day]) / 1000 AS decimal(9, 0)),
       [total miles] = CAST(SUM(ISNULL(Geog.STDistance(prev), 0)) OVER (ORDER BY [Day]) / 1609.344 AS decimal(9, 0))
FROM hops ORDER BY [Day];

--#demo Santa's Christmas Eve, leg by leg
--#desc Each stop at about local midnight. Leg distance with STDistance, flying time from the timetable, and the speed that implies.
--#view map
--#tags tracker.SantaStop, STDistance, DATEDIFF, LEAD
WITH legs AS (
    SELECT Seq, City, Geog, VisitUtc, nextCity = LEAD(City) OVER (ORDER BY Seq), nextGeog = LEAD(Geog) OVER (ORDER BY Seq),
           nextUtc = LEAD(VisitUtc) OVER (ORDER BY Seq)
    FROM tracker.SantaStop)
SELECT Seq, [from] = City, [to] = nextCity, [leaves UTC] = VisitUtc,
       [km] = CAST(Geog.STDistance(nextGeog) / 1000 AS decimal(9, 0)),
       [minutes] = DATEDIFF(MINUTE, VisitUtc, nextUtc),
       [km/h] = CAST(Geog.STDistance(nextGeog) / 1000 / NULLIF(DATEDIFF(MINUTE, VisitUtc, nextUtc) / 60.0, 0) AS decimal(9, 0)),
       shape = geography::STGeomFromText(CONCAT('LINESTRING (', Geog.Long, ' ', Geog.Lat, ', ', nextGeog.Long, ' ', nextGeog.Lat, ')'), 4326),
       color = '#ffd36b'
FROM legs WHERE nextGeog IS NOT NULL AND Geog.STDistance(nextGeog) > 0
ORDER BY Seq;
SELECT Geog, label = City, color = '#ff4d4d' FROM tracker.SantaStop WHERE Seq BETWEEN 1 AND (SELECT MAX(Seq) - 1 FROM tracker.SantaStop);

--#demo The chase, animated
--#desc Every 10 minutes of Christmas Eve: Santa's position slerped along his current leg with sx.Interpolate, The AI Man in the same place 40 minutes later,
--#desc and the gap between them drawn with ShortestLineTo and measured with STDistance. Press play.
--#view map
--#tags sx.Interpolate, ShortestLineTo, STDistance, animation, frame
SET NOCOUNT ON;
DECLARE @t0 datetime2(0) = (SELECT MIN(VisitUtc) FROM tracker.SantaStop), @t1 datetime2(0) = (SELECT MAX(VisitUtc) FROM tracker.SantaStop);
DROP TABLE IF EXISTS #pos;
WITH f AS (
    SELECT frame = g.value, t = DATEADD(MINUTE, g.value * 10, @t0)
    FROM GENERATE_SERIES(0, DATEDIFF(MINUTE, @t0, @t1) / 10) AS g),
who AS (
    SELECT f.frame, f.t, w.Who, tt = CASE WHEN DATEADD(MINUTE, w.LagMin, f.t) < @t0 THEN @t0 ELSE DATEADD(MINUTE, w.LagMin, f.t) END
    FROM f CROSS JOIN (VALUES ('Santa', 0), ('AI Man', -40)) AS w (Who, LagMin))
SELECT who.frame, who.Who, who.tt,
       g = CASE WHEN b.Geog IS NULL THEN a.Geog
                ELSE sx.Interpolate(a.Geog, b.Geog, DATEDIFF(SECOND, a.VisitUtc, who.tt) * 1.0 / NULLIF(DATEDIFF(SECOND, a.VisitUtc, b.VisitUtc), 0)) END,
       nearCity = a.City
INTO #pos
FROM who
CROSS APPLY (SELECT TOP (1) s.Seq, s.City, s.Geog, s.VisitUtc FROM tracker.SantaStop AS s WHERE s.VisitUtc <= who.tt ORDER BY s.VisitUtc DESC, s.Seq DESC) AS a
OUTER APPLY (SELECT s.Geog, s.VisitUtc FROM tracker.SantaStop AS s WHERE s.Seq = a.Seq + 1) AS b;

SELECT shape = geography::STGeomFromText('LINESTRING (' +
           STRING_AGG(CAST(CONCAT(Geog.Long, ' ', Geog.Lat) AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY Seq) + ')', 4326),
       color = '#8a7a4a'
FROM tracker.SantaStop WHERE Seq > 0 AND Seq < (SELECT MAX(Seq) FROM tracker.SantaStop);
SELECT s.frame, shape = s.g.ShortestLineTo(a.g),
       label = CONCAT(FORMAT(s.g.STDistance(a.g) / 1000, 'N0'), ' km'), color = '#93a0bb'
FROM #pos AS s JOIN #pos AS a ON a.frame = s.frame AND a.Who = 'AI Man'
WHERE s.Who = 'Santa' AND s.g.STDistance(a.g) > 1000;
SELECT frame, shape = g, label = CONCAT(Who, ' ', FORMAT(tt, 'HH:mm')), color = CASE Who WHEN 'Santa' THEN '#ff4d4d' ELSE '#c9d2de' END
FROM #pos ORDER BY frame, Who DESC;

--#demo Where was he furthest behind?
--#desc The same positions as the animation, ranked by the gap. Not that it ever mattered.
--#tags STDistance, TOP, ranking
SET NOCOUNT ON;
DECLARE @t0 datetime2(0) = (SELECT MIN(VisitUtc) FROM tracker.SantaStop), @t1 datetime2(0) = (SELECT MAX(VisitUtc) FROM tracker.SantaStop);
WITH f AS (SELECT t = DATEADD(MINUTE, g.value * 5, @t0) FROM GENERATE_SERIES(0, DATEDIFF(MINUTE, @t0, @t1) / 5) AS g),
p AS (
    SELECT f.t, w.Who, tt = CASE WHEN DATEADD(MINUTE, w.LagMin, f.t) < @t0 THEN @t0 ELSE DATEADD(MINUTE, w.LagMin, f.t) END
    FROM f CROSS JOIN (VALUES ('Santa', 0), ('AI Man', -40)) AS w (Who, LagMin)),
g AS (
    SELECT p.t, p.Who, a.City,
           g = CASE WHEN b.Geog IS NULL THEN a.Geog
                    ELSE sx.Interpolate(a.Geog, b.Geog, DATEDIFF(SECOND, a.VisitUtc, p.tt) * 1.0 / NULLIF(DATEDIFF(SECOND, a.VisitUtc, b.VisitUtc), 0)) END
    FROM p
    CROSS APPLY (SELECT TOP (1) s.Seq, s.City, s.Geog, s.VisitUtc FROM tracker.SantaStop AS s WHERE s.VisitUtc <= p.tt ORDER BY s.VisitUtc DESC, s.Seq DESC) AS a
    OUTER APPLY (SELECT s.Geog, s.VisitUtc FROM tracker.SantaStop AS s WHERE s.Seq = a.Seq + 1) AS b)
SELECT TOP (10) [UTC] = s.t, [Santa just left] = s.City, [AI Man just left] = a.City,
       [gap km] = CAST(s.g.STDistance(a.g) / 1000 AS decimal(9, 0))
FROM g AS s JOIN g AS a ON a.t = s.t AND a.Who = 'AI Man'
WHERE s.Who = 'Santa'
ORDER BY s.g.STDistance(a.g) DESC;

--#demo Export the tracker as JSON
--#desc One FOR JSON query rebuilds the whole data file the web page runs on: escapades with their nested logs, and Santa's timetable.
--#tags FOR JSON, JSON_QUERY, export
SELECT lagMinutes = 40,
       escapades = JSON_QUERY((
           SELECT [day] = e.[Day], place = e.Place, lat = e.Geog.Lat, lon = e.Geog.Long, title = e.Title,
                  scheme = e.Scheme, outcome = e.Outcome, mood = e.Mood, brian = e.Brian,
                  [log] = JSON_QUERY((SELECT t = l.LogTime, [text] = l.[Text] FROM tracker.EscapadeLog AS l
                                      WHERE l.[Day] = e.[Day] ORDER BY l.Seq FOR JSON PATH))
           FROM tracker.Escapade AS e ORDER BY e.[Day] FOR JSON PATH)),
       santa = JSON_QUERY((
           SELECT city = City, lat = Geog.Lat, lon = Geog.Long, [offset] = UtcOffset,
                  utc = CONVERT(varchar(19), VisitUtc, 126) + 'Z', gag = Gag
           FROM tracker.SantaStop ORDER BY Seq FOR JSON PATH))
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
