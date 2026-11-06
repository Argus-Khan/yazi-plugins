--- @since 26.5.6
--- Archive toolkit for Yazi: extract, compress, and preview.
--- Backed by `7z` (and `tar` for non-7z formats).
---
--- Must stay async: `ya.which` (format dropdown) only captures keys in async
--- plugins. A sync entry lets <Enter> fall through to the manager `open`.
--- Because entry is async, do not call `ya.async` here (sync-entry only).

local M = {}
local TITLE = "Archive"

-- ── Helpers ────────────────────────────────────────────────────────────────

local archive_exts = {
	["zip"] = true,
	["7z"] = true,
	["rar"] = true,
	["tar"] = true,
	["gz"] = true,
	["xz"] = true,
	["bz2"] = true,
	["zst"] = true,
	["tgz"] = true,
	["txz"] = true,
	["tbz2"] = true,
	["tzst"] = true,
	["xapk"] = true,
	["iso"] = true,
}

local function is_archive(name)
	local ext = name:match("%.([^%.]+)$")
	if not ext then
		return false
	end
	return archive_exts[ext:lower()] or false
end

local function url_to_path(url)
	local path = type(url) == "userdata" and url.path
	local s = tostring(path or url)
	if s:sub(1, 7) == "file://" then
		return s:sub(8)
	end
	return s
end

local function shell_quote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function notify(content, level)
	ya.notify({ title = TITLE, content = content, timeout = 3, level = level or "info" })
end

local function has_cmd(name)
	local out = Command("sh")
			:arg({ "-c", "command -v " .. shell_quote(name) .. " >/dev/null 2>&1" })
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:output()
	return out and out.status and out.status.success
end

-- Runs in the async entry context (do not wrap with ya.async — that API is
-- sync-entry only). Command I/O yields, so the UI stays responsive via ya.task.
local function run_archive(command, action, target)
	local task = ya.task("custom", {
		pool = "plugin",
		scope = rt.scope(),
		track = true,
		progress = true,
	}):name(action .. " " .. target):spawn()

	local child = command
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
	if not child then
		task:fail(action .. " could not be started")
		notify(action .. " could not be started", "error")
		return
	end

	local last_percent = -1
	local reported_workload = false
	while true do
		local line, event = child:read_line()
		if event == 2 then
			break
		elseif event ~= 0 and event ~= 1 then
			task:fail(action .. " failed while reading progress")
			notify(action .. " failed while reading progress", "error")
			return
		end

		if line then
			local text = tostring(line)
			for value in text:gmatch("(%d?%d?%d)%%") do
				local percent = tonumber(value)
				if percent and percent > last_percent then
					local processed = percent - math.max(last_percent, 0)
					last_percent = percent
					task:progress({
						total = reported_workload and 0 or 1,
						workload = reported_workload and 0 or 100,
						processed = processed,
					})
					reported_workload = true
				end
			end
		end
	end

	local result = child:wait_with_output()
	if not result or not result.status or not result.status.success then
		local error_text = result and result.stderr and tostring(result.stderr):gsub("%s+$", "")
		task:fail(error_text or action .. " failed")
		notify(
			string.format("%s failed%s", action, error_text and error_text ~= "" and ": " .. error_text or ""),
			"error"
		)
		return
	end

	task:progress({
		total = reported_workload and 0 or 1,
		success = 1,
		workload = reported_workload and 0 or 100,
		processed = reported_workload and math.max(0, 100 - math.max(last_percent, 0)) or 100,
	})
	task:succeed()
	notify(action .. " complete", "info")
end

-- ── Compress formats ───────────────────────────────────────────────────────

local COMPRESS_FORMATS = {
	["7z"]      = { ext = "7z", tool = "7z", args = function(out, files) return { "a", "-bsp1", out, table.unpack(files) } end },
	["zip"]     = { ext = "zip", tool = "7z", args = function(out, files) return { "a", "-tzip", "-bsp1", out, table.unpack(files) } end },
	["rar"]     = { ext = "rar", tool = "rar", args = function(out, files) return { "a", out, table.unpack(files) } end },
	["tar"]     = { ext = "tar", tool = "tar", args = function(out, files) return { "-cf", out, table.unpack(files) } end },
	["tar.gz"]  = { ext = "tar.gz", tool = "tar", args = function(out, files) return { "-czf", out, table.unpack(files) } end },
	["tar.bz2"] = { ext = "tar.bz2", tool = "tar", args = function(out, files) return { "-cjf", out, table.unpack(files) } end },
	["tar.xz"]  = { ext = "tar.xz", tool = "tar", args = function(out, files) return { "-cJf", out, table.unpack(files) } end },
	["tar.zst"] = { ext = "tar.zst", tool = "tar", args = function(out, files) return { "--zstd", "-cf", out, table.unpack(files) } end },
}

local DEFAULT_FORMAT = "7z"

-- ── Navigable dropdown ──────────────────────────────────────────────────────
-- All state lives on the sync state object (the first arg of ya.sync closures).
-- Component methods installed on M are called with self = state at render time.

local DD_KEYS = {
	{ on = "k",       run = "up" },
	{ on = "<Up>",    run = "up" },
	{ on = "j",       run = "down" },
	{ on = "<Down>",  run = "down" },
	{ on = "l",       run = "select" },
	{ on = "<Enter>", run = "select" },
	{ on = "<Esc>",   run = "cancel" },
	{ on = "q",       run = "cancel" },
}

local dropdown_init = ya.sync(function(state, title, options)
	state.dd_title = title
	state.dd_options = options
	state.dd_cursor = 0
	state.dd_offset = 0
	state.dd_children = nil
end)

local dropdown_toggle = ya.sync(function(state)
	if state.dd_children then
		Modal:children_remove(state.dd_children)
		state.dd_children = nil
	else
		state.dd_cursor = state.dd_cursor or 0
		state.dd_offset = state.dd_offset or 0
		state.dd_children = Modal:children_add(state, 11)
	end
	ui.render()
end)

local dropdown_move = ya.sync(function(state, delta)
	state.dd_cursor = ya.clamp(0, (state.dd_cursor or 0) + delta, #state.dd_options - 1)
	ui.render()
end)

local dropdown_get_selection = ya.sync(function(state)
	return state.dd_options[state.dd_cursor + 1] and state.dd_options[state.dd_cursor + 1].value
end)

-- Component methods: yazi calls these with self = state. They render dropdown only when state.dd_title is set.
function M:new(area)
	self:layout(area)
	return self
end

function M:layout(area)
	local h = math.min(#(self.dd_options or {}) + 4, area.h - 4)
	local w = math.min(40, area.w - 4)
	local v = ui.Layout()
			:direction(ui.Layout.VERTICAL)
			:constraints({
				ui.Constraint.Min(0),
				ui.Constraint.Length(h),
				ui.Constraint.Min(0),
			})
			:split(area)
	local hz = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Min(0),
				ui.Constraint.Length(w),
				ui.Constraint.Min(0),
			})
			:split(v[2])
	self.dd_area = hz[2]
end

function M:reflow()
	return { self }
end

function M:redraw()
	local area = self.dd_area
	if not area or not self.dd_options then
		return {}
	end

	local inner = area:pad(ui.Pad(1, 1, 1, 1))
	local h = inner.h
	local cur = self.dd_cursor or 0
	self.dd_offset = self.dd_offset or 0
	if cur < self.dd_offset then
		self.dd_offset = cur
	elseif cur >= self.dd_offset + h then
		self.dd_offset = cur - h + 1
	end

	local lines = {}
	for i = self.dd_offset + 1, math.min(#self.dd_options, self.dd_offset + h) do
		local opt = self.dd_options[i]
		local is_cur = (i - 1) == cur
		local prefix = is_cur and "> " or "  "
		local style = is_cur and ui.Style():fg("blue"):bold() or ui.Style()
		lines[#lines + 1] = ui.Line(prefix .. opt.label):style(style)
	end

	return {
		ui.Clear(area),
		ui.Border(ui.Edge.ALL)
				:area(area)
				:type(ui.Border.ROUNDED)
				:style(ui.Style():fg("yellow"))
				:title(ui.Line(" " .. (self.dd_title or "") .. " "):align(ui.Align.CENTER)),
		ui.Text(lines):area(inner),
	}
end

function M:click() end

function M:scroll() end

function M:touch() end

-- Show dropdown, block until user selects, return option.value or nil.
local function dropdown_select(title, options)
	dropdown_init(title, options)
	dropdown_toggle()
	ya.dbg("[archive-manager] dropdown opened")

	local selected = nil
	while true do
		local idx = ya.which({ cands = DD_KEYS, silent = true })
		ya.dbg("[archive-manager] ya.which returned", idx)
		-- nil => user cancelled / which aborted (do not spin forever)
		if not idx then
			break
		end
		local cand = DD_KEYS[idx]
		local run = cand and cand.run
		ya.dbg("[archive-manager] run =", run)

		if run == "cancel" then
			break
		elseif run == "select" then
			selected = dropdown_get_selection()
			ya.dbg("[archive-manager] selected =", selected)
			break
		elseif run == "up" then
			dropdown_move(-1)
		elseif run == "down" then
			dropdown_move(1)
		end
	end

	dropdown_toggle()
	return selected
end

-- Get selected/hovered file paths + current cwd via ya.sync so `cx` is available.
-- cx.active.selected may be a sequence {idx=Url} or a set {Url=true} depending on yazi version.
local get_targets = ya.sync(function()
	local tab = cx.active
	local files = {}

	if tab.selected then
		for k, v in pairs(tab.selected) do
			local url
			if type(v) == "boolean" then
				url = k
			else
				url = v
			end
			table.insert(files, url_to_path(url))
		end
	end

	if #files == 0 and tab.current.hovered then
		table.insert(files, url_to_path(tab.current.hovered.url))
	end

	return files, url_to_path(tab.current.cwd)
end)

-- ── Extract ────────────────────────────────────────────────────────────────

local function perform_extract()
	local files, _ = get_targets()

	local archives = {}
	for _, path in ipairs(files) do
		if is_archive(path) then
			table.insert(archives, path)
		end
	end

	if #archives == 0 then
		notify("No archive files selected", "info")
		return
	end

	ya.emit("escape", { visual = true })
	notify(string.format("Extracting %d archive%s", #archives, #archives > 1 and "s" or ""))

	for _, path in ipairs(archives) do
		local dir = path:match("^(.*)%.%w+$") or (path .. "_extracted")
		run_archive(
			Command("7z"):arg({ "x", "-bsp1", "-y", "-o" .. dir, path }),
			"Extracting",
			path:match("([^/]+)$") or path
		)
	end
end

-- ── Compress ───────────────────────────────────────────────────────────────

local function perform_compress(format)
	format = format or DEFAULT_FORMAT
	local fmt = COMPRESS_FORMATS[format]
	if not fmt then
		notify("Unknown format: " .. format, "error")
		return
	end

	if not has_cmd(fmt.tool) then
		notify(fmt.tool .. " is not installed", "error")
		return
	end
	if format == "tar.zst" and not has_cmd("zstd") then
		notify("zstd is not installed", "error")
		return
	end

	local files, cwd = get_targets()

	if #files == 0 then
		notify("No files selected", "info")
		return
	end

	-- Pick output path: <cwd>/<basename-of-first-item>.<ext>, auto-increment on collision.
	local base = files[1]:match("([^/]+)$") or "archive"
	base = base:match("^(.+)%.%w+$") or base
	local out = cwd .. "/" .. base .. "." .. fmt.ext
	local n = 1
	while fs.cha(Url(out)) do
		out = string.format("%s/%s_%d.%s", cwd, base, n, fmt.ext)
		n = n + 1
	end

	local args = fmt.args(out, files)

	ya.emit("escape", { visual = true })
	notify(string.format("Compressing %d item%s as %s", #files, #files == 1 and "" or "s", format))
	run_archive(
		Command(fmt.tool):arg(args),
		"Compressing",
		out:match("([^/]+)$") or out
	)
end

-- ── Preview (peek/seek) ────────────────────────────────────────────────────

function M:peek(job)
	local path = url_to_path(job.file.url)
	if not is_archive(path) then
		return require("code"):peek(job)
	end

	local child = Command("7z")
			:arg({ "l", "-ba", path })
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
	if not child then
		return require("code"):peek(job)
	end

	local skip = job.skip or 0
	local limit = job.area.h
	local i, lines = 0, ""
	repeat
		local line, event = child:read_line()
		if event == 1 then
			child:start_kill()
			return require("code"):peek(job)
		elseif event ~= 0 then
			break
		end
		i = i + 1
		if i > skip then
			lines = lines .. line .. "\n"
		end
	until i >= skip + limit

	child:start_kill()
	if skip > 0 and i < skip + limit then
		ya.emit("peek", { math.max(0, i - limit), only_if = job.file.url, upper_bound = true })
	else
		ya.preview_widget(
			job,
			ui.Text.parse(lines):area(job.area):wrap(ui.Wrap.NO)
		)
	end
end

function M:seek(job)
	require("code"):seek(job)
end

-- ── Entry ──────────────────────────────────────────────────────────────────

function M:entry(job)
	job = job or {}
	local args = job.args or {}
	local action = args[1]
	if action == "compress" or args.compress then
		local format = args.format or args[2]
		if not format then
			format = dropdown_select("Compress format", {
				{ label = "zip",     value = "zip" },
				{ label = "tar",     value = "tar" },
				{ label = "7z",      value = "7z" },
				{ label = "rar",     value = "rar" },
				{ label = "tar.gz",  value = "tar.gz" },
				{ label = "tar.bz2", value = "tar.bz2" },
				{ label = "tar.xz",  value = "tar.xz" },
				{ label = "tar.zst", value = "tar.zst" },
			})
		end
		if format then
			perform_compress(format)
		end
		return
	end
	perform_extract()
end

return M
