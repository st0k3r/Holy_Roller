--[[pod_format="raw",created="2026-10-28 22:23:42",modified="2026-10-28 22:23:44",revision=1]]
-- Holy Roller
-- the car drives up the middle of the road while zombies close in from both sides.
-- hold left / right to lean out of that window; while leaning out you auto-fire.
-- driving burns fuel; run dry and the priest has to find a gas can in a first person forest maze.

local SW, SH = 480, 270
local ROAD_W = 140
local ROAD_X0 = SW/2 - ROAD_W/2
local ROAD_X1 = SW/2 + ROAD_W/2

local LEAN_SPEED = 0.15  -- how fast the gunner leans out / ducks back in (0..1 per frame)
local FIRE_DELAY = 8     -- frames between shots
local BULLET_SPD = 7
local GUN_RANGE = 260

local CRUISE_SPEED = 4
local ACCEL = 0.05
local BRAKE = 0.06
local DRIVE_TIME = 180   -- frames spent cruising between waves

local CAR_SPR = 1
local PRIEST_SPR = 8     -- the gunner leaning out the window, drawn facing right
local GUN_SPR = 9        -- the priest's right arm and pistol in the maze, first person
local GUN_MUZZLE_X = 18  -- pixel column of the pistol's centre line in GUN_SPR
local CROSS_SPR = 10     -- the priest's left arm and crucifix
local CROSS_MID_X = 19   -- pixel column of the crucifix's centre line in CROSS_SPR
local HAND_SPREAD = 80   -- how far each hand sits from the middle of the screen
local PRIEST_REACH = 4   -- how far past the car's side the sprite's centre slides when fully leaned out
local PRIEST_SKIN = 15   -- flesh colour, matching the face in the sprite
local PRIEST_HANDS = {2, 5}  -- distances along the gun line where his hands grip it
local ZOMBIE_SPR = 2     -- first walk frame, drawn facing left
local WALK_FRAMES = 3  -- walk frames are ZOMBIE_SPR .. ZOMBIE_SPR+WALK_FRAMES-1
local WALK_FRAME_T = 20 -- frames each walk frame is held for
local STEP_PUSH = {1.4, 0.8, 0.8}  -- per walk frame: a big lurch on the step, weaker drag after (averages 1)
local CRAWLER_SPR = 5    -- first crawl frame, also facing left; same frame count and timing as the walk
local CRAWLER_CHANCE = 0.2   -- odds a wave zombie is a crawler on wave 1; rises each wave
local CRAWLER_SPD = 2    -- crawlers close in this many times faster than walkers
local CRAWLER_ANIM = 1.6 -- and scrabble through their frames this much faster
local TRANS_COL = 14     -- pink is the transparent colour in the sprites (they use a lot of black)

local STEER_SPEED = 2.5  -- sideways speed when steering between waves
local ROADKILL_SCORE = 25
local ROADKILL_HEAL = 1
local GLASS_COL = 7      -- windshield colour in the car sprite
local WIPE_SWEEP = 24    -- frames for one there-and-back pass of the wiper
local WIPE_PASSES = 2

local MAX_FUEL = 100
local FUEL_BURN = 0.03   -- fuel per frame per unit of speed, so a parked car burns nothing
local ROADKILL_FUEL = 4  -- running a zombie down costs a little fuel
local LOW_FUEL = 25
local STALL_WAIT = 60    -- frames sat dead on the road before the priest gets out

local state         -- "title", "play", "maze", "over"
-- while playing, phase cycles: "drive" -> "brake" -> "wave" -> "drive" ...
-- running out of fuel cuts in with "stall", which hands over to the maze
local phase, phase_t, wave, to_spawn
local banner, banner_t
local car, car_img, gunner
local stains            -- blood on the windshield, keyed by pixel: {x, y}
local glass, gx0, gy0, gx1, gy1  -- windshield pixel mask and its bounds, in sprite coords
local wiper             -- pivot (x, y), blade length, angle a; t is nil unless wiping
local zw, zh            -- zombie sprite size
local pw, ph            -- priest sprite size
local zombies, road_zs, bullets, parts
local scroll, speed, score, kills, spawn_t, road_t, shake
local fuel, strandings  -- strandings counts trips into the maze; each one is harder
local mz                -- maze state while on foot, nil while driving

function reset_game()
	-- size the car (and its hitbox) from the sprite
	local s = get_spr(CAR_SPR)
	car = {x=SW/2, y=185, w=s:width(), h=s:height(), hp=10, max_hp=10, hit_t=0}
	-- private copy of the sprite so blood can be painted onto it
	car_img = s:copy()
	stains = {}

	-- the sprite has transparent margins, so find how far the body really reaches at the window
	-- (the priest's row, 8px above centre) and lean him out from there
	car.side = 0
	local wy = flr(car.h/2) - 8
	for px=car.w-1,0,-1 do
		if s:get(px, wy) ~= TRANS_COL then
			car.side = px + 1 - car.w/2
			break
		end
	end

	-- find the windshield: glass pixels in the front half (the rear window is glass too)
	glass, gx0, gy0, gx1, gy1 = {}, car.w, car.h, -1, -1
	for py=0,flr(car.h/2)-1 do
		for px=0,car.w-1 do
			if s:get(px, py) == GLASS_COL then
				glass[py*car.w + px] = true
				gx0, gx1 = min(gx0, px), max(gx1, px)
				gy0, gy1 = min(gy0, py), max(gy1, py)
			end
		end
	end
	-- wiper pivots at the hood edge of the windshield (the top, since the car faces up),
	-- long enough to reach the far corners by the roof
	local wx, wy = (gx0 + gx1 + 1)/2, gy0 - 0.5
	wiper = {x=wx, y=wy, len=sqrt(max(wx - gx0, gx1 + 1 - wx)^2 + (gy1 + 1 - wy)^2), a=1}
	-- side: -1 left, 1 right, 0 inside. out: lean amount 0..1
	gunner = {side=0, out=0, cool=0, ax=0, ay=-1, flash=0}
	zombies, road_zs, bullets, parts = {}, {}, {}, {}
	score, kills = 0, 0
	spawn_t, road_t, shake = 0, 30, 0
	wave, to_spawn = 1, 0
	phase, phase_t = "drive", DRIVE_TIME
	banner, banner_t = "", 0
	fuel, strandings = MAX_FUEL, 0
	mz = nil
end

local function show_banner(text)
	banner, banner_t = text, 90
end

function _init()
	state = "title"
	-- road state lives outside reset_game so starting a run doesn't jolt the car
	scroll, speed = 0, CRUISE_SPEED
	local zs = get_spr(ZOMBIE_SPR)
	zw, zh = zs:width(), zs:height()
	local ps = get_spr(PRIEST_SPR)
	pw, ph = ps:width(), ps:height()
	reset_game()
end

-- helpers ------------------------------------------------------------------

local function norm(dx, dy)
	local len = sqrt(dx*dx + dy*dy)
	if len < 0.001 then return 0, 0, 0 end
	return dx/len, dy/len, len
end

local function burst(x, y, n, cols, spd)
	for i=1,n do
		add(parts, {
			x=x, y=y,
			vx=(rnd(2)-1)*spd, vy=(rnd(2)-1)*spd,
			life=10+rnd(15), col=cols[flr(rnd(#cols))+1]
		})
	end
end

-- centre of the priest sprite: slides out past the car's side as he leans
local function gunner_pos()
	return car.x + gunner.side*(car.side + PRIEST_REACH*gunner.out), car.y - 8
end

local function muzzle_pos()
	local sx, sy = gunner_pos()
	return sx + gunner.ax*8, sy + gunner.ay*8, sx, sy
end

local function print_c(s, y, col)
	local w = print(s, 0, -100)  -- print offscreen to measure width
	print(s, SW/2 - w/2, y, col)
end

-- spawning -----------------------------------------------------------------

local function spawn_zombie()
	local side = rnd(1) < 0.5 and -1 or 1
	local crawler = rnd(1) < min(CRAWLER_CHANCE + (wave - 1) * 0.05, 0.5)
	local s = crawler and CRAWLER_SPR or ZOMBIE_SPR
	local img = get_spr(s)
	local w, h = img:width(), img:height()
	local spd = 0.25 + rnd(0.25) + min(wave * 0.06, 0.45)
	add(zombies, {
		x = side < 0 and -w/2 or SW+w/2,
		y = 10 + rnd(SH-20),
		side = side,
		spr = s, w = w, h = h,
		spd = crawler and spd * CRAWLER_SPD or spd,
		anim = crawler and CRAWLER_ANIM or 1,
		hp = 2,
		hit_t = 0,
		wob = rnd(1),
	})
end

-- stragglers standing in the road while driving; run them down for points + HP
local function spawn_road_zombie()
	add(road_zs, {
		x = ROAD_X0 + 8 + rnd(ROAD_W - 16),
		y = -zh/2,
		hit_t = 0,
		wob = rnd(1),
	})
end

-- which walk frame a zombie is on, and how far through it (0..1).
-- wob ticks up 0.05 a frame, so it doubles as the walk-cycle clock
local function walk_phase(z)
	local f = z.wob * 20 / WALK_FRAME_T
	return flr(f) % WALK_FRAMES, f % 1
end

-- speed multiplier synced to the walk cycle: each frame surges from a standstill
-- and settles back to one, so zombies only move while their legs do
local function shamble(z)
	local frame, t = walk_phase(z)
	return STEP_PUSH[frame + 1] * (1 - cos(t))
end

-- the forest maze ----------------------------------------------------------
-- out of gas: the priest searches a maze of trees for a gas can, seen first person.
-- the map is a grid of tiles (1 = trees, 0 = path); positions are in tiles, y pointing down.

local TEX = 32           -- tree wall texture size
local COLW = 2           -- screen pixels per ray
local NCOL = SW / COLW
local FOV_K = 0.66       -- camera plane length; about a 66 degree field of view
local FOG_STEP = 2.2     -- tiles per step of darkness
local WALK_SPD = 0.05
local TURN_SPD = 0.012   -- turns (fractions of a full circle) per frame
local BODY_R = 0.2       -- collision radius for the priest and zombies
local MZ_FIRE_DELAY = 12
local MZ_ZOMBIE_SPD = 0.022
local MZ_AGGRO = 7       -- zombies notice you within this many tiles
local MZ_ZOMBIE_SCALE = 0.75  -- zombie height relative to the trees
local CAN_SCALE = 0.3
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- each colour's darker neighbour, for fog
local DARK = {[0]=0, 0, 1, 1, 2, 1, 5, 6, 2, 4, 9, 3, 1, 1, 2, 4}

local CAN_ART = {
	"...kkk.kkk..",
	"...kyk.kwk..",
	"..kkkkkkkkk.",
	".krrrrrrrrrk",
	".krwrrrrrrdk",
	".krrdrrrrddk",
	".krrrdrrdrdk",
	".krrrrddrrdk",
	".krrrrddrrdk",
	".krrrdrrdrdk",
	".krrdrrrrddk",
	".krrrrrrrrdk",
	".kdddddddddk",
	"..kkkkkkkkk.",
}
local CAN_COLS = {["."]=TRANS_COL, k=0, r=8, d=2, y=10, w=7}

local wall_tex          -- tree texture at each fog level, 0 (near) .. 4 (darkest)
local can_img
local zbuf = {}         -- wall distance per ray column, so sprites hide behind trees

local function darken(c, n)
	for i=1,n do c = DARK[c] or c end
	return c
end

local function disc(img, cx, cy, r, col)
	for y=flr(cy-r),flr(cy+r) do
		for x=flr(cx-r),flr(cx+r) do
			-- wrap sideways so the texture tiles along a wall
			if y >= 0 and y < TEX and (x-cx)^2 + (y-cy)^2 <= r*r then img:set(x % TEX, y, col) end
		end
	end
end

local function build_maze_art()
	-- trunks behind a mass of leaf clumps, with undergrowth along the bottom
	local t = userdata("u8", TEX, TEX)
	for y=0,TEX-1 do
		for x=0,TEX-1 do t:set(x, y, 1) end
	end
	for tx in all({5, 21}) do
		for y=0,TEX-1 do
			t:set(tx, y, 4)
			t:set(tx+1, y, 4)
			t:set(tx+2, y, 2)
		end
	end
	for i=1,50 do
		local cx, cy, r = rnd(TEX), rnd(24), 2 + rnd(2.5)
		disc(t, cx+1, cy+1, r, 1)
		disc(t, cx, cy, r, 3)
		disc(t, cx - r*0.35, cy - r*0.35, r*0.45, 11)
	end
	for i=1,10 do
		local cx, cy, r = rnd(TEX), 28 + rnd(4), 1.5 + rnd(2)
		disc(t, cx, cy, r, 3)
		disc(t, cx - 0.5, cy - 0.8, r*0.4, 11)
	end

	wall_tex = {}
	for lvl=0,4 do
		local s = t:copy()
		for y=0,TEX-1 do
			for x=0,TEX-1 do s:set(x, y, darken(t:get(x, y), lvl)) end
		end
		wall_tex[lvl] = s
	end

	can_img = userdata("u8", #CAN_ART[1], #CAN_ART)
	for y=1,#CAN_ART do
		for x=1,#CAN_ART[y] do
			can_img:set(x-1, y-1, CAN_COLS[CAN_ART[y]:sub(x, x)])
		end
	end
end

-- n x n cells carved by a recursive backtracker, then a few extra walls knocked
-- out so there are loops to run around. cell (cx, cy) is tile (cx*2+1, cy*2+1).
local function gen_maze(n)
	local size = n*2 + 1
	local m = {}
	for y=0,size-1 do
		m[y] = {}
		for x=0,size-1 do m[y][x] = 1 end
	end

	m[1][1] = 0
	local stack = {{0, 0}}
	while #stack > 0 do
		local c = stack[#stack]
		local opts = {}
		for d in all(DIRS) do
			local nx, ny = c[1] + d[1], c[2] + d[2]
			if nx >= 0 and nx < n and ny >= 0 and ny < n and m[ny*2+1][nx*2+1] == 1 then
				add(opts, {nx, ny, d})
			end
		end
		if #opts == 0 then
			deli(stack)
		else
			local o = opts[flr(rnd(#opts)) + 1]
			m[c[2]*2+1 + o[3][2]][c[1]*2+1 + o[3][1]] = 0
			m[o[2]*2+1][o[1]*2+1] = 0
			add(stack, {o[1], o[2]})
		end
	end

	for i=1,flr(n*n/6) do
		local x, y = 1 + flr(rnd(size-2)), 1 + flr(rnd(size-2))
		if (x + y) % 2 == 1 then m[y][x] = 0 end  -- odd sum = a wall between two cells
	end
	return m, size
end

-- walking distance to every open tile from (sx, sy); also returns the farthest tile
local function maze_dists(m, size, sx, sy)
	local dist = {[sy*size + sx] = 0}
	local q, qi = {{sx, sy}}, 1
	while qi <= #q do
		local c = q[qi]
		qi += 1
		local d = dist[c[2]*size + c[1]]
		for dir in all(DIRS) do
			local nx, ny = c[1] + dir[1], c[2] + dir[2]
			if m[ny][nx] == 0 and not dist[ny*size + nx] then
				dist[ny*size + nx] = d + 1
				add(q, {nx, ny})
			end
		end
	end
	return dist, q[#q]
end

local function wall(x, y)
	local row = mz.map[y]
	return not row or row[x] ~= 0
end

local function blocked(x, y)
	local r = BODY_R
	return wall(flr(x-r), flr(y-r)) or wall(flr(x+r), flr(y-r))
		or wall(flr(x-r), flr(y+r)) or wall(flr(x+r), flr(y+r))
end

-- slide along walls: each axis moves only if it stays clear
local function move_body(o, dx, dy)
	if not blocked(o.x + dx, o.y) then o.x += dx end
	if not blocked(o.x, o.y + dy) then o.y += dy end
end

-- facing angle a is in turns: 0 east, 0.25 north (sin is flipped for screen space).
-- the camera plane points to the priest's right
local function set_dir()
	mz.dx, mz.dy = cos(mz.a), sin(mz.a)
	mz.plx, mz.ply = -mz.dy * FOV_K, mz.dx * FOV_K
end

-- march a ray through the grid (DDA). returns the distance to the wall along the view
-- direction, which side was hit (0 = x face, 1 = y face) and where along the wall (0..1)
local function cast(rdx, rdy)
	local mx, my = flr(mz.x), flr(mz.y)
	local ddx = rdx == 0 and 1e30 or abs(1 / rdx)
	local ddy = rdy == 0 and 1e30 or abs(1 / rdy)
	local stx, sty, sdx, sdy
	if rdx < 0 then stx, sdx = -1, (mz.x - mx) * ddx else stx, sdx = 1, (mx + 1 - mz.x) * ddx end
	if rdy < 0 then sty, sdy = -1, (mz.y - my) * ddy else sty, sdy = 1, (my + 1 - mz.y) * ddy end

	local side = 0
	for i=1,64 do
		if sdx < sdy then
			sdx += ddx
			mx += stx
			side = 0
		else
			sdy += ddy
			my += sty
			side = 1
		end
		if wall(mx, my) then break end
	end
	mz.seen[my*mz.size + mx] = true

	local d = side == 0 and sdx - ddx or sdy - ddy
	local wx = side == 0 and mz.y + d*rdy or mz.x + d*rdx
	return d, side, wx - flr(wx)
end

-- world position -> camera space: tx across the view, ty depth
local function to_cam(x, y)
	local rx, ry = x - mz.x, y - mz.y
	local inv = 1 / (mz.plx*mz.dy - mz.dx*mz.ply)
	return inv * (mz.dy*rx - mz.dx*ry), inv * (mz.plx*ry - mz.ply*rx)
end

local function enter_maze()
	if not wall_tex then build_maze_art() end
	local n = min(6 + strandings, 10)
	strandings += 1

	local m, size = gen_maze(n)
	mz = {map=m, size=size, x=1.5, y=1.5, cool=0, flash=0, hurt_t=0, bob=0, zs={}, seen={}}
	mz.a = m[1][2] == 0 and 0 or 0.75  -- face down the open path
	set_dir()

	-- the can is as far from the car as the maze allows
	local dist, far = maze_dists(m, size, 1, 1)
	mz.can = {x=far[1] + 0.5, y=far[2] + 0.5}

	-- zombies wait in open tiles well away from the start
	local spots = {}
	for y=1,size-2 do
		for x=1,size-2 do
			local d = dist[y*size + x]
			if d and d > 8 and not (x == far[1] and y == far[2]) then add(spots, {x, y}) end
		end
	end
	for i=1,min(2 + strandings, 8) do
		if #spots == 0 then break end
		local s = deli(spots, flr(rnd(#spots)) + 1)
		add(mz.zs, {x=s[1] + 0.5, y=s[2] + 0.5, hp=2, hit_t=0, wob=rnd(1), flip=false})
	end

	state = "maze"
	road_zs, bullets, parts = {}, {}, {}
	shake = 0
	show_banner("FIND A GAS CAN")
end

local function leave_maze()
	mz = nil
	fuel = MAX_FUEL
	score += 100
	state = "play"
	phase, phase_t = "drive", DRIVE_TIME
	show_banner("TANK FULL")
end

local function update_maze()
	banner_t = max(banner_t - 1, 0)
	mz.cool = max(mz.cool - 1, 0)
	mz.flash = max(mz.flash - 1, 0)
	mz.hurt_t = max(mz.hurt_t - 1, 0)

	-- left / right turn, up / down walk
	if btn(0) then mz.a += TURN_SPD end
	if btn(1) then mz.a -= TURN_SPD end
	set_dir()
	local mv = 0
	if btn(2) then mv = WALK_SPD end
	if btn(3) then mv = -WALK_SPD * 0.7 end
	if mv ~= 0 then
		move_body(mz, mz.dx * mv, mz.dy * mv)
		mz.bob += 0.04
	end
	mz.seen[flr(mz.y)*mz.size + flr(mz.x)] = true

	-- hitscan: the nearest zombie under the crosshair, if it's in front of the trees
	if btn(4) and mz.cool == 0 then
		mz.cool, mz.flash = MZ_FIRE_DELAY, 3
		local best, best_d = nil, cast(mz.dx, mz.dy)
		local half = MZ_ZOMBIE_SCALE * SH * zw / zh / SW
		for z in all(mz.zs) do
			local tx, ty = to_cam(z.x, z.y)
			if ty > 0.1 and ty < best_d and abs(tx) < half then best, best_d = z, ty end
		end
		if best then
			best.hp -= 1
			best.hit_t = 4
			move_body(best, mz.dx * 0.15, mz.dy * 0.15)  -- knockback
		end
	end

	for i=#mz.zs,1,-1 do
		local z = mz.zs[i]
		z.hit_t = max(z.hit_t - 1, 0)
		if z.hp <= 0 then
			kills += 1
			score += 10
			shake = 3
			deli(mz.zs, i)
		else
			local dx, dy, d = norm(mz.x - z.x, mz.y - z.y)
			if d < MZ_AGGRO then
				local step = shamble(z) * MZ_ZOMBIE_SPD
				move_body(z, dx * step, dy * step)
				z.wob += 0.05
				-- the sprite faces left, so flip it when it's heading right across the view
				z.flip = dx*mz.plx + dy*mz.ply > 0
			end
			if d < 0.45 and mz.hurt_t == 0 then
				car.hp -= 1
				mz.hurt_t = 40
				shake = 6
				move_body(z, -dx * 0.6, -dy * 0.6)
				if car.hp <= 0 then
					state = "over"
					shake = 12
				end
			end
		end
	end

	local _, _, d = norm(mz.can.x - mz.x, mz.can.y - mz.y)
	if d < 0.5 then leave_maze() end
end

-- draw a sprite standing on the floor at (x, y), one ray column at a time so trees
-- in front cut it off. returns true if any of it was on screen.
local function draw_billboard(img, x, y, scale, fog, flip, tint)
	local tx, ty = to_cam(x, y)
	if ty < 0.15 then return false end
	local iw, ih = img:width(), img:height()
	local wall_h = SH / ty
	local h = wall_h * scale
	local w = h * iw / ih
	local x0 = SW/2 * (1 + tx/ty) - w/2
	local top = SH/2 + wall_h/2 - h
	local c0, c1 = max(0, flr(x0 / COLW)), min(NCOL - 1, flr((x0 + w) / COLW))
	if c0 > c1 then return false end

	palt(0, false)
	palt(TRANS_COL, true)
	local lvl = fog and min(flr(ty / FOG_STEP), 3) or 0
	for c=0,31 do
		if c ~= TRANS_COL then pal(c, tint or darken(c, lvl)) end
	end
	local drawn = false
	for c=c0,c1 do
		if ty < zbuf[c] then
			local u = flr((c*COLW + COLW/2 - x0) / w * iw)
			if u >= 0 and u < iw then
				if flip then u = iw - 1 - u end
				sspr(img, u, 0, 1, ih, c*COLW, top, COLW, h)
				drawn = true
			end
		end
	end
	pal()
	palt()
	return drawn
end

local function draw_hands()
	local sway = cos(mz.bob) * 5
	-- bob and recoil only push them down, so the sleeves always run off the bottom edge
	local top = SH - get_spr(GUN_SPR):height() + abs(sin(mz.bob)) * 4
	local gun_x = SW/2 + HAND_SPREAD + sway
	local gun_top = top + (mz.flash > 0 and 4 or 0)

	palt(0, false)
	palt(TRANS_COL, true)
	spr(CROSS_SPR, flr(SW/2 - HAND_SPREAD + sway) - CROSS_MID_X, flr(top))
	spr(GUN_SPR, flr(gun_x) - GUN_MUZZLE_X, flr(gun_top))
	palt()

	if mz.flash > 0 then
		circfill(gun_x, gun_top-2, 5 + mz.flash*2, 9)
		circfill(gun_x, gun_top-2, 3 + mz.flash, 10)
		circfill(gun_x, gun_top-2, 2, 7)
	end
end

local function draw_maze()
	camera(rnd(shake) - shake/2, rnd(shake) - shake/2)
	local hz = SH/2

	-- night sky; stars slide past as you turn (one full turn is about 5.4 screens)
	rectfill(0, 0, SW, hz, 0)
	for i=0,39 do
		local x = (i*137 + mz.a * SW * 5.4) % SW
		pset(x, (i*53) % (hz - 20), i % 5 == 0 and 7 or (i % 2 == 0 and 6 or 5))
	end

	-- ground in the same fog bands as the trees: a row hz + hz/d is d tiles away
	rectfill(0, hz, SW, SH, 0)
	rectfill(0, hz + hz / (FOG_STEP*2), SW, SH, 1)
	rectfill(0, hz + hz / FOG_STEP, SW, SH, 3)

	-- trees
	for c=0,NCOL-1 do
		local camx = 2 * (c + 0.5) / NCOL - 1
		local d, side, u = cast(mz.dx + mz.plx*camx, mz.dy + mz.ply*camx)
		zbuf[c] = d
		local h = SH / d
		local lvl = min(flr(d / FOG_STEP), 3) + side  -- y faces a shade darker
		sspr(wall_tex[lvl], flr(u * TEX), 0, 1, TEX, c*COLW, hz - h/2, COLW, h)
	end

	-- zombies and the can, far to near
	local sprites = {}
	for z in all(mz.zs) do add(sprites, {o=z, d=(z.x - mz.x)^2 + (z.y - mz.y)^2}) end
	add(sprites, {o=mz.can, d=(mz.can.x - mz.x)^2 + (mz.can.y - mz.y)^2})
	for i=2,#sprites do
		local j = i
		while j > 1 and sprites[j-1].d < sprites[j].d do
			sprites[j-1], sprites[j] = sprites[j], sprites[j-1]
			j -= 1
		end
	end
	for s in all(sprites) do
		local o = s.o
		if o == mz.can then
			-- no fog on the can so it stands out once you've found the right corridor
			if draw_billboard(can_img, o.x, o.y, CAN_SCALE, false, false) then o.seen = true end
		else
			local frame = walk_phase(o)
			draw_billboard(get_spr(ZOMBIE_SPR + frame), o.x, o.y, MZ_ZOMBIE_SCALE, true, o.flip,
				o.hit_t > 0 and 7 or nil)
		end
	end

	draw_hands()

	-- crosshair: shots hit the nearest zombie in line with it
	local cx, cy = SW/2, hz
	line(cx-5, cy, cx-2, cy, 7)
	line(cx+2, cy, cx+5, cy, 7)
	line(cx, cy-5, cx, cy-2, 7)
	line(cx, cy+2, cx, cy+5, 7)

	if mz.hurt_t > 25 then
		for i=0,3 do rect(i, i, SW-1-i, SH-1-i, 8) end
	end
	camera()
end

-- everything you've laid eyes on, while X is held
local function draw_automap()
	local size = mz.size
	local cs = flr(min(200 / size, 12))
	local ox, oy = flr(SW/2 - size*cs/2), flr(SH/2 - size*cs/2)
	rectfill(ox-4, oy-4, ox + size*cs + 3, oy + size*cs + 3, 0)
	rect(ox-4, oy-4, ox + size*cs + 3, oy + size*cs + 3, 5)
	for y=0,size-1 do
		for x=0,size-1 do
			if mz.seen[y*size + x] then
				rectfill(ox + x*cs, oy + y*cs, ox + x*cs + cs-1, oy + y*cs + cs-1, mz.map[y][x] == 1 and 3 or 1)
			end
		end
	end
	if mz.can.seen then circfill(ox + mz.can.x*cs, oy + mz.can.y*cs, 2, 8) end
	local px, py = ox + mz.x*cs, oy + mz.y*cs
	line(px, py, px + mz.dx*cs, py + mz.dy*cs, 10)
	circfill(px, py, 1.5, 10)
end

-- update -------------------------------------------------------------------

local function update_gunner()
	-- left / right only lean out during a wave; between waves they steer
	local want = 0
	if phase == "wave" then
		if btn(0) then want = -1 end
		if btn(1) then want = 1 end
	end

	-- switching sides means ducking back in first
	if want ~= 0 and want == gunner.side then
		gunner.out = min(gunner.out + LEAN_SPEED, 1)
	else
		gunner.out = max(gunner.out - LEAN_SPEED, 0)
		if gunner.out == 0 then gunner.side = want end
	end

	gunner.cool = max(gunner.cool - 1, 0)
	gunner.flash = max(gunner.flash - 1, 0)
	if gunner.side == 0 or gunner.out < 1 then return end

	-- find nearest zombie on this side of the car
	local _, _, sx, sy = muzzle_pos()
	local target, best = nil, GUN_RANGE
	for z in all(zombies) do
		if (z.x - car.x) * gunner.side > 0 then
			local _, _, d = norm(z.x - sx, z.y - sy)
			if d < best then target, best = z, d end
		end
	end

	if target then
		gunner.ax, gunner.ay = norm(target.x - sx, target.y - sy)
		if gunner.cool == 0 then
			local mx, my = muzzle_pos()
			add(bullets, {x=mx, y=my, vx=gunner.ax*BULLET_SPD, vy=gunner.ay*BULLET_SPD, life=50})
			gunner.cool = FIRE_DELAY
			gunner.flash = 3
		end
	else
		-- idle aim: straight out the window
		gunner.ax, gunner.ay = gunner.side, 0
	end
end

local function hurt_car(x, y)
	car.hp -= 1
	car.hit_t = 20
	shake = 6
	burst(x, y, 10, {8, 2, 7}, 2)
	if car.hp <= 0 then
		state = "over"
		shake = 12
		burst(car.x, car.y, 40, {8, 9, 10, 7}, 4)
	end
end

local function is_glass(px, py)
	return px >= 0 and px < car.w and glass[py*car.w + px]
end

-- paint blood onto the windshield, roughly in line with where the zombie hit (hx, in sprite coords).
-- only glass pixels get painted; it stays there until the wiper clears it.
local function splatter(hx)
	for i=1,3 do
		local cx = mid(gx0, hx + rnd(8) - 4, gx1)
		local cy = gy0 + rnd(gy1 - gy0 + 1)
		local r = 0.7 + rnd(1.5)
		local col = rnd(1) < 0.6 and 8 or 2
		for py=flr(cy-r),flr(cy+r) do
			for px=flr(cx-r),flr(cx+r) do
				if is_glass(px, py) and (px-cx)^2 + (py-cy)^2 <= r*r then
					car_img:set(px, py, col)
					stains[py*car.w + px] = {x=px, y=py}
				end
			end
		end
	end
end

local function start_wipe()
	wiper.t, wiper.a = 0, 1
end

-- swing the wiper across the windshield and back; blood the blade passes over becomes clean glass.
-- angle 1 lies flat pointing right, 0.75 straight down toward the roof, 0.5 flat pointing left.
local function update_wiper()
	if not wiper.t then return end
	wiper.t += 1
	local prev = wiper.a
	wiper.a = 0.75 + 0.25 * cos(wiper.t / WIPE_SWEEP)
	local lo, hi = min(prev, wiper.a), max(prev, wiper.a)
	for key, st in pairs(stains) do
		-- wrap into 0..1, since stains below the pivot can come back from atan2 as negative angles
		local a = atan2(st.x + 0.5 - wiper.x, st.y + 0.5 - wiper.y) % 1
		if a >= lo and a <= hi then
			car_img:set(st.x, st.y, GLASS_COL)
			stains[key] = nil
		end
	end
	if wiper.t >= WIPE_SWEEP * WIPE_PASSES then wiper.t = nil end
end

local function burn_fuel(amount)
	if phase == "stall" then return end
	fuel = max(fuel - amount, 0)
	if fuel == 0 then
		phase, phase_t = "stall", STALL_WAIT
		show_banner("OUT OF GAS")
	end
end

local function steer_car()
	if phase == "wave" then return end
	if btn(0) then car.x -= STEER_SPEED end
	if btn(1) then car.x += STEER_SPEED end
	car.x = mid(ROAD_X0 + car.w/2, car.x, ROAD_X1 - car.w/2)
end

local function update_road_zombies()
	-- only spawn while cruising, so none are left over when the wave starts
	if phase == "drive" then
		road_t -= 1
		if road_t <= 0 then
			spawn_road_zombie()
			road_t = 25 + rnd(35)
		end
	end

	for i=#road_zs,1,-1 do
		local z = road_zs[i]
		-- the road carries them toward the car; they shuffle toward it a little too
		local step = shamble(z)
		z.y += speed + 0.22 * step
		z.x += sgn(car.x - z.x) * 0.15 * step
		z.wob += 0.05

		if abs(z.x - car.x) < car.w/2 + 3 and abs(z.y - car.y) < car.h/2 + 3 then
			kills += 1
			score += ROADKILL_SCORE
			car.hp = min(car.hp + ROADKILL_HEAL, car.max_hp)
			burn_fuel(ROADKILL_FUEL)
			shake = 3
			burst(z.x, z.y, 20, {8, 2, 3, 11}, 3)
			splatter(z.x - (car.x - car.w/2))
			deli(road_zs, i)
		elseif z.y > SH + zh then
			deli(road_zs, i)
		end
	end
end

local function update_phase()
	if phase == "drive" then
		speed = min(speed + ACCEL, CRUISE_SPEED)
		phase_t -= 1
		if phase_t <= 0 then phase = "brake" end

	elseif phase == "brake" then
		speed = max(speed - BRAKE, 0)
		if speed == 0 then
			phase = "wave"
			to_spawn = 6 + wave * 4
			spawn_t = 30
			show_banner("WAVE " .. wave)
			start_wipe()
		end

	elseif phase == "wave" then
		spawn_t -= 1
		if to_spawn > 0 and spawn_t <= 0 then
			spawn_zombie()
			to_spawn -= 1
			spawn_t = max(10, 45 - wave * 4)
		end
		if to_spawn == 0 and #zombies == 0 then
			score += 50 * wave
			show_banner("WAVE " .. wave .. " CLEAR")
			wave += 1
			phase, phase_t = "drive", DRIVE_TIME
		end

	elseif phase == "stall" then
		-- coast to a stop, sit a moment, then the priest gets out and walks
		speed = max(speed - BRAKE, 0)
		if speed == 0 then
			phase_t -= 1
			if phase_t <= 0 then enter_maze() end
		end
	end
end

local function update_play()
	update_phase()
	if state ~= "play" then return end
	burn_fuel(speed * FUEL_BURN)
	scroll += speed
	score += speed * 0.02
	banner_t = max(banner_t - 1, 0)

	steer_car()
	update_road_zombies()
	update_gunner()

	-- bullets
	for i=#bullets,1,-1 do
		local b = bullets[i]
		b.x += b.vx
		b.y += b.vy
		b.life -= 1
		local dead = b.life <= 0 or b.x < -10 or b.x > SW+10 or b.y < -10 or b.y > SH+10
		if not dead then
			for z in all(zombies) do
				if abs(b.x - z.x) < z.w/2 and abs(b.y - z.y) < z.h/2 then
					z.hp -= 1
					z.hit_t = 4
					z.x += b.vx * 0.6  -- knockback
					z.y += b.vy * 0.6
					burst(b.x, b.y, 4, {3, 11, 8}, 1.5)
					dead = true
					break
				end
			end
		end
		if dead then deli(bullets, i) end
	end

	-- zombies shamble toward the car
	local gx, gy = gunner_pos()
	for i=#zombies,1,-1 do
		local z = zombies[i]
		if z.hp <= 0 then
			kills += 1
			score += 10
			burst(z.x, z.y, 14, {3, 11, 8, 2}, 2.5)
			deli(zombies, i)
		else
			local dx, dy = norm(car.x - z.x, car.y - z.y)
			local step = shamble(z)
			z.x += dx * z.spd * step
			z.y += dy * z.spd * step
			z.wob += 0.05 * z.anim
			z.hit_t = max(z.hit_t - 1, 0)

			local touching_car = abs(z.x - car.x) < car.w/2 + 3 and abs(z.y - car.y) < car.h/2 + 3
			local touching_gunner = gunner.out > 0.5 and abs(z.x - gx) < pw/2 + 1 and abs(z.y - gy) < ph/2 + 1
			if touching_car or touching_gunner then
				hurt_car(z.x, z.y)
				deli(zombies, i)
			end
		end
	end

	car.hit_t = max(car.hit_t - 1, 0)
	update_wiper()
end

local function update_parts()
	for i=#parts,1,-1 do
		local p = parts[i]
		p.x += p.vx
		p.y += p.vy + speed * 0.5  -- gore gets left behind on the road
		p.vx *= 0.9
		p.vy *= 0.9
		p.life -= 1
		if p.life <= 0 then deli(parts, i) end
	end
end

function _update()
	shake = max(shake - 0.5, 0)
	update_parts()

	if state == "title" then
		scroll += speed
		if btnp(4) or btnp(5) then
			reset_game()
			state = "play"
		end
	elseif state == "play" then
		update_play()
	elseif state == "maze" then
		update_maze()
	elseif state == "over" then
		if btnp(4) or btnp(5) then
			reset_game()
			state = "play"
		end
	end
end

-- draw ---------------------------------------------------------------------

local function draw_world()
	-- verges
	rectfill(0, 0, ROAD_X0-1, SH, 3)
	rectfill(ROAD_X1+1, 0, SW, SH, 3)

	-- grass tufts scroll past to sell the motion
	for i=0,59 do
		local tx = (i * 137) % (ROAD_X0 - 10) + 4
		if i % 2 == 1 then tx = SW - tx end
		local ty = (i * 53 + scroll) % (SH + 20) - 10
		line(tx, ty, tx+2, ty-3, 11)
		line(tx+3, ty, tx+3, ty-4, 11)
	end

	-- road
	rectfill(ROAD_X0, 0, ROAD_X1, SH, 5)
	rectfill(ROAD_X0-3, 0, ROAD_X0-1, SH, 6)
	rectfill(ROAD_X1+1, 0, ROAD_X1+3, SH, 6)

	-- lane dashes
	local off = scroll % 40
	for y=-40,SH,40 do
		rectfill(SW/2 - 1, y + off, SW/2 + 1, y + off + 20, 10)
	end
end

-- draw a sprite centred on (x, y) with pink as the transparent colour.
-- tint (optional) recolours every visible pixel, for hit flashes etc.
local function draw_sprite(s, x, y, w, h, flip_x, tint)
	palt(0, false)
	palt(TRANS_COL, true)
	if tint then
		for c=0,31 do
			if c ~= TRANS_COL then pal(c, tint) end
		end
	end

	spr(s, x - w/2, y - h/2, flip_x)

	pal()
	palt()
end

local function draw_zombie(z)
	-- the sprite faces left, so flip it when the car is off to the right
	local flip = z.x < car.x
	local frame = walk_phase(z)
	draw_sprite((z.spr or ZOMBIE_SPR) + frame, z.x, z.y, z.w or zw, z.h or zh, flip, z.hit_t > 0 and 7 or nil)
end

local function draw_gunner()
	if gunner.side == 0 or gunner.out <= 0 then return end
	local s = gunner.side
	local wx = car.x + s*(car.side - 1)  -- start on the car's outline so there's no seam
	local sx, sy = gunner_pos()

	-- black cassock bridging the window and the sprite, whose body trails off its bottom inner corner
	local ex = sx - s*pw/2
	local top = flr(sy - ph/2)
	rectfill(min(wx, ex), top + ph - 3, max(wx, ex), top + ph - 1, 0)
	-- the sprite faces right, so flip it out the left window
	draw_sprite(PRIEST_SPR, sx, sy, pw, ph, s < 0)

	if gunner.out >= 1 then
		local mx, my = muzzle_pos()
		line(sx, sy, mx, my, 6)
		-- hands gripping the gun: one near the stock, one further up the barrel
		for d in all(PRIEST_HANDS) do
			pset(sx + gunner.ax*d, sy + gunner.ay*d, PRIEST_SKIN)
		end
		if gunner.flash > 0 then
			circfill(mx, my, 2 + gunner.flash, 10)
			circfill(mx, my, 1 + gunner.flash/2, 7)
		end
	end
end

local function draw_car()
	local flash = car.hit_t > 0 and flr(car.hit_t / 3) % 2 == 0
	local tint = nil
	if state == "over" then tint = 1      -- burnt-out wreck
	elseif flash then tint = 8 end        -- hit flash

	draw_sprite(car_img, car.x, car.y, car.w, car.h, false, tint)

	-- wiper blade, only drawn where it's over the glass
	if wiper.t then
		local ox, oy = flr(car.x - car.w/2), flr(car.y - car.h/2)
		local dx, dy = cos(wiper.a), sin(wiper.a)
		for d=1,wiper.len,0.5 do
			local px, py = flr(wiper.x + dx*d), flr(wiper.y + dy*d)
			if is_glass(px, py) then pset(ox + px, oy + py, 0) end
		end
	end
end

local function draw_bar(label, y, frac, col)
	local bw = 80
	local bx = SW - bw - 6
	print(label, bx - 22, y, 7)
	rectfill(bx, y, bx + bw, y + 6, 0)
	if frac > 0 then rectfill(bx, y, bx + bw * frac, y + 6, col) end
end

local function draw_hud()
	print("SCORE " .. flr(score), 6, 6, 7)
	print("KILLS " .. kills, 6, 16, 7)
	print("WAVE " .. wave, 6, 26, 7)
	if phase == "wave" then
		print("LEFT " .. (to_spawn + #zombies), 6, 36, 8)
	end

	if mz then
		print("ON FOOT - FIND A GAS CAN", 6, 36, 9)
		print("hold X for map", 6, SH - 12, 5)
	end

	draw_bar("HP", 6, car.hp / car.max_hp, car.hp > 3 and 11 or 8)
	-- low fuel blinks red
	local low = fuel < LOW_FUEL
	draw_bar("FUEL", 16, fuel / MAX_FUEL, low and (flr(time() * 4) % 2 == 0 and 8 or 2) or 9)
	if low and not mz then print(fuel > 0 and "LOW FUEL" or "EMPTY", SW - 86, 26, 8) end
end

local function draw_banner()
	-- blink the banner in its final half-second
	if banner_t > 30 or (banner_t > 0 and banner_t % 8 < 4) then
		rectfill(SW/2 - 60, 54, SW/2 + 60, 70, 0)
		print_c(banner, 59, 10)
	end
end

function _draw()
	cls(0)

	if mz then
		draw_maze()
	else
		camera(rnd(shake) - shake/2, rnd(shake) - shake/2)

		draw_world()
		for p in all(parts) do pset(p.x, p.y, p.col) end
		for z in all(road_zs) do draw_zombie(z) end
		for z in all(zombies) do draw_zombie(z) end
		draw_car()
		draw_gunner()
		for b in all(bullets) do
			line(b.x, b.y, b.x - b.vx*0.6, b.y - b.vy*0.6, 10)
		end

		camera()
	end

	if state == "title" then
		rectfill(SW/2 - 130, 74, SW/2 + 130, 168, 0)
		print_c("HOLY ROLLER", 86, 10)
		print_c("waves: hold LEFT / RIGHT to lean out and shoot", 100, 7)
		print_c("between waves: steer and run zombies down", 112, 7)
		print_c("driving burns fuel, and so does roadkill", 124, 7)
		print_c("run dry and you walk: find a gas can in the woods", 136, 7)
		print_c("press Z or X to start", 152, 6)
	elseif state == "play" or state == "maze" then
		draw_hud()
		draw_banner()
		if mz and btn(5) then draw_automap() end
	elseif state == "over" then
		draw_hud()
		rectfill(SW/2 - 90, 100, SW/2 + 90, 150, 0)
		print_c(mz and "LOST IN THE WOODS" or "THE HORDE PREVAILS", 110, 8)
		print_c("score " .. flr(score) .. "   kills " .. kills, 122, 7)
		print_c("press Z or X to ride again", 136, 6)
	end
end
