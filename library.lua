--!nonstrict
--[=[
	NECTAR UI ─ a commercial-grade interface framework for Roblox
	============================================================
	Design language : floating surfaces · layered depth · soft shadows · restrained motion
	Architecture    : Signal → State → Motion → Theme → Components → Chrome (Window/Tab/Section)

	WHY one file?  The framework is deliberately shipped as a single module so it can be
	loadstring'd, required, or bundled without a loader graph. Internally it is still
	organized as isolated "modules" (local tables) with explicit dependencies, so the
	single-file constraint never leaks into the architecture.

	Public entry:
		local Nectar  = require(...Library)
		local Window  = Nectar:CreateWindow({ Title = "…" })
		local Tab     = Window:CreateTab({ Name = "Main", Icon = "home" })
		local Section = Tab:CreateSection("Settings")
		Section:CreateToggle({ Name = "…", Callback = print })
]=]

local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

--═══════════════════════════════════════════════════════════════════════════
-- § Util ─ instance construction, connection ownership, misc helpers
--═══════════════════════════════════════════════════════════════════════════
local Util = {}

-- WHY: every builder in the framework funnels through one constructor so that
-- defaults (BorderSizePixel, AutoButtonColor, text behaviour) are enforced in
-- exactly one place instead of 400.
function Util.Create(className, props, children)
	local inst = Instance.new(className)
	-- Only GuiObjects carry BorderSizePixel; ScreenGui / UICorner / UIStroke /
	-- layout & constraint objects do not, and assigning it would throw.
	if inst:IsA("GuiObject") then inst.BorderSizePixel = 0 end
	if className == "TextButton" or className == "ImageButton" then
		inst.AutoButtonColor = false
		inst.Text = ""
	end
	if className == "TextLabel" or className == "TextButton" or className == "TextBox" then
		inst.BackgroundTransparency = (props and props.BackgroundTransparency) or 1
		inst.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
		inst.TextColor3 = Color3.fromRGB(235, 235, 240)
		inst.TextSize = 13
		inst.Text = "" -- clear Roblox defaults ("Label"/"Button"/"TextBox"); props.Text overrides
	end
	if props then
		for k, v in pairs(props) do
			if k ~= "Parent" then inst[k] = v end
		end
	end
	if children then
		for _, child in ipairs(children) do child.Parent = inst end
	end
	if props and props.Parent then inst.Parent = props.Parent end
	return inst
end

function Util.Round(inst, radius)
	return Util.Create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = inst })
end

function Util.Stroke(inst, color, transparency, thickness)
	return Util.Create("UIStroke", {
		Color = color, Transparency = transparency or 0, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = inst,
	})
end

function Util.Padding(inst, t, b, l, r)
	return Util.Create("UIPadding", {
		PaddingTop = UDim.new(0, t or 0), PaddingBottom = UDim.new(0, b or t or 0),
		PaddingLeft = UDim.new(0, l or t or 0), PaddingRight = UDim.new(0, r or l or t or 0),
		Parent = inst,
	})
end

-- Soft drop shadow, assetless. WHY behind-as-sibling: a shadow parented *into*
-- the element (even at ZIndex -1) draws over the element's own background and
-- tints its face; a mis-sliced image asset renders as a hard translucent square.
-- Instead we drop one rounded, low-opacity frame just behind the element, so it
-- always matches the curvature, needs no asset, and never darkens the face.
-- Intended for static elements (it snapshots geometry at creation).
function Util.Shadow(parent, transparency, spread, radius)
	spread = spread or 24
	transparency = transparency or 0.5
	radius = radius or 16
	local host = parent.Parent
	if not host then return nil end
	local shadow = Util.Create("Frame", {
		Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = transparency, AnchorPoint = parent.AnchorPoint,
		Position = parent.Position,
		Size = UDim2.new(parent.Size.X.Scale, parent.Size.X.Offset + spread,
			parent.Size.Y.Scale, parent.Size.Y.Offset + spread),
		ZIndex = math.max(0, parent.ZIndex - 1), Parent = host,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(0, radius + math.floor(spread * 0.5)), Parent = shadow })
	return shadow
end

-- Connection bag: everything the framework connects is owned by a Maid so a
-- destroyed component can never leak a Heartbeat or Input connection.
local Maid = {}
Maid.__index = Maid
function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end
function Maid:Add(job)
	table.insert(self._tasks, job)
	return job
end
function Maid:Clean()
	for _, job in ipairs(self._tasks) do
		if typeof(job) == "RBXScriptConnection" then
			job:Disconnect()
		elseif typeof(job) == "Instance" then
			job:Destroy()
		elseif type(job) == "function" then
			job()
		elseif type(job) == "table" and job.Destroy then
			job:Destroy()
		end
	end
	table.clear(self._tasks)
end

Util.Maid = Maid

--═══════════════════════════════════════════════════════════════════════════
-- § Signal ─ minimal, allocation-light event primitive
--═══════════════════════════════════════════════════════════════════════════
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handlers = self._handlers
	handlers[fn] = true
	local connection = {
		Connected = true,
		Disconnect = function(conn)
			conn.Connected = false
			handlers[fn] = nil
		end,
	}
	return connection
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Fire(...)
	for fn in pairs(self._handlers) do
		task.spawn(fn, ...)
	end
end

function Signal:Destroy()
	table.clear(self._handlers)
end

--═══════════════════════════════════════════════════════════════════════════
-- § State ─ tiny reactive layer: State, Computed, bindings
--═══════════════════════════════════════════════════════════════════════════
local State = {}
State.__index = State

function State.new(initial)
	return setmetatable({
		_value = initial,
		Changed = Signal.new(),
	}, State)
end

function State:Get()
	return self._value
end

function State:Set(value, force)
	if self._value == value and not force then return end
	local old = self._value
	self._value = value
	self.Changed:Fire(value, old)
end

-- Subscribe and immediately receive the current value. WHY: UI bindings almost
-- always want "render now, then re-render on change" — this removes the classic
-- forgotten-initial-render bug.
function State:Observe(fn)
	fn(self._value, self._value)
	return self.Changed:Connect(fn)
end

-- Bind a state directly to an instance property.
function State:Bind(inst, prop, transform)
	return self:Observe(function(value)
		inst[prop] = transform and transform(value) or value
	end)
end

function State.Computed(states, compute)
	local out = State.new(compute())
	local function recompute()
		out:Set(compute())
	end
	for _, s in ipairs(states) do
		s.Changed:Connect(recompute)
	end
	return out
end

--═══════════════════════════════════════════════════════════════════════════
-- § Motion ─ the animation engine
--═══════════════════════════════════════════════════════════════════════════
--[=[
	Motion wraps TweenService for property tweens and implements a genuine
	damped-spring integrator for physical motion (window opening, sidebar
	collapse, toggle knobs). Springs are interruptible by construction: setting
	a new target simply retargets the integrator and velocity is preserved,
	which is what makes drag-release and rapid toggling feel physical instead
	of restarting a canned tween.
]=]
local Motion = {}

Motion.Easing = {
	Standard  = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Emphasis  = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Soft      = TweenInfo.new(0.16, Enum.EasingStyle.Sine,  Enum.EasingDirection.Out),
	Enter     = TweenInfo.new(0.38, Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
	Exit      = TweenInfo.new(0.20, Enum.EasingStyle.Quad,  Enum.EasingDirection.In),
	Linear    = TweenInfo.new(0.15, Enum.EasingStyle.Linear),
}

-- Active tweens keyed per instance+property so a new tween cancels the old one
-- (interruption without visual snapping — TweenService already lerps from the
-- current value, we just make sure two tweens never fight).
local activeTweens = setmetatable({}, { __mode = "k" })

function Motion.Tween(inst, props, info)
	info = info or Motion.Easing.Standard
	local bucket = activeTweens[inst]
	if not bucket then
		bucket = {}
		activeTweens[inst] = bucket
	end
	for prop in pairs(props) do
		if bucket[prop] then bucket[prop]:Cancel() end
	end
	local tween = TweenService:Create(inst, info, props)
	for prop in pairs(props) do
		bucket[prop] = tween
	end
	tween:Play()
	return tween
end

-- ── Spring integrator ──────────────────────────────────────────────────────
local springTypes = {
	number = {
		unpack = function(v) return { v } end,
		pack   = function(c) return c[1] end,
	},
	UDim2 = {
		unpack = function(v) return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } end,
		pack   = function(c) return UDim2.new(c[1], c[2], c[3], c[4]) end,
	},
	Vector2 = {
		unpack = function(v) return { v.X, v.Y } end,
		pack   = function(c) return Vector2.new(c[1], c[2]) end,
	},
}

local activeSprings = {} -- [inst][prop] = springState
local springStepper = nil

local function stepSprings(dt)
	dt = math.min(dt, 1 / 20) -- clamp to keep the integrator stable through frame spikes
	local alive = false
	for inst, props in pairs(activeSprings) do
		if not inst.Parent then
			activeSprings[inst] = nil
			continue
		end
		for prop, s in pairs(props) do
			local done = true
			for i = 1, #s.pos do
				local delta = s.target[i] - s.pos[i]
				-- semi-implicit Euler on a damped harmonic oscillator
				local accel = delta * s.stiffness - s.vel[i] * s.damping
				s.vel[i] += accel * dt
				s.pos[i] += s.vel[i] * dt
				if math.abs(delta) > s.epsilon or math.abs(s.vel[i]) > s.epsilon then
					done = false
				end
			end
			if done then
				for i = 1, #s.pos do
					s.pos[i] = s.target[i]
					s.vel[i] = 0
				end
				props[prop] = nil
				if s.onComplete then task.spawn(s.onComplete) end
			end
			inst[prop] = s.codec.pack(s.pos)
			alive = true
		end
		if next(props) == nil then activeSprings[inst] = nil end
	end
	if not alive and springStepper then
		springStepper:Disconnect()
		springStepper = nil
	end
end

--[=[
	Motion.Spring(instance, "Position", targetUDim2, { Stiffness = 220, Damping = 24 })
	Retargeting a live spring keeps its velocity → naturally interruptible.
]=]
function Motion.Spring(inst, prop, target, opts)
	opts = opts or {}
	local codec = springTypes[typeof(target)]
	assert(codec, "Motion.Spring: unsupported type " .. typeof(target))

	local props = activeSprings[inst]
	if not props then
		props = {}
		activeSprings[inst] = props
	end
	local s = props[prop]
	if s then
		s.target = codec.unpack(target)
		s.onComplete = opts.OnComplete or s.onComplete
	else
		s = {
			codec = codec,
			pos = codec.unpack(inst[prop]),
			vel = {},
			target = codec.unpack(target),
			stiffness = opts.Stiffness or 220,
			damping = opts.Damping or 26,
			epsilon = opts.Epsilon or 0.05,
			onComplete = opts.OnComplete,
		}
		for i = 1, #s.pos do s.vel[i] = 0 end
		props[prop] = s
	end
	s.stiffness = opts.Stiffness or s.stiffness
	s.damping = opts.Damping or s.damping

	if not springStepper then
		springStepper = RunService.Heartbeat:Connect(function(dt)
			stepSprings(dt)
		end)
	end
end

function Motion.StopSprings(inst)
	activeSprings[inst] = nil
end

-- Timeline: declarative sequential/parallel animation choreography.
-- steps = { { Time = 0.2, Run = fn } | { Time = 0.2, Tween = {inst, props, info} } }
function Motion.Timeline(steps)
	local cancelled = false
	task.spawn(function()
		for _, step in ipairs(steps) do
			if cancelled then return end
			if step.Run then step.Run() end
			if step.Tween then Motion.Tween(unpack(step.Tween)) end
			if step.Time and step.Time > 0 then task.wait(step.Time) end
		end
	end)
	return { Cancel = function() cancelled = true end }
end

-- Stagger: run fn(item, index) across a list with a fixed inter-item delay.
function Motion.Stagger(items, delayEach, fn)
	task.spawn(function()
		for index, item in ipairs(items) do
			fn(item, index)
			task.wait(delayEach)
		end
	end)
end

-- Material-style ripple used for button press feedback.
function Motion.Ripple(container, inputPosition, color)
	local absPos = container.AbsolutePosition
	local size = math.max(container.AbsoluteSize.X, container.AbsoluteSize.Y) * 2.2
	local ripple = Util.Create("Frame", {
		BackgroundColor3 = color or Color3.new(1, 1, 1),
		BackgroundTransparency = 0.82,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(inputPosition.X - absPos.X, inputPosition.Y - absPos.Y),
		Size = UDim2.fromOffset(0, 0),
		ZIndex = container.ZIndex + 1,
		Parent = container,
	})
	Util.Round(ripple, 999)
	Motion.Tween(ripple, { Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 },
		TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out))
	task.delay(0.5, function() ripple:Destroy() end)
end

--═══════════════════════════════════════════════════════════════════════════
-- § Theme ─ design-token engine with animated runtime switching
--═══════════════════════════════════════════════════════════════════════════
--[=[
	Every visual property in the framework is bound to a SEMANTIC token
	("Surface", "TextMuted", "Accent") rather than a literal color. Switching
	themes re-resolves every binding and tweens it, so the whole interface
	cross-fades between palettes at runtime with no rebuild.
]=]
local Theme = {}
Theme.Registry = {} -- [name] = token table
Theme.Current = State.new("Dark")
Theme._bindings = setmetatable({}, { __mode = "k" }) -- [inst] = { {prop, token, alphaToken} }

Theme.Registry.Dark = {
	Backdrop      = Color3.fromRGB(16, 16, 20),
	Surface       = Color3.fromRGB(22, 22, 27),
	SurfaceHigh   = Color3.fromRGB(28, 28, 34),
	SurfaceHover  = Color3.fromRGB(36, 36, 44),
	Field         = Color3.fromRGB(14, 14, 18),
	Stroke        = Color3.fromRGB(255, 255, 255),
	StrokeAlpha   = 0.92,
	Text          = Color3.fromRGB(238, 238, 243),
	TextMuted     = Color3.fromRGB(148, 148, 160),
	TextFaint     = Color3.fromRGB(96, 96, 108),
	Accent        = Color3.fromRGB(255, 176, 46),   -- mango amber
	AccentSoft    = Color3.fromRGB(64, 50, 26),
	AccentText    = Color3.fromRGB(24, 18, 6),
	Success       = Color3.fromRGB(84, 200, 130),
	Warning       = Color3.fromRGB(240, 180, 70),
	Error         = Color3.fromRGB(238, 96, 96),
	Info          = Color3.fromRGB(96, 158, 238),
	ShadowAlpha   = 0.45,
}

Theme.Registry.Light = {
	Backdrop      = Color3.fromRGB(238, 238, 242),
	Surface       = Color3.fromRGB(250, 250, 252),
	SurfaceHigh   = Color3.fromRGB(242, 242, 246),
	SurfaceHover  = Color3.fromRGB(232, 232, 238),
	Field         = Color3.fromRGB(255, 255, 255),
	Stroke        = Color3.fromRGB(0, 0, 0),
	StrokeAlpha   = 0.90,
	Text          = Color3.fromRGB(28, 28, 34),
	TextMuted     = Color3.fromRGB(110, 110, 122),
	TextFaint     = Color3.fromRGB(164, 164, 176),
	Accent        = Color3.fromRGB(226, 140, 16),
	AccentSoft    = Color3.fromRGB(250, 232, 202),
	AccentText    = Color3.fromRGB(255, 252, 246),
	Success       = Color3.fromRGB(38, 158, 92),
	Warning       = Color3.fromRGB(200, 140, 30),
	Error         = Color3.fromRGB(206, 62, 62),
	Info          = Color3.fromRGB(52, 118, 202),
	ShadowAlpha   = 0.78,
}

Theme.Registry.Amoled = setmetatable({
	Backdrop     = Color3.fromRGB(0, 0, 0),
	Surface      = Color3.fromRGB(6, 6, 8),
	SurfaceHigh  = Color3.fromRGB(12, 12, 15),
	SurfaceHover = Color3.fromRGB(22, 22, 27),
	Field        = Color3.fromRGB(2, 2, 3),
	ShadowAlpha  = 0.2,
}, { __index = Theme.Registry.Dark })

function Theme.Get(token)
	local palette = Theme.Registry[Theme.Current:Get()] or Theme.Registry.Dark
	local value = palette[token]
	if value == nil then value = Theme.Registry.Dark[token] end
	return value
end

-- Bind instance.property → token; re-resolved (and tweened) on theme switch.
function Theme.Bind(inst, prop, token)
	local list = Theme._bindings[inst]
	if not list then
		list = {}
		Theme._bindings[inst] = list
	end
	table.insert(list, { prop, token })
	inst[prop] = Theme.Get(token)
end

function Theme.Paint(inst, bindings) -- convenience: { BackgroundColor3 = "Surface", ... }
	for prop, token in pairs(bindings) do
		Theme.Bind(inst, prop, token)
	end
	return inst
end

function Theme.SetTheme(name)
	if not Theme.Registry[name] then
		warn("[Nectar] unknown theme: " .. tostring(name))
		return
	end
	Theme.Current:Set(name)
	for inst, list in pairs(Theme._bindings) do
		if inst.Parent then
			local goal = {}
			for _, binding in ipairs(list) do
				goal[binding[1]] = Theme.Get(binding[2])
			end
			Motion.Tween(inst, goal, Motion.Easing.Emphasis)
		end
	end
end

function Theme.AddTheme(name, tokens, base)
	Theme.Registry[name] = setmetatable(tokens, { __index = Theme.Registry[base or "Dark"] })
end

function Theme.Export(name)
	local palette = Theme.Registry[name or Theme.Current:Get()]
	local out = {}
	for token, value in pairs(palette) do
		if typeof(value) == "Color3" then
			out[token] = { math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5) }
		else
			out[token] = value
		end
	end
	return HttpService:JSONEncode(out)
end

function Theme.Import(name, json)
	local decoded = HttpService:JSONDecode(json)
	local tokens = {}
	for token, value in pairs(decoded) do
		if type(value) == "table" and #value == 3 then
			tokens[token] = Color3.fromRGB(value[1], value[2], value[3])
		else
			tokens[token] = value
		end
	end
	Theme.AddTheme(name, tokens)
end

--═══════════════════════════════════════════════════════════════════════════
-- § Icons ─ glyph registry with pluggable packs
--═══════════════════════════════════════════════════════════════════════════
--[=[
	WHY glyphs by default: shipping hundreds of hardcoded rbxassetid values is
	fragile (moderation, ownership). Nectar ships a curated unicode glyph set
	that renders everywhere, and exposes Icons.RegisterPack so studios can map
	the same names to their own uploaded Lucide/Material/Fluent image assets —
	components automatically prefer image assets when a pack provides them.
]=]
local Icons = {}
Icons._packs = {} -- [name] = assetId (registered image packs override the vector icons)
Icons._parts = setmetatable({}, { __mode = "k" }) -- holder -> { {inst, isStroke}, … }

function Icons.RegisterPack(map) -- { home = "rbxassetid://...", ... }
	for name, assetId in pairs(map) do
		Icons._packs[name] = assetId
	end
end

--[=[
	WHY vector icons: unicode glyphs render as "tofu" boxes in Roblox's UI fonts
	and hardcoded rbxassetid values are fragile (moderation, ownership). Every
	built-in icon is instead drawn from a few themed <Frame> primitives in the
	holder's 0..1 scale space, so it renders identically on every executor with
	no assets and no glyph dependency. Icons.RegisterPack still overrides any
	name with a real image for studios who prefer Lucide/Material/Fluent.
]=]
local function _reg(holder, inst, isStroke)
	local list = Icons._parts[holder]
	if not list then list = {} Icons._parts[holder] = list end
	table.insert(list, { inst = inst, stroke = isStroke })
end
local function bar(holder, x, y, len, thick, rot, token) -- rounded pill line
	local f = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(len, thick), Rotation = rot or 0, Parent = holder,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	Theme.Bind(f, "BackgroundColor3", token); _reg(holder, f, false)
	return f
end
local function dotf(holder, x, y, d, token) -- filled circle
	local f = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(d, d), Parent = holder,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	Theme.Bind(f, "BackgroundColor3", token); _reg(holder, f, false)
	return f
end
local function ring(holder, x, y, d, thick, token) -- circle outline
	local f = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(d, d), BackgroundTransparency = 1, Parent = holder,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	local s = Util.Create("UIStroke", { Thickness = thick or 1.5, Parent = f })
	Theme.Bind(s, "Color", token); _reg(holder, s, true)
	return f
end
local function box(holder, x, y, w, h, token, corner, filled) -- square/rect, outline or filled
	local f = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y),
		Size = UDim2.fromScale(w, h), BackgroundTransparency = filled and 0 or 1, Parent = holder,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(0, corner or 2), Parent = f })
	if filled then
		Theme.Bind(f, "BackgroundColor3", token); _reg(holder, f, false)
	else
		local s = Util.Create("UIStroke", { Thickness = 1.5, Parent = f })
		Theme.Bind(s, "Color", token); _reg(holder, s, true)
	end
	return f
end

local VEC = {}
function VEC.close(h, t)      bar(h, 0.5, 0.5, 0.66, 0.13, 45, t)  bar(h, 0.5, 0.5, 0.66, 0.13, -45, t) end
function VEC.check(h, t)      bar(h, 0.38, 0.62, 0.30, 0.13, 45, t) bar(h, 0.60, 0.46, 0.60, 0.13, -45, t) end
function VEC.chevron_down(h, t) bar(h, 0.33, 0.43, 0.44, 0.12, 45, t) bar(h, 0.67, 0.43, 0.44, 0.12, -45, t) end
function VEC.plus(h, t)       bar(h, 0.5, 0.5, 0.62, 0.13, 0, t)  bar(h, 0.5, 0.5, 0.62, 0.13, 90, t) end
function VEC.minus(h, t)      bar(h, 0.5, 0.5, 0.62, 0.13, 0, t) end
function VEC.search(h, t)     ring(h, 0.42, 0.42, 0.56, 1.6, t)   bar(h, 0.72, 0.72, 0.32, 0.12, 45, t) end
function VEC.sliders(h, t)
	bar(h, 0.5, 0.3, 0.72, 0.1, 0, t) dotf(h, 0.68, 0.3, 0.2, t)
	bar(h, 0.5, 0.5, 0.72, 0.1, 0, t) dotf(h, 0.36, 0.5, 0.2, t)
	bar(h, 0.5, 0.7, 0.72, 0.1, 0, t) dotf(h, 0.6, 0.7, 0.2, t)
end
function VEC.settings(h, t)   ring(h, 0.5, 0.5, 0.52, 1.6, t) dotf(h, 0.5, 0.5, 0.18, t)
	for i = 0, 5 do local a = math.rad(i * 60) dotf(h, 0.5 + math.cos(a) * 0.4, 0.5 + math.sin(a) * 0.4, 0.12, t) end
end
function VEC.home(h, t)
	bar(h, 0.34, 0.34, 0.46, 0.12, -37, t) bar(h, 0.66, 0.34, 0.46, 0.12, 37, t)
	box(h, 0.5, 0.66, 0.46, 0.42, t, 2, false)
end
function VEC.grid(h, t)
	box(h, 0.32, 0.32, 0.3, 0.3, t, 2, true) box(h, 0.68, 0.32, 0.3, 0.3, t, 2, true)
	box(h, 0.32, 0.68, 0.3, 0.3, t, 2, true) box(h, 0.68, 0.68, 0.3, 0.3, t, 2, true)
end
function VEC.terminal(h, t)
	box(h, 0.5, 0.5, 0.84, 0.7, t, 3, false)
	bar(h, 0.36, 0.46, 0.2, 0.09, 45, t) bar(h, 0.36, 0.56, 0.2, 0.09, -45, t)
	bar(h, 0.62, 0.66, 0.22, 0.09, 0, t)
end
function VEC.bolt(h, t)       bar(h, 0.46, 0.36, 0.42, 0.15, 62, t) bar(h, 0.54, 0.64, 0.42, 0.15, 62, t) end
function VEC.user(h, t)       dotf(h, 0.5, 0.33, 0.34, t) box(h, 0.5, 0.8, 0.62, 0.4, t, 12, true) end
function VEC.info(h, t)       ring(h, 0.5, 0.5, 0.84, 1.6, t) dotf(h, 0.5, 0.31, 0.12, t) bar(h, 0.5, 0.58, 0.28, 0.12, 90, t) end
function VEC.warning(h, t)    bar(h, 0.5, 0.44, 0.38, 0.13, 90, t) dotf(h, 0.5, 0.72, 0.14, t) end
function VEC.error(h, t)      ring(h, 0.5, 0.5, 0.84, 1.6, t) bar(h, 0.5, 0.5, 0.42, 0.12, 45, t) bar(h, 0.5, 0.5, 0.42, 0.12, -45, t) end
function VEC.success(h, t)    VEC.check(h, t) end
function VEC.list(h, t)       bar(h, 0.52, 0.3, 0.68, 0.1, 0, t) bar(h, 0.52, 0.5, 0.68, 0.1, 0, t) bar(h, 0.52, 0.7, 0.68, 0.1, 0, t) dotf(h, 0.16, 0.3, 0.1, t) dotf(h, 0.16, 0.5, 0.1, t) dotf(h, 0.16, 0.7, 0.1, t) end
function VEC.folder(h, t)     box(h, 0.36, 0.32, 0.34, 0.14, t, 2, true) box(h, 0.5, 0.6, 0.74, 0.44, t, 3, true) end
function VEC.clock(h, t)      ring(h, 0.5, 0.5, 0.84, 1.6, t) bar(h, 0.5, 0.42, 0.22, 0.09, 90, t) bar(h, 0.56, 0.5, 0.2, 0.09, 0, t) end
function VEC.eye(h, t)        ring(h, 0.5, 0.5, 0.34, 1.5, t) dotf(h, 0.5, 0.5, 0.16, t) end
function VEC.dot(h, t)        dotf(h, 0.5, 0.5, 0.34, t) end

function Icons.Resolve(name) -- image resolution only; vectors are handled in Make
	if not name then return nil end
	if string.find(name, "rbxassetid://", 1, true) then return { Image = name } end
	if Icons._packs[name] then return { Image = Icons._packs[name] } end
	return nil
end

-- Instant colour override for an icon returned by Make (text / image / vector).
function Icons.Tint(icon, color)
	if not icon then return end
	if icon:IsA("TextLabel") then icon.TextColor3 = color return end
	if icon:IsA("ImageLabel") then icon.ImageColor3 = color return end
	local parts = Icons._parts[icon]
	if parts then
		for _, p in ipairs(parts) do
			if p.stroke then p.inst.Color = color else p.inst.BackgroundColor3 = color end
		end
	end
end

-- Renders an icon (image pack or built-in vector) into a size×size holder.
function Icons.Make(name, size, colorToken, parent)
	if not name then return nil end
	local token = colorToken or "TextMuted"
	local resolved = Icons.Resolve(name)
	if resolved then
		local img = Util.Create("ImageLabel", {
			BackgroundTransparency = 1, Image = resolved.Image,
			Size = UDim2.fromOffset(size, size), Parent = parent,
		})
		Theme.Bind(img, "ImageColor3", token)
		return img
	end
	local holder = Util.Create("Frame", {
		BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size), Parent = parent,
	})
	local base, rot = name, 0
	if name == "chevron_up" then base, rot = "chevron_down", 180
	elseif name == "chevron_left" then base, rot = "chevron_down", 90
	elseif name == "chevron_right" then base, rot = "chevron_down", -90
	end
	local builder = VEC[base]
	if builder then builder(holder, token) else dotf(holder, 0.5, 0.5, 0.32, token) end
	holder.Rotation = rot
	return holder
end

--═══════════════════════════════════════════════════════════════════════════
-- § Root ─ ScreenGui host, tooltip layer, notification layer
--═══════════════════════════════════════════════════════════════════════════
local Root = {}

local function safeParent(gui)
	-- Prefer the hidden UI container when available (executor contexts), fall
	-- back to CoreGui, then PlayerGui — in that order of resilience.
	local ok = pcall(function()
		local hidden = (gethui and gethui()) or nil
		if hidden then gui.Parent = hidden return end
		gui.Parent = game:GetService("CoreGui")
	end)
	if not ok or not gui.Parent then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
end

function Root.Get()
	if Root.Gui and Root.Gui.Parent then return Root.Gui end
	local gui = Util.Create("ScreenGui", {
		Name = "Nectar", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999,
	})
	safeParent(gui)
	Root.Gui = gui

	Root.WindowLayer  = Util.Create("Frame", { Name = "Windows",  BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
	Root.OverlayLayer = Util.Create("Frame", { Name = "Overlays", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = gui })
	Root.ToastLayer   = Util.Create("Frame", { Name = "Toasts",   BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 100, Parent = gui })
	return gui
end

--─────────────────────────────────────────────
-- Tooltip: one shared floating label, repositioned on hover. WHY shared: a
-- 40-control window would otherwise allocate 40 idle tooltip frames.
--─────────────────────────────────────────────
local Tooltip = {}

function Tooltip._ensure()
	if Tooltip.Frame and Tooltip.Frame.Parent then return end
	Root.Get()
	local frame = Util.Create("Frame", {
		Name = "Tooltip", AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1, Visible = false, ZIndex = 200,
		Parent = Root.ToastLayer,
	})
	Theme.Paint(frame, { BackgroundColor3 = "SurfaceHigh" })
	Util.Round(frame, 6)
	local stroke = Util.Stroke(frame, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")
	Util.Padding(frame, 6, 6, 9, 9)
	local label = Util.Create("TextLabel", {
		Name = "Label", AutomaticSize = Enum.AutomaticSize.XY, TextSize = 12,
		TextWrapped = true, Parent = frame,
	})
	Util.Create("UISizeConstraint", { MaxSize = Vector2.new(260, math.huge), Parent = label })
	Theme.Bind(label, "TextColor3", "Text")
	Tooltip.Frame, Tooltip.Label = frame, label
end

function Tooltip.Attach(element, textProvider, maid)
	local moveConn
	local function show()
		Tooltip._ensure()
		local text = type(textProvider) == "function" and textProvider() or textProvider
		if not text or text == "" then return end
		Tooltip.Label.Text = text
		Tooltip.Frame.Visible = true
		Tooltip.Frame.BackgroundTransparency = 1
		Tooltip.Label.TextTransparency = 1
		Motion.Tween(Tooltip.Frame, { BackgroundTransparency = 0.04 }, Motion.Easing.Soft)
		Motion.Tween(Tooltip.Label, { TextTransparency = 0 }, Motion.Easing.Soft)
		moveConn = RunService.Heartbeat:Connect(function()
			local pos = UserInputService:GetMouseLocation()
			local screen = Root.Gui.AbsoluteSize
			local size = Tooltip.Frame.AbsoluteSize
			local x = math.clamp(pos.X + 14, 4, screen.X - size.X - 4)
			local y = math.clamp(pos.Y + 18, 4, screen.Y - size.Y - 4)
			Tooltip.Frame.Position = UDim2.fromOffset(x, y)
		end)
	end
	local function hide()
		if moveConn then moveConn:Disconnect() moveConn = nil end
		if Tooltip.Frame then Tooltip.Frame.Visible = false end
	end
	maid:Add(element.MouseEnter:Connect(show))
	maid:Add(element.MouseLeave:Connect(hide))
	maid:Add(hide)
end

--─────────────────────────────────────────────
-- Notifications: stacked toasts, bottom-right, typed accents, progress rail.
--─────────────────────────────────────────────
local Notify = {}

function Notify._stack()
	if Notify.List and Notify.List.Parent then return Notify.List end
	Root.Get()
	local holder = Util.Create("Frame", {
		Name = "NotifyStack", AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18), Size = UDim2.fromOffset(304, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		Parent = Root.ToastLayer,
	})
	Util.Create("UIListLayout", {
		Padding = UDim.new(0, 8), FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder,
	})
	Notify.List = holder
	return holder
end

local NOTIFY_TOKEN = { Success = "Success", Warning = "Warning", Error = "Error", Info = "Info" }

--[=[
	Nectar:Notify({ Title, Content, Type = "Info"|"Success"|"Warning"|"Error",
	                Duration = 4, Icon = "bolt" })
	Returns { Dismiss = fn, SetProgress = fn(alpha) } — SetProgress converts the
	toast into a live progress notification.
]=]
function Notify.Push(opts)
	opts = opts or {}
	local stack = Notify._stack()
	local token = NOTIFY_TOKEN[opts.Type or "Info"] or "Info"
	local maid = Maid.new()

	local card = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.02,
		LayoutOrder = -math.floor(os.clock() * 1000), Parent = stack,
	})
	Theme.Paint(card, { BackgroundColor3 = "SurfaceHigh" })
	Util.Round(card, 10)
	local stroke = Util.Stroke(card, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")
	-- NOTE: no drop shadow here on purpose — a shadow overflows the card and,
	-- combined with AutomaticSize.Y, inflates the measured height (phantom gap
	-- under the progress rail). The stroke provides enough separation.

	-- accent: inset + rounded so its ends stay inside the card's rounded corners
	local accent = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 7, 0.5, 0),
		Size = UDim2.new(0, 3, 1, -16), Parent = card,
	})
	Util.Round(accent, 2)
	Theme.Bind(accent, "BackgroundColor3", token)

	local body = Util.Create("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Parent = card,
	})
	Util.Padding(body, 11, 15, 18, 12) -- extra bottom room for the progress rail

	local hasIcon = opts.Icon ~= nil
	if hasIcon then
		local icon = Icons.Make(opts.Icon, 15, token, body)
		icon.Position = UDim2.fromOffset(0, 1)
	end

	local title = Util.Create("TextLabel", {
		Text = opts.Title or "Notification", TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Size = UDim2.new(1, hasIcon and -24 or 0, 0, 16),
		Position = UDim2.fromOffset(hasIcon and 24 or 0, 0), Parent = body,
	})
	Theme.Bind(title, "TextColor3", "Text")

	if opts.Content then
		Util.Create("TextLabel", {
			Text = opts.Content, TextWrapped = true, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, hasIcon and -24 or 0, 0, 0),
			Position = UDim2.fromOffset(hasIcon and 24 or 0, 19),
			TextColor3 = Theme.Get("TextMuted"), Parent = body,
		})
	end

	local railTrack = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.new(1, -20, 0, 3), BackgroundTransparency = 1, Parent = card,
	})
	local rail = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.25, Parent = railTrack,
	})
	Util.Round(rail, 2)
	Theme.Bind(rail, "BackgroundColor3", token)

	-- entrance: slide up + settle
	card.Position = UDim2.fromOffset(30, 0)
	card.BackgroundTransparency = 1
	Motion.Tween(card, { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.02 }, Motion.Easing.Enter)

	local alive = true
	local function dismiss()
		if not alive then return end
		alive = false
		Motion.Tween(card, { Position = UDim2.fromOffset(320, 0), BackgroundTransparency = 1 }, Motion.Easing.Exit)
		task.delay(0.24, function()
			maid:Clean()
			card:Destroy()
		end)
	end

	local handle = { Dismiss = dismiss }
	function handle.SetProgress(alpha)
		Motion.Tween(rail, { Size = UDim2.fromScale(math.clamp(alpha, 0, 1), 1) }, Motion.Easing.Soft)
	end

	if opts.Duration == 0 then
		rail.Size = UDim2.fromScale(0, 1) -- progress mode: fills as SetProgress is called
	else
		local duration = opts.Duration or 4
		Motion.Tween(rail, { Size = UDim2.fromScale(0, 1) }, TweenInfo.new(duration, Enum.EasingStyle.Linear))
		task.delay(duration, dismiss)
	end

	maid:Add(card.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dismiss() end
	end))
	return handle
end

--═══════════════════════════════════════════════════════════════════════════
-- § Components ─ shared scaffolding
--═══════════════════════════════════════════════════════════════════════════
local Components = {}

-- ADDED (Mango): per-row live description setters, keyed weakly by the row
-- instance so handles can update their description/readout line after creation
-- without every control having to thread the label reference through by hand.
Components._rowDesc = setmetatable({}, { __mode = "k" })

-- Standard interactive hover/press treatment. WHY centralized: all 20+
-- controls share identical affordances so the interface feels like one hand
-- designed it — and a tuning change lands everywhere at once.
function Components.Hoverable(frame, maid, opts)
	opts = opts or {}
	local baseToken = opts.Base or "SurfaceHigh"
	local hoverToken = opts.Hover or "SurfaceHover"
	Theme.Bind(frame, "BackgroundColor3", baseToken)
	maid:Add(frame.MouseEnter:Connect(function()
		if opts.Enabled and not opts.Enabled() then return end
		Motion.Tween(frame, { BackgroundColor3 = Theme.Get(hoverToken) }, Motion.Easing.Soft)
	end))
	maid:Add(frame.MouseLeave:Connect(function()
		Motion.Tween(frame, { BackgroundColor3 = Theme.Get(baseToken) }, Motion.Easing.Soft)
	end))
end

-- Base row: rounded card w/ name + optional description, returns pieces the
-- specific control decorates. Every Section control builds on this scaffold.
function Components.Row(parent, opts, controlWidth)
	local maid = Maid.new()
	local row = Util.Create("TextButton", {
		Size = UDim2.new(1, 0, 0, opts.Description and 52 or 38),
		BackgroundTransparency = 0, Text = "", Parent = parent,
	})
	Components.Hoverable(row, maid)
	Util.Round(row, 8)
	local stroke = Util.Stroke(row, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")

	local hasDesc = opts.Description ~= nil and opts.Description ~= ""
	local title = Util.Create("TextLabel", {
		Text = opts.Name or "Element", TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.new(0, 12, 0, hasDesc and 9 or 0),
		Size = UDim2.new(1, -(controlWidth or 0) - 24, 0, hasDesc and 16 or 38),
		Parent = row,
	})
	Theme.Bind(title, "TextColor3", "Text")

	-- ADDED (Mango): the description line is now lazily created and live-
	-- editable. Passing opts.Description still works exactly as before, but a
	-- control created WITHOUT one can grow a description later — this is what
	-- lets handle:SetDescription() drive a live data readout under any control
	-- (e.g. an A-Chassis tune input showing its current in-game value).
	local descLabel
	local function setDescription(text)
		if text == nil or text == "" then
			if descLabel then descLabel.Visible = false end
			row.Size = UDim2.new(1, 0, 0, 38)
			title.Position = UDim2.new(0, 12, 0, 0)
			title.Size = UDim2.new(1, -(controlWidth or 0) - 24, 0, 38)
			return
		end
		if not descLabel then
			descLabel = Util.Create("TextLabel", {
				Text = "", TextSize = 11.5, TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.new(0, 12, 0, 27), TextWrapped = true, RichText = true,
				Size = UDim2.new(1, -(controlWidth or 0) - 24, 0, 15), Parent = row,
			})
			Theme.Bind(descLabel, "TextColor3", "TextMuted")
		end
		row.Size = UDim2.new(1, 0, 0, 52)
		title.Position = UDim2.new(0, 12, 0, 9)
		title.Size = UDim2.new(1, -(controlWidth or 0) - 24, 0, 16)
		descLabel.Visible = true
		descLabel.Text = text
	end
	if hasDesc then setDescription(opts.Description) end
	Components._rowDesc[row] = setDescription

	if opts.Tooltip then
		Tooltip.Attach(row, opts.Tooltip, maid)
	end
	return row, title, maid
end

-- Element handle shared by all controls: Visible/Destroy/SetName + per-type extensions.
function Components.Handle(row, title, maid)
	local handle = {}
	function handle:SetName(text) title.Text = text end
	function handle:SetTitle(text) title.Text = text end -- ADDED (Mango): readable alias for SetName
	function handle:SetVisible(visible) row.Visible = visible end
	-- ADDED (Mango): update (or add / clear) the row's description line at
	-- runtime. Returns the handle so calls can chain. Safe on every Row-based
	-- control (Button, Toggle, Slider, Textbox, NumberInput, Dropdown, Keybind…).
	function handle:SetDescription(text)
		local setter = Components._rowDesc[row]
		if setter then setter(text) end
		return self
	end
	function handle:Destroy()
		maid:Clean()
		Motion.StopSprings(row)
		row:Destroy()
	end
	handle.Instance = row
	return handle
end

--═══════════════════════════════════════════════════════════════════════════
-- § Controls ─ the component library
--═══════════════════════════════════════════════════════════════════════════
local Flags = {}      -- [flag] = element handle (for config save/load + Nectar.Flags access)
local Config          -- forward declaration: the ConfigManager control (defined in Controls) references it; the module itself is assigned lower down
local Controls = {}

local function registerFlag(opts, handle)
	if opts.Flag then Flags[opts.Flag] = handle end
end

--─────────────────────────────────────────────  Button
function Controls.Button(parent, opts)
	local row, title, maid = Components.Row(parent, opts, 0)
	title.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)
	local chev = Icons.Make("chevron_right", 13, "TextFaint", row)
	chev.AnchorPoint = Vector2.new(1, 0.5)
	chev.Position = UDim2.new(1, -12, 0.5, 0)

	local enabled = true
	maid:Add(row.MouseButton1Down:Connect(function()
		if not enabled then return end
		Motion.Ripple(row, UserInputService:GetMouseLocation(), Theme.Get("Accent"))
		Motion.Spring(row, "Size", UDim2.new(1, -4, 0, row.AbsoluteSize.Y), { Stiffness = 500, Damping = 30 })
	end))
	maid:Add(row.MouseButton1Up:Connect(function()
		Motion.Spring(row, "Size", UDim2.new(1, 0, 0, row.AbsoluteSize.Y), { Stiffness = 300, Damping = 22 })
	end))
	maid:Add(row.MouseButton1Click:Connect(function()
		if not enabled then return end
		if opts.Callback then task.spawn(opts.Callback) end
	end))

	local handle = Components.Handle(row, title, maid)
	function handle:SetEnabled(state)
		enabled = state
		Motion.Tween(title, { TextTransparency = state and 0 or 0.6 }, Motion.Easing.Soft)
	end
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Toggle
function Controls.Toggle(parent, opts)
	local row, title, maid = Components.Row(parent, opts, 46)
	local value = opts.Default == true
	local enabled = true

	local track = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(38, 20), Parent = row,
	})
	Util.Round(track, 10)
	local knob = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16), BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = track,
	})
	Util.Round(knob, 9)

	local function render(animate)
		local trackColor = value and Theme.Get("Accent") or Theme.Get("SurfaceHover")
		local knobPos = value and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
		if animate then
			Motion.Tween(track, { BackgroundColor3 = trackColor }, Motion.Easing.Soft)
			knob.AnchorPoint = value and Vector2.new(0, 0.5) or Vector2.new(0, 0.5)
			Motion.Spring(knob, "Position", knobPos, { Stiffness = 420, Damping = 28 })
		else
			track.BackgroundColor3 = trackColor
			knob.Position = knobPos
		end
	end
	render(false)

	local handle = Components.Handle(row, title, maid)
	function handle:Set(newValue, silent)
		newValue = newValue == true
		if newValue == value then return end
		value = newValue
		render(true)
		if not silent and opts.Callback then task.spawn(opts.Callback, value) end
	end
	function handle:Get() return value end
	function handle:SetEnabled(state)
		enabled = state
		Motion.Tween(row, { BackgroundTransparency = state and 0 or 0.4 }, Motion.Easing.Soft)
	end
	maid:Add(row.MouseButton1Click:Connect(function()
		if enabled then handle:Set(not value) end
	end))
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Slider (+ shared track logic for RangeSlider)
local function makeTrack(row, maid)
	local track = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(148, 5), Parent = row,
	})
	Theme.Bind(track, "BackgroundColor3", "SurfaceHover")
	Util.Round(track, 3)
	return track
end

function Controls.Slider(parent, opts)
	local min, max = opts.Min or 0, opts.Max or 100
	local step = opts.Step or 1
	local suffix = opts.Suffix or ""
	local value = math.clamp(opts.Default or min, min, max)

	local row, title, maid = Components.Row(parent, opts, 214)
	local track = makeTrack(row, maid)
	local fill = Util.Create("Frame", { Size = UDim2.fromScale(0, 1), Parent = track })
	Theme.Bind(fill, "BackgroundColor3", "Accent")
	Util.Round(fill, 3)
	local knob = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(13, 13),
		BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 2, Parent = track,
	})
	Util.Round(knob, 7)
	local readout = Util.Create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -172, 0.5, 0),
		Size = UDim2.fromOffset(52, 16), TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 12, Parent = row,
	})
	Theme.Bind(readout, "TextColor3", "TextMuted")

	local function quantize(v)
		return math.clamp(math.floor((v - min) / step + 0.5) * step + min, min, max)
	end
	local function alpha() return (max == min) and 0 or (value - min) / (max - min) end
	local function render(animate)
		local a = alpha()
		local goalFill = UDim2.fromScale(a, 1)
		local goalKnob = UDim2.fromScale(a, 0.5)
		readout.Text = (step % 1 == 0 and tostring(value) or string.format("%.2f", value)) .. suffix
		if animate then
			Motion.Spring(fill, "Size", goalFill, { Stiffness = 380, Damping = 30 })
			Motion.Spring(knob, "Position", goalKnob, { Stiffness = 380, Damping = 30 })
		else
			fill.Size, knob.Position = goalFill, goalKnob
		end
	end
	render(false)

	local handle = Components.Handle(row, title, maid)
	function handle:Set(v, silent)
		local q = quantize(v)
		if q == value then return end
		value = q
		render(true)
		if not silent and opts.Callback then task.spawn(opts.Callback, value) end
	end
	function handle:Get() return value end

	local dragging = false
	local function applyFromX(x)
		local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		handle:Set(min + rel * (max - min))
	end
	maid:Add(row.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Motion.Spring(knob, "Size", UDim2.fromOffset(16, 16), { Stiffness = 500, Damping = 26 })
			applyFromX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			applyFromX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				Motion.Spring(knob, "Size", UDim2.fromOffset(13, 13), { Stiffness = 400, Damping = 26 })
			end
		end
	end))
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  RangeSlider (two thumbs)
function Controls.RangeSlider(parent, opts)
	local min, max = opts.Min or 0, opts.Max or 100
	local step = opts.Step or 1
	local lo = math.clamp(opts.DefaultMin or min, min, max)
	local hi = math.clamp(opts.DefaultMax or max, lo, max)

	local row, title, maid = Components.Row(parent, opts, 224)
	local track = makeTrack(row, maid)
	local fill = Util.Create("Frame", { Parent = track })
	Theme.Bind(fill, "BackgroundColor3", "Accent")
	Util.Round(fill, 3)
	local knobA = Util.Create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 2, Parent = track })
	local knobB = knobA:Clone() knobB.Parent = track
	Util.Round(knobA, 6) Util.Round(knobB, 6)
	local readout = Util.Create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -172, 0.5, 0),
		Size = UDim2.fromOffset(64, 16), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 12, Parent = row,
	})
	Theme.Bind(readout, "TextColor3", "TextMuted")

	local function quantize(v) return math.clamp(math.floor((v - min) / step + 0.5) * step + min, min, max) end
	local function render()
		local aLo, aHi = (lo - min) / (max - min), (hi - min) / (max - min)
		fill.Position = UDim2.fromScale(aLo, 0)
		fill.Size = UDim2.fromScale(aHi - aLo, 1)
		knobA.Position = UDim2.fromScale(aLo, 0.5)
		knobB.Position = UDim2.fromScale(aHi, 0.5)
		readout.Text = tostring(lo) .. " – " .. tostring(hi)
	end
	render()

	local handle = Components.Handle(row, title, maid)
	function handle:Set(newLo, newHi, silent)
		lo = quantize(math.min(newLo, newHi))
		hi = quantize(math.max(newLo, newHi))
		render()
		if not silent and opts.Callback then task.spawn(opts.Callback, lo, hi) end
	end
	function handle:Get() return lo, hi end

	local dragging = nil -- "lo" | "hi"
	local function applyFromX(x)
		local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		local v = quantize(min + rel * (max - min))
		if dragging == "lo" then
			handle:Set(math.min(v, hi), hi)
		else
			handle:Set(lo, math.max(v, lo))
		end
	end
	maid:Add(row.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local rel = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			local v = min + rel * (max - min)
			dragging = (math.abs(v - lo) <= math.abs(v - hi)) and "lo" or "hi"
			applyFromX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			applyFromX(input.Position.X)
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = nil
		end
	end))
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Textbox
function Controls.Textbox(parent, opts)
	local row, title, maid = Components.Row(parent, opts, 158)
	local holder = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(146, 26), Parent = row,
	})
	Theme.Paint(holder, { BackgroundColor3 = "Field" })
	Util.Round(holder, 6)
	local stroke = Util.Stroke(holder, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")

	local box = Util.Create("TextBox", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0), Text = opts.Default or "",
		PlaceholderText = opts.Placeholder or "…", ClearTextOnFocus = opts.ClearOnFocus == true,
		TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12,
		ClipsDescendants = true, Parent = holder,
	})
	Theme.Bind(box, "TextColor3", "Text")
	Theme.Bind(box, "PlaceholderColor3", "TextFaint")

	maid:Add(box.Focused:Connect(function()
		Motion.Tween(stroke, { Color = Theme.Get("Accent"), Transparency = 0.2 }, Motion.Easing.Soft)
	end))
	maid:Add(box.FocusLost:Connect(function(enterPressed)
		Motion.Tween(stroke, { Color = Theme.Get("Stroke"), Transparency = Theme.Get("StrokeAlpha") }, Motion.Easing.Soft)
		if opts.Callback and (enterPressed or opts.CallbackOnBlur ~= false) then
			task.spawn(opts.Callback, box.Text)
		end
		-- optional: wipe the field after a committed entry so it's ready for the next
		if opts.ClearOnEnter and enterPressed then box.Text = "" end
	end))

	local handle = Components.Handle(row, title, maid)
	function handle:Set(text, silent)
		box.Text = text
		if not silent and opts.Callback then task.spawn(opts.Callback, text) end
	end
	function handle:Get() return box.Text end
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  NumberInput (stepper)
function Controls.NumberInput(parent, opts)
	local min, max = opts.Min or -math.huge, opts.Max or math.huge
	local step = opts.Step or 1
	local value = math.clamp(opts.Default or 0, min, max)

	local row, title, maid = Components.Row(parent, opts, 132)
	local holder = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(120, 26), Parent = row,
	})
	Theme.Paint(holder, { BackgroundColor3 = "Field" })
	Util.Round(holder, 6)
	local stroke = Util.Stroke(holder, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")

	local box = Util.Create("TextBox", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -52, 1, 0), Position = UDim2.fromOffset(26, 0),
		Text = tostring(value), TextSize = 12, ClipsDescendants = true, Parent = holder,
	})
	Theme.Bind(box, "TextColor3", "Text")

	local handle -- fwd decl
	local function makeStepButton(iconName, xPos, delta)
		local btn = Util.Create("TextButton", {
			Text = "", Size = UDim2.fromOffset(24, 26),
			Position = UDim2.fromOffset(xPos, 0), BackgroundTransparency = 1, Parent = holder,
		})
		local ic = Icons.Make(iconName, 11, "TextMuted", btn)
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		maid:Add(btn.MouseButton1Click:Connect(function()
			handle:Set(value + delta)
		end))
		return btn
	end

	local function render()
		box.Text = (step % 1 == 0) and tostring(value) or string.format("%.2f", value)
	end

	handle = Components.Handle(row, title, maid)
	function handle:Set(v, silent)
		v = tonumber(v)
		if not v then render() return end
		v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
		if v ~= value then
			value = v
			if not silent and opts.Callback then task.spawn(opts.Callback, value) end
		end
		render()
	end
	function handle:Get() return value end

	makeStepButton("minus", 0, -step)
	makeStepButton("plus", 96, step)
	maid:Add(box.FocusLost:Connect(function() handle:Set(box.Text) end))
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Dropdown (single + multi)
function Controls.Dropdown(parent, opts)
	local values = opts.Values or {}
	local multi = opts.Multi == true
	local selected = {} -- set for multi, single string otherwise
	if multi then
		for _, v in ipairs(opts.Default or {}) do selected[v] = true end
	else
		selected = opts.Default or values[1]
	end

	local row, title, maid = Components.Row(parent, opts, 158)
	local face = Util.Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(146, 26), Text = "", Parent = row,
	})
	Theme.Paint(face, { BackgroundColor3 = "Field" })
	Util.Round(face, 6)
	local faceStroke = Util.Stroke(face, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(faceStroke, "Color", "Stroke")
	local faceLabel = Util.Create("TextLabel", {
		Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(9, 0),
		TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = face,
	})
	Theme.Bind(faceLabel, "TextColor3", "Text")
	local chev = Icons.Make("chevron_down", 12, "TextMuted", face)
	chev.AnchorPoint = Vector2.new(1, 0.5)
	chev.Position = UDim2.new(1, -8, 0.5, 0)

	local function summary()
		if multi then
			local names = {}
			for _, v in ipairs(values) do
				if selected[v] then table.insert(names, v) end
			end
			return #names == 0 and "None" or table.concat(names, ", ")
		end
		return selected and tostring(selected) or "None"
	end

	local open = false
	local menu, menuMaid

	local function closeMenu()
		if not open then return end
		open = false
		Motion.Tween(chev, chev:IsA("TextLabel") and { Rotation = 0 } or { Rotation = 0 }, Motion.Easing.Soft)
		if menu then
			local dying = menu
			menu = nil
			Motion.Tween(dying, { Size = UDim2.fromOffset(dying.AbsoluteSize.X, 0), BackgroundTransparency = 1 }, Motion.Easing.Exit)
			task.delay(0.22, function()
				if menuMaid then menuMaid:Clean() menuMaid = nil end
				dying:Destroy()
			end)
		end
	end

	local handle = Components.Handle(row, title, maid)

	local function openMenu()
		if open then closeMenu() return end
		open = true
		menuMaid = Maid.new()
		Motion.Tween(chev, { Rotation = 180 }, Motion.Easing.Soft)

		local itemH, pad = 26, 6
		local visible = math.min(#values, 7)
		local fullH = visible * (itemH + 2) + pad * 2 + (opts.Searchable and 32 or 0)

		menu = Util.Create("Frame", {
			Position = UDim2.fromOffset(face.AbsolutePosition.X, face.AbsolutePosition.Y + face.AbsoluteSize.Y + 6),
			Size = UDim2.fromOffset(math.max(face.AbsoluteSize.X, 180), 0),
			ClipsDescendants = true, ZIndex = 60, Parent = Root.OverlayLayer,
		})
		Theme.Paint(menu, { BackgroundColor3 = "SurfaceHigh" })
		Util.Round(menu, 8)
		local ms = Util.Stroke(menu, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
		Theme.Bind(ms, "Color", "Stroke")

		local filterState = State.new("")
		local yStart = pad
		if opts.Searchable then
			local sBox = Util.Create("TextBox", {
				Size = UDim2.new(1, -12, 0, 24), Position = UDim2.fromOffset(6, pad),
				PlaceholderText = "Filter…", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
				BackgroundTransparency = 0, ZIndex = 61, ClearTextOnFocus = false, Parent = menu,
			})
			Theme.Paint(sBox, { BackgroundColor3 = "Field" })
			Theme.Bind(sBox, "TextColor3", "Text")
			Theme.Bind(sBox, "PlaceholderColor3", "TextFaint")
			Util.Round(sBox, 6)
			Util.Padding(sBox, 0, 0, 8, 8)
			menuMaid:Add(sBox:GetPropertyChangedSignal("Text"):Connect(function()
				filterState:Set(string.lower(sBox.Text))
			end))
			yStart += 32
		end

		local scroll = Util.Create("ScrollingFrame", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(0, yStart),
			Size = UDim2.new(1, 0, 1, -yStart - pad), CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3,
			ScrollBarImageColor3 = Theme.Get("TextFaint"), ZIndex = 61, Parent = menu,
		})
		Util.Create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
		Util.Padding(scroll, 0, 0, pad, pad)

		for _, valueName in ipairs(values) do
			local item = Util.Create("TextButton", {
				Size = UDim2.new(1, -pad, 0, itemH), Text = "", ZIndex = 62, Parent = scroll,
			})
			local itemMaid = menuMaid:Add(Maid.new())
			Components.Hoverable(item, itemMaid, { Base = "SurfaceHigh", Hover = "SurfaceHover" })
			Util.Round(item, 6)
			local itemLabel = Util.Create("TextLabel", {
				Text = valueName, Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(9, 0),
				TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12, ZIndex = 62, Parent = item,
			})
			local tick = Icons.Make("check", 13, "Accent", item)
			tick.AnchorPoint = Vector2.new(1, 0.5)
			tick.Position = UDim2.new(1, -8, 0.5, 0)
			tick.ZIndex = 62
			local function paintItem()
				local isSel = multi and selected[valueName] or selected == valueName
				tick.Visible = isSel == true
				itemLabel.TextColor3 = isSel and Theme.Get("Accent") or Theme.Get("Text")
			end
			paintItem()
			menuMaid:Add(filterState:Observe(function(filter)
				item.Visible = filter == "" or string.find(string.lower(valueName), filter, 1, true) ~= nil
			end))
			menuMaid:Add(item.MouseButton1Click:Connect(function()
				if multi then
					selected[valueName] = not selected[valueName] or nil
					paintItem()
					faceLabel.Text = summary()
					if opts.Callback then
						local list = {}
						for _, v in ipairs(values) do if selected[v] then table.insert(list, v) end end
						task.spawn(opts.Callback, list)
					end
				else
					selected = valueName
					faceLabel.Text = summary()
					if opts.Callback then task.spawn(opts.Callback, valueName) end
					closeMenu()
				end
			end))
		end

		menu.BackgroundTransparency = 1
		Motion.Tween(menu, { Size = UDim2.fromOffset(menu.Size.X.Offset, fullH), BackgroundTransparency = 0 }, Motion.Easing.Emphasis)

		-- click-away dismiss
		task.defer(function()
			if not menuMaid then return end
			menuMaid:Add(UserInputService.InputBegan:Connect(function(input)
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
				if not menu then return end
				local p, s = menu.AbsolutePosition, menu.AbsoluteSize
				local m = input.Position
				local inside = m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
				local fp, fs = face.AbsolutePosition, face.AbsoluteSize
				local onFace = m.X >= fp.X and m.X <= fp.X + fs.X and m.Y >= fp.Y and m.Y <= fp.Y + fs.Y
				if not inside and not onFace then closeMenu() end
			end))
		end)
	end

	faceLabel.Text = summary()
	maid:Add(face.MouseButton1Click:Connect(openMenu))
	maid:Add(closeMenu)

	function handle:Set(newValue, silent)
		if multi then
			selected = {}
			for _, v in ipairs(newValue or {}) do selected[v] = true end
		else
			selected = newValue
		end
		faceLabel.Text = summary()
		if not silent and opts.Callback then task.spawn(opts.Callback, newValue) end
	end
	function handle:Get()
		if multi then
			local list = {}
			for _, v in ipairs(values) do if selected[v] then table.insert(list, v) end end
			return list
		end
		return selected
	end
	function handle:Refresh(newValues, keepSelection)
		values = newValues
		if not keepSelection then
			selected = multi and {} or newValues[1]
		end
		faceLabel.Text = summary()
		closeMenu()
	end
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  ColorPicker (HSV panel + hue rail)
function Controls.ColorPicker(parent, opts)
	local color = opts.Default or Theme.Get("Accent")
	local h, s, v = color:ToHSV()

	local row, title, maid = Components.Row(parent, opts, 46)
	local swatch = Util.Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(34, 20), Text = "", BackgroundColor3 = color, Parent = row,
	})
	Util.Round(swatch, 5)
	local swStroke = Util.Stroke(swatch, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(swStroke, "Color", "Stroke")

	local open, panel, panelMaid = false, nil, nil
	local handle = Components.Handle(row, title, maid)

	local function apply(silent)
		color = Color3.fromHSV(h, s, v)
		swatch.BackgroundColor3 = color
		if not silent and opts.Callback then task.spawn(opts.Callback, color) end
	end

	local function closePanel()
		if not open then return end
		open = false
		if panel then
			local dying = panel
			panel = nil
			Motion.Tween(dying, { BackgroundTransparency = 1 }, Motion.Easing.Exit)
			for _, child in ipairs(dying:GetDescendants()) do
				if child:IsA("GuiObject") then Motion.Tween(child, { BackgroundTransparency = 1 }, Motion.Easing.Exit) end
			end
			task.delay(0.2, function()
				if panelMaid then panelMaid:Clean() panelMaid = nil end
				dying:Destroy()
			end)
		end
	end

	local function openPanel()
		if open then closePanel() return end
		open = true
		panelMaid = Maid.new()
		panel = Util.Create("Frame", {
			Position = UDim2.fromOffset(swatch.AbsolutePosition.X - 186, swatch.AbsolutePosition.Y + 30),
			Size = UDim2.fromOffset(220, 178), BackgroundTransparency = 1, ZIndex = 60, Parent = Root.OverlayLayer,
		})
		Theme.Paint(panel, { BackgroundColor3 = "SurfaceHigh" })
		Util.Round(panel, 10)
		local ps = Util.Stroke(panel, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
		Theme.Bind(ps, "Color", "Stroke")
		Util.Padding(panel, 10)
		-- WHY a plain Frame, not a CanvasGroup: CanvasGroup flattens its children
		-- to one texture, which makes a child UIGradient.Transparency render as
		-- solid — turning the value overlay fully black. A Frame composites the
		-- saturation/value gradients correctly.
		Motion.Tween(panel, { BackgroundTransparency = 0 }, Motion.Easing.Emphasis)

		-- saturation/value plane. WHY a white base: UIGradient.Color *multiplies*
		-- the frame's BackgroundColor3, so to get a white→hue saturation ramp the
		-- base must be white (a hue base would multiply to hue→hue², never white).
		local plane = Util.Create("TextButton", {
			Size = UDim2.new(1, 0, 0, 118), Text = "", AutoButtonColor = false,
			BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, ZIndex = 61, Parent = panel,
		})
		Util.Round(plane, 8)
		Util.Create("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(h, 1, 1)),
			Name = "SatGrad", Parent = plane,
		})
		local darkOverlay = Util.Create("Frame", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0, ZIndex = 62, Parent = plane,
		})
		Util.Round(darkOverlay, 8)
		Util.Create("UIGradient", {
			Transparency = NumberSequence.new(1, 0), Rotation = 90, Parent = darkOverlay,
		})
		local cursor = Util.Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12),
			BackgroundTransparency = 1, ZIndex = 63, Parent = plane,
		})
		Util.Stroke(cursor, Color3.new(1, 1, 1), 0, 2)
		Util.Round(cursor, 6)

		local hueRail = Util.Create("TextButton", {
			Position = UDim2.new(0, 0, 0, 128), Size = UDim2.new(1, 0, 0, 12),
			Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0, ZIndex = 61, Parent = panel,
		})
		Util.Round(hueRail, 6)
		local hueKeys = {}
		for i = 0, 6 do
			table.insert(hueKeys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)))
		end
		Util.Create("UIGradient", { Color = ColorSequence.new(hueKeys), Parent = hueRail })
		local hueCursor = Util.Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(6, 16),
			BackgroundColor3 = Color3.new(1, 1, 1), ZIndex = 62, Parent = hueRail,
		})
		Util.Round(hueCursor, 3)
		Util.Stroke(hueCursor, Color3.new(0, 0, 0), 0.6, 1)

		local hexLabel = Util.Create("TextLabel", {
			Position = UDim2.new(0, 0, 0, 146), Size = UDim2.new(1, 0, 0, 14),
			TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 61, Parent = panel,
		})
		Theme.Bind(hexLabel, "TextColor3", "TextMuted")

		local function paintPanel()
			local hueColor = Color3.fromHSV(h, 1, 1)
			-- plane stays white; the gradient carries the hue (multiplicative)
			plane.SatGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), hueColor)
			cursor.Position = UDim2.fromScale(s, 1 - v)
			hueCursor.Position = UDim2.fromScale(h, 0.5)
			hexLabel.Text = "#" .. color:ToHex():upper() .. string.format("   RGB %d %d %d",
				math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
		end

		local dragPlane, dragHue = false, false
		local function planeFrom(pos)
			s = math.clamp((pos.X - plane.AbsolutePosition.X) / plane.AbsoluteSize.X, 0, 1)
			v = 1 - math.clamp((pos.Y - plane.AbsolutePosition.Y) / plane.AbsoluteSize.Y, 0, 1)
			apply() paintPanel()
		end
		local function hueFrom(pos)
			h = math.clamp((pos.X - hueRail.AbsolutePosition.X) / hueRail.AbsoluteSize.X, 0, 1)
			apply() paintPanel()
		end
		panelMaid:Add(plane.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then dragPlane = true planeFrom(input.Position) end
		end))
		panelMaid:Add(hueRail.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then dragHue = true hueFrom(input.Position) end
		end))
		panelMaid:Add(UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				if dragPlane then planeFrom(input.Position) end
				if dragHue then hueFrom(input.Position) end
			end
		end))
		panelMaid:Add(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then dragPlane, dragHue = false, false end
		end))
		paintPanel()

		task.defer(function()
			if not panelMaid then return end
			panelMaid:Add(UserInputService.InputBegan:Connect(function(input)
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
				if not panel then return end
				local p, sz = panel.AbsolutePosition, panel.AbsoluteSize
				local m = input.Position
				if m.X < p.X or m.X > p.X + sz.X or m.Y < p.Y or m.Y > p.Y + sz.Y then
					local fp, fs = swatch.AbsolutePosition, swatch.AbsoluteSize
					local onFace = m.X >= fp.X and m.X <= fp.X + fs.X and m.Y >= fp.Y and m.Y <= fp.Y + fs.Y
					if not onFace then closePanel() end
				end
			end))
		end)
	end

	maid:Add(swatch.MouseButton1Click:Connect(openPanel))
	maid:Add(closePanel)

	function handle:Set(newColor, silent)
		if type(newColor) == "string" then
			local okHex, c = pcall(Color3.fromHex, newColor)
			if okHex then newColor = c end
		end
		if typeof(newColor) ~= "Color3" then return end -- ignore malformed values
		h, s, v = newColor:ToHSV()
		apply(silent)
	end
	function handle:Get() return color end
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Keybind
function Controls.Keybind(parent, opts)
	local bind = opts.Default -- Enum.KeyCode or nil
	local listening = false

	local row, title, maid = Components.Row(parent, opts, 100)
	local face = Util.Create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(88, 24), Text = "", Parent = row,
	})
	Theme.Paint(face, { BackgroundColor3 = "Field" })
	Util.Round(face, 6)
	local faceStroke = Util.Stroke(face, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(faceStroke, "Color", "Stroke")
	local label = Util.Create("TextLabel", { Size = UDim2.fromScale(1, 1), TextSize = 11.5, Parent = face })
	Theme.Bind(label, "TextColor3", "TextMuted")

	local function render()
		label.Text = listening and "press key…" or (bind and bind.Name or "unbound")
	end
	render()

	maid:Add(face.MouseButton1Click:Connect(function()
		listening = true
		render()
		Motion.Tween(faceStroke, { Color = Theme.Get("Accent"), Transparency = 0.2 }, Motion.Easing.Soft)
	end))
	maid:Add(UserInputService.InputBegan:Connect(function(input, processed)
		if listening then
			if input.UserInputType == Enum.UserInputType.Keyboard then
				bind = input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode or nil
				listening = false
				render()
				Motion.Tween(faceStroke, { Color = Theme.Get("Stroke"), Transparency = Theme.Get("StrokeAlpha") }, Motion.Easing.Soft)
				if opts.ChangedCallback then task.spawn(opts.ChangedCallback, bind) end
			end
			return
		end
		if processed then return end
		if bind and input.KeyCode == bind and opts.Callback then
			task.spawn(opts.Callback, bind)
		end
	end))

	local handle = Components.Handle(row, title, maid)
	function handle:Set(keyCode) bind = keyCode render() end
	function handle:Get() return bind end
	registerFlag(opts, handle)
	return handle
end

--─────────────────────────────────────────────  Label / Paragraph / Divider
function Controls.Label(parent, opts)
	local label = Util.Create("TextLabel", {
		Text = opts.Text or opts.Name or "", Size = UDim2.new(1, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left, RichText = true, Parent = parent,
	})
	Theme.Bind(label, "TextColor3", opts.Muted and "TextMuted" or "Text")
	local handle = { Instance = label }
	function handle:Set(text) label.Text = text end
	function handle:Destroy() label:Destroy() end
	return handle
end

function Controls.Paragraph(parent, opts)
	local card = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent,
	})
	Theme.Paint(card, { BackgroundColor3 = "SurfaceHigh" })
	Util.Round(card, 8)
	local stroke = Util.Stroke(card, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")
	Util.Padding(card, 10, 10, 12, 12)
	Util.Create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = card })

	local title = Util.Create("TextLabel", {
		Text = opts.Title or "", TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 1, Parent = card,
	})
	Theme.Bind(title, "TextColor3", "Text")
	local body = Util.Create("TextLabel", {
		Text = opts.Content or "", TextWrapped = true, RichText = true, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 2, Parent = card,
	})
	Theme.Bind(body, "TextColor3", "TextMuted")

	local handle = { Instance = card }
	function handle:Set(newTitle, newContent)
		if newTitle then title.Text = newTitle end
		if newContent then body.Text = newContent end
	end
	function handle:Destroy() card:Destroy() end
	return handle
end

function Controls.Divider(parent, opts)
	local holder = Util.Create("Frame", { Size = UDim2.new(1, 0, 0, 9), BackgroundTransparency = 1, Parent = parent })
	local line = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 0.85, Parent = holder,
	})
	Theme.Bind(line, "BackgroundColor3", "Stroke")
	if opts and opts.Text then
		local tag = Util.Create("TextLabel", {
			Text = "  " .. opts.Text .. "  ", TextSize = 10.5, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5), AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 0, Parent = holder,
		})
		Theme.Paint(tag, { BackgroundColor3 = "Surface" })
		Theme.Bind(tag, "TextColor3", "TextFaint")
	end
	return { Instance = holder, Destroy = function() holder:Destroy() end }
end

--─────────────────────────────────────────────  ProgressBar / Spinner / Badge / Image
function Controls.ProgressBar(parent, opts)
	local row, title, maid = Components.Row(parent, opts, 170)
	local track = makeTrack(row, maid)
	track.Size = UDim2.fromOffset(148, 6)
	local fill = Util.Create("Frame", { Size = UDim2.fromScale(0, 1), Parent = track })
	Theme.Bind(fill, "BackgroundColor3", opts.ColorToken or "Accent")
	Util.Round(fill, 3)
	Util.Create("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 0) }),
		Parent = fill,
	})

	local handle = Components.Handle(row, title, maid)
	function handle:Set(alpha)
		Motion.Spring(fill, "Size", UDim2.fromScale(math.clamp(alpha, 0, 1), 1), { Stiffness = 200, Damping = 26 })
	end
	handle:Set(opts.Default or 0)
	return handle
end

function Controls.Spinner(parent, opts)
	local holder = Util.Create("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Parent = parent })
	-- assetless spinner: 8 dots on a ring with graded transparency, rotated on Heartbeat
	local ring = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, Parent = holder,
	})
	local N = 8
	for i = 0, N - 1 do
		local a = math.rad((i / N) * 360)
		local dot = Util.Create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5 + math.cos(a) * 0.42, 0.5 + math.sin(a) * 0.42),
			Size = UDim2.fromOffset(4, 4), BackgroundTransparency = i / N, Parent = ring,
		})
		Util.Round(dot, 2)
		Theme.Bind(dot, "BackgroundColor3", "Accent")
	end
	local conn = RunService.Heartbeat:Connect(function(dt)
		ring.Rotation = (ring.Rotation + dt * 260) % 360
	end)
	local handle = { Instance = holder }
	function handle:Destroy() conn:Disconnect() holder:Destroy() end
	return handle
end

function Controls.Badge(parent, opts)
	local row, title, maid = Components.Row(parent, opts, 90)
	local pill = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 20), Parent = row,
	})
	Theme.Bind(pill, "BackgroundColor3", "AccentSoft")
	Util.Round(pill, 10)
	Util.Padding(pill, 0, 0, 9, 9)
	local text = Util.Create("TextLabel", {
		Text = opts.Value or "", TextSize = 11, AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Parent = pill,
	})
	Theme.Bind(text, "TextColor3", "Accent")
	local handle = Components.Handle(row, title, maid)
	function handle:Set(value) text.Text = tostring(value) end
	return handle
end

function Controls.Image(parent, opts)
	local holder = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, opts.Height or 120), ClipsDescendants = true, Parent = parent,
	})
	Theme.Paint(holder, { BackgroundColor3 = "Field" })
	Util.Round(holder, 8)
	local img = Util.Create("ImageLabel", {
		Image = opts.Image or "", BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1), ScaleType = opts.ScaleType or Enum.ScaleType.Crop, Parent = holder,
	})
	local handle = { Instance = holder }
	function handle:Set(image) img.Image = image end
	function handle:Destroy() holder:Destroy() end
	return handle
end

--─────────────────────────────────────────────  Console (log feed)
function Controls.Console(parent, opts)
	opts = opts or {}
	local maxLines = opts.MaxLines or 200
	local holder = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, opts.Height or 140), ClipsDescendants = true, Parent = parent,
	})
	Theme.Paint(holder, { BackgroundColor3 = "Field" })
	Util.Round(holder, 8)
	local stroke = Util.Stroke(holder, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")
	local scroll = Util.Create("ScrollingFrame", {
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Get("TextFaint"), Parent = holder,
	})
	local layout = Util.Create("UIListLayout", { Padding = UDim.new(0, 1), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
	Util.Padding(scroll, 8, 8, 10, 10)

	local count = 0
	local levelToken = { info = "TextMuted", ok = "Success", warn = "Warning", error = "Error" }
	local handle = { Instance = holder }
	function handle:Log(message, level)
		count += 1
		local line = Util.Create("TextLabel", {
			Text = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(message)),
			FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json"),
			TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = count, Parent = scroll,
		})
		Theme.Bind(line, "TextColor3", levelToken[level or "info"] or "TextMuted")
		local kids = scroll:GetChildren()
		if #kids - 2 > maxLines then -- minus layout+padding
			for _, child in ipairs(kids) do
				if child:IsA("TextLabel") then child:Destroy() break end
			end
		end
		task.defer(function()
			if not scroll.Parent then return end -- console may be destroyed before the deferred scroll runs
			scroll.CanvasPosition = Vector2.new(0, math.max(0, layout.AbsoluteContentSize.Y - scroll.AbsoluteSize.Y))
		end)
	end
	function handle:Clear()
		for _, child in ipairs(scroll:GetChildren()) do
			if child:IsA("TextLabel") then child:Destroy() end
		end
	end
	function handle:Destroy() holder:Destroy() end
	return handle
end

--─────────────────────────────────────────────  Config manager (list / save / load / delete)
function Controls.ConfigManager(parent, opts)
	opts = opts or {}
	local maid = Maid.new()
	local current = opts.Default or "default"

	local card = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = parent,
	})
	Theme.Paint(card, { BackgroundColor3 = "Surface" })
	Util.Round(card, 8)
	local cs = Util.Stroke(card, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(cs, "Color", "Stroke")
	Util.Padding(card, 12, 12, 12, 12)
	Util.Create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = card })

	local heading = Util.Create("TextLabel", {
		Text = opts.Title or "Configuration", TextSize = 13, LayoutOrder = 1,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 16), Parent = card,
	})
	Theme.Bind(heading, "TextColor3", "Text")

	local field = Util.Create("TextBox", {
		Size = UDim2.new(1, 0, 0, 30), Text = current, PlaceholderText = "config name",
		TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 0,
		ClearTextOnFocus = false, LayoutOrder = 2, Parent = card,
	})
	Theme.Paint(field, { BackgroundColor3 = "Field" })
	Theme.Bind(field, "TextColor3", "Text")
	Theme.Bind(field, "PlaceholderColor3", "TextFaint")
	Util.Round(field, 6)
	Util.Padding(field, 0, 0, 10, 10)
	maid:Add(field:GetPropertyChangedSignal("Text"):Connect(function()
		current = field.Text
	end))

	local status = Util.Create("TextLabel", {
		Text = "", TextSize = 11, LayoutOrder = 5, TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 14), Parent = card,
	})
	Theme.Bind(status, "TextColor3", "TextFaint")
	local function say(msg) status.Text = msg end

	local actions = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = 3, Parent = card,
	})
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = actions,
	})
	local list
	local function mkButton(text, token, order, cb)
		local b = Util.Create("TextButton", {
			Text = text, TextSize = 12, AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0), BackgroundTransparency = 0, LayoutOrder = order, Parent = actions,
		})
		Theme.Paint(b, { BackgroundColor3 = "SurfaceHigh" })
		Theme.Bind(b, "TextColor3", token)
		Util.Round(b, 6)
		Util.Padding(b, 0, 0, 12, 12)
		local bm = maid:Add(Maid.new())
		Components.Hoverable(b, bm, { Base = "SurfaceHigh", Hover = "SurfaceHover" })
		maid:Add(b.MouseButton1Click:Connect(cb))
		return b
	end

	local function refresh()
		if not list then return end
		for _, ch in ipairs(list:GetChildren()) do
			if ch:IsA("TextButton") or ch.Name == "__empty" then ch:Destroy() end
		end
		local names = Config.List()
		if #names == 0 then
			local empty = Util.Create("TextLabel", {
				Text = "No saved configs", TextSize = 11, Size = UDim2.new(1, 0, 0, 20),
				TextXAlignment = Enum.TextXAlignment.Left, Parent = list, Name = "__empty",
			})
			Theme.Bind(empty, "TextColor3", "TextFaint")
			return
		end
		for i, name in ipairs(names) do
			local item = Util.Create("TextButton", {
				Size = UDim2.new(1, 0, 0, 26), Text = "", BackgroundTransparency = 1, LayoutOrder = i, Parent = list,
			})
			Util.Round(item, 6)
			local im = maid:Add(Maid.new())
			Components.Hoverable(item, im, { Base = "Surface", Hover = "SurfaceHover" })
			local lbl = Util.Create("TextLabel", {
				Text = name, TextSize = 12, Position = UDim2.fromOffset(9, 0),
				Size = UDim2.new(1, -18, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, Parent = item,
			})
			Theme.Bind(lbl, "TextColor3", "TextMuted")
			maid:Add(item.MouseButton1Click:Connect(function()
				current = name
				field.Text = name
				say("selected '" .. name .. "'")
			end))
		end
	end

	mkButton("Save", "Text", 1, function()
		if current == "" then say("enter a name first") return end
		local ok, err = Config.Save(current)
		say(ok and ("saved '" .. current .. "'") or ("save failed: " .. tostring(err)))
		refresh()
	end)
	mkButton("Load", "Accent", 2, function()
		if current == "" then say("enter a name first") return end
		local ok, err = Config.Load(current)
		say(ok and ("loaded '" .. current .. "'") or ("load failed: " .. tostring(err)))
	end)
	mkButton("Delete", "Error", 3, function()
		if current == "" then say("enter a name first") return end
		local ok, err = Config.Delete(current)
		say(ok and ("deleted '" .. current .. "'") or ("delete failed: " .. tostring(err)))
		refresh()
	end)
	mkButton("Refresh", "TextMuted", 4, function() refresh() say("list refreshed") end)

	list = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1, LayoutOrder = 4, Parent = card,
	})
	Util.Create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	refresh()

	local handle = {}
	function handle:Refresh() refresh() end
	function handle:Get() return current end
	function handle:Set(name) current = name field.Text = name end
	function handle:Destroy() maid:Clean() card:Destroy() end
	return handle
end

--═══════════════════════════════════════════════════════════════════════════
-- § Section ─ card container exposing every control as Create<Name>
--═══════════════════════════════════════════════════════════════════════════
local Section = {}
Section.__index = Section

local SECTION_METHODS = {
	Button = "Button", Toggle = "Toggle", Slider = "Slider", RangeSlider = "RangeSlider",
	Textbox = "Textbox", Input = "Textbox", NumberInput = "NumberInput",
	Dropdown = "Dropdown", ColorPicker = "ColorPicker", Keybind = "Keybind",
	Label = "Label", Paragraph = "Paragraph", Divider = "Divider",
	ProgressBar = "ProgressBar", Spinner = "Spinner", Badge = "Badge",
	Image = "Image", Console = "Console", ConfigManager = "ConfigManager",
}

function Section._new(parentCanvas, titleText, opts)
	opts = opts or {}
	local self = setmetatable({}, Section)
	self._maid = Maid.new()

	local card = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true, Parent = parentCanvas,
	})
	Theme.Paint(card, { BackgroundColor3 = "Surface" })
	Util.Round(card, 10)
	local stroke = Util.Stroke(card, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(stroke, "Color", "Stroke")
	self.Instance = card

	local collapsed = State.new(false)
	local header = Util.Create("TextButton", {
		Size = UDim2.new(1, 0, 0, 34), Text = "", BackgroundTransparency = 1, Parent = card,
	})
	local headerLabel = Util.Create("TextLabel", {
		Text = titleText or "Section", TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		TextSize = 12.5, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -50, 1, 0), Parent = header,
	})
	Theme.Bind(headerLabel, "TextColor3", "TextMuted")
	local chev = Icons.Make("chevron_down", 12, "TextFaint", header)
	chev.AnchorPoint = Vector2.new(1, 0.5)
	chev.Position = UDim2.new(1, -14, 0.5, 0)

	local body = Util.Create("Frame", {
		Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = card,
	})
	Util.Create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	Util.Padding(body, 0, 12, 12, 12)
	self._canvas = body

	-- Collapse: AutomaticSize can't tween, so we freeze to the measured pixel
	-- height, tween, then restore automatic sizing when expanding finishes.
	self._maid:Add(header.MouseButton1Click:Connect(function()
		if opts.Collapsible == false then return end
		collapsed:Set(not collapsed:Get())
	end))
	collapsed.Changed:Connect(function(isCollapsed)
		Motion.Tween(chev, { Rotation = isCollapsed and -90 or 0 }, Motion.Easing.Standard)
		if isCollapsed then
			local h = card.AbsoluteSize.Y
			card.AutomaticSize = Enum.AutomaticSize.None
			card.Size = UDim2.new(1, 0, 0, h)
			Motion.Tween(card, { Size = UDim2.new(1, 0, 0, 34) }, Motion.Easing.Emphasis)
			Motion.Tween(body, { BackgroundTransparency = 1 }, Motion.Easing.Soft)
		else
			local target = 34 + body.AbsoluteSize.Y
			local tween = Motion.Tween(card, { Size = UDim2.new(1, 0, 0, target) }, Motion.Easing.Emphasis)
			tween.Completed:Once(function()
				card.AutomaticSize = Enum.AutomaticSize.Y
				card.Size = UDim2.new(1, 0, 0, 0)
			end)
		end
	end)

	self._elements = {} -- { {name, instance} } for search filtering
	return self
end

for methodSuffix, controlName in pairs(SECTION_METHODS) do
	Section["Create" .. methodSuffix] = function(self, opts)
		opts = opts or {}
		local handle = Controls[controlName](self._canvas, opts)
		table.insert(self._elements, { Name = string.lower(tostring(opts.Name or opts.Title or opts.Text or "")), Handle = handle })
		return handle
	end
end

-- ADDED (Mango): destroy every control currently inside this section
-- without destroying the section card itself. This is what lets a section be
-- rebuilt on the fly — e.g. the Performance Mods tab regenerates its whole
-- A-Chassis tune control list each time you enter a different car — with no
-- leaked rows, connections or springs (each handle's own Destroy is called).
function Section:Clear()
	for _, entry in ipairs(self._elements) do
		if entry.Handle and entry.Handle.Destroy then
			pcall(function() entry.Handle:Destroy() end)
		end
	end
	table.clear(self._elements)
end

-- ADDED (Mango): read-only list of { Name, Handle } for controls in this
-- section (handy for bulk live-refresh loops).
function Section:GetElements()
	return self._elements
end

function Section:Destroy()
	self._maid:Clean()
	self.Instance:Destroy()
end

--═══════════════════════════════════════════════════════════════════════════
-- § Window ─ chrome: sidebar navigation, drag, resize, minimize, close
--═══════════════════════════════════════════════════════════════════════════
local Window = {}
Window.__index = Window

local Tab = {}
Tab.__index = Tab

function Tab:CreateSection(title, opts)
	local section = Section._new(self._canvas, title, opts)
	table.insert(self._sections, section)
	return section
end

function Tab:Select()
	self._window:_selectTab(self)
end

--─────────────────────────────────────────────
function Window._new(nectar, opts)
	opts = opts or {}
	local self = setmetatable({}, Window)
	self._nectar = nectar
	self._maid = Maid.new()
	self._tabs = {}
	self._minimized = false

	Root.Get()
	local width = opts.Size and opts.Size.X.Offset or 620
	local height = opts.Size and opts.Size.Y.Offset or 420

	local frame = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = opts.Position or UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		ClipsDescendants = true, Parent = Root.WindowLayer,
	})
	Theme.Paint(frame, { BackgroundColor3 = "Backdrop" })
	Util.Round(frame, 14)
	local frameStroke = Util.Stroke(frame, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(frameStroke, "Color", "Stroke")
	self.Instance = frame

	-- ── Title bar ──
	local SIDEBAR_W = 168
	local titlebar = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = frame,
	})
	local title = Util.Create("TextLabel", {
		Text = opts.Title or "Nectar", TextSize = 14,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
		Position = UDim2.fromOffset(18, 0), Size = UDim2.new(0.5, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left, Parent = titlebar,
	})
	Theme.Bind(title, "TextColor3", "Text")
	if opts.Subtitle then
		local sub = Util.Create("TextLabel", {
			Text = opts.Subtitle, TextSize = 11,
			Position = UDim2.fromOffset(18, 26), Size = UDim2.new(0.5, 0, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Left, Parent = titlebar,
		})
		Theme.Bind(sub, "TextColor3", "TextFaint")
		title.Size = UDim2.new(0.5, 0, 0, 30)
		title.TextYAlignment = Enum.TextYAlignment.Bottom
		title.Position = UDim2.fromOffset(18, -2)
	end

	local function chromeButton(iconName, xOffset, colorToken)
		local btn = Util.Create("TextButton", {
			Text = "", AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, xOffset, 0.5, 0), Size = UDim2.fromOffset(26, 26),
			BackgroundTransparency = 1, Parent = titlebar,
		})
		Util.Round(btn, 7)
		local icon = Icons.Make(iconName, 12, "TextMuted", btn)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		self._maid:Add(btn.MouseEnter:Connect(function()
			Motion.Tween(btn, { BackgroundTransparency = 0, BackgroundColor3 = Theme.Get("SurfaceHover") }, Motion.Easing.Soft)
			Icons.Tint(icon, Theme.Get(colorToken or "Text"))
		end))
		self._maid:Add(btn.MouseLeave:Connect(function()
			Motion.Tween(btn, { BackgroundTransparency = 1 }, Motion.Easing.Soft)
			Icons.Tint(icon, Theme.Get("TextMuted"))
		end))
		return btn
	end
	local closeBtn = chromeButton("close", -14, "Error")
	local minBtn = chromeButton("minus", -44)

	-- ── Sidebar ──
	local sidebar = Util.Create("Frame", {
		Position = UDim2.fromOffset(0, 44), Size = UDim2.new(0, SIDEBAR_W, 1, -44),
		BackgroundTransparency = 1, Parent = frame,
	})
	local sidebarList = Util.Create("ScrollingFrame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -10),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 0, Parent = sidebar,
	})
	Util.Create("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = sidebarList })
	Util.Padding(sidebarList, 6, 6, 10, 10)
	self._sidebarList = sidebarList

	local vDivider = Util.Create("Frame", {
		Position = UDim2.fromOffset(SIDEBAR_W, 44), Size = UDim2.new(0, 1, 1, -44),
		BackgroundTransparency = 0.88, Parent = frame,
	})
	Theme.Bind(vDivider, "BackgroundColor3", "Stroke")

	-- selection pill that springs between sidebar items
	local pill = Util.Create("Frame", {
		Size = UDim2.fromOffset(3, 18), Position = UDim2.fromOffset(2, 0),
		Visible = false, ZIndex = 3, Parent = sidebar,
	})
	Theme.Bind(pill, "BackgroundColor3", "Accent")
	Util.Round(pill, 2)
	self._pill = pill

	-- ── Content host ──
	local content = Util.Create("Frame", {
		Position = UDim2.fromOffset(SIDEBAR_W + 1, 44),
		Size = UDim2.new(1, -SIDEBAR_W - 1, 1, -44),
		BackgroundTransparency = 1, ClipsDescendants = true, Parent = frame,
	})
	self._content = content

	-- ── Drag ──
	do
		local dragging, dragStart, startPos = false, nil, nil
		self._maid:Add(titlebar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, dragStart, startPos = true, input.Position, frame.Position
			end
		end))
		self._maid:Add(UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				-- spring-follow gives the window pleasing inertia instead of 1:1 rigid drag
				Motion.Spring(frame, "Position", UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				), { Stiffness = 900, Damping = 55 })
			end
		end))
		self._maid:Add(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))
	end

	-- ── Resize grip ──
	do
		local grip = Util.Create("TextButton", {
			Text = "", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, ZIndex = 5, Parent = frame,
		})
		-- small assetless corner grip (two stacked diagonal ticks)
		local g1 = Util.Create("Frame", {
			AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -4, 1, -4),
			Size = UDim2.fromOffset(9, 2), Rotation = -45, Parent = grip,
		})
		Util.Round(g1, 1) Theme.Bind(g1, "BackgroundColor3", "TextFaint")
		local g2 = Util.Create("Frame", {
			AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -4, 1, -8),
			Size = UDim2.fromOffset(5, 2), Rotation = -45, Parent = grip,
		})
		Util.Round(g2, 1) Theme.Bind(g2, "BackgroundColor3", "TextFaint")

		local resizing, resizeStart, startSize, startPos = false, nil, nil, nil
		self._maid:Add(grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing, resizeStart, startSize, startPos = true, input.Position, frame.AbsoluteSize, frame.Position
			end
		end))
		self._maid:Add(UserInputService.InputChanged:Connect(function(input)
			if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - resizeStart
				local newW = math.max(460, startSize.X + delta.X)
				local newH = math.max(300, startSize.Y + delta.Y)
				-- WHY shift Position too: the frame is centre-anchored (0.5,0.5), so
				-- growing Size alone moves the far edge only half the cursor travel.
				-- Nudging Position by half the *applied* delta pins the top-left
				-- corner, making the grip track the cursor 1:1.
				local appliedDX, appliedDY = newW - startSize.X, newH - startSize.Y
				frame.Size = UDim2.fromOffset(newW, newH)
				frame.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + appliedDX / 2,
					startPos.Y.Scale, startPos.Y.Offset + appliedDY / 2
				)
				if not self._minimized then self._fullHeight = newH end
			end
		end))
		self._maid:Add(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then resizing = false end
		end))
	end

	-- ── Minimize / close / toggle key ──
	self._fullHeight = height
	self._maid:Add(minBtn.MouseButton1Click:Connect(function() self:SetMinimized(not self._minimized) end))
	self._maid:Add(closeBtn.MouseButton1Click:Connect(function() self:Destroy() end))

	self._toggleKey = opts.ToggleKey or Enum.KeyCode.RightShift
	self._maid:Add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == self._toggleKey then
			self:SetVisible(not frame.Visible)
		end
	end))

	-- entrance
	frame.Size = UDim2.fromOffset(width * 0.92, height * 0.92)
	local gt = Util.Create("UIScale", { Scale = 0.96, Parent = frame })
	frame.BackgroundTransparency = 1
	Motion.Tween(frame, { BackgroundTransparency = 0 }, Motion.Easing.Emphasis)
	Motion.Spring(frame, "Size", UDim2.fromOffset(width, height), { Stiffness = 190, Damping = 22 })
	Motion.Tween(gt, { Scale = 1 }, Motion.Easing.Enter)

	return self
end

function Window:_selectTab(tab)
	if self._activeTab == tab then return end
	local previous = self._activeTab
	self._activeTab = tab

	for _, other in ipairs(self._tabs) do
		local active = other == tab
		Motion.Tween(other._sidebarLabel, { TextColor3 = active and Theme.Get("Text") or Theme.Get("TextMuted") }, Motion.Easing.Soft)
		Motion.Tween(other._sidebarButton, { BackgroundTransparency = active and 0 or 1 }, Motion.Easing.Soft)
		if other._sidebarIcon then
			Icons.Tint(other._sidebarIcon, active and Theme.Get("Accent") or Theme.Get("TextMuted"))
		end
	end

	-- selection pill springs to the active row
	local btn = tab._sidebarButton
	self._pill.Visible = true
	Motion.Spring(self._pill, "Position",
		UDim2.fromOffset(2, btn.AbsolutePosition.Y - self._pill.Parent.AbsolutePosition.Y + (btn.AbsoluteSize.Y - 18) / 2),
		{ Stiffness = 320, Damping = 26 })

	-- cross-fade + slide canvases
	if previous then
		local dying = previous._canvas
		Motion.Tween(dying, { Position = UDim2.fromOffset(-14, 0) }, Motion.Easing.Exit)
		task.delay(0.14, function()
			if self._activeTab ~= previous then dying.Visible = false end
		end)
	end
	local canvas = tab._canvas
	canvas.Visible = true
	canvas.Position = UDim2.fromOffset(18, 0)
	Motion.Spring(canvas, "Position", UDim2.fromOffset(0, 0), { Stiffness = 260, Damping = 26 })
end

function Window:CreateTab(opts)
	if type(opts) == "string" then opts = { Name = opts } end
	local tab = setmetatable({ _window = self, _sections = {} }, Tab)

	local btn = Util.Create("TextButton", {
		Size = UDim2.new(1, 0, 0, 32), Text = "", BackgroundTransparency = 1, Parent = self._sidebarList,
	})
	Theme.Bind(btn, "BackgroundColor3", "SurfaceHover")
	Util.Round(btn, 8)
	local xText = 12
	if opts.Icon then
		tab._sidebarIcon = Icons.Make(opts.Icon, 14, "TextMuted", btn)
		tab._sidebarIcon.AnchorPoint = Vector2.new(0, 0.5)
		tab._sidebarIcon.Position = UDim2.new(0, 10, 0.5, 0)
		xText = 32
	end
	local label = Util.Create("TextLabel", {
		Text = opts.Name or "Tab", TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(xText, 0), Size = UDim2.new(1, -xText - 8, 1, 0), Parent = btn,
	})
	Theme.Bind(label, "TextColor3", "TextMuted")
	tab._sidebarButton = btn
	tab._sidebarLabel = label

	local canvas = Util.Create("ScrollingFrame", {
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Get("TextFaint"),
		Parent = self._content,
	})
	Util.Create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = canvas })
	Util.Padding(canvas, 14, 18, 16, 16)
	tab._canvas = canvas

	self._maid:Add(btn.MouseButton1Click:Connect(function() self:_selectTab(tab) end))
	self._maid:Add(btn.MouseEnter:Connect(function()
		if self._activeTab ~= tab then Motion.Tween(btn, { BackgroundTransparency = 0.55 }, Motion.Easing.Soft) end
	end))
	self._maid:Add(btn.MouseLeave:Connect(function()
		if self._activeTab ~= tab then Motion.Tween(btn, { BackgroundTransparency = 1 }, Motion.Easing.Soft) end
	end))

	table.insert(self._tabs, tab)
	if #self._tabs == 1 then
		task.defer(function() self:_selectTab(tab) end)
	end
	return tab
end

function Window:SetMinimized(minimized)
	if minimized == self._minimized then return end
	self._minimized = minimized
	if minimized then
		self._fullHeight = self.Instance.AbsoluteSize.Y
		Motion.Spring(self.Instance, "Size", UDim2.fromOffset(self.Instance.AbsoluteSize.X, 44), { Stiffness = 240, Damping = 26 })
	else
		Motion.Spring(self.Instance, "Size", UDim2.fromOffset(self.Instance.AbsoluteSize.X, self._fullHeight), { Stiffness = 240, Damping = 26 })
	end
end

function Window:SetVisible(visible)
	local frame = self.Instance
	if visible then
		frame.Visible = true
		local scale = frame:FindFirstChildOfClass("UIScale") or Util.Create("UIScale", { Parent = frame })
		scale.Scale = 0.97
		frame.BackgroundTransparency = 1
		Motion.Tween(frame, { BackgroundTransparency = 0 }, Motion.Easing.Standard)
		Motion.Tween(scale, { Scale = 1 }, Motion.Easing.Enter)
	else
		local scale = frame:FindFirstChildOfClass("UIScale") or Util.Create("UIScale", { Parent = frame })
		Motion.Tween(scale, { Scale = 0.97 }, Motion.Easing.Exit)
		Motion.Tween(frame, { BackgroundTransparency = 1 }, Motion.Easing.Exit)
		task.delay(0.2, function()
			if frame.BackgroundTransparency == 1 then frame.Visible = false end
		end)
	end
end

function Window:SetToggleKey(keyCode)
	self._toggleKey = keyCode
end

function Window:Destroy()
	local frame = self.Instance
	local scale = frame:FindFirstChildOfClass("UIScale") or Util.Create("UIScale", { Parent = frame })
	Motion.Tween(scale, { Scale = 0.92 }, Motion.Easing.Exit)
	Motion.Tween(frame, { BackgroundTransparency = 1 }, Motion.Easing.Exit)
	task.delay(0.22, function()
		self._maid:Clean()
		Motion.StopSprings(frame)
		frame:Destroy()
	end)
end

--═══════════════════════════════════════════════════════════════════════════
-- § Config persistence (flags → JSON via writefile/readfile when available)
--═══════════════════════════════════════════════════════════════════════════
Config = {}

local function fsAvailable()
	return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

function Config.Save(name)
	if not fsAvailable() then return false, "filesystem API unavailable" end
	local out = {}
	for flag, handle in pairs(Flags) do
		if handle.Get then
			local value = handle:Get()
			local vType = typeof(value)
			if vType == "Color3" then
				-- named fields, not { __t, [1] }: a mixed table JSON-encodes as an
				-- array and drops __t, which then round-trips as an opaque table.
				out[flag] = { __t = "color", hex = value:ToHex() }
			elseif vType == "EnumItem" then
				out[flag] = { __t = "key", name = value.Name }
			elseif vType == "boolean" or vType == "number" or vType == "string" or vType == "table" then
				out[flag] = value
			end
		end
	end
	out.__theme = Theme.Current and Theme.Current:Get() or nil -- persist the active theme
	writefile("nectar_" .. name .. ".json", HttpService:JSONEncode(out))
	return true
end

function Config.Load(name)
	if not fsAvailable() then return false, "filesystem API unavailable" end
	local path = "nectar_" .. name .. ".json"
	if not isfile(path) then return false, "no saved config" end
	local ok, decoded = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
	if not ok or type(decoded) ~= "table" then return false, "config is corrupt" end
	if type(decoded.__theme) == "string" and Theme.Registry[decoded.__theme] then
		Theme.SetTheme(decoded.__theme)
	end
	for flag, value in pairs(decoded) do
		local handle = Flags[flag]
		if handle and handle.Set then
			if type(value) == "table" and value.__t == "color" and value.hex then
				handle:Set(Color3.fromHex(value.hex), true)
			elseif type(value) == "table" and value.__t == "key" and value.name then
				handle:Set(Enum.KeyCode[value.name], true)
			elseif type(value) ~= "table" or (value.__t == nil) then
				handle:Set(value, true)
			end
		end
	end
	return true
end

-- Lists saved config names (without the nectar_ prefix / .json suffix).
function Config.List()
	if type(listfiles) ~= "function" then return {} end
	local names = {}
	local ok, files = pcall(listfiles, "")
	if ok and files then
		for _, path in ipairs(files) do
			local n = string.match(path, "nectar_(.+)%.json$")
			if n then table.insert(names, n) end
		end
	end
	table.sort(names)
	return names
end

function Config.Delete(name)
	if type(delfile) ~= "function" then return false, "delete API unavailable" end
	local path = "nectar_" .. name .. ".json"
	if type(isfile) == "function" and not isfile(path) then return false, "no such config" end
	local ok = pcall(delfile, path)
	return ok
end

--═══════════════════════════════════════════════════════════════════════════
-- § Info ─ built-in runtime info helpers (fps, user, executor, ping, game, …)
--═══════════════════════════════════════════════════════════════════════════
-- Everything here is pcall-guarded so it degrades to a safe default off-executor
-- or in Studio rather than throwing. Designed for easy dev integration and to
-- back the Watermark system's stat tokens.
local Info = {}
do
	local sessionStart = os.clock()
	local frameTimes, frameIdx, fpsConn = {}, 0, nil
	local function ensureFps()
		if fpsConn then return end
		fpsConn = RunService.Heartbeat:Connect(function(dt)
			frameIdx += 1
			frameTimes[(frameIdx % 30) + 1] = dt
		end)
	end

	function Info.GetFPS()
		ensureFps()
		local sum, n = 0, 0
		for _, dt in pairs(frameTimes) do sum += dt n += 1 end
		if n == 0 or sum <= 0 then return 60 end
		return math.clamp(math.floor(n / sum + 0.5), 1, 999)
	end
	function Info.GetUsername()
		local ok, v = pcall(function() return LocalPlayer and LocalPlayer.Name end)
		return (ok and v) or "Player"
	end
	function Info.GetDisplayName()
		local ok, v = pcall(function() return LocalPlayer and LocalPlayer.DisplayName end)
		return (ok and v) or Info.GetUsername()
	end
	function Info.GetUserId()
		local ok, v = pcall(function() return LocalPlayer and LocalPlayer.UserId end)
		return (ok and v) or 0
	end
	function Info.GetExecutor()
		local ok, name = pcall(function()
			if identifyexecutor then return (identifyexecutor()) end
			if getexecutorname then return (getexecutorname()) end
			if syn and syn.request then return "Synapse" end
			return nil
		end)
		return (ok and name) or "Unknown"
	end
	function Info.GetPing()
		local ok, ping = pcall(function()
			local stats = game:GetService("Stats")
			return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and ping then return math.floor(ping + 0.5) end
		local ok2, p2 = pcall(function() return LocalPlayer:GetNetworkPing() * 1000 end)
		return (ok2 and p2 and math.floor(p2 + 0.5)) or 0
	end
	function Info.GetPlaceId()
		local ok, v = pcall(function() return game.PlaceId end)
		return (ok and v) or 0
	end
	local gameName
	function Info.GetGameName()
		if gameName then return gameName end
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
		end)
		gameName = (ok and info and info.Name) or ("Place " .. tostring(Info.GetPlaceId()))
		return gameName
	end
	function Info.GetPlayerCount()
		local ok, v = pcall(function() return #Players:GetPlayers() end)
		return (ok and v) or 1
	end
	local region
	function Info.GetServerRegion()
		if region then return region end
		region = "…"
		task.spawn(function()
			local ok, res = pcall(function()
				return game:HttpGet("http://ip-api.com/line/?fields=country,city")
			end)
			if ok and type(res) == "string" and #res > 0 then
				region = (res:gsub("%s+$", "")):gsub("[\r\n]+", ", ")
			else
				region = "Unknown"
			end
		end)
		return region
	end
	function Info.GetPlaytime()
		local t = math.max(0, math.floor(os.clock() - sessionStart))
		local h, m, s = math.floor(t / 3600), math.floor((t % 3600) / 60), t % 60
		if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
		return string.format("%d:%02d", m, s)
	end
	function Info.GetClock()
		local ok, v = pcall(function() return os.date("%H:%M") end)
		return (ok and v) or ""
	end
	function Info.ResetPlaytime() sessionStart = os.clock() end

	-- token → display string. Used by the Watermark; unknown tokens return nil
	-- so callers can treat them as literal custom text.
	local RESOLVERS = {
		user = function() return "User: " .. Info.GetUsername() end,
		username = function() return Info.GetUsername() end,
		display = function() return Info.GetDisplayName() end,
		userid = function() return "ID: " .. Info.GetUserId() end,
		executor = function() return "Exec: " .. Info.GetExecutor() end,
		ping = function() return "Ping: " .. Info.GetPing() .. "ms" end,
		fps = function() return "FPS: " .. Info.GetFPS() end,
		game = function() return Info.GetGameName() end,
		place = function() return "Place: " .. Info.GetPlaceId() end,
		players = function() return "Players: " .. Info.GetPlayerCount() end,
		region = function() return Info.GetServerRegion() end,
		location = function() return Info.GetServerRegion() end,
		playtime = function() return "Time: " .. Info.GetPlaytime() end,
		clock = function() return Info.GetClock() end,
		time = function() return Info.GetClock() end,
	}
	function Info.Resolve(token)
		local key = string.lower(tostring(token):gsub("%s", ""))
		local fn = RESOLVERS[key]
		if not fn then return nil end
		local ok, v = pcall(fn)
		return ok and v or ""
	end
	function Info.Tokens()
		local t = {}
		for k in pairs(RESOLVERS) do table.insert(t, k) end
		table.sort(t)
		return t
	end
end

--═══════════════════════════════════════════════════════════════════════════
-- § Watermark ─ configurable stats overlay (corner watermark / top bar / mixed)
--═══════════════════════════════════════════════════════════════════════════
--[=[
	Nectar:CreateWatermark({
		Enabled = true,
		Title   = "Nectar",
		Mode    = "watermark" | "topbar" | "mixed" | "none",
		Location = "BottomRight" | "TopLeft" | "TopRight" | "BottomLeft",
		Info    = "user, executor, ping, fps"  -- or { "user", "fps", … }
		TopBarInfo = { "fps", "ping" },          -- used by "mixed" mode
		Interval = 1,          -- stat refresh seconds
	})
	Any token not recognised (see Info.Tokens) is shown as literal text, so
	studios can mix stats with custom branding freely. Returns a handle:
	:SetInfo :SetLocation :SetMode :SetTitle :SetVisible :SetEnabled :Destroy
]=]
local Watermark = {}

local WM_CORNERS = {
	topleft     = { a = Vector2.new(0, 0), p = UDim2.new(0, 14, 0, 14) },
	topright    = { a = Vector2.new(1, 0), p = UDim2.new(1, -14, 0, 14) },
	bottomleft  = { a = Vector2.new(0, 1), p = UDim2.new(0, 14, 1, -14) },
	bottomright = { a = Vector2.new(1, 1), p = UDim2.new(1, -14, 1, -14) },
}

local function wmList(info)
	if type(info) == "string" then
		local t = {}
		for token in string.gmatch(info, "[^,]+") do
			token = token:gsub("^%s+", ""):gsub("%s+$", "")
			if #token > 0 then table.insert(t, token) end
		end
		return t
	elseif type(info) == "table" then
		return info
	end
	return {}
end

local function wmSegText(token)
	local resolved = Info.Resolve(token)
	if resolved ~= nil then return resolved end
	return tostring(token) -- literal custom text
end

-- Builds one horizontal stat strip; returns (frame, refreshFn).
local function wmBuildStrip(tokens, brand)
	local strip = Util.Create("Frame", {
		AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0),
		ZIndex = 130, Parent = Root.ToastLayer,
	})
	Theme.Paint(strip, { BackgroundColor3 = "SurfaceHigh" })
	Util.Round(strip, 8)
	local s = Util.Stroke(strip, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(s, "Color", "Stroke")
	Util.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = strip,
	})
	Util.Padding(strip, 6, 6, 11, 11)

	local labels, order = {}, 0
	local function sep()
		order += 1
		local d = Util.Create("Frame", { Size = UDim2.fromOffset(3, 3), LayoutOrder = order, ZIndex = 131, Parent = strip })
		Util.Round(d, 2)
		Theme.Bind(d, "BackgroundColor3", "TextFaint")
	end
	local function add(text, token, accent)
		order += 1
		local lbl = Util.Create("TextLabel", {
			Text = text, TextSize = 12, AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 16), LayoutOrder = order, ZIndex = 131,
			FontFace = accent and Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold) or nil,
			Parent = strip,
		})
		Theme.Bind(lbl, "TextColor3", accent and "Accent" or "TextMuted")
		if token then table.insert(labels, { lbl = lbl, token = token }) end
	end

	local first = true
	if brand and #brand > 0 then add(brand, nil, true) first = false end
	for _, token in ipairs(tokens) do
		if not first then sep() end
		add(wmSegText(token), token, false)
		first = false
	end

	local function refresh()
		for _, e in ipairs(labels) do e.lbl.Text = wmSegText(e.token) end
	end
	return strip, refresh
end

function Watermark.Create(opts)
	opts = opts or {}
	Root.Get()
	local maid = Maid.new()
	local handle = { _maid = maid }

	local state = {
		enabled  = opts.Enabled ~= false,
		title    = opts.Title or "Nectar",
		mode     = string.lower(opts.Mode or "watermark"),
		location = string.lower((opts.Location or "BottomRight"):gsub("%s", "")),
		info     = wmList(opts.Info or opts.WatermarkInfo or { "user", "fps", "ping" }),
		topbar   = wmList(opts.TopBarInfo or {}),
		interval = opts.Interval or 1,
	}

	local strips = {}
	local refreshers = {}

	local function clear()
		for _, st in ipairs(strips) do st:Destroy() end
		strips, refreshers = {}, {}
	end

	local function placeCorner(strip, locKey)
		local c = WM_CORNERS[locKey] or WM_CORNERS.bottomright
		strip.AnchorPoint = c.a
		strip.Position = c.p
	end

	local function rebuild()
		clear()
		if not state.enabled or state.mode == "none" then return end

		if state.mode == "topbar" then
			local strip, r = wmBuildStrip(state.info, state.title)
			strip.AnchorPoint = Vector2.new(0.5, 0)
			strip.Position = UDim2.new(0.5, 0, 0, 12)
			table.insert(strips, strip) table.insert(refreshers, r)
		elseif state.mode == "mixed" then
			local topTokens = #state.topbar > 0 and state.topbar or { "fps", "ping" }
			local topStrip, tr = wmBuildStrip(topTokens, state.title)
			topStrip.AnchorPoint = Vector2.new(0.5, 0)
			topStrip.Position = UDim2.new(0.5, 0, 0, 12)
			table.insert(strips, topStrip) table.insert(refreshers, tr)

			local cornerStrip, cr = wmBuildStrip(state.info, nil)
			placeCorner(cornerStrip, state.location)
			table.insert(strips, cornerStrip) table.insert(refreshers, cr)
		else
			local strip, r = wmBuildStrip(state.info, state.title)
			placeCorner(strip, state.location)
			table.insert(strips, strip) table.insert(refreshers, r)
		end
	end

	rebuild()

	local acc = 0
	maid:Add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < state.interval then return end
		acc = 0
		for _, r in ipairs(refreshers) do r() end
	end))
	maid:Add(clear)

	function handle:SetVisible(v)
		for _, st in ipairs(strips) do st.Visible = v end
	end
	function handle:SetEnabled(v) state.enabled = v ~= false rebuild() end
	function handle:SetMode(m) state.mode = string.lower(m or "watermark") rebuild() end
	function handle:SetLocation(loc) state.location = string.lower((loc or "BottomRight"):gsub("%s", "")) rebuild() end
	function handle:SetTitle(t) state.title = t or "" rebuild() end
	function handle:SetInfo(info) state.info = wmList(info) rebuild() end
	function handle:SetTopBarInfo(info) state.topbar = wmList(info) rebuild() end
	function handle:SetInterval(s) state.interval = s or 1 end
	function handle:Refresh() for _, r in ipairs(refreshers) do r() end end
	function handle:Destroy() maid:Clean() end
	return handle
end

--═══════════════════════════════════════════════════════════════════════════
-- § Bootstrapper ─ optional cosmetic startup splash (integrated)
--═══════════════════════════════════════════════════════════════════════════
-- Self-contained loading splash: a progress line + status-text progression.
-- No logo, no spinner — just the line and the text stepping through your phases.
-- Fully variable-driven and yields (task.wait) until it finishes, then removes
-- every instance and connection it made.
local Bootstrapper = {}

local function bootTween(inst, props, time, style, dir)
	local t = TweenService:Create(inst,
		TweenInfo.new(time, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

function Bootstrapper.Play(opts)
	opts = opts or {}
	local accent     = opts.Accent or Color3.fromRGB(255, 176, 46)
	local background = opts.Background or Color3.fromRGB(18, 18, 23)
	local duration   = math.clamp(opts.Duration or 3, 1.2, 10)
	local phases     = opts.Steps or opts.Phases or { "Loading interface", "Preparing components", "Initializing" }
	local finalText  = opts.FinalText or "Welcome"
	local dimTrans   = opts.Dim or 0.25 -- backdrop transparency: lower = darker

	local connections = {}
	local function track(conn) table.insert(connections, conn) return conn end

	local gui = Util.Create("ScreenGui", {
		Name = "NectarBoot", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local parented = pcall(function()
		local hidden = (gethui and gethui()) or nil
		if hidden then gui.Parent = hidden return end
		gui.Parent = game:GetService("CoreGui")
	end)
	if not parented or not gui.Parent then
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	end

	local dim = Util.Create("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(8, 8, 10),
		BackgroundTransparency = 1, Parent = gui,
	})
	bootTween(dim, { BackgroundTransparency = dimTrans }, 0.4)

	local cardW, cardH = 340, 140
	local card = Util.Create("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(cardW, cardH), BackgroundColor3 = background,
		GroupTransparency = 1, Parent = gui,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(0, 16), Parent = card })
	Util.Create("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.92, Parent = card })
	local scale = Util.Create("UIScale", { Scale = 0.9, Parent = card })

	-- top accent line with a drifting sheen (this is the "line", not a logo)
	local sheen = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = accent, BackgroundTransparency = 0.35, Parent = card,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = sheen })
	local sheenGrad = Util.Create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1),
		}), Offset = Vector2.new(-1, 0), Parent = sheen,
	})
	track(RunService.Heartbeat:Connect(function(dt)
		sheenGrad.Offset = Vector2.new(((sheenGrad.Offset.X + dt * 0.6 + 1) % 3) - 1, 0)
	end))

	local title = Util.Create("TextLabel", {
		Text = opts.Title or "NECTAR", TextSize = 18, TextColor3 = Color3.fromRGB(238, 238, 243),
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 38),
		Size = UDim2.new(1, 0, 0, 22), TextTransparency = 1, BackgroundTransparency = 1, Parent = card,
	})
	local subtitle = Util.Create("TextLabel", {
		Text = opts.Subtitle or "Interface Suite", TextSize = 12, TextColor3 = Color3.fromRGB(140, 140, 152),
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 62),
		Size = UDim2.new(1, 0, 0, 14), TextTransparency = 1, BackgroundTransparency = 1, Parent = card,
	})

	local rail = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 94),
		Size = UDim2.fromOffset(240, 4), BackgroundColor3 = Color3.fromRGB(36, 36, 44), Parent = card,
	})
	Util.Create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = rail })
	local fill = Util.Create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = accent, Parent = rail })
	Util.Create("UICorner", { CornerRadius = UDim.new(0, 2), Parent = fill })
	Util.Create("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) }),
		Parent = fill,
	})

	local status = Util.Create("TextLabel", {
		Text = "", TextSize = 11.5, TextColor3 = Color3.fromRGB(120, 120, 132),
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 108),
		Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Parent = card,
	})

	-- choreography
	bootTween(card, { GroupTransparency = 0 }, 0.45)
	bootTween(scale, { Scale = 1 }, 0.6, Enum.EasingStyle.Back)
	task.wait(0.22)
	bootTween(title, { TextTransparency = 0, Position = UDim2.new(0.5, 0, 0, 36) }, 0.4)
	task.wait(0.08)
	bootTween(subtitle, { TextTransparency = 0 }, 0.4)

	local phaseTime = (duration - 1.0) / math.max(1, #phases)
	for index, phase in ipairs(phases) do
		status.Text = tostring(phase) .. "…"
		status.TextTransparency = 1
		bootTween(status, { TextTransparency = 0 }, 0.22)
		bootTween(fill, { Size = UDim2.fromScale(index / #phases, 1) }, phaseTime, Enum.EasingStyle.Quart)
		task.wait(phaseTime)
	end

	status.Text = finalText
	status.TextColor3 = accent
	bootTween(status, { TextTransparency = 0 }, 0.2)
	task.wait(0.5)

	bootTween(scale, { Scale = 1.04 }, 0.3)
	bootTween(card, { GroupTransparency = 1 }, 0.3)
	bootTween(dim, { BackgroundTransparency = 1 }, 0.35)
	task.wait(0.4)

	for _, conn in ipairs(connections) do conn:Disconnect() end
	table.clear(connections)
	gui:Destroy()
end

--═══════════════════════════════════════════════════════════════════════════
-- § Loader ─ game/script selector hub
--═══════════════════════════════════════════════════════════════════════════
--[=[
	A pre-UI script selector. Left: a scrolling list of scripts (one small table
	entry each — adding a button is adding a line). Right: session info
	(username / current game / executor) until a script is selected, then the
	script's detail (name, version, updated date, patched status, Load button).
	If the current PlaceId matches an entry, it is auto-selected with a
	"Game Detected" chip. Load closes the loader and runs the entry.

	Status API (dormant until Enabled = true): GETs a JSON array of
	{ id, title, version, updatedDate, patched } and overlays it onto entries
	by id. When disabled (or unreachable), per-entry fields and then the
	global Fallback are used instead, so every script always displays
	something sensible.
]=]
local Loader = {}

function Loader.Create(opts)
	opts = opts or {}
	Root.Get()
	local maid = Maid.new()
	local scripts = opts.Scripts or {}
	local fallback = opts.Fallback or {}
	local api = opts.StatusApi or {}
	local remote = {} -- [tostring(id)] = api row

	local function coalesce(a, b, c)
		if a ~= nil then return a end
		if b ~= nil then return b end
		return c
	end
	-- effective display status for an entry: API row → entry fields → Fallback
	local function statusFor(entry)
		local r = remote[tostring(entry.Id or "")] or {}
		return {
			version = r.version or entry.Version or fallback.Version or "1.0",
			updated = r.updatedDate or entry.UpdatedDate or fallback.UpdatedDate or "—",
			patched = coalesce(r.patched, entry.Patched, fallback.Patched == true),
		}
	end

	-- ── shell ──
	local frame = Util.Create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 330), ClipsDescendants = true, Parent = Root.WindowLayer,
	})
	Theme.Paint(frame, { BackgroundColor3 = "Backdrop" })
	Util.Round(frame, 14)
	local fs = Util.Stroke(frame, Theme.Get("Stroke"), Theme.Get("StrokeAlpha"))
	Theme.Bind(fs, "Color", "Stroke")
	local gt = Util.Create("UIScale", { Scale = 0.92, Parent = frame })
	Motion.Tween(gt, { Scale = 1 }, Motion.Easing.Enter)

	local handle = { Instance = frame }
	local destroyed = false
	function handle:Destroy()
		if destroyed then return end
		destroyed = true
		maid:Clean()
		frame:Destroy()
	end

	-- ── title bar (title only — no version number) ──
	local titlebar = Util.Create("Frame", {
		Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1, Parent = frame,
	})
	local titleLabel = Util.Create("TextLabel", {
		Text = opts.Title or "Loader", TextSize = 14,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -60, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left, Parent = titlebar,
	})
	Theme.Bind(titleLabel, "TextColor3", "Text")

	local closeBtn = Util.Create("TextButton", {
		Text = "", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(26, 26), BackgroundTransparency = 1, Parent = titlebar,
	})
	Util.Round(closeBtn, 7)
	local closeIcon = Icons.Make("close", 12, "TextMuted", closeBtn)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	maid:Add(closeBtn.MouseEnter:Connect(function()
		Motion.Tween(closeBtn, { BackgroundTransparency = 0, BackgroundColor3 = Theme.Get("SurfaceHover") }, Motion.Easing.Soft)
		Icons.Tint(closeIcon, Theme.Get("Error"))
	end))
	maid:Add(closeBtn.MouseLeave:Connect(function()
		Motion.Tween(closeBtn, { BackgroundTransparency = 1 }, Motion.Easing.Soft)
		Icons.Tint(closeIcon, Theme.Get("TextMuted"))
	end))
	maid:Add(closeBtn.MouseButton1Click:Connect(function() handle:Destroy() end))

	-- drag
	do
		local dragging, dragStart, startPos = false, nil, nil
		maid:Add(titlebar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, dragStart, startPos = true, input.Position, frame.Position
			end
		end))
		maid:Add(UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end))
		maid:Add(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
		end))
	end

	-- ── left: script list ──
	local LIST_W = 200
	local listHost = Util.Create("Frame", {
		Position = UDim2.fromOffset(0, 42), Size = UDim2.new(0, LIST_W, 1, -42),
		BackgroundTransparency = 1, Parent = frame,
	})
	local divider = Util.Create("Frame", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 6),
		Size = UDim2.new(0, 1, 1, -12), BackgroundTransparency = 0.7, Parent = listHost,
	})
	Theme.Bind(divider, "BackgroundColor3", "Stroke")
	local list = Util.Create("ScrollingFrame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -1, 1, 0),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Get("TextFaint"), Parent = listHost,
	})
	Util.Create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	Util.Padding(list, 4, 10, 10, 10)

	-- ── right: session info pane + script detail pane ──
	local right = Util.Create("Frame", {
		Position = UDim2.fromOffset(LIST_W, 42), Size = UDim2.new(1, -LIST_W, 1, -42),
		BackgroundTransparency = 1, Parent = frame,
	})
	Util.Padding(right, 8, 16, 18, 18)

	local infoPane = Util.Create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = right })
	local detailPane = Util.Create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = right })

	-- session info
	local infoHeading = Util.Create("TextLabel", {
		Text = "Session", TextSize = 13,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Size = UDim2.new(1, 0, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, Parent = infoPane,
	})
	Theme.Bind(infoHeading, "TextColor3", "Text")
	local function infoRow(y, label, value)
		local l = Util.Create("TextLabel", {
			Text = label, TextSize = 11, Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 13), TextXAlignment = Enum.TextXAlignment.Left, Parent = infoPane,
		})
		Theme.Bind(l, "TextColor3", "TextFaint")
		local v = Util.Create("TextLabel", {
			Text = value, TextSize = 12.5, Position = UDim2.fromOffset(0, y + 15),
			Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = infoPane,
		})
		Theme.Bind(v, "TextColor3", "TextMuted")
		return v
	end
	infoRow(30, "LOGGED IN AS", Info.GetDisplayName() .. " (@" .. Info.GetUsername() .. ")")
	local gameValue = infoRow(72, "CURRENT GAME", Info.GetGameName())
	infoRow(114, "EXECUTOR", Info.GetExecutor())
	local hint = Util.Create("TextLabel", {
		Text = "Select a script from the list to continue", TextSize = 11,
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -2),
		Size = UDim2.new(1, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Left, Parent = infoPane,
	})
	Theme.Bind(hint, "TextColor3", "TextFaint")

	-- script detail
	local detectedChip = Util.Create("TextLabel", {
		Text = "GAME DETECTED", TextSize = 10, Visible = false,
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
		Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0.85, Parent = detailPane,
	})
	Theme.Bind(detectedChip, "TextColor3", "Accent")
	Theme.Bind(detectedChip, "BackgroundColor3", "Accent")
	Util.Round(detectedChip, 5)
	Util.Padding(detectedChip, 0, 0, 7, 7)

	local dName = Util.Create("TextLabel", {
		Text = "", TextSize = 16, Position = UDim2.fromOffset(0, 24),
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
		Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = detailPane,
	})
	Theme.Bind(dName, "TextColor3", "Text")
	local dVer = Util.Create("TextLabel", {
		Text = "", TextSize = 12, Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Left, Parent = detailPane,
	})
	Theme.Bind(dVer, "TextColor3", "TextMuted")
	local dUpd = Util.Create("TextLabel", {
		Text = "", TextSize = 11, Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 0, 13), TextXAlignment = Enum.TextXAlignment.Left, Parent = detailPane,
	})
	Theme.Bind(dUpd, "TextColor3", "TextFaint")
	local dStatus = Util.Create("TextLabel", {
		Text = "", TextSize = 12, Position = UDim2.fromOffset(0, 90),
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Size = UDim2.new(1, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Left, Parent = detailPane,
	})

	local loadBtn = Util.Create("TextButton", {
		Text = "Load", TextSize = 13, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -2), Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 0, TextColor3 = Color3.new(1, 1, 1),
		FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold),
		Parent = detailPane,
	})
	Util.Round(loadBtn, 8)

	-- ── selection + load ──
	local selected, buttons = nil, {}

	local function paintButtons()
		for entry, rec in pairs(buttons) do
			local active = entry == selected
			Motion.Tween(rec.btn, { BackgroundTransparency = active and 0 or 1, BackgroundColor3 = Theme.Get("SurfaceHover") }, Motion.Easing.Soft)
			rec.label.TextColor3 = active and Theme.Get("Text") or Theme.Get("TextMuted")
		end
	end

	local detectedEntry -- set below, before any select() runs

	local function select(entry)
		selected = entry
		paintButtons()
		local st = statusFor(entry)
		dName.Text = entry.Name or ("Script " .. tostring(entry.Id or "?"))
		dVer.Text = "v" .. tostring(st.version)
		dUpd.Text = "Updated " .. tostring(st.updated)
		if st.patched then
			dStatus.Text = "Patched"
			dStatus.TextColor3 = Theme.Get("Error")
			loadBtn.Text = "Patched"
			loadBtn.BackgroundColor3 = Theme.Get("Surface")
			loadBtn.TextColor3 = Theme.Get("TextFaint")
			loadBtn.AutoButtonColor = false
		else
			dStatus.Text = "Active"
			dStatus.TextColor3 = Theme.Get("Success")
			loadBtn.Text = "Load"
			loadBtn.BackgroundColor3 = Theme.Get("Accent")
			loadBtn.TextColor3 = Color3.new(1, 1, 1)
			loadBtn.AutoButtonColor = true
		end
		detectedChip.Visible = (entry == detectedEntry)
		infoPane.Visible = false
		detailPane.Visible = true
	end

	local function runEntry(entry)
		if statusFor(entry).patched then return end -- Load disabled for patched scripts
		handle:Destroy()
		task.spawn(function()
			local ok, err = pcall(function()
				if type(entry.Callback) == "function" then
					entry.Callback()
				elseif type(entry.Source) == "string" then
					local fn = assert(loadstring(entry.Source))
					fn()
				elseif type(entry.Script) == "string" then
					local body = game:HttpGet(entry.Script)
					local fn = assert(loadstring(body))
					fn()
				else
					error("entry has no Callback, Source, or Script")
				end
			end)
			if not ok then warn("[Nectar Loader] '" .. tostring(entry.Name) .. "' failed: " .. tostring(err)) end
			if opts.OnLoad then task.spawn(opts.OnLoad, entry) end
		end)
	end

	maid:Add(loadBtn.MouseButton1Click:Connect(function()
		if selected then runEntry(selected) end
	end))

	-- ── list buttons (one entry each — adding a script is adding a line) ──
	for i, entry in ipairs(scripts) do
		local btn = Util.Create("TextButton", {
			Text = "", Size = UDim2.new(1, -10, 0, 34), BackgroundTransparency = 1,
			LayoutOrder = i, Parent = list,
		})
		Util.Round(btn, 8)
		local bm = maid:Add(Maid.new())
		local label = Util.Create("TextLabel", {
			Text = entry.Name or ("Script " .. tostring(entry.Id or i)), TextSize = 12.5,
			Position = UDim2.fromOffset(entry.Icon and 32 or 12, 0),
			Size = UDim2.new(1, entry.Icon and -38 or -18, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn,
		})
		label.TextColor3 = Theme.Get("TextMuted")
		if entry.Icon then
			local ic = Icons.Make(entry.Icon, 14, "TextMuted", btn)
			ic.AnchorPoint = Vector2.new(0, 0.5)
			ic.Position = UDim2.new(0, 10, 0.5, 0)
		end
		bm:Add(btn.MouseEnter:Connect(function()
			if entry ~= selected then
				Motion.Tween(btn, { BackgroundTransparency = 0.5, BackgroundColor3 = Theme.Get("SurfaceHover") }, Motion.Easing.Soft)
			end
		end))
		bm:Add(btn.MouseLeave:Connect(function()
			if entry ~= selected then
				Motion.Tween(btn, { BackgroundTransparency = 1 }, Motion.Easing.Soft)
			end
		end))
		bm:Add(btn.MouseButton1Click:Connect(function() select(entry) end))
		buttons[entry] = { btn = btn, label = label }
	end

	-- ── game detection: PlaceId match → auto-select + chip ──
	do
		local place = Info.GetPlaceId()
		for _, entry in ipairs(scripts) do
			local ids = entry.PlaceIds or (entry.PlaceId ~= nil and { entry.PlaceId }) or nil
			if ids then
				for _, pid in ipairs(ids) do
					if pid == place then detectedEntry = entry break end
				end
			end
			if detectedEntry then break end
		end
		if detectedEntry then select(detectedEntry) end
	end

	-- ── status API (dormant until Enabled = true) ──
	if api.Enabled == true and type(api.Url) == "string" then
		task.spawn(function()
			local ok, res = pcall(function() return game:HttpGet(api.Url) end)
			if not ok or type(res) ~= "string" then return end
			local ok2, rows = pcall(function() return HttpService:JSONDecode(res) end)
			if not ok2 or type(rows) ~= "table" then return end
			for _, row in ipairs(rows) do
				if row.id ~= nil then remote[tostring(row.id)] = row end
			end
			if selected and not destroyed then select(selected) end -- re-render with live data
		end)
	end

	-- async game-name refresh for the info pane (MarketplaceService can be slow)
	task.spawn(function()
		local name = Info.GetGameName()
		if not destroyed and gameValue then gameValue.Text = name end
	end)

	-- ── public handle ──
	function handle:GetSelected() return selected end
	function handle:Select(idOrName)
		for _, entry in ipairs(scripts) do
			if tostring(entry.Id) == tostring(idOrName) or entry.Name == idOrName then
				select(entry)
				return entry
			end
		end
		return nil
	end
	function handle:Load()
		if selected then runEntry(selected) end
	end
	return handle
end

--═══════════════════════════════════════════════════════════════════════════
-- § Nectar ─ public API surface
--═══════════════════════════════════════════════════════════════════════════
local Nectar = {
	Version = "1.0.0",
	Flags = Flags,
	Theme = Theme,
	Motion = Motion,
	State = State,
	Signal = Signal,
	Icons = Icons,
	Util = Util,
	Info = Info,
}

function Nectar:Bootstrap(opts)
	if opts == false then return end
	if opts == true or opts == nil then opts = {} end
	Bootstrapper.Play(opts) -- yields (task.wait) until the splash finishes
end

function Nectar:CreateLoader(opts)
	opts = opts or {}
	if opts.Bootstrapper then
		self:Bootstrap(opts.Bootstrapper == true and {} or opts.Bootstrapper)
	end
	return Loader.Create(opts)
end

function Nectar:CreateWindow(opts)
	opts = opts or {}
	if opts.Bootstrapper then
		self:Bootstrap(opts.Bootstrapper == true and {} or opts.Bootstrapper)
	end
	local window = Window._new(self, opts)
	if opts.Watermark ~= nil then
		local wmOpts = opts.Watermark
		if type(wmOpts) ~= "table" then wmOpts = { Enabled = wmOpts == true } end
		self:CreateWatermark(wmOpts)
	end
	return window
end

function Nectar:CreateWatermark(opts)
	if self._watermark then self._watermark:Destroy() end
	self._watermark = Watermark.Create(opts)
	return self._watermark
end

function Nectar:GetWatermark()
	return self._watermark
end

function Nectar:Notify(opts)
	return Notify.Push(opts)
end

function Nectar:SetTheme(name)
	Theme.SetTheme(name)
end

function Nectar:AddTheme(name, tokens, base)
	Theme.AddTheme(name, tokens, base)
end

function Nectar:SaveConfig(name)
	return Config.Save(name or "default")
end

function Nectar:LoadConfig(name)
	return Config.Load(name or "default")
end

function Nectar:ListConfigs()
	return Config.List()
end

function Nectar:DeleteConfig(name)
	return Config.Delete(name or "default")
end

function Nectar:GetFlag(flag)
	local handle = Flags[flag]
	return handle and handle.Get and handle:Get() or nil
end

function Nectar:Destroy()
	if Root.Gui then
		Root.Gui:Destroy()
		Root.Gui = nil
	end
end

return Nectar
