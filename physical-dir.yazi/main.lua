--- Switch from symlinked dir to its physical (real) path
--- Equivalent to `cd -P .` in the shell

local M = {}

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

function M:entry()
	local cwd = get_cwd()
	local quoted = "'" .. tostring(cwd):gsub("'", "'\\''") .. "'"
	local handle = io.popen("realpath " .. quoted)
	if not handle then
		ya.notify({ title = "Physical dir", content = "Failed to run realpath", timeout = 5, level = "error" })
		return
	end

	local output = handle:read("*a")
	handle:close()

	if not output then
		ya.notify({ title = "Physical dir", content = "Failed to resolve path", timeout = 5, level = "error" })
		return
	end

	output = output:gsub("%s+$", "")
	if output == cwd then
		ya.notify({ title = "Physical dir", content = "Already at physical path", timeout = 3, level = "info" })
		return
	end

	ya.emit("cd", { output })
	ya.notify({ title = "Physical dir", content = output, timeout = 3, level = "info" })
end

return M
