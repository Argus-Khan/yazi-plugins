--- @since 26.5.6
--- Wrapper around yazi's `remove` that handles MTP mounts gracefully.
--- MTP doesn't support .Trash, so `gio trash` fails. This plugin detects
--- MTP paths (including through symlinks) and uses `gio remove` for those.

local M = {}

local MTP_PATTERNS = {
	"/run/user/%d+/gvfs/mtp:host=",
	"ExternalDrives/mtp:host=",
}

local function is_mtp(path)
	for _, pat in ipairs(MTP_PATTERNS) do
		if path:match(pat) then
			return true
		end
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

local function notify(level, s, ...)
	ya.notify({ title = "Safe Remove", content = string.format(s, ...), timeout = 3, level = level })
end

local get_targets = ya.sync(function()
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

function M:entry(job)
	local args = job.args or {}
	local permanent = false
	for _, a in ipairs(args) do
		if a == "--permanent" then
			permanent = true
		end
	end

	local files = get_targets()
	if #files == 0 then
		return
	end

	local ok, fail = 0, 0
	for _, f in ipairs(files) do
		local cmd, verb
		if permanent or is_mtp(f.path) then
			cmd = { "remove", f.path }
			verb = "delete"
		else
			cmd = { "trash", f.path }
			verb = "trash"
		end
		local out = Command("gio")
			:arg(cmd)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:output()
		if out and out.status and out.status.success then
			ok = ok + 1
		else
			fail = fail + 1
			local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
			notify("error", "Failed to %s %s%s", verb, f.name, err ~= "" and (": " .. err) or "")
		end
	end
	if fail == 0 then
		notify("info", "Removed %d file%s", ok, ok == 1 and "" or "s")
	elseif ok > 0 then
		notify("warn", "Removed %d, failed %d", ok, fail)
	end
end

return M
