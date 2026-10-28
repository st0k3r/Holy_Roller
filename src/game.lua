--[[pod_format="raw",created="2026-10-28 22:23:42",modified="2026-10-28 22:23:44",revision=1]]
-- Holy Roller
-- the car drives up the middle of the road while zombies close in from both sides.
-- hold left / right to lean out of that window; while leaning out you auto-fire.

local SW, SH = 480, 270
local ROAD_W = 140
local ROAD_X0 = SW/2 - ROAD_W/2
local ROAD_X1 = SW/2 + ROAD_W/2

local LEAN_SPEED = 0.15  -- how fast the gunner leans out / ducks back in (0..1 per frame)
local FIRE_DELAY = 8     -- frames between shots
local BULLET_SPD = 7
local GUN_RANGE = 260

local state         -- "title", "play", "over"
local car, gunner
local zombies, bullets, parts
local scroll, speed, score, kills, frame, spawn_t, shake

function reset_game()
	car = {x=SW/2, y=185, w=30, h=54, hp=10, max_hp=10, hit_t=0}
	-- side: -1 left, 1 right, 0 inside. out: lean amount 0..1
	gunner = {side=0, out=0, cool=0, ax=0, ay=-1, flash=0}
	zombies, bullets, parts = {}, {}, {}
	scroll, speed = 0, 3
	score, kills, frame = 0, 0, 0
	spawn_t, shake = 60, 0
end

function _init()
	state = "title"
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

local function muzzle_pos()
	local s = gunner.side
	local sx = car.x + s*(car.w/2 + 9*gunner.out)
	local sy = car.y - 8
	return sx + gunner.ax*8, sy + gunner.ay*8, sx, sy
end

local function print_c(s, y, col)
	local w = print(s, 0, -100)  -- print offscreen to measure width
	print(s, SW/2 - w/2, y, col)
end

-- spawning -----------------------------------------------------------------

local function spawn_zombie()
	local side = rnd(1) < 0.5 and -1 or 1
	local difficulty = min(frame / 3600, 1)  -- ramps over ~1 minute
	add(zombies, {
		x = side < 0 and -8 or SW+8,
		y = 10 + rnd(SH-20),
		side = side,
		spd = 0.35 + rnd(0.3) + difficulty*0.5,
		hp = 2,
		hit_t = 0,
		wob = rnd(1),
	})
end

-- update -------------------------------------------------------------------

local function update_gunner()
	local want = 0
	if btn(0) then want = -1 end
	if btn(1) then want = 1 end

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

local function update_play()
	frame += 1
	speed = 3 + min(frame / 3600, 1) * 2
	scroll += speed
	score += speed * 0.02

	update_gunner()

	-- spawning gets faster over time
	spawn_t -= 1
	if spawn_t <= 0 then
		spawn_zombie()
		spawn_t = max(18, 70 - frame / 60)
	end

	-- bullets
	for i=#bullets,1,-1 do
		local b = bullets[i]
		b.x += b.vx
		b.y += b.vy
		b.life -= 1
		local dead = b.life <= 0 or b.x < -10 or b.x > SW+10 or b.y < -10 or b.y > SH+10
		if not dead then
			for z in all(zombies) do
				if abs(b.x - z.x) < 6 and abs(b.y - z.y) < 8 then
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
	local gx = car.x + gunner.side*(car.w/2 + 9*gunner.out)
	local gy = car.y - 8
	for i=#zombies,1,-1 do
		local z = zombies[i]
		if z.hp <= 0 then
			kills += 1
			score += 10
			burst(z.x, z.y, 14, {3, 11, 8, 2}, 2.5)
			deli(zombies, i)
		else
			local dx, dy = norm(car.x - z.x, car.y - z.y)
			z.x += dx * z.spd
			z.y += dy * z.spd
			z.wob += 0.05
			z.hit_t = max(z.hit_t - 1, 0)

			local touching_car = abs(z.x - car.x) < car.w/2 + 3 and abs(z.y - car.y) < car.h/2 + 3
			local touching_gunner = gunner.out > 0.5 and abs(z.x - gx) < 7 and abs(z.y - gy) < 9
			if touching_car or touching_gunner then
				hurt_car(z.x, z.y)
				deli(zombies, i)
			end
		end
	end

	car.hit_t = max(car.hit_t - 1, 0)
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
		scroll += 2
		if btnp(4) or btnp(5) then
			reset_game()
			state = "play"
		end
	elseif state == "play" then
		update_play()
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

local function draw_zombie(z)
	local bob = sin(z.wob) * 1.5
	local body = z.hit_t > 0 and 7 or 3
	local skin = z.hit_t > 0 and 7 or 11
	local x, y = z.x, z.y + bob
	local dir = z.x < car.x and 1 or -1

	-- legs
	line(x-2, y+3, x-2 - bob, y+8, 1)
	line(x+2, y+3, x+2 + bob, y+8, 1)
	-- torso
	rectfill(x-3, y-4, x+3, y+3, body)
	-- arms reaching toward the car
	line(x, y-3, x + dir*8, y-4 + bob, skin)
	line(x, y-1, x + dir*8, y-1 - bob, skin)
	-- head
	circfill(x, y-7, 3, skin)
	pset(x + dir, y-8, 8)
end

local function draw_gunner()
	if gunner.side == 0 or gunner.out <= 0 then return end
	local s = gunner.side
	local wx = car.x + s*(car.w/2 - 2)
	local sx = car.x + s*(car.w/2 + 9*gunner.out)
	local sy = car.y - 8

	-- torso leaning out the window (black cassock, white collar)
	rectfill(min(wx, sx-3*s), sy-1, max(wx, sx-3*s), sy+6, 0)
	circfill(sx, sy, 4, 0)
	circfill(sx, sy-5, 3, 15)
	rectfill(sx-2, sy-2, sx+2, sy-2, 7)

	if gunner.out >= 1 then
		local mx, my = muzzle_pos()
		line(sx, sy, mx, my, 6)
		if gunner.flash > 0 then
			circfill(mx, my, 2 + gunner.flash, 10)
			circfill(mx, my, 1 + gunner.flash/2, 7)
		end
	end
end

local function draw_car()
	if state == "over" then
		-- burnt-out wreck
		rectfill(car.x - car.w/2, car.y - car.h/2, car.x + car.w/2, car.y + car.h/2, 1)
		return
	end

	local x0, y0 = car.x - car.w/2, car.y - car.h/2
	local x1, y1 = car.x + car.w/2, car.y + car.h/2
	local flash = car.hit_t > 0 and flr(car.hit_t / 3) % 2 == 0
	local body = flash and 8 or 7

	-- wheels
	rectfill(x0-2, y0+6, x0, y0+16, 0)
	rectfill(x1, y0+6, x1+2, y0+16, 0)
	rectfill(x0-2, y1-16, x0, y1-6, 0)
	rectfill(x1, y1-16, x1+2, y1-6, 0)

	-- body
	rectfill(x0, y0+2, x1, y1-2, body)
	rectfill(x0+2, y0, x1-2, y1, body)
	-- windscreen + rear window
	rectfill(x0+4, y0+8, x1-4, y0+14, 1)
	rectfill(x0+4, y1-10, x1-4, y1-6, 1)
	-- side windows (where the gunner leans out)
	rectfill(x0, y0+16, x0+1, y0+26, 1)
	rectfill(x1-1, y0+16, x1, y0+26, 1)
	-- roof with gold cross
	rectfill(x0+4, y0+15, x1-4, y1-11, 6)
	rectfill(car.x-1, y0+18, car.x+1, y1-14, 10)
	rectfill(car.x-5, y0+22, car.x+5, y0+24, 10)
	-- headlights
	rectfill(x0+3, y0, x0+7, y0+1, 10)
	rectfill(x1-7, y0, x1-3, y0+1, 10)
end

local function draw_hud()
	print("SCORE " .. flr(score), 6, 6, 7)
	print("KILLS " .. kills, 6, 16, 7)

	-- health bar
	local bw = 80
	local bx = SW - bw - 6
	print("HP", bx - 14, 6, 7)
	rectfill(bx, 6, bx + bw, 12, 0)
	rectfill(bx, 6, bx + bw * car.hp / car.max_hp, 12, car.hp > 3 and 11 or 8)
end

function _draw()
	cls(0)
	camera(rnd(shake) - shake/2, rnd(shake) - shake/2)

	draw_world()
	for p in all(parts) do pset(p.x, p.y, p.col) end
	for z in all(zombies) do draw_zombie(z) end
	draw_car()
	draw_gunner()
	for b in all(bullets) do
		line(b.x, b.y, b.x - b.vx*0.6, b.y - b.vy*0.6, 10)
	end

	camera()

	if state == "title" then
		rectfill(SW/2 - 110, 80, SW/2 + 110, 150, 0)
		print_c("HOLY ROLLER", 92, 10)
		print_c("hold LEFT / RIGHT to lean out and shoot", 112, 7)
		print_c("press Z or X to start", 132, 6)
	elseif state == "play" then
		draw_hud()
	elseif state == "over" then
		draw_hud()
		rectfill(SW/2 - 90, 100, SW/2 + 90, 150, 0)
		print_c("THE HORDE PREVAILS", 110, 8)
		print_c("score " .. flr(score) .. "   kills " .. kills, 122, 7)
		print_c("press Z or X to ride again", 136, 6)
	end
end
