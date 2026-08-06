--- @since 26.5.6
--- Wrapper around yazi's `remove` that handles MTP mounts gracefully.
--- MTP doesn't support .Trash, so `gio trash` fails. This plugin detects
--- MTP paths and uses `gio remove` (permanent delete) for those, while
--- using `gio trash` for everything else (same as yazi's built-in).

local MTP_GVFS = "/run/user/" .. (os.getenv("UID") or "1000") .. "/gvfs/mtp:host="

local function is_mtp(path)
	return path:sub(1, #MTP_GVFS) == MTP_GVFS
end

local function file_path(f)
	local url = tostring(f.url)
	if url:sub(1, 7) == "file://" then
		return url:sub(8)
	end
	return url
end

local function notify(level, s, ...)
	ya.notify({ title = "Safe Remove", content = string.format(s, ...), timeout = 3, level = level })
end

function M:entry(job)
	local args = job.args or {}
	local permanent = false
	for _, a in ipairs(args) do
		if a == "--permanent" then
			permanent = true
		end
	end

	local files = ya.selected({ confirm = true })
	if #files == 0 then
		return
	end

	local ok, fail = 0, 0
	for _, f in ipairs(files) do
		local path = file_path(f)
		local cmd, verb
		if permanent or is_mtp(path) then
			cmd = { "remove", path }
			verb = "delete"
		else
			cmd = { "trash", path }
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
	ya.mgr_refresh()
	if fail == 0 then
		notify("info", "Removed %d file%s", ok, ok == 1 and "" or "s")
	elseif ok > 0 then
		notify("warn", "Removed %d, failed %d", ok, fail)
	end
end

return M
