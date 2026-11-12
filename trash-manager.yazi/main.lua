--- @since 26.5.6
--- Interactive trash manager for Yazi.
--- Browse the freedesktop trash across all volumes, multi-select, then
--- restore / permanently delete / empty. Backed by `gio` (glib), which gives
--- a unified cross-volume view and stable per-item handles (trash:/// URIs).
---
--- Also provides "safe-remove": trash files from the file browser, using
--- yazi's native remove for local drives and `gio remove` for MTP/network.
---
--- The "undo last trash" action is inspired by boydaihungst's `restore` plugin
--- (MIT, https://github.com/boydaihungst/restore), reimplemented on top of
--- `gio trash --restore` so it shares the same backend as the rest of the
--- manager. Original copyright (c) 2024 boydaihungst.

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

-- ── Safe Remove (trash files from the file browser) ─────────────────────────

local MTP_PATTERNS = {
	"/run/user/%d+/gvfs/mtp:host=",
	"ExternalDrives/mtp:host=",
}

local function is_remote(path)
	for _, pat in ipairs(MTP_PATTERNS) do
		if path:match(pat) then
			return true
		end
	end
	if path:match("^/run/user/%d+/gvfs/") then
		return true
	end
	return false
end

local function url_to_path(url)
	local s = tostring(url)
	if s:sub(1, 7) == "file://" then
		return s:sub(8)
	end
	return s
end

-- Resolve symlinks so classification sees the real target: yazi hands us
-- ~/ExternalDrives/<link> paths, whose targets live under /run/user/*/gvfs/.
local function resolve_path(path)
	local out = Command("realpath"):arg({ "-m", path }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if out and out.status and out.status.success and out.stdout and out.stdout ~= "" then
		return (out.stdout:gsub("%s+$", ""))
	end
	return path
end

--- Get selected/hovered files from the file browser (not the modal UI).
local get_file_targets = ya.sync(function()
	local tab = cx.active
	local files = {}
	if tab.selected then
		for k, v in pairs(tab.selected) do
			local url = type(v) == "boolean" and k or v
			files[#files + 1] = { path = url_to_path(url), name = tostring(url):match("([^/]+)$") or "?" }
		end
	end
	if #files == 0 and tab.current.hovered then
		local url = tab.current.hovered.url
		files[1] = { path = url_to_path(url), name = tostring(url):match("([^/]+)$") or "?" }
	end
	return files
end)

-- Active tab's cwd as a plain path (safe-remove needs it before deleting).
local get_active_cwd = ya.sync(function()
	return url_to_path(tostring(cx.active.current.cwd))
end)

local function perform_safe_remove(permanent)
	local files = get_file_targets()
	if #files == 0 then
		return
	end

	-- Split: remote (MTP/network) vs local.
	-- Classify on the RESOLVED path: without this a gvfs target (via the
	-- ExternalDrives symlink) counts as local, yazi's native trash runs, and
	-- the trash crate looks for .Trash-1000 at the read-only gvfs root (ENOENT).
	local remote = {}
	for _, f in ipairs(files) do
		if is_remote(resolve_path(f.path)) then
			remote[#remote + 1] = f
		end
	end

	-- Trash is impossible on gvfs mounts (GLib refuses "system internal"
	-- mounts, `gio remove` can't recurse), so safe-remove on a remote path
	-- falls back to a permanent rm. Ask before deleting anything.
	if #remote > 0 and not permanent then
		local sure = ya.confirm({
			title = ui.Line("No trash on network/phone mounts"):style(ui.Style():fg("yellow"):bold()),
			body = ui.Text({
				ui.Line(""),
				ui.Line(string.format(
					"Permanently delete %d file%s? There is no undo on remote mounts.",
					#remote, #remote == 1 and "" or "s"
				)),
			}),
			pos = { "center", w = 64, h = 8 },
		})
		if not sure then
			return
		end
	end

	-- Never strand our own cwd: if the current dir sits inside a target,
	-- move up to the outermost target's parent before deleting (our rm
	-- bypasses yazi's own deleted-cwd recovery, so shell keymaps would
	-- otherwise error with getcwd until yazi notices on its own).
	local cwd = get_active_cwd()
	local inside
	for _, f in ipairs(remote) do
		if (cwd == f.path or cwd:sub(1, #f.path + 1) == f.path .. "/") and (not inside or #f.path < #inside) then
			inside = f.path
		end
	end
	if inside then
		local parent = inside:match("^(.*)/[^/]+$")
		if parent == "" then
			parent = "/"
		end
		if parent then
			ya.emit("cd", { parent })
		end
	end

	-- Local files: yazi handles it natively.
	-- shortcut: yazi's `remove` acts on every selected file, so a mixed
	-- local+remote selection still feeds the remote ones to native trash;
	-- upgrade if yazi ever gains a per-file-scoped remove.
	if #remote < #files then
		ya.emit("remove", permanent and { "--permanently" } or {})
	end

	-- Remote (MTP/network) files: permanent rm (confirmed above for safe-remove).
	if #remote > 0 then
		local ok, fail = 0, 0
		for _, f in ipairs(remote) do
			local out = Command("rm")
				:arg({ "-rf", "--", f.path })
				:stdout(Command.PIPED)
				:stderr(Command.PIPED)
				:output()
			if out and out.status and out.status.success then
				ok = ok + 1
			else
				fail = fail + 1
				local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
				notify("error", "Failed to delete %s: %s", f.name, err ~= "" and err or "unknown error")
			end
		end
		if fail == 0 then
			notify("info", "Permanently deleted %d file%s", ok, ok == 1 and "" or "s")
		elseif ok > 0 then
			notify("warn", "Deleted %d, failed %d", ok, fail)
		end
	end
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

-- Find the most recently trashed batch: all items sharing the latest deletion date.
---@return table[]|nil batch, string|nil latest_date
local function latest_batch()
	local items = load_items()
	if #items == 0 then
		return nil, nil
	end
	local latest = nil
	for _, it in ipairs(items) do
		if not latest or it.date > latest then
			latest = it.date
		end
	end
	local batch = {}
	for _, it in ipairs(items) do
		if it.date == latest then
			batch[#batch + 1] = it
		end
	end
	return batch, latest
end

local function perform_undo_last()
	local batch, latest = latest_batch()
	if not batch then
		notify("info", "Trash is empty, nothing to undo")
		return
	end

	local preview_max = math.min(8, #batch)
	local preview = { ui.Line("") }
	for i = 1, preview_max do
		preview[#preview + 1] = ui.Line("  " .. batch[i].path)
	end
	if #batch > preview_max then
		preview[#preview + 1] = ui.Line(string.format("  ... and %d more", #batch - preview_max))
	end

	local ok = ya.confirm({
		title = ui.Line("Undo last trash"):style(ui.Style():fg("yellow"):bold()),
		body = ui.Text({
			ui.Line(""),
			ui.Line(string.format(
				"Restore %d item%s from %s?",
				#batch, #batch == 1 and "" or "s", latest
			)),
			table.unpack(preview),
		}),
		pos = { "center", w = 70, h = math.min(20, #batch + 5) },
	})
	if not ok then
		return
	end

	local restored_ok, restored_fail = 0, 0
	for _, it in ipairs(batch) do
		local out = Command("gio")
			:arg({ "trash", "--restore", it.uri })
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:output()
		if out and out.status and out.status.success then
			restored_ok = restored_ok + 1
		else
			restored_fail = restored_fail + 1
		end
	end

	if restored_fail == 0 then
		notify("info", "Restored %d item%s", restored_ok, restored_ok == 1 and "" or "s")
	else
		notify("error", "Restored %d, failed %d", restored_ok, restored_fail)
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
		{ on = "u", run = "undo_last" },
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
			ui.Line(" r restore   u undo-last   d delete   e empty   v preview   q quit"):style(act),
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

function M:entry(job)
	job = job or {}
	-- Direct, UI-less entry: restore the most recently trashed batch.
	if job.args and job.args[1] == "undo-last" then
		perform_undo_last()
		return
	end
	-- Direct, UI-less entry: trash/delete files from the file browser.
	if job.args and job.args[1] == "safe-remove" then
		perform_safe_remove(job.args[2] == "--permanent")
		return
	end
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
			elseif run == "undo_last" then
				perform_undo_last()
				set_items(load_items())
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
