--- @since 26.5.6
--- Interactive mounter for Yazi.
--- Browse and mount local drives, phones, and network shares (SFTP/SMB).
--- Native yazi UI replacement for ~/.config/zsh/custom_tools/mounter.
--- Backends: lsblk + udisksctl (drives), gio (phones/network), avahi-browse (discovery).

local M = {}
local TITLE = "Mounter"

-- ── Capability detection ───────────────────────────────────────────────────

local function has_cmd(name)
	local out = Command("sh")
		:arg({ "-c", "command -v " .. name .. " >/dev/null 2>&1" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	return out and out.status and out.status.success
end

local HAS_LSBLK = has_cmd("lsblk")
local HAS_UDISKSCTL = has_cmd("udisksctl")
local HAS_GIO = has_cmd("gio")
local HAS_AVAHI = has_cmd("avahi-browse")
local HAS_TIMEOUT = has_cmd("timeout")

local MTP_ROOT = "/run/user/" .. (os.getenv("UID") or "1000") .. "/gvfs"
local HOME_DIR = os.getenv("HOME") or "/tmp"

local PHONE_URI_REGEX = "(mtp|gphoto2|afc)://[^%s]+"
local SFTP_URI_REGEX = "sftp://[^%s]+"
local SMB_URI_REGEX = "smb://[^%s]+"

-- ── Helpers ────────────────────────────────────────────────────────────────

local function notify(content, level)
	ya.notify({ title = TITLE, content = content, timeout = 3, level = level or "info" })
end

local function uri_to_gvfs_entry(uri)
	local proto, host = uri:match("^([a-z0-9+.-]+)://([^/]+)")
	if proto and host then
		return proto .. ":host=" .. host
	end
	return nil
end

local function shell_quote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function prompt(title, default)
	local input = ya.input({
		title = title,
		value = default or "",
		pos = { "center", w = 60 },
	})
	if not input then
		return nil
	end
	while true do
		local value, event = input:recv()
		if event == 1 then
			return value
		elseif event == 2 or event < 0 then
			return nil
		end
	end
end

-- ── State (ya.sync) ────────────────────────────────────────────────────────

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
	self.cursor = ya.clamp(0, self.cursor or 0, math.max(0, #items - 1))
	self.offset = 0
	ui.render()
end)

local move = ya.sync(function(self, delta)
	local n = #(self.items or {})
	self.cursor = n == 0 and 0 or ya.clamp(0, (self.cursor or 0) + delta, n - 1)
	ui.render()
end)

local set_cursor = ya.sync(function(self, idx)
	local n = #(self.items or {})
	self.cursor = n == 0 and 0 or ya.clamp(0, idx, n - 1)
	ui.render()
end)

-- ── Backend: USB drives ───────────────────────────────────────────────────

local function lsblk_parts()
	if not HAS_LSBLK then
		return {}
	end
	local out = Command("lsblk")
		:arg({ "-lpno", "NAME,SIZE,TYPE,MOUNTPOINTS" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if not (out and out.status and out.status.success) then
		return {}
	end
	local items = {}
	for line in out.stdout:gmatch("[^\r\n]+") do
		local fields = {}
		for f in line:gmatch("%S+") do
			fields[#fields + 1] = f
		end
		if #fields >= 3 and fields[3] == "part" then
			items[#items + 1] = {
				dev = fields[1],
				size = fields[2],
				mountpoint = fields[4] or "",
			}
		end
	end
	return items
end

local function mount_drive(dev)
	if not HAS_UDISKSCTL then
		notify("udisksctl not installed", "error")
		return false
	end
	local out = Command("udisksctl")
		:arg({ "mount", "-b", dev })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.status and out.status.success then
		notify("Mounted " .. dev)
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to mount " .. dev .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

local function unmount_drive(dev)
	if not HAS_UDISKSCTL then
		notify("udisksctl not installed", "error")
		return false
	end
	local out = Command("udisksctl")
		:arg({ "unmount", "-b", dev })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.status and out.status.success then
		notify("Unmounted " .. dev)
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to unmount " .. dev .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

-- ── Backend: phones ────────────────────────────────────────────────────────

local function gio_output(args)
	if not HAS_GIO then
		return nil
	end
	return Command("gio"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
end

local function list_phones()
	if not HAS_GIO then
		return {}
	end
	local mounted = gio_output({ "mount", "-l" })
	local available = gio_output({ "mount", "-li" })

	local function first_uri(out, pat)
		if not (out and out.stdout) then
			return nil
		end
		return out.stdout:match(pat)
	end

	local mounted_uri = first_uri(mounted, PHONE_URI_REGEX)
	if mounted_uri then
		local name = (mounted_uri:match("^[^:/]+://([^/]+)") or "phone"):gsub("_", " ")
		return { { name = name, uri = mounted_uri, mounted = true } }
	end

	local avail_uri = first_uri(available, PHONE_URI_REGEX)
	if avail_uri then
		local name = (avail_uri:match("^[^:/]+://([^/]+)") or "phone"):gsub("_", " ")
		return { { name = name, uri = avail_uri, mounted = false } }
	end

	return {}
end

local function mount_phone(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end
	local out = gio_output({ "mount", uri })
	if out and out.status and out.status.success then
		local entry = uri_to_gvfs_entry(uri)
		if entry then
			local target = MTP_ROOT .. "/" .. entry
			local link = HOME_DIR .. "/" .. entry
			os.execute(string.format("ln -sfn %s %s 2>/dev/null", shell_quote(target), shell_quote(link)))
			notify("Phone mounted: " .. link)
		else
			notify("Phone mounted")
		end
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to mount phone" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

local function unmount_phone(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end
	local out = gio_output({ "mount", "-u", uri })
	if out and out.status and out.status.success then
		local entry = uri_to_gvfs_entry(uri)
		if entry then
			os.execute("rm -f " .. shell_quote(HOME_DIR .. "/" .. entry) .. " 2>/dev/null")
		end
		notify("Phone unmounted")
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to unmount phone" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

-- ── Backend: network ───────────────────────────────────────────────────────

local function list_network_mounts()
	if not HAS_GIO then
		return {}, {}
	end
	local out = gio_output({ "mount", "-l" })
	if not (out and out.stdout) then
		return {}, {}
	end
	local sftp, smb = {}, {}
	for uri in out.stdout:gmatch(SFTP_URI_REGEX) do
		sftp[#sftp + 1] = uri
	end
	for uri in out.stdout:gmatch(SMB_URI_REGEX) do
		smb[#smb + 1] = uri
	end
	return sftp, smb
end

local function scan_avahi(service, timeout_s)
	if not (HAS_AVAHI and HAS_TIMEOUT) then
		return {}
	end
	local out = Command("timeout")
		:arg({ tostring(timeout_s), "avahi-browse", "-rpt", service })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if not (out and out.stdout) then
		return {}
	end
	local seen, hosts = {}, {}
	for line in out.stdout:gmatch("[^\r\n]+") do
		local f1, f2, f3, _, _, _, f7 = line:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);.*$")
		if f1 == "=" and f3 == "IPv4" and f2 ~= "lo"
			and not f2:match("^veth")
			and not f2:match("^docker")
			and not f2:match("^br%-") then
			if f7 and f7 ~= "" and not seen[f7] then
				seen[f7] = true
				hosts[#hosts + 1] = f7
			end
		end
	end
	return hosts
end

local function normalize_sftp_uri(input)
	if input:match("^sftp://") then
		return input
	end
	return "sftp://" .. input
end

local function normalize_smb_uri(input)
	if input:match("^//") then
		return "smb:" .. input
	end
	if input:match("^smb://") then
		return input
	end
	return "smb://" .. input
end

local function mount_sftp(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end
	local out = gio_output({ "mount", uri })
	if out and out.status and out.status.success then
		local entry = uri_to_gvfs_entry(uri)
		notify("SFTP mounted: " .. (entry and (MTP_ROOT .. "/" .. entry) or uri))
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to mount SFTP" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

local function mount_smb_with_auth(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end

	local host_path = uri:match("^smb://(.+)$") or uri
	local default_user = os.getenv("USER") or ""

	local user = prompt("SMB — Username (blank = guest):", default_user)
	if user == nil then
		return false
	end

	local pass = prompt("SMB — Password (blank = none):", "")
	if pass == nil then
		return false
	end

	local final_uri
	if user ~= "" and pass ~= "" then
		final_uri = "smb://" .. user .. ":" .. pass .. "@" .. host_path
	elseif user ~= "" then
		final_uri = "smb://" .. user .. "@" .. host_path
	else
		final_uri = uri
	end

	local out = gio_output({ "mount", final_uri })
	if out and out.status and out.status.success then
		notify("SMB mounted")
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to mount SMB" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

local function unmount_network(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end
	local out = gio_output({ "mount", "-u", uri })
	if out and out.status and out.status.success then
		notify("Unmounted: " .. uri)
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to unmount" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

-- ── Build items list ───────────────────────────────────────────────────────

local function build_items()
	local items = {}

	-- Unmounted drives
	for _, d in ipairs(lsblk_parts()) do
		if d.mountpoint == "" then
			items[#items + 1] = {
				type = "mount_drive",
				label = "Mount drive  " .. d.dev .. "  (" .. d.size .. ")",
				dev = d.dev,
			}
		end
	end

	-- Mounted drives
	for _, d in ipairs(lsblk_parts()) do
		if d.mountpoint:match("^/run/media") then
			items[#items + 1] = {
				type = "unmount_drive",
				label = "Unmount drive  " .. d.dev .. "  (" .. d.size .. ")",
				dev = d.dev,
			}
		end
	end

	-- Phones
	for _, p in ipairs(list_phones()) do
		if p.mounted then
			items[#items + 1] = {
				type = "unmount_phone",
				label = "Unmount phone: " .. p.name,
				uri = p.uri,
			}
		else
			items[#items + 1] = {
				type = "mount_phone",
				label = "Mount phone: " .. p.name,
				uri = p.uri,
			}
		end
	end

	-- Network mounts
	local sftp_mounted, smb_mounted = list_network_mounts()
	for _, uri in ipairs(sftp_mounted) do
		items[#items + 1] = {
			type = "unmount_sftp",
			label = "Unmount SFTP: " .. uri:gsub("^sftp://", ""),
			uri = uri,
		}
	end
	for _, uri in ipairs(smb_mounted) do
		items[#items + 1] = {
			type = "unmount_smb",
			label = "Unmount SMB:  " .. uri:gsub("^smb://", ""),
			uri = uri,
		}
	end

	-- Discovered + manual network
	if HAS_GIO then
		local ssh_hosts = scan_avahi("_ssh._tcp", 2)
		local smb_hosts = scan_avahi("_smb._tcp", 2)
		for _, host in ipairs(ssh_hosts) do
			items[#items + 1] = {
				type = "mount_sftp_discovered",
				label = "Mount SFTP  ›  " .. host,
				host = host,
			}
		end
		for _, host in ipairs(smb_hosts) do
			items[#items + 1] = {
				type = "mount_smb_discovered",
				label = "Mount SMB   ›  " .. host,
				host = host,
			}
		end

		items[#items + 1] = {
			type = "mount_sftp_manual",
			label = "Mount SFTP  ›  manual address…",
		}
		items[#items + 1] = {
			type = "mount_smb_manual",
			label = "Mount SMB   ›  manual address…",
		}
	end

	if #items == 0 then
		items[#items + 1] = {
			type = "noop",
			label = "(no devices or actions available)",
		}
	end

	return items
end

-- ── Activate item ──────────────────────────────────────────────────────────

local function activate(item)
	if not item or item.type == "noop" then
		return
	end

	if item.type == "mount_drive" then
		mount_drive(item.dev)
	elseif item.type == "unmount_drive" then
		unmount_drive(item.dev)
	elseif item.type == "mount_phone" then
		mount_phone(item.uri)
	elseif item.type == "unmount_phone" then
		unmount_phone(item.uri)
	elseif item.type == "unmount_sftp" or item.type == "unmount_smb" then
		unmount_network(item.uri)
	elseif item.type == "mount_sftp_discovered" then
		local user = prompt("Mount SFTP — " .. item.host .. " (username, blank = current user):", "")
		if user == nil then
			return
		end
		local target = (user ~= "" and (user .. "@") or "") .. item.host
		mount_sftp(normalize_sftp_uri(target))
	elseif item.type == "mount_smb_discovered" then
		local share = prompt("Mount SMB — " .. item.host .. " (share name, blank = browse):", "")
		if share == nil then
			return
		end
		local uri = share == "" and ("smb://" .. item.host) or ("smb://" .. item.host .. "/" .. share)
		mount_smb_with_auth(uri)
	elseif item.type == "mount_sftp_manual" then
		local input = prompt("Mount SFTP (user@host  or  user@host/path):", "")
		if not input or input == "" then
			return
		end
		mount_sftp(normalize_sftp_uri(input))
	elseif item.type == "mount_smb_manual" then
		local input = prompt("Mount SMB (//host/share  or  smb://host/share):", "")
		if not input or input == "" then
			return
		end
		mount_smb_with_auth(normalize_smb_uri(input))
	end
end

-- ── Component ──────────────────────────────────────────────────────────────

M.keys = {
	{ on = "q", run = "quit" },
	{ on = "<Esc>", run = "quit" },
	{ on = "k", run = "up" },
	{ on = "<Up>", run = "up" },
	{ on = "j", run = "down" },
	{ on = "<Down>", run = "down" },
	{ on = "g", run = "top" },
	{ on = "G", run = "bottom" },
	{ on = "<Enter>", run = "activate" },
	{ on = "l", run = "activate" },
	{ on = "r", run = "refresh" },
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
	local items = self.items or {}

	local inner = area:pad(ui.Pad(1, 2, 1, 2))
	local chunks = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({ ui.Constraint.Min(1), ui.Constraint.Length(2) })
		:split(inner)
	local list_area, help_area = chunks[1], chunks[2]

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
	for i = self.offset + 1, math.min(#items, self.offset + h) do
		local item = items[i]
		local is_cur = (i - 1) == cur
		local arrow = is_cur and ">" or " "
		local style
		if item.type == "noop" then
			style = ui.Style():fg("darkgray")
		elseif is_cur then
			style = ui.Style():fg("blue"):bold()
		else
			style = ui.Style()
		end
		lines[#lines + 1] = ui.Line(string.format("%s   %s", arrow, item.label)):style(style)
	end

	local title = string.format(" Mounter — %d action%s ", #items, #items == 1 and "" or "s")
	local help_text = ui.Text({
		ui.Line(" j/k move   g/G top/end   <Enter>/l activate   r refresh   q quit"):style(
			ui.Style():fg("darkgray")
		),
	})

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
	set_items({ { type = "noop", label = "Scanning for devices..." } })
	set_items(build_items())

	while true do
		local idx = ya.which({ cands = self.keys, silent = true })
		local cand = idx and self.keys[idx]
		local run = cand and cand.run

		if run == "quit" then
			toggle_ui()
			break
		elseif run == "up" then
			move(-1)
		elseif run == "down" then
			move(1)
		elseif run == "top" then
			set_cursor(0)
		elseif run == "bottom" then
			set_cursor(math.huge)
		elseif run == "refresh" then
			set_items(build_items())
		elseif run == "activate" then
			local item = self.items[(self.cursor or 0) + 1]
			activate(item)
			set_items(build_items())
		end
	end
end

function M:click() end
function M:scroll() end
function M:touch() end

return M
