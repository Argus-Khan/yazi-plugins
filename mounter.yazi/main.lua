--- @since 26.5.6
--- Interactive mounter for Yazi.
--- Browse and mount local drives, phones, and network shares (SFTP/SMB).
--- Native yazi UI replacement for ~/.config/zsh/custom_tools/mounter.
--- Backends: lsblk + udisksctl (drives), gio (phones/network), avahi-browse (discovery).

local M = {}
local TITLE = "Mounter"

-- ── Capability detection ───────────────────────────────────────────────────

local function has_cmd(name)
	return os.execute("command -v " .. name .. " >/dev/null 2>&1") == true
end

local HAS_LSBLK = has_cmd("lsblk")
local HAS_UDISKSCTL = has_cmd("udisksctl")
local HAS_GIO = has_cmd("gio")
local HAS_AVAHI = has_cmd("avahi-browse")
local HAS_TIMEOUT = has_cmd("timeout")
local HAS_SMBCLIENT = has_cmd("smbclient")

local MTP_ROOT = "/run/user/" .. (os.getenv("UID") or "1000") .. "/gvfs"
local HOME_DIR = os.getenv("HOME") or "/tmp"
local MOUNT_DIR = HOME_DIR .. "/ExternalDrives"

function M:setup(args)
	if args and args.mount_dir then
		MOUNT_DIR = args.mount_dir:gsub("^~", HOME_DIR)
	end
end

local PHONE_URI_REGEX = "(mtp|gphoto2|afc)://[^%s]+"
local SFTP_URI_REGEX = "sftp://[^%s]+"
local SMB_URI_REGEX = "smb://[^%s]+"

-- avahi-browse is slow (the plugin blocks on it, leaking focus to the yazi
-- manager underneath). Cache the discovered hosts for a short TTL so refreshes
-- don't re-scan the network every time.
local AVAHI_TTL = 60
local avahi_cache = { ssh = {}, smb = {}, ts = 0 }

-- ── Helpers ────────────────────────────────────────────────────────────────

local function notify(content, level)
	ya.notify({ title = TITLE, content = content, timeout = 3, level = level or "info" })
end

local function uri_to_gvfs_entry(uri)
	local proto, host = uri:match("^([a-z0-9+.-]+)://([^/]+)")
	if proto and host then
		-- Strip userinfo (user:pass@) from the authority; server= must be the bare host.
		local host_only = host:match("@([^@]*)$") or host
		if proto == "smb" then
			local user = uri:match("^smb://([^@:/]+)@")
			local share = uri:match("^smb://[^/]+/([^/?]+)")
			-- gvfs canonicalizes smb server and share to lowercase in the gvfs dir name.
			host_only = host_only:lower()
			share = share and share:lower()
			if share then
				local entry = "smb-share:server=" .. host_only .. ",share=" .. share
				if user then
					entry = entry .. ",user=" .. user
				end
				return entry
			end
			return "smb:host=" .. host_only
		end
		return proto .. ":host=" .. host_only
	end
	return nil
end

-- Parse the host and share from an smb:// URI, stripping any userinfo and
-- lowercasing (gvfs canonical form). Returns host, share (`nil` if no share).
-- The `[ignore]` arg makes the host/share parsing robust to URIs like
-- `smb://bridgetech.local/office_share/` (trailing slash) and
-- `smb://user@host/share` (with userinfo) without the `[^@]*@?` foot-gun.
local function smb_host_share(uri)
	local body = uri:match("^smb://(.+)$") or ""
	-- Drop userinfo (everything up to the first "/") by stripping a leading `user@`.
	body = body:gsub("^([^/]-)@", "")
	local host, rest = body:match("^([^/]+)(/.*)$")
	if not host then
		host = body
		rest = ""
	end
	local share = rest:match("^/+([^/?#]+)")
	host = host:lower()
	share = share and share:lower() or nil
	return host, share
end

local function find_gvfs_entry(pattern)
	local out = Command("ls")
		:arg({ MTP_ROOT })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		for line in out.stdout:gmatch("[^\r\n]+") do
			if line:match(pattern) then
				return line
			end
		end
	end
	return nil
end

local function shell_quote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function save_credential(server, share, user, pass)
	local label = user .. "@" .. server .. "/" .. share
	os.execute(string.format(
		"secret-tool store --label %s service samba server %s share %s user %s 2>/dev/null <<< %s",
		shell_quote(label), shell_quote(server), shell_quote(share), shell_quote(user), shell_quote(pass)
	))
end

local function load_credential(server, share)
	local out = Command("secret-tool")
		:arg({ "lookup", "service", "samba", "server", server, "share", share })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		local pass = out.stdout:gsub("%s+$", "")
		if pass ~= "" then
			local user_out = Command("python3"):arg({ "-c", string.format(
				"import secretstorage; bus=secretstorage.dbus_init(); c=secretstorage.get_default_collection(bus);\nfor item in c.search_items({'service':'samba','server':%q,'share':%q}):\n    print(item.get_attributes().get('user','')); break",
				server, share
			) }):stdout(Command.PIPED):stderr(Command.PIPED):output()
			local user = ""
			if user_out and user_out.stdout then
				user = user_out.stdout:gsub("%s+$", "")
			end
			return user, pass
		end
	end
	return nil, nil
end

local function ensure_mount_dir()
	os.execute("mkdir -p " .. shell_quote(MOUNT_DIR))
end

local function link_mount(target, name)
	ensure_mount_dir()
	local link = MOUNT_DIR .. "/" .. name
	os.execute(string.format("ln -sfn %s %s", shell_quote(target), shell_quote(link)))
end

local function unlink_mount(name)
	local link = MOUNT_DIR .. "/" .. name
	os.execute("rm -f " .. shell_quote(link))
end

local function get_mountpoint(dev)
	local out = Command("lsblk")
		:arg({ "-no", "MOUNTPOINTS", dev })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		for line in out.stdout:gmatch("[^\r\n]+") do
			if line ~= "" and line ~= "[SWAP]" then
				return line
			end
		end
	end
	return nil
end

local function prompt(title, default)
	local value, event = ya.input({
		title = title,
		value = default or "",
		pos = { "center", w = 60 },
	})
	if event == 1 then
		return value
	end
	return nil
end

-- ── State (ya.sync) ────────────────────────────────────────────────────────

local toggle_ui = ya.sync(function(self)
	if self.children then
		Modal:children_remove(self.children)
		self.children = nil
	else
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

local get_active_item = ya.sync(function(self)
	local items = self.items or {}
	return items[(self.cursor or 0) + 1]
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
		local mp = get_mountpoint(dev)
		if mp then
			local name = dev:match("([^/]+)$") or dev
			link_mount(mp, name)
		end
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
		local name = dev:match("([^/]+)$") or dev
		unlink_mount(name)
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
			link_mount(target, entry)
			notify("Phone mounted: " .. MOUNT_DIR .. "/" .. entry)
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
			unlink_mount(entry)
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

-- Refresh the avahi cache if stale (or `force` is set). Safe to call on every
-- refresh; only scans the network when the TTL has expired, so most refreshes
-- don't block on avahi-browse and leak focus to the yazi manager.
local function refresh_avahi(force)
	if not (HAS_AVAHI and HAS_TIMEOUT) then
		return
	end
	if not force and (os.time() - avahi_cache.ts) < AVAHI_TTL then
		return
	end
	avahi_cache.ssh = scan_avahi("_ssh._tcp", 1)
	avahi_cache.smb = scan_avahi("_smb._tcp", 1)
	avahi_cache.ts = os.time()
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

-- List Disk-type shares on `host` via smbclient (guest unless user/pass given).
-- Returns an array of share names (lowercased), or {} on failure. We filter IPC$
-- and printer shares because gio can't mount them.
local function smb_list_shares(host, user, pass)
	if not HAS_SMBCLIENT then
		return {}
	end
	local args = { "-L", "//" .. host, "-N" }
	if user and user ~= "" then
		args = { "-L", "//" .. host, "-U", user }
		if pass and pass ~= "" then
			args[#args + 1] = pass
		else
			args[#args + 1] = "-N"
		end
	end
	local out = Command("smbclient"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not (out and out.stdout and out.status and out.status.success) then
		return {}
	end
	local shares = {}
	for line in out.stdout:gmatch("[^\r\n]+") do
		-- Parse "Sharename       Type      Comment" rows; only take Disk shares.
		local name, typ = line:match("^%s*(%S+)%s+(Disk)%s")
		if name and name ~= "IPC$" then
			shares[#shares + 1] = name:lower()
		end
	end
	return shares
end

local function mount_sftp(uri)
	if not HAS_GIO then
		notify("gio not installed", "error")
		return false
	end
	local out = gio_output({ "mount", uri })
	if out and out.status and out.status.success then
		local entry = uri_to_gvfs_entry(uri)
		if entry then
			local target = MTP_ROOT .. "/" .. entry
			link_mount(target, entry)
		end
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

	-- Split userinfo from authority once: body = [user[:pass]@]host[/share]
	local body = uri:match("^smb://(.+)$") or uri
	local userinfo, rest = body:match("^([^/]*@)(.*)$")
	rest = rest or body -- rest with no userinfo
	local host = rest:match("^([^/]+)") or rest
	local share = rest:match("^[^/]+/([^/?]+)") or ""
	-- gvfs canonicalizes smb server+share to lowercase in both the gvfs dir name and
	-- `gio mount -l` output, so all gvfs lookups and credential keys must use lowercase.
	host = host:lower()
	share = share:lower()
	-- gio can't mount a host without a share — it just parks the server in the
	-- browse daemon and reports "already mounted" without ever creating a gvfs dir.
	if share == "" then
		notify("SMB share name is required (blank share cannot be mounted): " .. host, "error")
		return false
	end
	-- Always mount the BARE uri (no user:pass@); gio rejects embedded creds with an
	-- interactive prompt that fails non-interactively. Auth comes from the keyring.
	local bare_uri = "smb://" .. rest

	-- Resolve the gvfs entry name we expect after a successful mount.
	local function expected_entry()
		if share ~= "" then
			return "smb-share:server=" .. host .. ",share=" .. share
		end
		return "smb:host=" .. host
	end

	-- Check if already mounted (match any share from this server if none specified)
	local existing
	if share ~= "" then
		existing = find_gvfs_entry("^smb%-share:server=" .. host .. ",share=" .. share .. "$")
	else
		existing = find_gvfs_entry("^smb%-share:server=" .. host)
	end
	if existing then
		local target = MTP_ROOT .. "/" .. existing
		-- Verify mount is actually accessible
		local check = Command("ls"):arg({ target }):stdout(Command.NULL):stderr(Command.NULL):output()
		if check and check.status and check.status.success then
			link_mount(target, existing)
			notify("SMB already mounted, linked")
			return true
		end
		-- Stale gvfs dir (not accessible): unmount and clean up before retrying.
		local s_host = existing:match("server=([^,]+)")
		local s_share = existing:match("share=([^,]+)")
		gio_output({ "mount", "-u", "smb://" .. (s_host or host) .. "/" .. (s_share or share) })
		ya.sleep(1)
		unlink_mount(existing)
	end

	-- Credential resolution: prefer saved keyring entry, else prompt and store BEFORE mount.
	local saved_user, saved_pass = load_credential(host, share)
	local user, pass
	if saved_user and saved_pass then
		user = saved_user
		pass = saved_pass
	else
		user = prompt("SMB — Username (blank = guest):", os.getenv("USER") or "")
		if user == nil then
			return false
		end
		pass = prompt("SMB — Password (blank = none):", "")
		if pass == nil then
			return false
		end
		-- Store credentials in the keyring BEFORE mounting so gio's gvfsd-smb can
		-- resolve them silently. guest (blank user) skips storage.
		if user ~= "" and pass ~= "" then
			save_credential(host, share, user, pass)
		end
	end

	local out = gio_output({ "mount", bare_uri })
	if out and out.status and out.status.success then
		local entry = expected_entry()
		local target = MTP_ROOT .. "/" .. entry
		-- Wait for gvfs to populate the mount dir.
		for _ = 1, 6 do
			ya.sleep(0.5)
			local check = Command("ls"):arg({ target }):stdout(Command.NULL):stderr(Command.NULL):output()
			if check and check.status and check.status.success then
				if share ~= "" then
					link_mount(target, host .. "-" .. share)
				else
					link_mount(target, entry)
				end
				notify("SMB mounted")
				return true
			end
		end
		-- Mount reported success but gvfs dir isn't accessible; link anyway and warn.
		if share ~= "" then
			link_mount(target, host .. "-" .. share)
		else
			link_mount(target, entry)
		end
		notify("SMB mounted but share not accessible", "warn")
		return true
	end

	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""

	-- "Location is already mounted": gvfs thinks it's mounted but the gvfs dir may
	-- be stale (no entry on disk). Only link if we can verify the target really
	-- exists; otherwise force-unmount the stale state and retry once.
	if err:match("already mounted") then
		-- Try to find and verify a real, accessible gvfs entry for this host/share.
		local function accessible_entry()
			local entry = share ~= ""
				and find_gvfs_entry("^smb%-share:server=" .. host .. ",share=" .. share .. "$")
				or find_gvfs_entry("^smb%-share:server=" .. host)
			if not entry then
				return nil
			end
			local t = MTP_ROOT .. "/" .. entry
			local c = Command("ls"):arg({ t }):stdout(Command.NULL):stderr(Command.NULL):output()
			if c and c.status and c.status.success then
				return entry
			end
			return nil
		end

		local entry = accessible_entry()
		if entry then
			if share ~= "" then
				link_mount(MTP_ROOT .. "/" .. entry, host .. "-" .. share)
			else
				link_mount(MTP_ROOT .. "/" .. entry, entry)
			end
			notify("SMB already mounted, linked")
			return true
		end

		-- Stale "already mounted" with no accessible dir: blow away state and retry.
		gio_output({ "mount", "-u", bare_uri })
		ya.sleep(1)
		out = gio_output({ "mount", bare_uri })
		if out and out.status and out.status.success then
			local e = expected_entry()
			local target = MTP_ROOT .. "/" .. e
			for _ = 1, 6 do
				ya.sleep(0.5)
				local c = Command("ls"):arg({ target }):stdout(Command.NULL):stderr(Command.NULL):output()
				if c and c.status and c.status.success then
					if share ~= "" then
						link_mount(target, host .. "-" .. share)
					else
						link_mount(target, e)
					end
					notify("SMB mounted")
					return true
				end
			end
		end
		notify("Failed to mount SMB (already mounted, no accessible share): " .. host .. "/" .. share, "error")
		return false
	end

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
		-- Clean up both possible symlinks: friendly name (host-share) and the raw
		-- gvfs entry name (in case an older plugin version created it).
		if uri:match("^smb://") then
			local host, share = smb_host_share(uri)
			if host and share then
				unlink_mount(host .. "-" .. share)
			end
		end
		local entry = uri_to_gvfs_entry(uri)
		if entry then
			unlink_mount(entry)
		end
		notify("Unmounted: " .. uri)
		return true
	end
	local err = out and out.stderr and out.stderr:gsub("%s+", " ") or ""
	notify("Failed to unmount" .. (err ~= "" and (": " .. err) or ""), "error")
	return false
end

-- ── Build items list ───────────────────────────────────────────────────────

local function cleanup_stale_links()
	ensure_mount_dir()
	local out = Command("find")
		:arg({ MOUNT_DIR, "-maxdepth", "1", "-type", "l", "-xtype", "l" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		for link in out.stdout:gmatch("[^\r\n]+") do
			os.execute("rm -f " .. shell_quote(link))
		end
	end
end

local function build_items()
	cleanup_stale_links()
	refresh_avahi(false)
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
			local name = d.dev:match("([^/]+)$") or d.dev
			link_mount(d.mountpoint, name)
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
			local entry = uri_to_gvfs_entry(p.uri)
			if entry then
				link_mount(MTP_ROOT .. "/" .. entry, entry)
			end
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
		local entry = uri_to_gvfs_entry(uri)
		if entry then
			link_mount(MTP_ROOT .. "/" .. entry, entry)
		end
		items[#items + 1] = {
			type = "unmount_sftp",
			label = "Unmount SFTP: " .. uri:gsub("^sftp://", ""),
			uri = uri,
		}
	end
	for _, uri in ipairs(smb_mounted) do
		local host, share = smb_host_share(uri)
		local entry = nil
		if host and share then
			entry = find_gvfs_entry("^smb%-share:server=" .. host .. ",share=" .. share)
		end
		if not entry then
			entry = uri_to_gvfs_entry(uri)
		end
		if entry then
			-- Friendly name only; the raw gvfs entry name is too verbose.
			if share then
				link_mount(MTP_ROOT .. "/" .. entry, host .. "-" .. share)
			else
				link_mount(MTP_ROOT .. "/" .. entry, entry)
			end
		end
		items[#items + 1] = {
			type = "unmount_smb",
			label = "Unmount SMB:  " .. uri:gsub("^smb://", ""),
			uri = uri,
		}
	end

	-- Discovered + manual network
	if HAS_GIO then
		local mounted_hosts = {}
		for _, uri in ipairs(smb_mounted) do
			local h = smb_host_share(uri)
			if h then mounted_hosts[h] = true end
		end
		for _, uri in ipairs(sftp_mounted) do
			local _, h = pcall(function()
				local body = uri:match("^sftp://(.+)$") or ""
				body = body:gsub("^([^/]-)@", "")
				return (body:match("^([^/:]+)") or body):lower()
			end)
			if h then mounted_hosts[h] = true end
		end

		for _, host in ipairs(avahi_cache.ssh) do
			if not mounted_hosts[host:lower()] then
				items[#items + 1] = {
					type = "mount_sftp_discovered",
					label = "Mount SFTP  ›  " .. host,
					host = host,
				}
			end
		end
		for _, host in ipairs(avahi_cache.smb) do
			if not mounted_hosts[host:lower()] then
				items[#items + 1] = {
					type = "mount_smb_discovered",
					label = "Mount SMB   ›  " .. host,
					host = host,
				}
			end
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
		if share == "" then
			-- "browse": list Disk shares via smbclient and auto-mount the only one,
			-- or re-prompt with the list shown so the user can pick.
			local shares = smb_list_shares(item.host)
			if #shares == 0 then
				notify("No browsable shares found on " .. item.host .. " (need smbclient, or type a share name)", "error")
				return
			elseif #shares == 1 then
				share = shares[1]
			else
				share = prompt("Mount SMB — " .. item.host .. " (shares: " .. table.concat(shares, ", ") .. "):", shares[1])
				if share == nil then
					return
				end
			end
		end
		mount_smb_with_auth("smb://" .. item.host .. "/" .. share)
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
	{ on = "R", run = "rescan" },
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
		ui.Line(" j/k move   g/G top/end   <Enter>/l activate   r refresh   R re-scan   q quit"):style(
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
			refresh_avahi(false)
			set_items(build_items())
		elseif run == "rescan" then
			set_items({ { type = "noop", label = "Re-scanning network..." } })
			refresh_avahi(true)
			set_items(build_items())
		elseif run == "activate" then
			local item = get_active_item()
			activate(item)
			set_items(build_items())
		end
	end
end

function M:click() end
function M:scroll() end
function M:touch() end

return M
