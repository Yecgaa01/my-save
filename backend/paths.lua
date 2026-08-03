local fs = require("fs")
local io = require("io")
local ok_json, json = pcall(require, "json")
local ok_ffi, ffi = pcall(require, "ffi")

local M = {}

local STEAM_ID64_BASE = "76561197960265728"

local function normalize_slashes(path)
    return tostring(path or ""):gsub("/", "\\")
end

local function replace_literal(value, needle, replacement)
    value = tostring(value or "")
    needle = tostring(needle or "")
    replacement = tostring(replacement or "")
    if needle == "" then return value end
    local start_pos = 1
    while true do
        local found_start, found_end = value:find(needle, start_pos, true)
        if not found_start then break end
        value = value:sub(1, found_start - 1) .. replacement .. value:sub(found_end + 1)
        start_pos = found_start + #replacement
    end
    return value
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function dirname(path)
    path = normalize_slashes(path)
    return path:match("^(.*)\\[^\\]+$") or path
end

local function env(name)
    local value = os.getenv(name) or ""
    if value ~= "" then return normalize_slashes(value) end
    if name == "USERPROFILE" then return "C:\\Users\\User" end
    if name == "APPDATA" then return env("USERPROFILE") .. "\\AppData\\Roaming" end
    if name == "LOCALAPPDATA" then return env("USERPROFILE") .. "\\AppData\\Local" end
    if name == "PROGRAMDATA" then return "C:\\ProgramData" end
    if name == "PUBLIC" then return "C:\\Users\\Public" end
    if name == "PROGRAMFILES" then return "C:\\Program Files" end
    if name == "PROGRAMFILES(X86)" then return "C:\\Program Files (x86)" end
    return ""
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

local function native_safe_path(path)
    local value = normalize_slashes(trim(path))
    if value == "" then return false end
    if #value > 1000 then return false end
    if value:find("%z") or value:find('"', 1, true) or value:find("*", 1, true) or value:find("?", 1, true) then return false end
    if value:find("<[^>]+>") or value:find("%%[%w_]+%%") then return false end
    if value:find("|", 1, true) or value:find(">", 1, true) or value:find("<", 1, true) then return false end
    return value:match("^%a:[\\/]") ~= nil or value:match("^[\\/][\\/][^\\/]+[\\/][^\\/]+") ~= nil
end

local function exists(path)
    if not native_safe_path(path) then return false end
    local ok, result = pcall(fs.exists, path)
    return ok and result == true
end

local function list_dir(path)
    if not native_safe_path(path) then return {} end
    local ok, entries = pcall(fs.list, path)
    if ok and type(entries) == "table" then return entries end
    return {}
end

local function basename(entry)
    local value = type(entry) == "table" and (entry.name or entry.path or entry.fullPath) or entry
    value = tostring(value or "")
    return value:match("([^\\/]+)$") or value
end

local function current_backend_path()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return dirname(normalize_slashes(source))
end

local function backend_path()
    return current_backend_path()
end

local KNOWN_FOLDERS_FILE = backend_path() .. "\\known-folders.json"
local registry_ready = false
local registry_available = false
local advapi32 = nil

local function init_registry()
    if registry_ready then return registry_available end
    registry_ready = true
    if not ok_ffi then return false end
    local ok = pcall(function()
        ffi.cdef[[
            typedef void* HKEY;
            typedef unsigned long DWORD;
            typedef long LONG;
            typedef wchar_t WCHAR;
            LONG RegOpenKeyExW(HKEY hKey, const WCHAR* lpSubKey, DWORD ulOptions, DWORD samDesired, HKEY* phkResult);
            LONG RegQueryValueExW(HKEY hKey, const WCHAR* lpValueName, DWORD* lpReserved, DWORD* lpType, unsigned char* lpData, DWORD* lpcbData);
            LONG RegCloseKey(HKEY hKey);
        ]]
        advapi32 = ffi.load("Advapi32")
    end)
    registry_available = ok and advapi32 ~= nil
    return registry_available
end

local function wchar_array(value)
    local arr = ffi.new("WCHAR[?]", #value + 1)
    for i = 1, #value do arr[i - 1] = value:byte(i) end
    arr[#value] = 0
    return arr
end

local function codepoint_to_utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    end
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
end

local function utf16le_to_string(bytes, size)
    local chars = {}
    local limit = math.max(0, tonumber(size or 0) - 2)
    for i = 0, limit, 2 do
        local lo = bytes[i]
        local hi = bytes[i + 1]
        local code = lo + hi * 256
        if code == 0 then break end
        table.insert(chars, codepoint_to_utf8(code))
    end
    return table.concat(chars)
end

local function expand_percent_vars(value)
    return tostring(value or ""):gsub("%%([^%%]+)%%", function(key) return env(key) or "" end)
end

local function registry_user_shell_folder(name)
    if not init_registry() then return "" end
    local HKEY_CURRENT_USER = ffi.cast("HKEY", tonumber("0x80000001"))
    local KEY_READ = 0x20019
    local ERROR_SUCCESS = 0
    local key = ffi.new("HKEY[1]")
    local subkey = wchar_array("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders")
    if advapi32.RegOpenKeyExW(HKEY_CURRENT_USER, subkey, 0, KEY_READ, key) ~= ERROR_SUCCESS then return "" end
    local value_name = wchar_array(name)
    local typ = ffi.new("DWORD[1]")
    local size = ffi.new("DWORD[1]", 0)
    advapi32.RegQueryValueExW(key[0], value_name, nil, typ, nil, size)
    if size[0] == 0 then advapi32.RegCloseKey(key[0]); return "" end
    local data = ffi.new("unsigned char[?]", size[0])
    local rc = advapi32.RegQueryValueExW(key[0], value_name, nil, typ, data, size)
    advapi32.RegCloseKey(key[0])
    if rc ~= ERROR_SUCCESS then return "" end
    return normalize_slashes(expand_percent_vars(utf16le_to_string(data, size[0])):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function registry_string(root, subkey_name, value_name)
    if not init_registry() then return "" end
    local KEY_READ = 0x20019
    local ERROR_SUCCESS = 0
    local roots = {
        HKCU = ffi.cast("HKEY", tonumber("0x80000001")),
        HKLM = ffi.cast("HKEY", tonumber("0x80000002")),
    }
    local root_key = roots[root]
    if not root_key then return "" end
    local key = ffi.new("HKEY[1]")
    if advapi32.RegOpenKeyExW(root_key, wchar_array(subkey_name), 0, KEY_READ, key) ~= ERROR_SUCCESS then return "" end
    local typ = ffi.new("DWORD[1]")
    local size = ffi.new("DWORD[1]", 0)
    advapi32.RegQueryValueExW(key[0], wchar_array(value_name), nil, typ, nil, size)
    if size[0] == 0 then advapi32.RegCloseKey(key[0]); return "" end
    local data = ffi.new("unsigned char[?]", size[0])
    local rc = advapi32.RegQueryValueExW(key[0], wchar_array(value_name), nil, typ, data, size)
    advapi32.RegCloseKey(key[0])
    if rc ~= ERROR_SUCCESS then return "" end
    local value = normalize_slashes(expand_percent_vars(utf16le_to_string(data, size[0])):gsub("^%s+", ""):gsub("%s+$", ""))
    return value:gsub("[\\/][^\\/]-%.exe$", "")
end

local function known_folders_file()
    if not ok_json then return {} end
    local content = read_file(KNOWN_FOLDERS_FILE)
    if not content then return {} end
    local ok, parsed = pcall(json.decode, content)
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

local function known_folder(name)
    local from_registry = registry_user_shell_folder(name)
    if from_registry ~= "" then return from_registry end
    local data = known_folders_file()
    local value = data[name]
    if type(value) == "string" and value ~= "" then return normalize_slashes(expand_percent_vars(value)) end
    return ""
end


function M.steam_root()
    local backend = current_backend_path()
    local current = backend
    for _ = 1, 8 do
        if current ~= "" and exists(current .. "\\steamapps") then return current end
        local parent = dirname(current)
        if parent == "" or parent == current then break end
        current = parent
    end
    local plugin_dir = dirname(backend)
    local plugins_dir = dirname(plugin_dir)
    local millennium_dir = dirname(plugins_dir)
    local root = dirname(millennium_dir)
    if root ~= "" and exists(root .. "\\steamapps") then return root end
    return root ~= "" and root or "C:\\Program Files (x86)\\Steam"
end

local function is_numeric(value)
    return tostring(value or ""):match("^%d+$") ~= nil
end

local function decimal_add(value, add)
    value = tostring(value or ""):gsub("^0+", "")
    add = tostring(add or ""):gsub("^0+", "")
    if value == "" then value = "0" end
    if add == "" then add = "0" end
    local result = {}
    local carry = 0
    local i, j = #value, #add
    while i > 0 or j > 0 or carry > 0 do
        local a = i > 0 and tonumber(value:sub(i, i)) or 0
        local b = j > 0 and tonumber(add:sub(j, j)) or 0
        local sum = a + b + carry
        table.insert(result, 1, tostring(sum % 10))
        carry = math.floor(sum / 10)
        i = i - 1
        j = j - 1
    end
    local text = table.concat(result):gsub("^0+", "")
    return text ~= "" and text or "0"
end

local function decimal_subtract(value, subtract)
    value = tostring(value or ""):gsub("^0+", "")
    subtract = tostring(subtract or ""):gsub("^0+", "")
    if value == "" then value = "0" end
    if subtract == "" then subtract = "0" end

    local result = {}
    local borrow = 0
    local i, j = #value, #subtract
    while i > 0 or j > 0 do
        local a = i > 0 and tonumber(value:sub(i, i)) or 0
        local b = j > 0 and tonumber(subtract:sub(j, j)) or 0
        local digit = a - b - borrow
        if digit < 0 then
            digit = digit + 10
            borrow = 1
        else
            borrow = 0
        end
        table.insert(result, 1, tostring(digit))
        i = i - 1
        j = j - 1
    end
    local text = table.concat(result):gsub("^0+", "")
    return text ~= "" and text or "0"
end

local function steam64_to_account_id(steam64)
    if not is_numeric(steam64) then return nil end
    local text = tostring(steam64)
    if not text:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then return nil end
    local account = decimal_subtract(text, STEAM_ID64_BASE)
    if not is_numeric(account) then return nil end
    return account
end

local function account_from_loginusers(steam_root)
    local content = read_file(normalize_slashes(steam_root) .. "\\config\\loginusers.vdf")
    if not content then return nil end
    local current = nil
    local current_recent = false
    local fallback = nil
    for line in content:gmatch("[^\r\n]+") do
        local steam64 = line:match('^%s*"(7656119%d+)"%s*$')
        if steam64 then
            if current and current_recent then return steam64_to_account_id(current) end
            if not fallback then fallback = steam64 end
            current = steam64
            current_recent = false
        elseif current then
            if line:match('"MostRecent"%s*"1"') then current_recent = true end
        end
    end
    if current and current_recent then return steam64_to_account_id(current) end
    if fallback then return steam64_to_account_id(fallback) end
    return nil
end

local function list_numeric_userdata(steam_root)
    local result = {}
    for _, entry in ipairs(list_dir(normalize_slashes(steam_root) .. "\\userdata")) do
        local name = basename(entry)
        if is_numeric(name) then table.insert(result, name) end
    end
    return result
end

function M.resolve_account_id(steam_root, provided)
    steam_root = normalize_slashes(steam_root or M.steam_root())
    provided = trim(provided)
    if is_numeric(provided) and provided ~= "" then
        local account = provided:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and steam64_to_account_id(provided) or provided
        if account and account ~= "" and exists(steam_root .. "\\userdata\\" .. account) then return account end
        if not provided:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and exists(steam_root .. "\\userdata\\" .. provided) then return provided end
    end

    local recent = account_from_loginusers(steam_root)
    if recent and recent ~= "" and exists(steam_root .. "\\userdata\\" .. recent) then return recent end

    local ids = list_numeric_userdata(steam_root)
    if #ids == 1 then return ids[1] end
    return recent or ""
end

function M.account_id_to_steam64(account_id)
    if not is_numeric(account_id) then return "" end
    return decimal_add(tostring(account_id), STEAM_ID64_BASE)
end

function M.steam64_to_account_id(steam64)
    return steam64_to_account_id(steam64) or ""
end

function M.steam_user_ids(steam_root, provided)
    steam_root = normalize_slashes(steam_root or M.steam_root())
    local account = M.resolve_account_id(steam_root, provided)
    local steam64 = ""
    provided = trim(provided)
    if provided:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then steam64 = provided end
    if steam64 == "" and account ~= "" then steam64 = M.account_id_to_steam64(account) end
    local ids = {}
    local seen = {}
    local function add(id)
        id = trim(id)
        if id ~= "" and is_numeric(id) and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    add(account)
    add(steam64)
    add(provided)
    return ids
end

function M.steam_libraries(steam_root)
    steam_root = normalize_slashes(steam_root)
    local result = { steam_root }
    local seen = { [steam_root:lower()] = true }
    local content = read_file(steam_root .. "\\steamapps\\libraryfolders.vdf")
    if content then
        for path in content:gmatch('"path"%s+"([^"]+)"') do
            path = normalize_slashes(path:gsub("\\\\", "\\"))
            if path ~= "" and not seen[path:lower()] then
                seen[path:lower()] = true
                table.insert(result, path)
            end
        end
    end
    return result
end

function M.installed_app_ids(steam_root)
    steam_root = normalize_slashes(steam_root or M.steam_root())
    local result = {}
    local seen = {}
    for _, library in ipairs(M.steam_libraries(steam_root)) do
        local steamapps = library .. "\\steamapps"
        for _, entry in ipairs(list_dir(steamapps)) do
            local name = basename(entry)
            local app_id = tostring(name or ""):match("^appmanifest_(%d+)%.acf$")
            if app_id and not seen[app_id] then
                seen[app_id] = true
                table.insert(result, app_id)
            end
        end
    end
    table.sort(result, function(a, b) return tonumber(a) < tonumber(b) end)
    return result
end

function M.game_install_dir(steam_root, app_id)
    app_id = trim(app_id)
    if app_id == "" then return "" end
    for _, library in ipairs(M.steam_libraries(steam_root)) do
        local manifest = read_file(library .. "\\steamapps\\appmanifest_" .. app_id .. ".acf")
        if manifest then
            local installdir = manifest:match('"installdir"%s+"([^"]+)"')
            if installdir and installdir ~= "" then
                return library .. "\\steamapps\\common\\" .. normalize_slashes(installdir:gsub("\\\\", "\\"))
            end
        end
    end
    return ""
end

function M.documents_dir()
    local candidates = {
        known_folder("Personal"),
    }
    local userprofile = env("USERPROFILE")
    if userprofile ~= "" then table.insert(candidates, normalize_slashes(userprofile) .. "\\Documents") end
    for _, candidate in ipairs(candidates) do
        if candidate ~= "" and exists(candidate) then return candidate end
    end
    return candidates[1] ~= "" and candidates[1] or ""
end

function M.saved_games_dir()
    local candidates = {
        known_folder("{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}"),
        known_folder("SavedGames"),
    }
    local userprofile = env("USERPROFILE")
    if userprofile ~= "" then table.insert(candidates, normalize_slashes(userprofile) .. "\\Saved Games") end
    for _, candidate in ipairs(candidates) do
        if candidate ~= "" and exists(candidate) then return candidate end
    end
    return candidates[1] ~= "" and candidates[1] or ""
end

function M.local_low_dir()
    local local_appdata = env("LOCALAPPDATA")
    if local_appdata ~= "" then return dirname(normalize_slashes(local_appdata)) .. "\\LocalLow" end
    local userprofile = env("USERPROFILE")
    if userprofile ~= "" then return normalize_slashes(userprofile) .. "\\AppData\\LocalLow" end
    return ""
end

function M.ubisoft_connect_folder()
    local candidates = {
        registry_string("HKLM", "SOFTWARE\\WOW6432Node\\Ubisoft\\Launcher", "InstallDir"),
        registry_string("HKLM", "SOFTWARE\\Ubisoft\\Launcher", "InstallDir"),
        registry_string("HKCU", "Software\\Ubisoft\\Launcher", "InstallDir"),
        registry_string("HKLM", "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Uplay", "InstallLocation"),
        registry_string("HKLM", "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Uplay", "InstallLocation"),
        registry_string("HKLM", "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ubisoft Connect", "InstallLocation"),
        registry_string("HKLM", "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ubisoft Connect", "InstallLocation"),
        registry_string("HKLM", "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ubisoft Game Launcher", "InstallLocation"),
        registry_string("HKLM", "SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ubisoft Game Launcher", "InstallLocation"),
        env("PROGRAMFILES(X86)") .. "\\Ubisoft\\Ubisoft Game Launcher",
        env("PROGRAMFILES") .. "\\Ubisoft\\Ubisoft Game Launcher",
        env("LOCALAPPDATA") .. "\\Ubisoft Game Launcher",
        env("PROGRAMDATA") .. "\\Ubisoft\\Ubisoft Game Launcher",
        env("PROGRAMDATA") .. "\\Ubisoft Game Launcher",
    }
    local extra_roots = { "C:", "D:", "E:", "F:", "G:" }
    local suffixes = {
        "Ubisoft\\Ubisoft Game Launcher",
        "Ubisoft Game Launcher",
        "Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher",
        "Program Files\\Ubisoft\\Ubisoft Game Launcher",
        "Games\\Ubisoft\\Ubisoft Game Launcher",
        "Games\\Ubisoft Game Launcher",
    }
    for _, root in ipairs(extra_roots) do
        for _, suffix in ipairs(suffixes) do table.insert(candidates, root .. "\\" .. suffix) end
    end
    for _, candidate in ipairs(candidates) do
        candidate = normalize_slashes(candidate)
        if candidate ~= "" and exists(candidate) then return candidate end
        if candidate ~= "" and exists(candidate .. "\\savegames") then return candidate end
    end
    for _, root in ipairs(extra_roots) do
        for _, parent in ipairs({ root .. "\\", root .. "\\Games", root .. "\\Program Files", root .. "\\Program Files (x86)", root .. "\\Ubisoft" }) do
            if exists(parent) then
                for _, child in ipairs(list_dir(parent)) do
                    local name = basename(child)
                    if name:lower():find("ubisoft", 1, true) then
                        local candidate = normalize_slashes(parent .. "\\" .. name .. "\\Ubisoft Game Launcher")
                        if exists(candidate) or exists(candidate .. "\\savegames") then return candidate end
                        candidate = normalize_slashes(parent .. "\\" .. name)
                        if exists(candidate .. "\\savegames") then return candidate end
                    end
                end
            end
        end
    end
    return candidates[1] or ""
end

function M.set_launcher_ids(rockstar_id, ubisoft_id)
    M.rockstar_id = trim(rockstar_id)
    M.ubisoft_id = trim(ubisoft_id)
end

local function launcher_context(path)
    local lower = tostring(path or ""):lower()
    if lower:find("rockstar", 1, true) then return "rockstar" end
    if lower:find("ubisoft", 1, true) or lower:find("ubisoft game launcher", 1, true) then return "ubisoft" end
    return ""
end

local function replace_generic_profile_tokens(path, profile_id)
    path = path:gsub("<[Uu]ser%-id>", profile_id)
    path = path:gsub("<[Uu]ser [Ii][Dd]>", profile_id)
    path = path:gsub("<[Pp]rofile%-id>", profile_id)
    path = path:gsub("<[Pp]rofile [Ii][Dd]>", profile_id)
    path = path:gsub("%[userid%]", profile_id)
    path = path:gsub("%[user%-id%]", profile_id)
    return path
end

local function apply_launcher_profile_ids(path)
    local context = launcher_context(path)
    local lower = tostring(path or ""):lower()
    if M.rockstar_id and M.rockstar_id ~= "" then
        path = path:gsub("<[Rr]ockstar[^>]*[Uu]ser[^>]*>", M.rockstar_id)
        path = path:gsub("<[Rr]ockstar[^>]*[Pp]rofile[^>]*>", M.rockstar_id)
        path = path:gsub("<[Rr]ockstar[^>]*[Ii][Dd][^>]*>", M.rockstar_id)
        path = path:gsub("%[rockstar%-?userid%]", M.rockstar_id)
        path = path:gsub("%[rockstar%-?profile%]", M.rockstar_id)
        path = path:gsub("%[rockstar%-?id%]", M.rockstar_id)
        if context == "rockstar" then
            path = replace_generic_profile_tokens(path, M.rockstar_id)
            path = path:gsub("%*", M.rockstar_id)
            if lower:find("\\profiles\\%*$") then path = path:gsub("\\%*$", "\\" .. M.rockstar_id) end
            if path:lower():match("\\profiles$") then path = path .. "\\" .. M.rockstar_id end
        end
    end
    if M.ubisoft_id and M.ubisoft_id ~= "" then
        path = path:gsub("<[Uu]bisoft[^>]*[Uu]ser[^>]*>", M.ubisoft_id)
        path = path:gsub("<[Uu]bisoft[^>]*[Pp]rofile[^>]*>", M.ubisoft_id)
        path = path:gsub("%[ubisoft%-?userid%]", M.ubisoft_id)
        path = path:gsub("%[ubisoft%-?profile%]", M.ubisoft_id)
        if context == "ubisoft" then
            path = replace_generic_profile_tokens(path, M.ubisoft_id)
            if lower:find("\\savegames\\%*$") then path = path:gsub("\\%*$", "\\" .. M.ubisoft_id) end
            if lower:find("\\savegames\\[^\\]+\\%*") then path = path:gsub("\\[^\\]+\\%*", "\\" .. M.ubisoft_id .. "\\*") end
            if path:lower():match("\\savegames$") then path = path .. "\\" .. M.ubisoft_id end
        end
    end
    return path
end

function M.user_dirs()
    local user_profile = env("USERPROFILE")
    return {
        home = user_profile,
        userProfile = user_profile,
        documents = M.documents_dir(),
        savedGames = M.saved_games_dir(),
        localAppData = env("LOCALAPPDATA"),
        localLow = M.local_low_dir(),
        appData = env("APPDATA"),
    }
end

local function has_unresolved(path)
    local value = tostring(path or "")
    local lower = value:lower()
    return value:find("<[^>]+>") ~= nil or value:find("%%[%w_]+%%") ~= nil or lower:find("[userid]", 1, true) ~= nil or lower:find("[user-id]", 1, true) ~= nil
end

function M.has_unresolved(path)
    return has_unresolved(path)
end

function M.list_dir(path)
    return list_dir(path)
end

function M.children(path)
    local result = {}
    local base = normalize_slashes(path):gsub("\\+$", "")
    for _, entry in ipairs(list_dir(base)) do
        local value = ""
        if type(entry) == "table" then
            value = normalize_slashes(entry.path or entry.fullPath or entry.name or "")
        else
            value = normalize_slashes(entry)
        end
        if value ~= "" then
            if not M.is_absolute_windows_path(value) then value = base .. "\\" .. basename(value) end
            table.insert(result, value)
        end
    end
    return result
end

function M.exists(path)
    return exists(path)
end

function M.is_absolute_windows_path(path)
    local value = tostring(path or "")
    return value:match("^%a:[\\/]") ~= nil or value:match("^[\\/][\\/]") ~= nil
end

local function apply_env(path)
    local replacements = {
        { "%DOCUMENTS%", M.documents_dir() },
        { "%USERPROFILE%\\Documents", M.documents_dir() },
        { "%USERPROFILE%\\Saved Games", M.saved_games_dir() },
        { "%USERPROFILE%\\AppData\\LocalLow", M.local_low_dir() },
        { "%USERPROFILE%", env("USERPROFILE") },
        { "%APPDATA%", env("APPDATA") },
        { "%LOCALAPPDATA%", env("LOCALAPPDATA") },
        { "%PROGRAMDATA%", env("PROGRAMDATA") },
        { "%PUBLIC%", env("PUBLIC") },
    }
    for _, replacement in ipairs(replacements) do
        local key, value = replacement[1], replacement[2]
        if value and value ~= "" then path = replace_literal(path, key, normalize_slashes(value)) end
    end
    return path
end

function M.expand(raw_path, context)
    context = context or {}
    local steam_root = normalize_slashes(context.steam_root or M.steam_root())
    local app_id = trim(context.app_id)
    local account_id = trim(context.account_id)
    local game_dir = M.game_install_dir(steam_root, app_id)

    local path = normalize_slashes(raw_path)
    path = replace_literal(path, "<home>", env("USERPROFILE"))
    path = replace_literal(path, "<Home>", env("USERPROFILE"))
    path = replace_literal(path, "<HOME>", env("USERPROFILE"))
    path = path:gsub("<[%w ]*[Pp]ath%-to%-game>", game_dir)
    path = path:gsub("<[Pp]ath to game>", game_dir)
    path = path:gsub("<[Gg]ame folder>", game_dir)
    path = path:gsub("<[Gg]ame directory>", game_dir)
    path = path:gsub("<[Ii]nstall dir>", game_dir)
    path = path:gsub("<[Ii]nstall directory>", game_dir)
    path = path:gsub("<[Bb]ase>", game_dir)
    path = path:gsub("<[Rr]oot>", steam_root)
    path = path:gsub("<[Ss]team%-folder>", steam_root)
    path = path:gsub("<[Ss]team folder>", steam_root)
    path = path:gsub("<[Ss]team>", steam_root)
    path = path:gsub("<[Uu]bisoft%-[Cc]onnect%-folder>", M.ubisoft_connect_folder())
    path = path:gsub("<[Uu]bisoft [Cc]onnect folder>", M.ubisoft_connect_folder())
    path = path:gsub("<[Uu]bisoft%-[Gg]ame%-[Ll]auncher%-folder>", M.ubisoft_connect_folder())
    path = path:gsub("<[Uu]bisoft [Gg]ame [Ll]auncher folder>", M.ubisoft_connect_folder())
    path = path:gsub("<[Hh]ome>", env("USERPROFILE"))
    path = path:gsub("<[Ww]in[Dd]ocuments>", M.documents_dir())
    path = path:gsub("<[Ww]in[Aa]pp[Dd]ata>", env("APPDATA"))
    path = path:gsub("<[Ww]in[Ll]ocal[Aa]pp[Dd]ata[Ll]ow>", M.local_low_dir())
    path = path:gsub("<[Ww]in[Ll]ocal[Aa]pp[Dd]ata>", env("LOCALAPPDATA"))
    path = path:gsub("<[Ww]in[Pp]rogram[Dd]ata>", env("PROGRAMDATA"))
    path = path:gsub("<[Ww][Pp]ublic>", env("PUBLIC"))
    path = path:gsub("<[Ww]in[Pp]ublic>", env("PUBLIC"))
    path = path:gsub("<[Ww]in[Dd]ir>", env("WINDIR") ~= "" and env("WINDIR") or "C:\\Windows")
    path = path:gsub("<[Oo][Ss][Uu]ser[Nn]ame>", env("USERNAME"))
    local use_store_user_id64 = context.store_user_id_kind == "steam64"
    if account_id ~= "" then
        local steam64 = account_id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and account_id or M.account_id_to_steam64(account_id)
        local account = account_id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and M.steam64_to_account_id(account_id) or account_id
        path = path:gsub("<[Ss]tore[Uu]ser[Ii]d>", use_store_user_id64 and steam64 or account)
        path = path:gsub("<[Ss]team%-user%-id>", account)
        path = path:gsub("<[Ss]team user ID>", account)
        path = path:gsub("<SteamID3>", account)
        if steam64 ~= "" then
            path = path:gsub("<[Ss]teamID64>", steam64)
            path = path:gsub("<[Ss]team [Ii][Dd]64>", steam64)
            path = path:gsub("<[Ss]team%-id64>", steam64)
        end
    end
    path = apply_launcher_profile_ids(path)
    path = path:gsub("<[Gg]ame%-id>", app_id)
    path = path:gsub("<[Gg]ame [Ii][Dd]>", app_id)
    path = path:gsub("<game%-id>", app_id)
    path = path:gsub("<appid>", app_id)
    path = path:gsub("<app%-id>", app_id)
    path = path:gsub("<[Ss]team [Aa]pp[Ii][Dd]>", app_id)
    path = path:gsub("<[Ss]tore[Gg]ame[Ii]d>", app_id)
    if game_dir ~= "" then path = path:gsub("<[Gg]ame>", basename(game_dir)) end
    path = apply_env(path)
    path = path:gsub("[\\/]+", "\\")
    if path:lower():find("^\\appdata\\") then path = env("USERPROFILE") .. path end
    return path
end

local function append_unique(result, seen, path)
    path = normalize_slashes(trim(path)):gsub("\\+$", "")
    if path == "" then return end
    local key = path:lower()
    if seen[key] then return end
    seen[key] = true
    table.insert(result, path)
end

local function wildcard_candidates(path)
    local result = {}
    if not path:find("%*") then return result end
    if launcher_context(path) == "rockstar" and not (M.rockstar_id and M.rockstar_id ~= "") then return result end
    local prefix, suffix = path:match("^(.-)%*(.*)$")
    prefix = normalize_slashes(prefix or "")
    suffix = normalize_slashes(suffix or "")
    local parent = prefix:gsub("\\+$", "")
    for _, entry in ipairs(list_dir(parent)) do
        local name = basename(entry)
        if name ~= "" then
            local candidate = parent .. "\\" .. name .. suffix
            if exists(candidate) then table.insert(result, candidate) end
        end
    end
    return result
end

local function launcher_user_candidates(path)
    local result = {}
    local value = normalize_slashes(trim(path))
    if value == "" then return result end
    local lower = value:lower()
    local token_start, token_end = lower:find("<user%-id>", 1, false)
    if not token_start then token_start, token_end = lower:find("<user id>", 1, true) end
    if not token_start then token_start, token_end = lower:find("[userid]", 1, true) end
    if not token_start then token_start, token_end = lower:find("[user-id]", 1, true) end
    if not token_start then return result end

    local prefix = value:sub(1, token_start - 1):gsub("\\+$", "")
    local suffix = value:sub(token_end + 1):gsub("^\\+", "")
    if prefix == "" or suffix == "" or not exists(prefix) then return result end
    for _, entry in ipairs(list_dir(prefix)) do
        local name = basename(entry)
        if name ~= "" then
            local candidate = prefix .. "\\" .. name .. "\\" .. suffix
            if exists(candidate) then table.insert(result, candidate) end
        end
    end
    return result
end

local function variable_leaf_candidates(path)
    local result = {}
    if exists(path) or not path:find("<[^>]+>") then return result end
    local wildcard = path:gsub("<[^>]+>", "*")
    for _, candidate in ipairs(wildcard_candidates(wildcard)) do table.insert(result, candidate) end
    return result
end

local function launcher_unknown_user_parent(path)
    local value = normalize_slashes(trim(path)):gsub("\\+$", "")
    if value == "" then return "" end

    local lower = value:lower()
    local marker_start, marker_end = lower:find("\\rockstar games\\", 1, true)
    local launcher = "rockstar"
    if not marker_start then marker_start, marker_end = lower:find("\\ubisoft\\", 1, true); launcher = "ubisoft" end
    if not marker_start then marker_start, marker_end = lower:find("\\ubisoft game launcher\\", 1, true); launcher = "ubisoft" end
    if not marker_start then return "" end
    if launcher == "rockstar" and M.rockstar_id and M.rockstar_id ~= "" then return "" end
    if launcher == "ubisoft" and M.ubisoft_id and M.ubisoft_id ~= "" then return "" end
    if launcher == "ubisoft" and lower:find("\\savegames\\", 1, true) then
        local savegames = value:sub(1, lower:find("\\savegames\\", 1, true) + 9)
        return savegames:gsub("\\+$", "")
    end

    local tail = value:sub(marker_end + 1)
    local segments = {}
    for segment in tail:gmatch("[^\\]+") do table.insert(segments, segment) end

    for index, segment in ipairs(segments) do
        local segment_lower = segment:lower()
        local previous_lower = index > 1 and segments[index - 1]:lower() or ""
        local is_unknown = segment_lower == "*" or segment_lower:find("[userid]", 1, true) ~= nil or segment_lower:find("[user-id]", 1, true) ~= nil or segment_lower:find("<[^>]*[Uu]ser[^>]*>") ~= nil or segment_lower:find("<[^>]*[Ii][Dd][^>]*>") ~= nil
        if is_unknown or previous_lower == "profiles" or (launcher == "ubisoft" and (previous_lower == "savegames" or previous_lower == "saves")) then
            local parent_segments = {}
            for parent_index = 1, index - 1 do table.insert(parent_segments, segments[parent_index]) end
            local parent_tail = table.concat(parent_segments, "\\")
            local marker_prefix = value:sub(1, marker_end):gsub("\\+$", "")
            local parent = marker_prefix .. (parent_tail ~= "" and "\\" .. parent_tail or "")
            if parent ~= "" then return parent end
        end
    end

    return ""
end

local function launcher_id_missing_parent(path)
    local value = normalize_slashes(trim(path)):gsub("\\+$", "")
    if value == "" then return "" end
    local launcher = launcher_context(value)
    if launcher == "rockstar" and M.rockstar_id and M.rockstar_id ~= "" then return "" end
    if launcher == "ubisoft" and M.ubisoft_id and M.ubisoft_id ~= "" then return "" end
    local lower = value:lower()
    local token_start = lower:find("<user%-id>", 1, false)
    if not token_start then token_start = lower:find("<user id>", 1, true) end
    if not token_start then token_start = lower:find("[userid]", 1, true) end
    if not token_start then token_start = lower:find("[user-id]", 1, true) end
    if not token_start then return "" end
    local parent = value:sub(1, token_start - 1):gsub("\\+$", "")
    if parent ~= "" and exists(parent) then return parent end
    return ""
end

function M.launcher_parent_for_missing_id(path)
    if not has_unresolved(path) then return "" end
    return launcher_id_missing_parent(path)
end

function M.nearest_existing_parent(path)
    path = normalize_slashes(trim(path)):gsub("\\+$", "")
    if path == "" then return "" end
    local launcher_parent = launcher_unknown_user_parent(path)
    if launcher_parent ~= "" and not has_unresolved(launcher_parent) and exists(launcher_parent) then return launcher_parent end
    while path ~= "" do
        if not has_unresolved(path) and exists(path) then return path end
        local parent = dirname(path)
        if parent == path then break end
        path = parent
    end
    return ""
end

function M.launcher_parent_for_unknown_user(path)
    local parent = launcher_unknown_user_parent(path)
    if parent ~= "" and not has_unresolved(parent) and exists(parent) then return parent end
    return ""
end

function M.userdata_app_dirs(steam_root, app_id, account_id)
    local result = {}
    local seen = {}
    steam_root = normalize_slashes(steam_root or M.steam_root())
    app_id = trim(app_id)
    account_id = trim(account_id)
    if steam_root == "" or app_id == "" then return result end

    local accounts = {}
    local account_seen = {}
    local function add_account(id)
        id = trim(id)
        if not is_numeric(id) then return end
        if not account_seen[id] then
            account_seen[id] = true
            table.insert(accounts, id)
        end
        local steam64 = id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and id or M.account_id_to_steam64(id)
        if steam64 ~= "" and not account_seen[steam64] then
            account_seen[steam64] = true
            table.insert(accounts, steam64)
        end
        local account = id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and M.steam64_to_account_id(id) or ""
        if account ~= "" and not account_seen[account] then
            account_seen[account] = true
            table.insert(accounts, account)
        end
    end

    add_account(account_id)
    if #accounts == 0 then add_account(M.resolve_account_id(steam_root, "")) end

    for _, id in ipairs(accounts) do
        local path = steam_root .. "\\userdata\\" .. id .. "\\" .. app_id
        if exists(path) then append_unique(result, seen, path) end
    end
    return result
end

local function store_user_id_variants(raw_path, context)
    local result = {}
    local value = tostring(raw_path or "")
    if not value:find("<[Ss]tore[Uu]ser[Ii]d>") then return result end
    context = context or {}
    local account_id = trim(context.account_id)
    if account_id == "" then return result end
    local steam64 = account_id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and account_id or M.account_id_to_steam64(account_id)
    local account = account_id:match("^7656119%d%d%d%d%d%d%d%d%d%d$") and M.steam64_to_account_id(account_id) or account_id
    local seen = {}
    local function add(kind)
        local copy = {}
        for key, child in pairs(context) do copy[key] = child end
        copy.store_user_id_kind = kind
        local expanded = M.expand(value, copy)
        local key = expanded:lower()
        if expanded ~= "" and not seen[key] then
            seen[key] = true
            table.insert(result, expanded)
        end
    end
    if context.store_user_id_kind == "steam64" then
        if steam64 ~= "" then add("steam64") end
        if account ~= "" then add("account") end
    else
        if account ~= "" then add("account") end
        if steam64 ~= "" then add("steam64") end
    end
    return result
end

function M.resolve_candidates(raw_path, context)
    local result = {}
    local seen = {}
    local expanded = M.expand(raw_path, context)
    local launcher = launcher_context(expanded)

    if launcher == "rockstar" then
        append_unique(result, seen, expanded)
        return result
    end
    if launcher == "ubisoft" then
        append_unique(result, seen, expanded)
        return result
    end

    for _, variant in ipairs(store_user_id_variants(raw_path, context)) do
        for _, candidate in ipairs(wildcard_candidates(variant)) do append_unique(result, seen, candidate) end
        for _, candidate in ipairs(variable_leaf_candidates(variant)) do append_unique(result, seen, candidate) end
        append_unique(result, seen, variant)
    end
    for _, candidate in ipairs(wildcard_candidates(expanded)) do append_unique(result, seen, candidate) end
    for _, candidate in ipairs(launcher_user_candidates(expanded)) do append_unique(result, seen, candidate) end
    for _, candidate in ipairs(variable_leaf_candidates(expanded)) do append_unique(result, seen, candidate) end
    append_unique(result, seen, expanded)

    return result
end

return M
