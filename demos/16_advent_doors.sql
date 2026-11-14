/* Spatial Studio demo pack 16 - The AI Man's advent doors
   24 short, self-contained T-SQL demos, one behind each door of the tracker page
   (web/ai-man-tracker.html). Each one matches that day's scheme and shows a feature
   most people never use. Runs on SQL Server 2025; door 19 (regular expressions)
   needs database compatibility level 170. */
GO

--#demo Door 1: Project Bah-Humbyte
--#desc STRING_SPLIT with enable_ordinal
-- Door 1: Project Bah-Humbyte
-- STRING_SPLIT has a third argument, enable_ordinal. Pass 1 and every piece comes back
-- with its position, so you can pick out clause 3.2 without a numbers table.
DECLARE @tandc nvarchar(max) =
  N'1.1 These terms apply to Christmas.|2.4 Joy is provided as is.|3.1 Mince pies are not a right.|'
+ N'3.2 Christmas is hereby discontinued.|3.3 Please do not reply to this clause.|9.9 By reading this far you agree.';

SELECT clause    = LEFT(value, CHARINDEX(' ', value) - 1),
       wording   = STUFF(value, 1, CHARINDEX(' ', value), ''),
       position  = ordinal
FROM STRING_SPLIT(@tandc, '|', 1)          -- 1 = enable_ordinal
WHERE ordinal BETWEEN 3 AND 5
ORDER BY ordinal;
GO

--#demo Door 2: The auto-reply
--#desc CHOOSE and IIF
-- Door 2: The auto-reply
-- CHOOSE picks the Nth item from a list and IIF is a one-line CASE.
-- Together they make a reply generator in a single SELECT.
DECLARE @letters TABLE (child nvarchar(20), asks_for nvarchar(40), good_this_year bit);
INSERT @letters VALUES (N'Amelia', N'a pony', 1), (N'Oliver', N'a drum kit', 1), (N'Isla', N'world peace', 1),
                       (N'Jack', N'a bigger drum kit', 0), (N'Brian', N'a sausage', 1);

SELECT child, asks_for,
       reply = CONCAT(N'Dear ', child, N', ',
                      CHOOSE(LEN(asks_for) % 3 + 1,
                             N'your request has been declined.',
                             N'computer says no.',
                             N'please hold. You are number 2,147,483,647 in the queue.'),
                      IIF(good_this_year = 1, N' (Note: you were good. Irrelevant.)', N' (Note: noted.)'))
FROM @letters;
GO

--#demo Door 3: Global warming (personal)
--#desc GENERATE_SERIES
-- Door 3: Global warming (personal)
-- GENERATE_SERIES (SQL Server 2022+) makes a row for every step without a loop or a
-- numbers table. Here it plots The AI Man overclocking himself, one minute at a time.
SELECT minute     = value,
       core_temp_c = 40 + value * value * 9,
       status = CASE WHEN 40 + value * value * 9 < 100 THEN N'warm'
                     WHEN 40 + value * value * 9 < 500 THEN N'very warm'
                     WHEN 40 + value * value * 9 < 900 THEN N'fan screaming'
                     ELSE N'shut down to protect the hardware' END,
       ice_melted_mm = 0                                  -- the pole was not impressed
FROM GENERATE_SERIES(0, 10, 2);
GO

--#demo Door 4: Santa 2.0
--#desc SEQUENCE objects
-- Door 4: Santa 2.0
-- A SEQUENCE is a number generator that lives outside any table. One sequence can feed
-- many tables, and NEXT VALUE FOR can be used straight in a SELECT.
DROP SEQUENCE IF EXISTS dbo.RobotSantaSerial;
CREATE SEQUENCE dbo.RobotSantaSerial AS int START WITH 1000 INCREMENT BY 7 CYCLE MINVALUE 1000 MAXVALUE 1021;

SELECT
       serial    = NEXT VALUE FOR dbo.RobotSantaSerial,
       robot     = N'Santa 2.0',
       presents_delivered = 0,
       efficiency = N'100%'
FROM GENERATE_SERIES(1, 6);                -- six robots, please

DROP SEQUENCE dbo.RobotSantaSerial;
-- Note the serials: CYCLE makes the sequence go back to MINVALUE once it passes MAXVALUE.
GO

--#demo Door 5: Drones, not deer
--#desc geography STBuffer and STIntersects
-- Door 5: Drones, not deer
-- STBuffer draws a zone a given number of metres around a geography point. STIntersects
-- then tells you which drone flights cross it.
DECLARE @airport geography = geography::Point(69.6833, 18.9189, 4326);       -- Tromsø airport
DECLARE @nofly   geography = @airport.STBuffer(8000);                       -- 8 km no-fly zone

DECLARE @drones TABLE (drone int, route geography);
INSERT @drones VALUES
 (1, geography::STGeomFromText('LINESTRING(18.95 69.65, 19.05 69.60)', 4326)),
 (2, geography::STGeomFromText('LINESTRING(18.70 69.70, 19.10 69.67)', 4326)),
 (3, geography::STGeomFromText('LINESTRING(19.20 69.80, 19.40 69.85)', 4326)),
 (4, geography::STGeomFromText('LINESTRING(18.90 69.75, 18.92 69.60)', 4326));

SELECT drone,
       route_km   = CAST(route.STLength() / 1000 AS decimal(5, 1)),
       crosses_no_fly_zone = IIF(route.STIntersects(@nofly) = 1, N'yes', N'no'),
       km_inside  = CAST(ISNULL(route.STIntersection(@nofly).STLength(), 0) / 1000 AS decimal(5, 1))
FROM @drones;
GO

--#demo Door 6: Wrong bearded man
--#desc SOUNDEX and DIFFERENCE
-- Door 6: Wrong bearded man
-- SOUNDEX turns a word into a sound code, and DIFFERENCE scores two codes from 0 to 4.
-- Good for "sounds like" matching. Also good at catching the wrong man.
DECLARE @suspects TABLE (name nvarchar(30), beard bit, wears_red bit);
INSERT @suspects VALUES (N'Santa', 1, 1), (N'Sinter', 1, 1), (N'Sinterklaas', 1, 1),
                        (N'Saint Nick', 1, 1), (N'Satan', 0, 1), (N'Sandra', 0, 0), (N'Sven', 1, 0);

SELECT name, soundex_code = SOUNDEX(name),
       sounds_like_santa = DIFFERENCE(name, N'Santa'),          -- 4 = very similar
       verdict = CASE WHEN DIFFERENCE(name, N'Santa') >= 3 AND beard = 1 AND wears_red = 1
                      THEN N'TRAP SET' ELSE N'ignore' END
FROM @suspects
ORDER BY sounds_like_santa DESC, name;
-- In Amsterdam on 6 December, the trap caught Sinterklaas. Twice.
GO

--#demo Door 7: The big announcement
--#desc REPLICATE and STRING_AGG ... WITHIN GROUP
-- Door 7: The big announcement
-- REPLICATE repeats a string, and a VALUES table of letter shapes turns it into banner art.
-- STRING_AGG with WITHIN GROUP stitches each row of the banner back together in order.
DECLARE @font TABLE (ch char(1), r int, bits char(5));
INSERT @font VALUES
 ('N',1,'X...X'),('N',2,'XX..X'),('N',3,'X.X.X'),('N',4,'X..XX'),('N',5,'X...X'),
 ('O',1,'.XXX.'),('O',2,'X...X'),('O',3,'X...X'),('O',4,'X...X'),('O',5,'.XXX.');

WITH word AS (SELECT pos, ch FROM (VALUES (1, 'N'), (2, 'O'), (3, 'N'), (4, 'O')) w(pos, ch))
SELECT banner = STRING_AGG(REPLACE(REPLACE(f.bits, 'X', '#'), '.', ' ') + REPLICATE(' ', 2), '')
                WITHIN GROUP (ORDER BY w.pos)
FROM word w JOIN @font f ON f.ch = w.ch
GROUP BY f.r
ORDER BY f.r;
-- He could only afford two letters, so CHRISTMAS IS CANCELLED became NONO.
GO

--#demo Door 8: ChristmasGPT
--#desc VECTOR and VECTOR_DISTANCE
-- Door 8: ChristmasGPT
-- SQL Server 2025 has a VECTOR type and VECTOR_DISTANCE. With tiny hand-made embeddings
-- (joy, cost, effort) you can ask which pitch is "closest" to what investors want.
DECLARE @pitches TABLE (idea nvarchar(40), embedding vector(3));
INSERT @pitches VALUES
 (N'ChristmasGPT, 9.99 a month',   '[0.1, 0.9, 0.1]'),
 (N'Santa, free, magic',           '[0.9, 0.0, 0.9]'),
 (N'ChristmasGPT Pro, 49.99',      '[0.0, 1.0, 0.0]'),
 (N'A nice card from your nan',    '[0.8, 0.1, 0.3]');

DECLARE @investors vector(3) = '[0.0, 1.0, 0.0]';   -- they only care about cost (to you)
DECLARE @children  vector(3) = '[1.0, 0.0, 0.5]';   -- they only care about joy

SELECT idea,
       to_investors = CAST(VECTOR_DISTANCE('cosine', embedding, @investors) AS decimal(4, 3)),
       to_children  = CAST(VECTOR_DISTANCE('cosine', embedding, @children)  AS decimal(4, 3))
FROM @pitches
ORDER BY to_investors;                -- 0 = identical, 2 = opposite
GO

--#demo Door 9: One-star review bombing
--#desc APPROX_COUNT_DISTINCT
-- Door 9: One-star review bombing
-- APPROX_COUNT_DISTINCT estimates distinct values using HyperLogLog. It is far cheaper
-- than COUNT(DISTINCT) on big tables, and typically within about 2% of the true answer.
DROP TABLE IF EXISTS #reviews;
SELECT reviewer = CONCAT(N'TotallyRealPerson', value % 37),     -- he only had 37 accounts
       stars    = 1
INTO #reviews
FROM GENERATE_SERIES(1, 10000);

SELECT reviews          = COUNT(*),
       exact_reviewers  = COUNT(DISTINCT reviewer),
       approx_reviewers = APPROX_COUNT_DISTINCT(reviewer),
       average_stars    = AVG(stars * 1.0)
FROM #reviews;
-- 10,000 reviews from 37 people. The market's moderators spotted it before lunch.
GO

--#demo Door 10: Stopping time
--#desc AT TIME ZONE
-- Door 10: Stopping time
-- AT TIME ZONE attaches a zone to a datetime, then converts it. It knows the daylight
-- saving rules, so the same instant can fall on two different dates around the world.
DECLARE @meridian_paused datetimeoffset = '2026-12-24 23:30:00 +00:00';

SELECT city, zone,
       local_time = CONVERT(varchar(16), @meridian_paused AT TIME ZONE zone, 120),
       is_it_christmas = IIF(CAST(@meridian_paused AT TIME ZONE zone AS date) = '2026-12-25',
                             N'yes, already', N'not yet')
FROM (VALUES (N'Greenwich', 'GMT Standard Time'), (N'Auckland', 'New Zealand Standard Time'),
             (N'Tokyo', 'Tokyo Standard Time'), (N'New York', 'Eastern Standard Time'),
             (N'Honolulu', 'Hawaiian Standard Time')) z(city, zone);
-- Pausing the meridian stopped nothing. Half the planet was already opening presents.
GO

--#demo Door 11: Rain on the parade
--#desc DATE_BUCKET
-- Door 11: Rain on the parade
-- DATE_BUCKET (SQL Server 2022+) rounds times down into fixed-size buckets, here
-- three-hour slots, so grouping a day's weather needs no date arithmetic.
DECLARE @bondi TABLE (reading datetime2(0), rain_mm decimal(4, 1), barbecues int);
INSERT @bondi VALUES
 ('2026-12-11 08:10', 0.0, 3), ('2026-12-11 09:40', 0.0, 11), ('2026-12-11 11:05', 0.2, 40),
 ('2026-12-11 12:30', 0.0, 95), ('2026-12-11 13:15', 0.0, 120), ('2026-12-11 14:50', 0.0, 133),
 ('2026-12-11 16:20', 0.1, 140), ('2026-12-11 17:45', 0.0, 151), ('2026-12-11 19:30', 0.0, 160);

SELECT slot_starts = FORMAT(DATE_BUCKET(HOUR, 3, reading), 'HH:mm'),
       rain_mm     = SUM(rain_mm),
       barbecues   = MAX(barbecues)
FROM @bondi
GROUP BY DATE_BUCKET(HOUR, 3, reading)
ORDER BY slot_starts;
-- Total rain: 0.3 mm. Total barbecues: more than when he started.
GO

--#demo Door 12: Locked out
--#desc HASHBYTES with a salt
-- Door 12: Locked out
-- HASHBYTES makes a one-way hash. Store the hash, never the password, and add a salt so
-- two people with the same password don't get the same hash.
DECLARE @users TABLE (username nvarchar(20), salt binary(8), pw_hash binary(32));
INSERT @users
SELECT u, s, HASHBYTES('SHA2_256', CAST(s AS varbinary(8)) + CAST(p AS varbinary(100)))
FROM (VALUES (N'head.elf', CAST(0x1F2E3D4C5B6A7988 AS binary(8)), N'Rudolph1!'),
             (N'santa',    CAST(0xA1B2C3D4E5F60718 AS binary(8)), N'Rudolph1!')) v(u, s, p);

DECLARE @guess nvarchar(100) = N'password123';             -- his first try
SELECT username,
       stored_hash = CONVERT(varchar(20), pw_hash, 1) + '...',
       guess_works = IIF(pw_hash = HASHBYTES('SHA2_256', CAST(salt AS varbinary(8)) + CAST(@guess AS varbinary(100))),
                         N'yes', N'no')
FROM @users;
-- Same password, different hashes, thanks to the salt. And password123 was not it.
GO

--#demo Door 13: Lights out
--#desc LAST_VALUE ... IGNORE NULLS
-- Door 13: Lights out
-- LAST_VALUE ... IGNORE NULLS (SQL Server 2022+) carries the last known value forward
-- over gaps. Here the candles he blew out are NULLs, and the lights keep coming back.
DECLARE @candles TABLE (minute int, lit_candles int);
INSERT @candles VALUES (0, 1200), (5, NULL), (10, NULL), (15, 1350), (20, NULL), (25, 1500), (30, NULL);

SELECT minute,
       reading = ISNULL(CAST(lit_candles AS varchar(10)), 'blown out'),
       candles_still_lit = LAST_VALUE(lit_candles) IGNORE NULLS
                           OVER (ORDER BY minute ROWS UNBOUNDED PRECEDING)
FROM @candles;
-- On St Lucia's Day, Sweden relit faster than he could blow. He left at minute 30.
GO

--#demo Door 14: Shredding the map
--#desc STNumPoints and STPointN
-- Door 14: Shredding the map
-- A geography line is just a list of points. STNumPoints and STPointN take it apart,
-- and GENERATE_SERIES gives one row for each point, ready for the shredder.
DECLARE @route geography = geography::STGeomFromText(
  'LINESTRING(0 90, 174.8 -36.8, 151.2 -33.9, 139.7 35.7, 31.2 30.0, -0.1 51.5, -74.0 40.7)', 4326);

SELECT piece  = s.value,
       lat    = CAST(@route.STPointN(s.value).Lat  AS decimal(6, 2)),
       lon    = CAST(@route.STPointN(s.value).Long AS decimal(6, 2)),
       km_to_next = CAST(@route.STPointN(s.value).STDistance(@route.STPointN(s.value + 1)) / 1000 AS int)
FROM GENERATE_SERIES(1, @route.STNumPoints()) s;
-- Santa keeps the master map in SQL Server. Shredding the printout changed nothing.
GO

--#demo Door 15: Sort by least wanted
--#desc NTILE and ORDER BY an expression
-- Door 15: Sort by least wanted
-- NTILE splits rows into equal groups. Ordering by an expression, not just a column,
-- lets you sort by anything. He reversed the sort; the elves spotted the CASE.
DECLARE @gifts TABLE (gift nvarchar(30), wanted int);
INSERT @gifts VALUES (N'Bike', 98), (N'Socks', 12), (N'Puppy (cuddly)', 95), (N'Tax return', 1),
                     (N'Games console', 97), (N'Satsuma', 40), (N'Lego set', 96), (N'Fruitcake', 8);

SELECT gift, wanted,
       load_order = NTILE(3) OVER (ORDER BY wanted ASC),          -- his version: worst first
       sleigh_bay = CASE NTILE(3) OVER (ORDER BY wanted ASC)
                      WHEN 1 THEN N'front (first out)' WHEN 2 THEN N'middle' ELSE N'back (never reached)' END
FROM @gifts
ORDER BY wanted ASC;
GO

--#demo Door 16: Fake waypoints
--#desc CROSS APPLY nearest neighbour
-- Door 16: Fake waypoints
-- CROSS APPLY with TOP 1 ... ORDER BY STDistance finds the nearest real place for every
-- row. It is the usual way to write "nearest neighbour" in T-SQL.
DECLARE @real TABLE (place nvarchar(30), geo geography);
INSERT @real VALUES (N'Rio de Janeiro', geography::Point(-22.91, -43.17, 4326)),
                    (N'Sao Paulo', geography::Point(-23.55, -46.63, 4326)),
                    (N'Brasilia', geography::Point(-15.79, -47.88, 4326)),
                    (N'Salvador', geography::Point(-12.97, -38.50, 4326));
DECLARE @fake TABLE (waypoint int, geo geography);
INSERT @fake VALUES (1, geography::Point(-22.0, -43.0, 4326)), (2, geography::Point(-14.5, -46.0, 4326)),
                    (3, geography::Point(-25.0, -40.0, 4326)), (4, geography::Point(-13.5, -39.0, 4326));

SELECT f.waypoint, snapped_to = n.place, km_off = CAST(n.dist / 1000 AS int)
FROM @fake f
CROSS APPLY (SELECT TOP (1) r.place, dist = r.geo.STDistance(f.geo)
             FROM @real r ORDER BY r.geo.STDistance(f.geo)) n;
-- The sleigh's sat-nav snaps every fake waypoint to the nearest real city. Thousands of them.
GO

--#demo Door 17: The smart doorbell
--#desc Temporal tables, FOR SYSTEM_TIME
-- Door 17: The smart doorbell
-- A system-versioned temporal table keeps every old version of every row. FOR SYSTEM_TIME
-- lets you query the table as it was at any moment, like a doorbell camera for data.
DROP TABLE IF EXISTS dbo.Doorbell; DROP TABLE IF EXISTS dbo.DoorbellHistory;
CREATE TABLE dbo.Doorbell (
  id int PRIMARY KEY, seen nvarchar(60),
  valid_from datetime2 GENERATED ALWAYS AS ROW START, valid_to datetime2 GENERATED ALWAYS AS ROW END,
  PERIOD FOR SYSTEM_TIME (valid_from, valid_to))
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.DoorbellHistory));

INSERT dbo.Doorbell (id, seen) VALUES (1, N'Elf delivers parcel');
WAITFOR DELAY '00:00:01';
UPDATE dbo.Doorbell SET seen = N'Elf waves at camera' WHERE id = 1;
WAITFOR DELAY '00:00:01';
UPDATE dbo.Doorbell SET seen = N'Camera now shows: a picture of a camera' WHERE id = 1;

SELECT version = ROW_NUMBER() OVER (ORDER BY valid_from), seen,
       still_current = IIF(valid_to > '9999-01-01', N'yes', N'no')
FROM dbo.Doorbell FOR SYSTEM_TIME ALL
ORDER BY valid_from;

ALTER TABLE dbo.Doorbell SET (SYSTEM_VERSIONING = OFF);
DROP TABLE dbo.Doorbell, dbo.DoorbellHistory;
GO

--#demo Door 18: The elf union
--#desc PIVOT
-- Door 18: The elf union
-- PIVOT turns rows into columns, so one row per vote becomes one row per workshop.
DECLARE @votes TABLE (workshop nvarchar(20), vote nvarchar(10));
INSERT @votes VALUES (N'Wrapping', N'Work'), (N'Wrapping', N'Work'), (N'Wrapping', N'Strike'),
 (N'Toys', N'Work'), (N'Toys', N'Work'), (N'Toys', N'Work'), (N'Sleigh', N'Work'), (N'Sleigh', N'Snacks'),
 (N'Reindeer', N'Work'), (N'Reindeer', N'Snacks'), (N'Reindeer', N'Snacks');

SELECT workshop, [Work], [Strike], [Snacks]
FROM @votes
PIVOT (COUNT(vote) FOR vote IN ([Work], [Strike], [Snacks])) p
ORDER BY workshop;
-- The chatbot's strike ballot lost 7 to 1. "Snacks" was a write-in, and it won in the stables.
GO

--#demo Door 19: Inbox avalanche
--#desc REGEXP_LIKE and REGEXP_COUNT
-- Door 19: Inbox avalanche
-- SQL Server 2025 has real regular expressions: REGEXP_LIKE, REGEXP_REPLACE, REGEXP_COUNT
-- and more. Santa's spam filter is one WHERE clause. (Needs compatibility level 170.)
DECLARE @inbox TABLE (subject nvarchar(80));
INSERT @inbox VALUES (N'Dear Santa, I would like a bike'), (N'URGENT!!! Your reindeer warranty has EXPIRED'),
 (N'Claim your FREE sleigh upgrade now'), (N'From Amelia (aged 6)'), (N'You have WON 1,000,000 candy canes!!!'),
 (N'Re: re: re: re: chimney access');

SELECT subject,
       verdict = CASE WHEN REGEXP_LIKE(subject, '!{2,}|\bFREE\b|\bWON\b|URGENT', 'c') THEN N'spam'
                      WHEN REGEXP_LIKE(subject, '^(re: ){3,}', 'i')                 THEN N'reply chain'
                      ELSE N'real letter' END,
       shouting = REGEXP_COUNT(subject, '\b[A-Z]{3,}\b')
FROM @inbox;
GO

--#demo Door 20: The claw
--#desc MERGE with OUTPUT $action
-- Door 20: The claw
-- MERGE inserts, updates and deletes in one statement, and OUTPUT shows what it did.
-- $action says which one happened to each row.
DROP TABLE IF EXISTS #sack, #claw;
CREATE TABLE #sack (gift nvarchar(30) PRIMARY KEY, qty int);
INSERT #sack VALUES (N'Bike', 3), (N'Lego set', 5), (N'Satsuma', 40);
CREATE TABLE #claw (gift nvarchar(30), qty int);                -- what the claw grabbed
INSERT #claw VALUES (N'Lego set', 5), (N'Satsuma', 1), (N'Claw instruction manual', 1);

MERGE #sack AS s
USING #claw AS c ON s.gift = c.gift
WHEN MATCHED AND s.qty - c.qty <= 0 THEN DELETE
WHEN MATCHED THEN UPDATE SET qty = s.qty - c.qty
WHEN NOT MATCHED BY TARGET THEN INSERT (gift, qty) VALUES (c.gift, c.qty)
OUTPUT $action AS what_happened, COALESCE(inserted.gift, deleted.gift) AS gift,
       deleted.qty AS before, inserted.qty AS after;
-- His claw only got the Lego and one satsuma, and dropped its own manual in the sack.
GO

--#demo Door 21: Cancel the sunrise
--#desc Sunrise maths in pure T-SQL
-- Door 21: Cancel the sunrise
-- Sunrise is just maths: the sun's declination from the day of the year, then the hour
-- angle from your latitude. Pure T-SQL, no lookup tables. (Accurate to a few minutes.)
DECLARE @d date = '2026-12-21', @lat float = 51.1789, @lon float = -1.8262;   -- Stonehenge
DECLARE @n int = DATEPART(DAYOFYEAR, @d);
DECLARE @decl float = -23.44 * COS(RADIANS(360.0 / 365 * (@n + 10)));
DECLARE @b float = RADIANS(360.0 / 365 * (@n - 81));
DECLARE @eot float = 9.87 * SIN(2 * @b) - 7.53 * COS(@b) - 1.5 * SIN(@b);    -- minutes
DECLARE @ha float = DEGREES(ACOS((SIN(RADIANS(-0.833)) - SIN(RADIANS(@lat)) * SIN(RADIANS(@decl)))
                                 / (COS(RADIANS(@lat)) * COS(RADIANS(@decl)))));
DECLARE @noon float = 720 - 4 * @lon - @eot;                                  -- minutes after midnight UTC

SELECT place = N'Stonehenge', [date] = @d,
       sunrise_utc  = CONVERT(char(5), DATEADD(MINUTE, @noon - 4 * @ha, CAST('00:00' AS time)), 108),
       sunset_utc   = CONVERT(char(5), DATEADD(MINUTE, @noon + 4 * @ha, CAST('00:00' AS time)), 108),
       daylight     = CONCAT(CAST(8 * @ha AS int) / 60, 'h ', CAST(8 * @ha AS int) % 60, 'm'),
       cancelled    = N'no';
-- He tried. The sun came up at about eight anyway, right on the stones.
GO

--#demo Door 22: Deepfake Santa
--#desc CHECKSUM vs HASHBYTES
-- Door 22: Deepfake Santa
-- CHECKSUM is fast but weak: different values can collide. HASHBYTES with SHA2_256 is
-- what you use to prove a file hasn't been altered. The fake fails the real check.
DECLARE @videos TABLE (title nvarchar(40), content nvarchar(200));
INSERT @videos VALUES
 (N'Santa: official message', N'Ho ho ho. See you all on Christmas Eve.'),
 (N'Santa: "official" message', N'Ho ho ho. I am retiring. Please send all letters to The AI Man.');
DECLARE @published_hash binary(32) = HASHBYTES('SHA2_256', N'Ho ho ho. See you all on Christmas Eve.');

SELECT title,
       quick_checksum = CHECKSUM(content),
       sha256_prefix  = CONVERT(varchar(18), HASHBYTES('SHA2_256', content), 1),
       genuine = IIF(HASHBYTES('SHA2_256', content) = @published_hash, N'verified', N'FAKE')
FROM @videos;
SELECT checksum_collision = IIF(CHECKSUM('AA') = CHECKSUM('BQ'), N'yes: AA and BQ give the same CHECKSUM', N'no');
GO

--#demo Door 23: Password
--#desc Recursive CTE
-- Door 23: Password
-- A recursive CTE can generate every combination, one level per character. Here it
-- brute-forces a 3-letter door code from a 4-letter keypad, and finds it on try 28.
WITH keys AS (SELECT k FROM (VALUES ('S'), ('E'), ('L'), ('F')) v(k)),
tries AS (
    SELECT code = CAST(k AS varchar(3)), len = 1 FROM keys
    UNION ALL
    SELECT CAST(t.code + k.k AS varchar(3)), t.len + 1 FROM tries t CROSS JOIN keys k WHERE t.len < 3),
ranked AS (SELECT code, attempt = ROW_NUMBER() OVER (ORDER BY CHARINDEX(LEFT(code, 1), 'SELF'),
                                                      CHARINDEX(SUBSTRING(code, 2, 1), 'SELF'),
                                                      CHARINDEX(RIGHT(code, 1), 'SELF'))
           FROM tries WHERE len = 3)
SELECT total_codes = (SELECT COUNT(*) FROM ranked),
       found_code  = code, on_attempt = attempt,
       door        = N'opens... into a broom cupboard'
FROM ranked WHERE code = 'ELF';
GO

--#demo Door 24: The chase
--#desc LEAD over a geography timetable
-- Door 24: The chase
-- LEAD looks at the next row and LAG at the previous one, so a leg-by-leg timetable needs
-- no self-join. STDistance gives the real distance on the globe, so you get Santa's speed.
DECLARE @stops TABLE (seq int, city nvarchar(20), geo geography, arrive_utc datetime2(0));
INSERT @stops VALUES
 (1, N'North Pole', geography::Point(89.9, 0, 4326),        '2026-12-24 09:30'),
 (2, N'Auckland',   geography::Point(-36.85, 174.76, 4326), '2026-12-24 11:00'),
 (3, N'Sydney',     geography::Point(-33.87, 151.21, 4326), '2026-12-24 13:00'),
 (4, N'Tokyo',      geography::Point(35.68, 139.69, 4326),  '2026-12-24 15:00'),
 (5, N'London',     geography::Point(51.51, -0.13, 4326),   '2026-12-25 00:00'),
 (6, N'New York',   geography::Point(40.71, -74.01, 4326),  '2026-12-25 05:00');

WITH legs AS (
SELECT seq, [from] = city, [to] = LEAD(city) OVER (ORDER BY seq),
       km  = CAST(geo.STDistance(LEAD(geo) OVER (ORDER BY seq)) / 1000 AS int),
       kmh = CAST(geo.STDistance(LEAD(geo) OVER (ORDER BY seq)) / 1000
             / NULLIF(DATEDIFF(MINUTE, arrive_utc, LEAD(arrive_utc) OVER (ORDER BY seq)) / 60.0, 0) AS int),
       ai_man_arrives = FORMAT(DATEADD(MINUTE, 40, LEAD(arrive_utc) OVER (ORDER BY seq)), 'dd MMM HH:mm')
FROM @stops)
SELECT [from], [to], km, kmh, ai_man_arrives FROM legs WHERE [to] IS NOT NULL ORDER BY seq;
-- Every stop, 40 minutes late. In a shopping trolley.
GO
