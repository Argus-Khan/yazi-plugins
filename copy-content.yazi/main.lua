--- @since 26.5.6

local M = {}
local TITLE = "Copy content"

local function notify(level, msg)
	ya.notify({ title = TITLE, content = msg, timeout = 4, level = level })
end

local get_hovered = ya.sync(function()
	local cur = cx.active and cx.active.current or nil
	if not cur then
		return nil
	end

	local h = cur.hovered
	if h then
		return { path = tostring(h.url), is_dir = h.cha and h.cha.is_dir or false }
	end

	local files = cur.files
	local cursor = cur.cursor
	if files and cursor then
		local f = files[cursor] or files[cursor + 1]
		if f then
			return { path = tostring(f.url), is_dir = f.cha and f.cha.is_dir or false }
		end
	end

	return nil
end)

local function url_to_path(url)
	local path = tostring(url)
	if path:sub(1, 7) == "file://" then
		path = path:sub(8)
	end
	return path
end

local function is_text_or_empty(path)
	local f = io.open(path, "rb")
	if not f then
		return false, "cannot open file"
	end

	local chunk = f:read(4096)
	f:close()

	if not chunk or chunk == "" then
		return true
	end

	if chunk:find("\0", 1, true) then
		return false
	end

	return true
end

local function spawn_clipboard()
	local child = Command("wl-copy"):stdin(Command.PIPED):spawn()
	if child then
		return child
	end

	child = Command("xclip")
		:args({ "-selection", "clipboard" })
		:stdin(Command.PIPED)
		:spawn()
	if child then
		return child
	end

	child = Command("xsel")
		:args({ "--clipboard", "--input" })
		:stdin(Command.PIPED)
		:spawn()
	if child then
		return child
	end

	return nil
end

local function write_file_to_child(path, child)
	local f = io.open(path, "rb")
	if not f then
		return false
	end

	while true do
		local chunk = f:read(65536)
		if not chunk then
			break
		end

		child:write_all(chunk)
	end

	f:close()
	child:flush()
	child:wait()

	return true
end

function M:entry()
	local h = get_hovered()
	if not h or not h.path then
		notify("error", "No file hovered")
		return
	end

	if h.is_dir then
		notify("error", "Invalid file: directory")
		return
	end

	local path = url_to_path(h.path)
	local ok = is_text_or_empty(path)
	if not ok then
		notify("error", "Invalid file: binary")
		return
	end

	local child = spawn_clipboard()
	if not child then
		notify("error", "No clipboard tool found")
		return
	end

	if not write_file_to_child(path, child) then
		notify("error", "Failed to read file")
		return
	end

	notify("info", "Copied file content")
end

return M
