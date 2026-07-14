--- @since 26.5.6
--- Interactive trash manager for Yazi.
--- Browse the freedesktop trash across all volumes, multi-select, then
--- restore / permanently delete / empty. Backed by `gio` (glib), which gives
--- a unified cross-volume view and stable per-item handles (trash:/// URIs).

local function notify(level, s, ...)
	ya.notify({ title = "Trash Manager", content = string.format(s, ...), timeout = 4, level = level })
end

-- Format a byte count into a human-readable string.
local function fmt_size(n)
	if n < 1024 then
		return string.format("%d B", n)
	elseif n < 1024 * 1024 then
		return string.format("%.1f KiB", n / 1024)
	elseif n < 1024 * 1024 * 1024 then
		return string.format("%.1f MiB", n / (1024 * 1024))
	else
		return string.format("%.1f GiB", n / (1024 * 1024 * 1024))
	end
end

-- Decode a percent-encoded URI component.
local function uri_decode(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Case-insensitive plain substring match against the original path.
local function filter_items(items, q)
	if not q or q == "" then
		return items
	end
	local ql = q:lower()
	local out = {}
	for _, it in ipairs(items or {}) do
		if it.path:lower():find(ql, 1, true) then
			out[#out + 1] = it
		end
	end
	return out
end

-- ── State (mutated only inside ya.sync, which can touch the UI) ──────────────

local toggle_ui = ya.sync(function(self)
	if self.children then
		Modal:children_remove(self.children)
		self.children = nil
	else
		self.cursor = self.cursor or 0
		self.offset = self.offset or 0
		self.children = Modal:children_add(self, 10)
	end
	ui.render()
end)

local set_items = ya.sync(function(self, items)
	self.items = items
	self.marks = {}
	self.visible = filter_items(items, self.filter)
	self.cursor = ya.clamp(0, self.cursor or 0, math.max(0, #self.visible - 1))
	ui.render()
end)

local set_filter = ya.sync(function(self, q)
	self.filter = (q and q ~= "") and q or nil
	self.visible = filter_items(self.items or {}, self.filter)
	self.marks = self.marks or {}
	self.cursor = ya.clamp(0, self.cursor or 0, math.max(0, #self.visible - 1))
	self.offset = 0
	ui.render()
end)

local move = ya.sync(function(self, delta)
	local n = #(self.visible or {})
	self.cursor = n == 0 and 0 or ya.clamp(0, (self.cursor or 0) + delta, n - 1)
	ui.render()
end)

local set_cursor = ya.sync(function(self, idx)
	local n = #(self.visible or {})
	self.cursor = n == 0 and 0 or ya.clamp(0, idx, n - 1)
	ui.render()
end)

local toggle_mark = ya.sync(function(self)
	local n = #(self.visible or {})
	if n == 0 then
		return
	end
	self.marks = self.marks or {}
	local it = self.visible[(self.cursor or 0) + 1]
	if it then
		self.marks[it.uri] = (not self.marks[it.uri]) or nil
		self.cursor = ya.clamp(0, (self.cursor or 0) + 1, n - 1) -- advance for fast multi-select
	end
	ui.render()
end)

local mark_all = ya.sync(function(self, on)
	self.marks = {}
	if on then
		for _, it in ipairs(self.visible or {}) do
			self.marks[it.uri] = true
		end
	end
	ui.render()
end)

-- Forward declarations: `set_pending` and the action handlers both need to
-- call `get_targets`/`get_current` from inside `ya.sync` closures, so the
-- locals must already be visible (i.e. declared earlier) when those closures
-- are built — otherwise Lua treats the names as globals (== nil) and the call
-- silently fails.
local get_targets
local get_current

local get_pending = ya.sync(function(self)
	return self.pending
end)

-- Items the next action applies to: every marked row, or the row under the
-- cursor when nothing is marked.
get_targets = ya.sync(function(self)
	local out = {}
	if self.marks and next(self.marks) ~= nil then
		for _, it in ipairs(self.visible or {}) do
			if self.marks[it.uri] then
				out[#out + 1] = it
			end
		end
	else
		local it = (self.visible or {})[(self.cursor or 0) + 1]
		if it then
			out[1] = it
		end
	end
	return out
end)

get_current = ya.sync(function(self)
	return (self.visible or {})[(self.cursor or 0) + 1]
end)

local set_pending = ya.sync(function(self, p)
	self.pending = p
	self.pending_n = #get_targets()
	ui.render()
end)

-- ── Trash backend (gio) ──────────────────────────────────────────────────────

--- Read every trashed item across all volumes.
--- @return { uri: string, path: string, date: string }[]
local function load_items()
	local items = {}
	local out = Command("gio")
		:arg({ "list", "-a", "standard::type,trash::deletion-date,trash::orig-path", "trash:///" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		for line in out.stdout:gmatch("[^\r\n]+") do
			local trash_name, raw_size, ftype, attrs = line:match("^(.-)\t(%d+)\t%((%w+)%)%c(.+)$")
			if trash_name and attrs then
				local uri = "trash:///" .. trash_name
				local path = attrs:match("trash::orig%-path=(.-)%s+trash::")
				local date = attrs:match("trash::deletion%-date=(%S+)%s*$")
				if path and date then
					items[#items + 1] = {
						uri = uri,
						path = path,
						date = (date:gsub("T", " ")),
						size = tonumber(raw_size) or 0,
						is_dir = (ftype == "directory"),
					}
				end
			end
		end
	end
	return items
end

local function run_each(targets, args_for)
	local ok, fail, err = 0, 0, nil
	for _, it in ipairs(targets) do
		local out = Command("gio"):arg(args_for(it)):stdout(Command.PIPED):stderr(Command.PIPED):output()
		if out and out.status and out.status.success then
			ok = ok + 1
		else
			fail = fail + 1
			if out and out.stderr ~= "" then
				err = out.stderr
			end
		end
	end
	return ok, fail, err
end

local function perform_restore()
	local targets = get_targets()
	if #targets == 0 then
		return
	end
	local ok, fail, err = run_each(targets, function(it)
		return { "trash", "--restore", it.uri }
	end)
	set_items(load_items())
	if fail == 0 then
		notify("info", "Restored %d item%s", ok, ok == 1 and "" or "s")
	else
		notify("error", "Restored %d, failed %d%s", ok, fail, err and (": " .. err:gsub("%s+", " ")) or "")
	end
end

local function perform_delete()
	local targets = get_targets()
	if #targets == 0 then
		return
	end
	local ok, fail, err = run_each(targets, function(it)
		return { "remove", "-f", it.uri }
	end)
	set_items(load_items())
	if fail == 0 then
		notify("info", "Permanently deleted %d item%s", ok, ok == 1 and "" or "s")
	else
		notify("error", "Deleted %d, failed %d%s", ok, fail, err and (": " .. err:gsub("%s+", " ")) or "")
	end
end

local function perform_empty()
	local out = Command("gio"):arg({ "trash", "--empty" }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	set_items(load_items())
	if out and out.status and out.status.success then
		notify("info", "Trash emptied")
	else
		notify("error", "Failed to empty trash%s", (out and out.stderr ~= "") and (": " .. out.stderr:gsub("%s+", " ")) or "")
	end
end

local function get_target_path(out)
	local target = out.stdout:match("standard::target%-uri:%s*file://(.+)")
	return target and uri_decode(target) or nil
end

local function perform_view()
	local it = get_current()
	if not it then
		return
	end
	local out = Command("gio"):arg({ "info", it.uri }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not (out and out.status and out.status.success) then
		notify("error", "Can't inspect %s%s", it.path, out and out.stderr ~= "" and (": " .. out.stderr:gsub("%s+", " ")) or "")
		return
	end
	local raw_size = tonumber(out.stdout:match("standard::size:%s*(%S+)") or out.stdout:match("size:%s*(%S+)") or "")
	local size = raw_size and fmt_size(raw_size) or "?"
	local ctype = out.stdout:match("standard::content%-type:%s*(%S+)") or "?"
	local ftype = out.stdout:match("type:%s*(%S+)") or "?"
	notify("info", "%s\nType: %s\nMIME: %s\nSize: %s\nDeleted: %s", it.path, ftype, ctype, size, it.date)

	local path = get_target_path(out)
	if not path then
		return
	end
	local thumb = "/tmp/trash_thumb.jpg"
	local gen = nil
	if ctype:match("^video/") then
		gen = Command("ffmpeg"):arg({ "-i", path, "-ss", "00:00:01", "-vframes", "1", "-q:v", "2", "-y", thumb })
	elseif ctype:match("^image/") then
		gen = Command("convert"):arg({ path, "-resize", "256x256", thumb })
	end
	if gen then
		local p = gen:stdout(Command.PIPED):stderr(Command.PIPED):start()
		if p then
			p:wait()
			Command("xdg-open"):arg({ thumb }):start()
		end
	end
end

-- ── Component ────────────────────────────────────────────────────────────────

local M = {
	keys = {
		{ on = "q", run = "quit" },
		{ on = "<Esc>", run = "quit" },

		{ on = "k", run = "up" },
		{ on = "<Up>", run = "up" },
		{ on = "j", run = "down" },
		{ on = "<Down>", run = "down" },
		{ on = "g", run = "top" },
		{ on = "G", run = "bottom" },

		{ on = "<Space>", run = "toggle" },
		{ on = "a", run = "all" },
		{ on = "c", run = "clear" },

		{ on = "r", run = "restore" },
		{ on = "d", run = "delete" },
		{ on = "e", run = "empty" },
		{ on = "v", run = "view" },
		{ on = "/", run = "filter" },
		{ on = "\\", run = "clear_filter" },
	},
}

function M:new(area)
	self:layout(area)
	return self
end

function M:layout(area)
	local v = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({
			ui.Constraint.Percentage(8),
			ui.Constraint.Percentage(84),
			ui.Constraint.Percentage(8),
		})
		:split(area)
	local h = ui.Layout()
		:direction(ui.Layout.HORIZONTAL)
		:constraints({
			ui.Constraint.Percentage(8),
			ui.Constraint.Percentage(84),
			ui.Constraint.Percentage(8),
		})
		:split(v[2])
	self._area = h[2]
end

function M:reflow()
	return { self }
end

function M:redraw()
	local area = self._area
	if not area then
		return {}
	end
	local items = self.visible or {}
	local marks = self.marks or {}

	local selected = 0
	for _ in pairs(marks) do
		selected = selected + 1
	end

	local inner = area:pad(ui.Pad(1, 2, 1, 2))
	local chunks = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({ ui.Constraint.Min(1), ui.Constraint.Length(2) })
		:split(inner)
	local list_area, help_area = chunks[1], chunks[2]

	-- Keep the cursor inside the viewport.
	local h = math.max(1, list_area.h or 1)
	local cur = self.cursor or 0
	self.offset = self.offset or 0
	if cur < self.offset then
		self.offset = cur
	elseif cur >= self.offset + h then
		self.offset = cur - h + 1
	end
	if self.offset < 0 then
		self.offset = 0
	end

	local lines = {}
	if #items == 0 then
		lines[1] = ui.Line("  (trash is empty)"):style(ui.Style():fg("darkgray"))
	else
		for i = self.offset + 1, math.min(#items, self.offset + h) do
			local it = items[i]
			local is_cur = (i - 1) == cur
			local mk = marks[it.uri]
			local box = mk and "[x]" or "[ ]"
			local arrow = is_cur and ">" or " "
			local style
			if is_cur then
				style = ui.Style():fg("blue"):bold()
			elseif mk then
				style = ui.Style():fg("green")
			else
				style = ui.Style()
			end
			local name = it.path:match("([^/]+)$") or it.path
			if it.is_dir then
				name = name .. "/"
			end
			lines[#lines + 1] = ui.Line(string.format("%s %s %3d  %s  %10s  %s", arrow, box, i, it.date, fmt_size(it.size), name)):style(style)
		end
	end

	local total = #(self.items or {})
	local flt = self.filter and string.format("  filter=%q", self.filter) or ""
	local title = string.format(
		" Trash Manager — %d item%s (%d shown, %d selected)%s ",
		total,
		total == 1 and "" or "s",
		#items,
		selected,
		flt
	)

	-- Two-line footer so nothing gets clipped at the right border.
	local help_text
	if self.pending == "delete" then
		help_text = ui.Text({
			ui.Line(string.format(" Press d again to PERMANENTLY DELETE %d item%s — any other key cancels", self.pending_n or 0, (self.pending_n or 0) == 1 and "" or "s"))
				:style(ui.Style():fg("red"):bold()),
			ui.Line(""),
		})
	elseif self.pending == "empty" then
		help_text = ui.Text({
			ui.Line(" Press e again to EMPTY ENTIRE trash — any other key cancels"):style(ui.Style():fg("red"):bold()),
			ui.Line(""),
		})
	else
		local nav = ui.Style():fg("darkgray")
		local act = ui.Style():fg("yellow")
		help_text = ui.Text({
			ui.Line(" j/k move   g/G top/end   <Space> select   a all   c clear   / filter   \\ clear-filter"):style(nav),
			ui.Line(" r restore   d delete   e empty   v preview   q quit"):style(act),
		})
	end

	return {
		ui.Clear(area),
		ui.Border(ui.Edge.ALL)
			:area(area)
			:type(ui.Border.ROUNDED)
			:style(ui.Style():fg("blue"))
			:title(ui.Line(title):align(ui.Align.CENTER)),
		ui.Text(lines):area(list_area),
		help_text:area(help_area),
	}
end

function M:entry()
	toggle_ui()
	set_items(load_items())

	while true do
		local idx = ya.which({ cands = self.keys, silent = true })
		local cand = idx and self.keys[idx]
		local run = cand and cand.run

		if run == "quit" then
			set_pending(nil)
			toggle_ui()
			break
		elseif run == "delete" or run == "empty" then
			if get_pending() == run then
				set_pending(nil)
				if run == "delete" then
					perform_delete()
				else
					perform_empty()
				end
			else
				set_pending(run) -- arm; require a second press to confirm
			end
		elseif run then
			if get_pending() then
				set_pending(nil) -- any other mapped key cancels a pending confirm
			elseif run == "up" then
				move(-1)
			elseif run == "down" then
				move(1)
			elseif run == "top" then
				set_cursor(0)
			elseif run == "bottom" then
				set_cursor(math.huge)
			elseif run == "toggle" then
				toggle_mark()
			elseif run == "all" then
				mark_all(true)
			elseif run == "clear" then
				mark_all(false)
			elseif run == "restore" then
				perform_restore()
			elseif run == "view" then
				perform_view()
			elseif run == "filter" then
				local input = ya.input {
					title = "Filter (substring on path, Enter to apply, Esc to keep current):",
					value = self.filter or "",
					pos = { "bottom-center", y = 1, w = 60 },
					realtime = true,
					debounce = 0.05,
				}
				while true do
					local value, event = input:recv()
					if event == 1 or event == 3 then
						set_filter(value)
						if event == 1 then
							break
						end
					else
						break
					end
				end
			elseif run == "clear_filter" then
				set_filter("")
			end
		end
	end
end

function M:click() end
function M:scroll() end
function M:touch() end

return M
