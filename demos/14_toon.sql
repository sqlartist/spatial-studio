/* Spatial Studio demo pack 14 - Toon: cut-out cartoons starring Brian */

--#demo Meet Brian: the puppet rig
--#desc Brian, a black-and-tan dachshund, is 19 geometry parts. Each one is pinned to a parent at a pivot (red dots), like a card cut-out:
--#desc legs, tail and head hang off the body; ear, eye and snout hang off the head. Arcs (CURVEPOLYGON) give him his round bits.
--#view plane
--#tags toon.Part, CURVEPOLYGON, COMPOUNDCURVE, puppet rig
SELECT Shape, color = Color, opacity = 1.0, linewidth = 1.6 FROM toon.Part WHERE Character = 'Brian' ORDER BY Z;
SELECT shape = geometry::Point(PivotX, PivotY, 0).STBuffer(1.8), label = Part, color = '#e15759', opacity = 1.0, fontsize = 10, linewidth = 0
FROM toon.Part WHERE Character = 'Brian';
SELECT Part, Parent, PivotX, PivotY, Z, Color, [swing period] = OscPeriod, [phase deg] = OscPhase, Boil
FROM toon.Part WHERE Character = 'Brian' ORDER BY Z;

--#demo Strike a pose: render one frame
--#desc toon.Render with @Store = 0 returns the drawn frame directly. Frame 100 is mid-gallop: legs swinging out of phase, ears flying.
--#view plane
--#tags toon.Render, sx.Affine, sx.Jitter
EXEC toon.Render @Scene = 'BrianAndTheBall', @FromFrame = 100, @ToFrame = 100, @Boil = 0.7, @Store = 0;

--#demo Render the episode
--#desc Interpolates 159 keyframes across 241 frames, composes each part's affine matrix down the puppet with a recursive CTE,
--#desc moves every shape with sx.Affine and adds the felt-tip boil with sx.Jitter. The result lands in toon.Frame. Takes a little while.
--#tags toon.Render, recursive CTE, affine transforms, keyframes
EXEC toon.Render @Scene = 'BrianAndTheBall';
SELECT Character, parts = COUNT(DISTINCT Part), [shapes drawn] = COUNT(*), [bytes of geometry] = SUM(CAST(DATALENGTH(Shape) AS bigint))
FROM toon.Frame WHERE Scene = 'BrianAndTheBall' GROUP BY Character ORDER BY Character;

--#demo Play: Brian in "The Ball"
--#desc Twenty seconds at 12 frames a second, every frame a set of geometry rows. Renders first if toon.Frame is empty.
--#desc Press play if it doesn't start on its own; the speed box lets you try 24 fps.
--#view plane
--#tags animation, frame, toon.Frame
IF NOT EXISTS (SELECT 1 FROM toon.Frame WHERE Scene = 'BrianAndTheBall')
    EXEC toon.Render @Scene = 'BrianAndTheBall';
SELECT frame = Frame, shape = Shape, color = Color, label = Label, fontsize = FontSize, linewidth = LineWidth, opacity = 1.0
FROM toon.Frame WHERE Scene = 'BrianAndTheBall'
ORDER BY Frame, Z, Character, Part;

--#demo The dope sheet
--#desc The whole performance is data: one row per key. ! marks a step (a cut), ~ a linear move, plain values ease in and out.
--#tags toon.Key, STRING_AGG, keyframes
SELECT Character, Part, Channel,
       keys = STRING_AGG(CONCAT(Frame, ':', Value, CASE Ease WHEN 'step' THEN '!' WHEN 'linear' THEN '~' ELSE '' END), '   ')
              WITHIN GROUP (ORDER BY Frame)
FROM toon.[Key] WHERE Scene = 'BrianAndTheBall'
GROUP BY Character, Part, Channel
ORDER BY CASE Character WHEN 'Brian' THEN 0 WHEN 'Ball' THEN 1 ELSE 2 END, Character, Part, Channel;

--#demo Motion paths
--#desc The track of Brian's nose, tail and the ball through the whole episode, built from toon.Frame by joining each frame's centre point into a LINESTRING.
--#view plane
--#tags STRING_AGG, sx.EnvelopeCentre, motion path
IF NOT EXISTS (SELECT 1 FROM toon.Frame WHERE Scene = 'BrianAndTheBall')
    EXEC toon.Render @Scene = 'BrianAndTheBall';
SELECT Shape, color = Color, opacity = 0.35, linewidth = 0 FROM toon.Frame WHERE Scene = 'BrianAndTheBall' AND Frame = 0 AND Character = 'Park';
WITH c AS (
    SELECT Character, Part, Frame, p = sx.EnvelopeCentre(Shape)
    FROM toon.Frame
    WHERE Scene = 'BrianAndTheBall' AND ((Character = 'Brian' AND Part IN ('Nose', 'Tail')) OR (Character = 'Ball' AND Part = 'Ball')))
SELECT Character, Part,
       shape = geometry::STGeomFromText('LINESTRING (' + STRING_AGG(CAST(CONCAT(sx.FormatNum(p.STX), ' ', sx.FormatNum(p.STY)) AS varchar(max)), ', ')
                                        WITHIN GROUP (ORDER BY Frame) + ')', 0),
       label = CONCAT(Character, ' ', Part),
       color = CASE Part WHEN 'Nose' THEN '#2b1d16' WHEN 'Tail' THEN '#8d6e63' ELSE '#e53935' END, linewidth = 2
FROM c GROUP BY Character, Part;

--#demo The felt-tip boil, on and off
--#desc Old hand-drawn cartoons shimmer because every drawing is slightly different. sx.Jitter nudges each vertex by a hash of the vertex itself
--#desc (so rings stay closed), and the seed changes every other frame. Left: @Boil = 0. Right: @Boil = 2.
--#view plane
--#tags sx.Jitter, sx.Hash01, INSERT EXEC
DROP TABLE IF EXISTS #clean, #boil;
CREATE TABLE #clean (frame int, shape geometry, color varchar(30), label nvarchar(60), fontsize int, linewidth float, opacity decimal(3, 1), part varchar(70), z int);
CREATE TABLE #boil  (frame int, shape geometry, color varchar(30), label nvarchar(60), fontsize int, linewidth float, opacity decimal(3, 1), part varchar(70), z int);
INSERT #clean EXEC toon.Render @Scene = 'BrianAndTheBall', @FromFrame = 40, @ToFrame = 63, @Boil = 0, @Store = 0;
INSERT #boil  EXEC toon.Render @Scene = 'BrianAndTheBall', @FromFrame = 40, @ToFrame = 63, @Boil = 2, @Store = 0;
SELECT frame, shape, color, label, fontsize, linewidth, opacity, side = 0, z FROM #clean
UNION ALL
SELECT frame, sx.Translate(shape, 1020, 0), color, label, fontsize, linewidth, opacity, 1, z FROM #boil
ORDER BY frame, side, z;

--#demo Direct your own shot: Zoomies
--#desc A new scene in a dozen INSERTs: Brian tears back and forth across the park, flipping round at each end.
--#desc Change the keys and run it again - the renderer returns frames straight to the viewer (@Store = 0).
--#view plane
--#tags toon.Scene, toon.Key, toon.Render, keyframes
DELETE toon.[Key] WHERE Scene = 'Zoomies';
DELETE toon.Casting WHERE Scene = 'Zoomies';
DELETE toon.Scene WHERE Scene = 'Zoomies';
INSERT toon.Scene (Scene, Title, Frames, Fps) VALUES ('Zoomies', N'Zoomies', 121, 12);
INSERT toon.Casting (Scene, Character) VALUES ('Zoomies', 'Park'), ('Zoomies', 'Brian');
INSERT toon.[Key] (Scene, Character, Part, Channel, Frame, Value, Ease) VALUES
-- where he is: there, back, and there again (the 'step' keys flip him round instantly)
('Zoomies', 'Brian', 'Body', 'dx', 0, 120, 'smooth'), ('Zoomies', 'Brian', 'Body', 'dx', 38, 800, 'smooth'),
('Zoomies', 'Brian', 'Body', 'dx', 42, 800, 'smooth'), ('Zoomies', 'Brian', 'Body', 'dx', 80, 160, 'smooth'),
('Zoomies', 'Brian', 'Body', 'dx', 84, 160, 'smooth'), ('Zoomies', 'Brian', 'Body', 'dx', 120, 700, 'smooth'),
('Zoomies', 'Brian', 'Body', 'dy', 0, 65, 'smooth'),
('Zoomies', 'Brian', 'Body', 'sx', 0, 1, 'smooth'), ('Zoomies', 'Brian', 'Body', 'sx', 40, 1, 'smooth'), ('Zoomies', 'Brian', 'Body', 'sx', 41, -1, 'step'),
('Zoomies', 'Brian', 'Body', 'sx', 82, -1, 'smooth'), ('Zoomies', 'Brian', 'Body', 'sx', 83, 1, 'step'),
-- how he moves
('Zoomies', 'Brian', 'Body', 'bob', 0, 5, 'smooth'),
('Zoomies', 'Brian', 'LegFrontNear', 'osc', 0, 40, 'smooth'), ('Zoomies', 'Brian', 'LegFrontFar', 'osc', 0, 40, 'smooth'),
('Zoomies', 'Brian', 'LegBackNear', 'osc', 0, 40, 'smooth'),  ('Zoomies', 'Brian', 'LegBackFar', 'osc', 0, 40, 'smooth'),
('Zoomies', 'Brian', 'Ear', 'angle', 0, -60, 'smooth'), ('Zoomies', 'Brian', 'Ear', 'osc', 0, 15, 'smooth'),
('Zoomies', 'Brian', 'Tail', 'angle', 0, -20, 'smooth'), ('Zoomies', 'Brian', 'Tail', 'osc', 0, 30, 'smooth'),
('Zoomies', 'Brian', 'Tag', 'osc', 0, 30, 'smooth'),
('Zoomies', 'Brian', 'Head', 'angle', 0, 6, 'smooth'),
('Zoomies', 'Park', 'Rays', 'angle', 0, 0, 'smooth'), ('Zoomies', 'Park', 'Rays', 'angle', 120, -60, 'linear');
EXEC toon.Render @Scene = 'Zoomies', @Boil = 0.8, @Store = 0;
