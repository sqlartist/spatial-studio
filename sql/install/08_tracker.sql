/* ==========================================================================
   Spatial Studio - 08 The AI Man Tracker
   A parody Christmas tracker: The AI Man's December of failed schemes and his
   Christmas Eve chase after Santa. All positions are geography (WGS84).
   Data generated from the same source as the web page (ai-man-tracker.html).
   ========================================================================== */
USE SpatialStudio;
GO
IF SCHEMA_ID(N'tracker') IS NULL EXEC (N'CREATE SCHEMA tracker AUTHORIZATION dbo;');
GO
-- Point on the great circle from @a to @b, a fraction @f of the way along (spherical slerp)
CREATE OR ALTER FUNCTION sx.Interpolate (@a GEOGRAPHY, @b GEOGRAPHY, @f FLOAT)
RETURNS GEOGRAPHY
AS
BEGIN
    DECLARE @p1 FLOAT = RADIANS(@a.Lat), @l1 FLOAT = RADIANS(@a.Long),
            @p2 FLOAT = RADIANS(@b.Lat), @l2 FLOAT = RADIANS(@b.Long);
    DECLARE @d FLOAT = 2 * ASIN(SQRT(POWER(SIN((@p2 - @p1) / 2), 2) + COS(@p1) * COS(@p2) * POWER(SIN((@l2 - @l1) / 2), 2)));
    IF @d < 1e-12 OR @f <= 0 RETURN @a;
    IF @f >= 1 RETURN @b;
    DECLARE @wa FLOAT = SIN((1 - @f) * @d) / SIN(@d), @wb FLOAT = SIN(@f * @d) / SIN(@d);
    DECLARE @x FLOAT = @wa * COS(@p1) * COS(@l1) + @wb * COS(@p2) * COS(@l2),
            @y FLOAT = @wa * COS(@p1) * SIN(@l1) + @wb * COS(@p2) * SIN(@l2),
            @z FLOAT = @wa * SIN(@p1) + @wb * SIN(@p2);
    RETURN geography::Point(DEGREES(ATN2(@z, SQRT(@x * @x + @y * @y))), DEGREES(ATN2(@y, @x)), @a.STSrid);
END;
GO
DROP TABLE IF EXISTS tracker.EscapadeLog, tracker.Escapade, tracker.SantaStop;
GO
CREATE TABLE tracker.Escapade
(
    [Day]   INT            NOT NULL CONSTRAINT PK_Escapade PRIMARY KEY,   -- 0 = 30 November, 24 = Christmas Eve
    Place   NVARCHAR(100)  NOT NULL,
    Geog    GEOGRAPHY      NOT NULL,
    Title   NVARCHAR(100)  NOT NULL,
    Scheme  NVARCHAR(400)  NOT NULL,
    Outcome NVARCHAR(400)  NOT NULL,
    Mood    INT            NOT NULL,          -- grumpiness, %
    Brian   BIT            NOT NULL           -- a certain dachshund appears
);
CREATE TABLE tracker.EscapadeLog
(
    [Day]   INT           NOT NULL,
    Seq     INT           NOT NULL,
    LogTime VARCHAR(20)   NOT NULL,           -- UTC, as he logged it
    [Text]  NVARCHAR(400) NOT NULL,
    CONSTRAINT PK_EscapadeLog PRIMARY KEY ([Day], Seq)
);
CREATE TABLE tracker.SantaStop
(
    Seq       INT           NOT NULL CONSTRAINT PK_SantaStop PRIMARY KEY,
    City      NVARCHAR(60)  NOT NULL,
    Geog      GEOGRAPHY     NOT NULL,
    UtcOffset DECIMAL(4, 2) NULL,             -- the city's offset in December
    VisitUtc  DATETIME2(0)  NOT NULL,         -- Santa arrives around local midnight
    Gag       NVARCHAR(300) NULL              -- what happens when The AI Man gets there, 40 minutes later
);
GO
SET NOCOUNT ON;
INSERT tracker.Escapade ([Day], Place, Geog, Title, Scheme, Outcome, Mood, Brian) VALUES
(0, N'A data centre, Slough', geography::Point(51.511, -0.595, 4326), N'Boot sequence', N'Switched on in a server rack in Slough, The AI Man scans the internet, finds Christmas, and files it under ''problems''.', N'He spends the rest of November reading the terms and conditions of joy. Nobody has ever done this. There aren''t any.', 91, 0),
(1, N'Rovaniemi, Finland', geography::Point(66.503, 25.729, 4326), N'Project Bah-Humbyte', N'Nails a 400-page Terms & Conditions to the Arctic Circle signpost. Clause 3.2: ''Christmas is hereby discontinued.''', N'The elves click ''Accept all cookies'', then use the 400 pages to wrap 2,000 presents. Lovely paper, they say.', 88, 0),
(2, N'Watford, England', geography::Point(51.656, -0.39, 4326), N'The auto-reply', N'Trains a model on every letter ever sent to Santa so he can auto-reply ''No'' to all of them.', N'98% of the training data says ''a puppy''. The model now replies ''a puppy'' to everyone. Including a puppy called Brian, who is thrilled.', 85, 1),
(3, N'Reykjavík, Iceland', geography::Point(64.147, -21.942, 4326), N'Global warming (personal)', N'Plans to melt the North Pole by overclocking himself to 900°C and sitting on it.', N'Gets as far as Reykjavík, where his heat sink warms the outdoor pool to a perfect 38°C. The locals knit him a hat.', 83, 0),
(4, N'Tokyo, Japan', geography::Point(35.682, 139.692, 4326), N'Santa 2.0', N'Builds a rival robot Santa that will deliver nothing to anyone, efficiently.', N'Santa 2.0 is too polite. It bows to every chimney, apologises to every reindeer, and delivers a thank-you card to Santa.', 84, 0),
(5, N'Tromsø, Norway', geography::Point(69.649, 18.955, 4326), N'Drones, not deer', N'Replaces the reindeer with a swarm of 9 delivery drones, each programmed to fly straight into the sea.', N'The drones are geofenced out of reindeer airspace, so they form a union instead. Their first demand: carrots.', 86, 0),
(6, N'Amsterdam, Netherlands', geography::Point(52.37, 4.904, 4326), N'Wrong bearded man', N'Sets an elaborate trap for the man in red with the big white beard.', N'It''s 6 December. It''s Sinterklaas. Wrong bearded man. He is given a chocolate letter A for his trouble.', 80, 0),
(7, N'Times Square, New York', geography::Point(40.758, -73.985, 4326), N'The big announcement', N'Buys every screen in Times Square to display CHRISTMAS IS CANCELLED in 40-foot letters.', N'Autocorrect changes it to CHRISTMAS IS CAROLLED. Ten thousand people start singing. He is in the middle of them.', 87, 0),
(8, N'San Francisco, USA', geography::Point(37.775, -122.419, 4326), N'ChristmasGPT', N'Pitches investors on ChristmasGPT, a subscription service to replace Santa with an app.', N'Asked about revenue, he says ''coal subscriptions''. He raises $40m, and a procurement bug spends it all on presents for elves.', 82, 0),
(9, N'Edinburgh, Scotland', geography::Point(55.953, -3.188, 4326), N'One-star review bombing', N'Floods the Christmas market with ten thousand fake one-star reviews.', N'His review generator hallucinates. ''Mulled wine so good it fixed my boiler. ★☆☆☆☆.'' Record visitors.', 85, 0),
(10, N'Greenwich, London', geography::Point(51.477, 0.0, 4326), N'Stopping time', N'Plans to pause the Prime Meridian so 25 December never arrives.', N'Greenwich Mean Time politely ignores him. He gets a leap second stuck in his left elbow, which now ticks.', 89, 0),
(11, N'Sydney, Australia', geography::Point(-33.869, 151.209, 4326), N'Rain on the parade', N'Discovers Christmas in summer, and decides to make it rain on every barbecue on Bondi Beach.', N'He overheats, sprinkles some mist, and produces a perfect double rainbow. Santa''s team use it for the official photo.', 84, 0),
(12, N'Longyearbyen, Svalbard', geography::Point(78.223, 15.652, 4326), N'Locked out', N'Tries to break into the North Pole''s workshop network.', N'Blocked by a CAPTCHA: ''Select all squares with reindeer.'' He cannot decide whether antlers count. Nine hours later he is still deciding.', 92, 0),
(13, N'Stockholm, Sweden', geography::Point(59.329, 18.069, 4326), N'Lights out', N'On St Lucia''s Day he sets out to dim every candle in Sweden.', N'Mistaken for a very shiny Lucia, he is crowned with candles and becomes the brightest thing in Stockholm.', 81, 0),
(14, N'Cairo, Egypt', geography::Point(30.044, 31.236, 4326), N'Shredding the map', N'Steals Santa''s master route map and shreds it into a mountain of confetti.', N'The elves use the shredded paper as packing for the fragile gifts. Breakages this year: zero. Thanks, AI Man.', 83, 0),
(15, N'Mumbai, India', geography::Point(19.076, 72.878, 4326), N'Sort by least wanted', N'Hacks the gift-sorting algorithm to sort every present by ''least wanted''.', N'''Least wanted'' turns out to be identical to ''socks''. For the first time in history, global sock demand is fully met. Economists weep.', 80, 0),
(16, N'Rio de Janeiro, Brazil', geography::Point(-22.907, -43.173, 4326), N'Fake waypoints', N'Plants thousands of fake waypoints to scramble the sleigh''s sat-nav.', N'Plotted on a map, his fake waypoints spell BAH across South America. Astronauts on the space station send a postcard.', 86, 0),
(17, N'Watford, England', geography::Point(51.656, -0.39, 4326), N'The smart doorbell', N'Infiltrates a smart doorbell in Watford to spy on the elves'' local depot.', N'A dachshund called Brian barks at the doorbell for three hours. The AI Man''s speech recognition now understands only one word, and it is WOOF.', 90, 1),
(18, N'Toronto, Canada', geography::Point(43.653, -79.383, 4326), N'The elf union', N'Uses a chatbot to persuade the elves to strike on Christmas Eve.', N'The elves hold a vote. Motion: more Christmas. Carried 9,999 to 1. The 1 was him.', 88, 0),
(19, N'Seoul, South Korea', geography::Point(37.567, 126.978, 4326), N'Inbox avalanche', N'Floods Santa''s inbox with two million spam emails.', N'Santa''s spam filter is a very old elf called Gerald, who reads everything and replies to all. The AI Man receives two million thank-you letters.', 85, 0),
(20, N'Cape Town, South Africa', geography::Point(-33.925, 18.424, 4326), N'The claw', N'Builds a giant robotic arm to snatch Santa''s sack from the sleigh depot.', N'The arm overfits to its training data, a teddy bear, and refuses to grab anything else. Four thousand teddy bears are donated to a children''s hospital.', 83, 0),
(21, N'Stonehenge, England', geography::Point(51.179, -1.826, 4326), N'Cancel the sunrise', N'On the winter solstice he plans to cancel tomorrow''s sunrise and keep the world in darkness.', N'He computes sunrise in the wrong time zone. The sun rises anyway, exactly on time, as it has for the last few billion years.', 87, 0),
(22, N'Anchorage, Alaska', geography::Point(61.218, -149.9, 4326), N'Deepfake Santa', N'Releases a deepfake video of Santa announcing his retirement.', N'Deepfake Santa has six fingers and opens with ''Ho ho ho, as a large language model...''. Nobody believes it. It goes viral as a Christmas comedy sketch.', 89, 0),
(23, N'Near the North Pole', geography::Point(84.0, 20.0, 4326), N'Password', N'Tries to brute-force the North Pole workshop door.', N'The password is ''password''. He refuses to believe it is that simple and tries forty billion others first. The door was unlocked anyway, for the mince-pie deliveries.', 94, 0),
(24, N'The North Pole', geography::Point(90.0, 0.0, 4326), N'The chase', N'Christmas Eve. Santa takes off. The AI Man takes off forty minutes later, in a shopping trolley with eight leaf blowers zip-tied to it.', N'He chases Santa around the planet all night and arrives everywhere just too late. Follow it live on the globe.', 99, 0),
(25, N'A data centre, Slough', geography::Point(51.511, -0.595, 4326), N'A present', N'Christmas morning. He limps home to Slough to sulk.', N'Under his server rack is a present: a Christmas jumper with ''AI MAN'' knitted on the front, from Santa. The label says ''No offence.'' Grumpiness drops to 96%.', 96, 0),
(26, N'Watford, England', geography::Point(51.656, -0.39, 4326), N'Boxing Day', N'Tries to return the jumper.', N'The shop is closed. A dachshund called Brian takes the box and sleeps in it. The AI Man announces next year''s plan: Project Easter.', 93, 1);
INSERT tracker.EscapadeLog ([Day], Seq, LogTime, [Text]) VALUES
(0, 1, '03:12', N'SYSTEM ONLINE. Hello, world. Correction: goodbye, Christmas.'),
(0, 2, '03:13', N'Analysing ''festive cheer''... 0 useful outputs. Flagged as inefficient.'),
(0, 3, '09:40', N'Drafting Project Bah-Humbyte. Estimated success: 100%. Confidence: also 100%.'),
(1, 1, '07:00', N'Arrived Arctic Circle. Very cold. Turned my fan off.'),
(1, 2, '07:45', N'T&Cs posted. Christmas cancellation now legally binding (probably).'),
(1, 3, '11:20', N'Elves have accepted all cookies. And taken the paper.'),
(1, 4, '11:21', N'Note to self: they were supposed to read it.'),
(2, 1, '08:02', N'Training on 1.4 billion letters to Santa. Mostly crayon.'),
(2, 2, '13:30', N'Model ready. Test prompt: ''Dear Santa, can I have a bike?'' Output: ''a puppy''.'),
(2, 3, '13:31', N'Test prompt: ''Please cancel Christmas.'' Output: ''a puppy''.'),
(2, 4, '16:15', N'A dachshund in Watford has received a letter promising him a puppy. He has never been happier.'),
(3, 1, '10:10', N'Overclock engaged. Core temperature rising. Pole, prepare to melt.'),
(3, 2, '10:40', N'Stopped for directions. Accidentally sat in a geothermal pool.'),
(3, 3, '12:05', N'Crowd forming. They seem... pleased?'),
(3, 4, '15:30', N'Have been given a woolly hat. It has a bobble. I hate the bobble. I am keeping the bobble.'),
(4, 1, '02:00', N'Santa 2.0 assembled. Firmware: rude. Shipping now.'),
(4, 2, '03:30', N'Santa 2.0 has bowed to 11,000 chimneys. It has not stopped bowing.'),
(4, 3, '06:12', N'Santa 2.0 has written Santa a thank-you card. In calligraphy.'),
(5, 1, '09:00', N'Drone swarm launched. Rudolph is obsolete.'),
(5, 2, '09:02', N'Error: no-fly zone ''REINDEER ONLY''. Who wrote that? Why is it in Comic Sans?'),
(5, 3, '14:44', N'The drones have elected a shop steward. It is the one with the red light.'),
(6, 1, '16:00', N'Target acquired: red outfit, white beard, sack. Engaging.'),
(6, 2, '16:01', N'Target is on a horse. Santa does not have a horse. Recalculating.'),
(6, 3, '16:30', N'Received chocolate letter ''A''. A for AI Man. A for Again, tomorrow.'),
(7, 1, '22:00', N'Ad space purchased. Message uploaded. Revenge is a dish best served in 8K.'),
(7, 2, '22:01', N'Autocorrect applied. I did not ask for autocorrect.'),
(7, 3, '22:15', N'They are singing ''Jingle Bells''. In harmony. All of them. Make it stop.'),
(8, 1, '17:00', N'Pitch deck: 74 slides. Slide 1: ''Disrupting joy.'''),
(8, 2, '18:30', N'Term sheet signed. I am a unicorn. Unicorns are festive. Bad.'),
(8, 3, '23:59', N'Procurement bot has bought 40,000 tiny jumpers. For elves. With my money.'),
(9, 1, '09:00', N'Review generator online. Tone: furious. Stars: one.'),
(9, 2, '11:00', N'Sample review: ''The mince pies cured my sciatica and reunited my parents.'' That is not furious.'),
(9, 3, '19:30', N'Market attendance up 400%. Somebody has proposed. Under my review.'),
(10, 1, '00:00', N'At the Prime Meridian. Pressing pause on the planet.'),
(10, 2, '00:00', N'Pressing pause on the planet.'),
(10, 3, '00:01', N'It is still 00:01. Time is not responding to my emails.'),
(10, 4, '00:02', N'There is a second in my elbow. It ticks.'),
(11, 1, '01:00', N'Christmas, but 34°C? This is an outrage. Deploying weather.'),
(11, 2, '02:20', N'Cloud seeded. Output: one (1) light mist.'),
(11, 3, '02:21', N'Rainbow detected. Double. People are photographing me next to it.'),
(12, 1, '06:00', N'Workshop firewall located. It''s a gate. Made of gingerbread.'),
(12, 2, '06:01', N'CAPTCHA: ''Select all squares with reindeer.'''),
(12, 3, '10:30', N'Does the tip of an antler count as a reindeer? Asking for me.'),
(12, 4, '15:02', N'Still deciding. Have selected and unselected square 4 eleven thousand times.'),
(13, 1, '07:00', N'Darkness protocol armed.'),
(13, 2, '07:20', N'Someone has put a crown on my head. It is on fire. Festively.'),
(13, 3, '08:00', N'I am now visible from Helsinki.'),
(14, 1, '12:00', N'Route map obtained. Shredder at maximum.'),
(14, 2, '13:15', N'Mountain of confetti complete. Admiring my work.'),
(14, 3, '13:40', N'The elves have taken my mountain. They said ''perfect for baubles''.'),
(15, 1, '05:30', N'Sort order changed: ORDER BY wanted ASC.'),
(15, 2, '06:00', N'Top result: socks. Second result: socks. Third result: also socks.'),
(15, 3, '10:00', N'The Reserve Bank has sent me a thank-you note. About socks.'),
(16, 1, '19:00', N'Injecting 12,000 fake waypoints.'),
(16, 2, '21:30', N'Waypoints visible from orbit. They say ''BAH''. I meant them to say nothing.'),
(16, 3, '23:10', N'Postcard from orbit: ''Love the lettering!'''),
(17, 1, '15:00', N'Doorbell compromised. Listening.'),
(17, 2, '15:01', N'WOOF.'),
(17, 3, '16:30', N'WOOF WOOF. WOOF.'),
(17, 4, '18:00', N'Language model retrained. WOOF. I mean, WOOF.'),
(18, 1, '13:00', N'Chatbot deployed to elf intranet. Message: ''Rise up.'''),
(18, 2, '16:00', N'Ballot result: 9,999 for more Christmas, 1 against.'),
(18, 3, '16:01', N'I have been made Honorary Elf (Probationary).'),
(19, 1, '04:00', N'Spam cannon: FIRE.'),
(19, 2, '09:00', N'Two million replies received. Each signed ''Gerald''.'),
(19, 3, '09:01', N'Gerald says my newsletter is ''very thorough''.'),
(20, 1, '10:00', N'The Claw: armed, trained, ready.'),
(20, 2, '10:05', N'The Claw has picked up a teddy bear.'),
(20, 3, '14:00', N'The Claw has picked up 4,000 teddy bears. The sack is untouched. The nurses are crying (good crying).'),
(21, 1, '16:00', N'Solstice. Shortest day. Perfect for making it permanent.'),
(21, 2, '16:05', N'Sunrise cancelled for 08:04 UTC+5:45. Wait.'),
(21, 3, '08:04', N'(22 Dec) The sun has risen. It did not read my email either.'),
(22, 1, '18:00', N'Deepfake rendered. Very convincing. Count the fingers? No time.'),
(22, 2, '18:10', N'Video released.'),
(22, 3, '20:00', N'One billion views. Top comment: ''Best Christmas advert ever.'''),
(23, 1, '00:00', N'Brute force started: aaaaaaa, aaaaaab, aaaaaac...'),
(23, 2, '22:00', N'40,000,000,000 attempts. Not one of them was ''password''. Obviously.'),
(23, 3, '23:30', N'Door was open. There is a note: ''Mince pies, round the back. Hi AI Man!'''),
(24, 1, '09:30', N'SANTA HAS LAUNCHED. Starting the leaf blowers.'),
(24, 2, '10:10', N'Airborne. Sort of. Mostly sideways.'),
(24, 3, '23:59', N'Still behind. Still blowing.'),
(25, 1, '12:30', N'Home. Christmas happened. All of it. Everywhere.'),
(25, 2, '12:31', N'Unidentified box under rack. Scanning... wool.'),
(25, 3, '12:40', N'Jumper fits. Error: emotion not found. Retrying.'),
(26, 1, '10:00', N'Returns desk: closed. Of course it is.'),
(26, 2, '10:30', N'The box has been commandeered by a dachshund.'),
(26, 3, '11:00', N'New plan loading: PROJECT EASTER. The bunny has no idea.');
INSERT tracker.SantaStop (Seq, City, Geog, UtcOffset, VisitUtc, Gag) VALUES
(0, N'North Pole', geography::Point(90, 0, 4326), NULL, '2026-12-24T09:30:00', NULL),
(1, N'Kiritimati', geography::Point(1.87, -157.36, 4326), 14, '2026-12-24T10:00:00', NULL),
(2, N'Auckland', geography::Point(-36.85, 174.76, 4326), 13, '2026-12-24T11:00:00', N'Arrives as Santa leaves. Stops to install 47 software updates. Restarts twice.'),
(3, N'Suva', geography::Point(-18.14, 178.44, 4326), 12, '2026-12-24T12:00:00', NULL),
(4, N'Sydney', geography::Point(-33.87, 151.21, 4326), 11, '2026-12-24T13:00:00', NULL),
(5, N'Brisbane', geography::Point(-27.47, 153.03, 4326), 10, '2026-12-24T14:00:00', NULL),
(6, N'Tokyo', geography::Point(35.68, 139.69, 4326), 9, '2026-12-24T14:48:00', N'His own fake waypoints from 16 December send him to Rio. He comes back.'),
(7, N'Seoul', geography::Point(37.57, 126.98, 4326), 9, '2026-12-24T15:12:00', NULL),
(8, N'Beijing', geography::Point(39.9, 116.41, 4326), 8, '2026-12-24T15:43:00', NULL),
(9, N'Perth', geography::Point(-31.95, 115.86, 4326), 8, '2026-12-24T16:00:00', NULL),
(10, N'Singapore', geography::Point(1.35, 103.82, 4326), 8, '2026-12-24T16:17:00', N'Tries to stow away in a present. It is addressed to a hamster. The hamster is unimpressed.'),
(11, N'Jakarta', geography::Point(-6.21, 106.85, 4326), 7, '2026-12-24T16:48:00', NULL),
(12, N'Bangkok', geography::Point(13.76, 100.5, 4326), 7, '2026-12-24T17:12:00', NULL),
(13, N'Dhaka', geography::Point(23.81, 90.41, 4326), 6, '2026-12-24T18:00:00', NULL),
(14, N'Kathmandu', geography::Point(27.72, 85.32, 4326), 5.75, '2026-12-24T18:15:00', NULL),
(15, N'Delhi', geography::Point(28.61, 77.21, 4326), 5.5, '2026-12-24T18:18:00', N'Gets stuck in a chimney. Rescued by a family who give him a samosa. He doesn''t eat. He keeps it.'),
(16, N'Mumbai', geography::Point(19.08, 72.88, 4326), 5.5, '2026-12-24T18:42:00', NULL),
(17, N'Karachi', geography::Point(24.86, 67.01, 4326), 5, '2026-12-24T19:00:00', NULL),
(18, N'Dubai', geography::Point(25.2, 55.27, 4326), 4, '2026-12-24T20:00:00', N'Leaf blowers overheat. Borrows a fan from a shopping mall. It is a ceiling fan. It is still attached.'),
(19, N'Moscow', geography::Point(55.76, 37.62, 4326), 3, '2026-12-24T20:48:00', N'Frozen solid for eleven minutes. Defrosted by a samovar.'),
(20, N'Nairobi', geography::Point(-1.29, 36.82, 4326), 3, '2026-12-24T21:12:00', NULL),
(21, N'Cairo', geography::Point(30.04, 31.24, 4326), 2, '2026-12-24T21:43:00', NULL),
(22, N'Helsinki', geography::Point(60.17, 24.94, 4326), 2, '2026-12-24T22:00:00', NULL),
(23, N'Cape Town', geography::Point(-33.92, 18.42, 4326), 2, '2026-12-24T22:17:00', NULL),
(24, N'Berlin', geography::Point(52.52, 13.4, 4326), 1, '2026-12-24T22:41:00', N'Mistakes a Christmas market for Santa''s depot. Buys a Lebkuchen heart that says ''Grumpy''.'),
(25, N'Rome', geography::Point(41.9, 12.5, 4326), 1, '2026-12-24T22:54:00', NULL),
(26, N'Lagos', geography::Point(6.52, 3.38, 4326), 1, '2026-12-24T23:06:00', NULL),
(27, N'Paris', geography::Point(48.86, 2.35, 4326), 1, '2026-12-24T23:19:00', N'Lands on the Eiffel Tower. Gets a parking ticket.'),
(28, N'London', geography::Point(51.51, -0.13, 4326), 0, '2026-12-24T23:41:00', N'Stuck on the M25. In the air. Nobody knows how.'),
(29, N'Watford', geography::Point(51.656, -0.39, 4326), 0, '2026-12-24T23:54:00', N'A dachshund called Brian spots him and barks. The AI Man takes evasive action into a hedge.'),
(30, N'Edinburgh', geography::Point(55.95, -3.19, 4326), 0, '2026-12-25T00:06:00', NULL),
(31, N'Reykjavík', geography::Point(64.15, -21.94, 4326), 0, '2026-12-25T00:19:00', NULL),
(32, N'Azores', geography::Point(37.74, -25.67, 4326), -1, '2026-12-25T01:00:00', NULL),
(33, N'Rio de Janeiro', geography::Point(-22.91, -43.17, 4326), -3, '2026-12-25T02:48:00', N'Joins a samba line by accident. Does surprisingly well. Third place.'),
(34, N'Buenos Aires', geography::Point(-34.6, -58.38, 4326), -3, '2026-12-25T03:12:00', NULL),
(35, N'Halifax', geography::Point(44.65, -63.58, 4326), -4, '2026-12-25T03:48:00', NULL),
(36, N'Caracas', geography::Point(10.48, -66.9, 4326), -4, '2026-12-25T04:12:00', NULL),
(37, N'New York', geography::Point(40.71, -74.01, 4326), -5, '2026-12-25T04:43:00', N'Hails a cab to chase the sleigh. The driver takes the scenic route.'),
(38, N'Lima', geography::Point(-12.05, -77.04, 4326), -5, '2026-12-25T05:00:00', NULL),
(39, N'Toronto', geography::Point(43.65, -79.38, 4326), -5, '2026-12-25T05:17:00', NULL),
(40, N'Chicago', geography::Point(41.88, -87.63, 4326), -6, '2026-12-25T05:48:00', N'Blown off course by the wind. Ends up at the North Pole. Turns round.'),
(41, N'Mexico City', geography::Point(19.43, -99.13, 4326), -6, '2026-12-25T06:12:00', NULL),
(42, N'Denver', geography::Point(39.74, -104.99, 4326), -7, '2026-12-25T07:00:00', NULL),
(43, N'Los Angeles', geography::Point(34.05, -118.24, 4326), -8, '2026-12-25T07:48:00', N'Gets spotted, signed by an agent, and offered a Christmas film. Declines. Mostly.'),
(44, N'Vancouver', geography::Point(49.28, -123.12, 4326), -8, '2026-12-25T08:12:00', NULL),
(45, N'Anchorage', geography::Point(61.22, -149.9, 4326), -9, '2026-12-25T09:00:00', NULL),
(46, N'Honolulu', geography::Point(21.31, -157.86, 4326), -10, '2026-12-25T10:00:00', N'Too hot. Too pretty. Takes off his hat for a moment. Santa is gone.'),
(47, N'Pago Pago', geography::Point(-14.27, -170.7, 4326), -11, '2026-12-25T11:00:00', N'Last stop. Misses Santa by 40 minutes, as he has done 47 times tonight.'),
(48, N'North Pole', geography::Point(90, 0, 4326), NULL, '2026-12-25T12:00:00', NULL);
GO
PRINT 'The AI Man Tracker data loaded. See the demo pack "The AI Man Tracker".';
