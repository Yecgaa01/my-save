local logger = require("logger")
local millennium = require("millennium")
local json = require("json")
local io = require("io")
local http = require("http")
local ok_ffi, ffi = pcall(require, "ffi")
local pcgw = require("pcgw")
local paths = require("paths")

local function backend_path()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", ""):gsub("/", "\\")
    local path = source:match("^(.*)\\[^\\]+$")
    return path or ".\\backend"
end

local SETTINGS_FILE = backend_path() .. "\\settings.json"
local UBISOFT_IDS_FILE = backend_path() .. "\\ubisoft-gameids.json"
local UBISOFT_IDS_CACHE_FILE = backend_path() .. "\\ubisoft-gameids-cache.json"
local UBISOFT_IDS_UPDATER_CACHE_FILE = backend_path() .. "\\ubisoft-gameids-updater-cache.json"
local UBISOFT_IDS_UPDATER_URL = "https://raw.githubusercontent.com/Yecgaa01/pp-updater/refs/heads/main/backend/ubisoft-gameids-updater-cache.json"
local UBISOFT_IDS_UPDATER_TTL = 86400
local CACHE_FILE = backend_path() .. "\\my-save-cache.json"
local LS_STEAM_FILE = backend_path() .. "\\LS.json"
local PCGW_LOCAL_DATA_FILE = backend_path() .. "\\pcgw-paths.json"
local ONLINE_ONLY_FILE = backend_path() .. "\\online-only-games.json"


local function safe_encode(value)
    local ok, encoded = pcall(json.encode, value)
    if ok then return encoded end
    return "{\"success\":false,\"error\":\"JSON encode failed\"}"
end

local json_cache = {}
local update_ubisoft_ids_from_remote

local shell32 = nil
local kernel32 = nil
if ok_ffi then
    pcall(function()
        ffi.cdef[[
            typedef void* HWND;
            typedef const wchar_t* LPCWSTR;
            typedef void* HINSTANCE;
            HINSTANCE ShellExecuteW(HWND hwnd, LPCWSTR lpOperation, LPCWSTR lpFile, LPCWSTR lpParameters, LPCWSTR lpDirectory, int nShowCmd);
            void Sleep(unsigned long dwMilliseconds);
        ]]
        shell32 = ffi.load("shell32")
        kernel32 = ffi.load("kernel32")
    end)
end

local function wchar_array(str)
    if not ok_ffi then return nil end
    str = tostring(str or "")
    local arr = ffi.new("wchar_t[?]", #str + 1)
    for i = 1, #str do arr[i - 1] = str:byte(i) end
    arr[#str] = 0
    return arr
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function open_folder_silent(path)
    if not shell32 then return false end
    local target = tostring(path or "")
    local result = shell32.ShellExecuteW(nil, wchar_array("explore"), wchar_array(target), nil, nil, 5)
    return tonumber(ffi.cast("intptr_t", result)) > 32
end

local function run_powershell_hidden(script)
    if not shell32 then return false end
    script = tostring(script or "")
    if script == "" then return false end
    local params = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' .. script .. '"'
    local result = shell32.ShellExecuteW(nil, wchar_array("open"), wchar_array("powershell.exe"), wchar_array(params), nil, 0)
    return tonumber(ffi.cast("intptr_t", result)) > 32
end

local function wait_for_path(path, should_exist)
    for _ = 1, 40 do
        local exists = paths.exists(path)
        if should_exist and exists then return true end
        if not should_exist and not exists then return true end
        if kernel32 then kernel32.Sleep(250) end
    end
    return should_exist and paths.exists(path) or not paths.exists(path)
end


local function sanitize_backup_name(value)
    value = tostring(value or "")
    value = value:gsub("[<>:\"/\\|%?%*]", " ")
    value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return "Save folder" end
    if #value > 80 then value = value:sub(1, 80):gsub("%s+$", "") end
    return value
end

local function timestamp_name()
    return os.date("%Y-%m-%d_%H-%M-%S")
end

local function unique_path(base)
    if not paths.exists(base) then return base end
    for index = 2, 99 do
        local candidate = base .. " (" .. tostring(index) .. ")"
        if not paths.exists(candidate) then return candidate end
    end
    return base .. " (" .. tostring(os.time()) .. ")"
end

local function default_backup_root()
    local dirs = paths.user_dirs()
    local root = tostring(dirs.savedGames or "")
    if root == "" then root = tostring(dirs.documents or "") end
    if root == "" then root = tostring(dirs.userProfile or dirs.home or "") end
    if root == "" then return "" end
    return root:gsub("[\\/]+$", "") .. "\\My Save Backups"
end

local function backup_root(settings)
    settings = settings or load_settings()
    local root = trim(settings.backupRoot or "")
    if root == "" then root = default_backup_root() end
    return root:gsub("[\\/]+", "\\"):gsub("\\+$", "")
end

local function ensure_dir(path)
    path = tostring(path or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    if path == "" then return false end
    if paths.exists(path) then return true end
    local escaped_path = path:gsub("'", "''")
    local script = "New-Item -ItemType Directory -Force -Path '" .. escaped_path .. "' | Out-Null"
    if not run_powershell_hidden(script) then return false end
    return wait_for_path(path, true)
end

local function backup_game_folder(root, app_id, game_name)
    local id = tostring(app_id or "")
    local name = sanitize_backup_name((id ~= "" and (id .. " - ") or "") .. tostring(game_name or "Game"))
    return root:gsub("[\\/]+$", "") .. "\\" .. name
end

local function backup_metadata_path(path)
    return tostring(path or ""):gsub("[\\/]+$", "") .. "\\.my-save-backup.json"
end

local function write_backup_metadata(path, data)
    local file = io.open(backup_metadata_path(path), "w")
    if not file then return false end
    file:write(safe_encode(data or {}))
    file:close()
    return true
end

local function read_backup_metadata(path)
    local file = io.open(backup_metadata_path(path), "r")
    if not file then return {} end
    local content = file:read("*all")
    file:close()
    local ok, parsed = pcall(json.decode, content or "")
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

local function remove_folder(path)
    path = tostring(path or "")
    if path == "" then return false end
    if not paths.exists(path) then return true end
    local escaped_path = path:gsub("'", "''")
    local script = "Remove-Item -LiteralPath '" .. escaped_path .. "' -Recurse -Force"
    if not run_powershell_hidden(script) then return false end
    return wait_for_path(path, false)
end

local function wait_for_copy(source, target)
    for _ = 1, 80 do
        if paths.exists(target) then
            local source_count = 0
            local target_count = 0
            for _, _ in ipairs(paths.children(source)) do source_count = source_count + 1 end
            for _, _ in ipairs(paths.children(target)) do target_count = target_count + 1 end
            if source_count == 0 or target_count > 0 then return true end
        end
        if kernel32 then kernel32.Sleep(250) end
    end
    return paths.exists(target)
end

local function copy_folder(source, target)
    source = tostring(source or "")
    target = tostring(target or "")
    if source == "" or target == "" then return false, "Invalid path" end
    if not paths.exists(source) then return false, "Source folder does not exist" end
    if not ensure_dir(target) then return false, "Unable to create target folder" end
    local escaped_source = source:gsub("'", "''")
    local escaped_target = target:gsub("'", "''")
    local script = "$source = '" .. escaped_source .. "'; $target = '" .. escaped_target .. "'; Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $target -Recurse -Force"
    if not run_powershell_hidden(script) then return false, "Copy failed" end
    if wait_for_copy(source, target) then return true end
    return false, "Copy did not finish"
end

local function clean_pre_restore_backups(base_folder)
    if not paths.exists(base_folder) then return 0 end
    local cleaned = 0
    for _, child in ipairs(paths.children(base_folder)) do
        local name = tostring(child):match("([^\\/]+)$") or ""
        if name:match("^pre%-restore%-") then
            if remove_folder(child) then cleaned = cleaned + 1 end
        end
    end
    if cleaned > 0 then logger:info("GetSaveFolders cleaned pre-restore backups count=" .. tostring(cleaned) .. ", folder=" .. base_folder) end
    return cleaned
end

local function valid_save_source(item)
    if type(item) ~= "table" then return nil, "Missing save item" end
    local source = tostring(item.openPath or item.path or "")
    if tostring(item.kind or "") ~= "save" then return nil, "Item is not a save folder" end
    if item.exists ~= true then return nil, "Save folder is not on disk" end
    if item.unresolved == true or paths.has_unresolved(source) then return nil, "Save path has unresolved placeholders" end
    if source == "" or not paths.is_absolute_windows_path(source) then return nil, "Save path must be absolute" end
    if not paths.exists(source) then return nil, "Save folder does not exist" end
    return source, nil
end

local function backup_source_for_item(item)
    local source, err = valid_save_source(item)
    if not source then return nil, err end
    return source, source
end

local function parse_backup_arg_string(value)
    value = tostring(value or "")
    if value:sub(1, 16) == "backup-settings|" then
        local root, allow = value:match("^backup%-settings|(.-)|(.*)$")
        return { backupRoot = root or "", allowMultipleBackups = allow ~= "false" and allow ~= "0" }
    end
    if value:sub(1, 19) == "choose-backup-root|" then
        return { mode = "choose", initialPath = value:sub(20) }
    end
    if value:sub(1, 18) == "open-backup-root|" then
        return { backupRoot = value:sub(19) }
    end
    if value:sub(1, 18) == "create-backup-dir|" then
        return { mode = "create", appId = value:sub(19) }
    end
    return nil
end

local function find_backup_arg(value, depth)
    depth = depth or 0
    if depth > 6 then return nil end
    if type(value) == "string" then
        local parsed_string = parse_backup_arg_string(value)
        if parsed_string then return parsed_string end
        local ok, parsed = pcall(json.decode, value)
        if ok and type(parsed) == "table" then return find_backup_arg(parsed, depth + 1) end
        if ok and type(parsed) == "string" then return find_backup_arg(parsed, depth + 1) end
        return nil
    end
    if type(value) == "table" then
        if value.backupRoot ~= nil or value.allowMultipleBackups ~= nil or value.initialPath ~= nil or value.item ~= nil or value.save ~= nil or value.appId ~= nil or value.app_id ~= nil or value.backupPath ~= nil or value.savePath ~= nil or value.save_path ~= nil then return value end
        for _, key in ipairs({ "argumentList", 1, "args", "payload" }) do
            local found = find_backup_arg(value[key], depth + 1)
            if found then return found end
        end
        for _, nested in pairs(value) do
            local found = find_backup_arg(nested, depth + 1)
            if found then return found end
        end
    end
    return nil
end

local function normalize_backup_args(args)
    local backup_arg = find_backup_arg(args)
    if backup_arg then return backup_arg end
    if type(args) == "table" then
        if type(args.argumentList) == "table" then args = args.argumentList end
        if type(args[1]) == "table" and (args[1].item ~= nil or args[1].save ~= nil or args[1].appId ~= nil or args[1].app_id ~= nil) then args = args[1] end
        return args
    end
    return {}
end

local function backup_item_from_args(args)
    if type(args.item) == "table" then return args.item end
    if type(args.save) == "table" then return args.save end
    local explicit_path = trim(args.savePath or args.save_path or args.openPath or args.path or "")
    if explicit_path ~= "" then
        return { kind = "save", exists = true, unresolved = false, openPath = explicit_path, path = explicit_path, label = tostring(args.saveLabel or args.label or "Save folder") }
    end
    if type(args[1]) == "table" and (args[1].kind ~= nil or args[1].openPath ~= nil or args[1].path ~= nil) then return args[1] end
    return {}
end

local function snapshot_label_from_name(name)
    local value = tostring(name or "")
    if value == "Current" then return "Current" end
    local date, hour, minute, second = value:match("^(%d%d%d%d%-%d%d%-%d%d)_(%d%d)%-(%d%d)%-(%d%d)")
    if date then return date .. " " .. hour .. ":" .. minute .. ":" .. second end
    local pre_date, pre_hour, pre_minute, pre_second = value:match("^pre%-restore%-(%d%d%d%d%-%d%d%-%d%d)_(%d%d)%-(%d%d)%-(%d%d)")
    if pre_date then return "pre-restore " .. pre_date .. " " .. pre_hour .. ":" .. pre_minute .. ":" .. pre_second end
    return value
end

local function read_json_file(path)
    if path == LS_STEAM_FILE or path == UBISOFT_IDS_FILE then
        local cached = json_cache[path]
        if cached ~= nil then return cached end
        local file = io.open(path, "r")
        if not file then json_cache[path] = {}; return json_cache[path] end
        local content = file:read("*all")
        file:close()
        local ok, parsed = pcall(json.decode, content or "")
        json_cache[path] = ok and type(parsed) == "table" and parsed or {}
        return json_cache[path]
    end
    local file = io.open(path, "r")
    if not file then return {} end
    local content = file:read("*all")
    file:close()
    local ok, parsed = pcall(json.decode, content or "")
    if ok and type(parsed) == "table" then return parsed end
    return {}
end

local function read_ls_entry(app_id)
    app_id = tostring(app_id or "")
    if app_id == "" then return nil end
    local cached = json_cache[LS_STEAM_FILE .. ":" .. app_id]
    if cached ~= nil then return cached end
    local file = io.open(LS_STEAM_FILE, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    local key = '"' .. app_id .. '":'
    local start_key = content:find(key, 1, true)
    if not start_key then json_cache[LS_STEAM_FILE .. ":" .. app_id] = false; return nil end
    local object_start = content:find("{", start_key + #key, true)
    if not object_start then json_cache[LS_STEAM_FILE .. ":" .. app_id] = false; return nil end
    local depth = 0
    local in_string = false
    local escaped = false
    for index = object_start, #content do
        local char = content:sub(index, index)
        if in_string then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                in_string = false
            end
        else
            if char == '"' then
                in_string = true
            elseif char == "{" then
                depth = depth + 1
            elseif char == "}" then
                depth = depth - 1
                if depth == 0 then
                    local ok, parsed = pcall(json.decode, content:sub(object_start, index))
                    local entry = ok and type(parsed) == "table" and parsed or false
                    json_cache[LS_STEAM_FILE .. ":" .. app_id] = entry
                    if type(entry) == "table" then return entry end
                    return nil
                end
            end
        end
    end
    json_cache[LS_STEAM_FILE .. ":" .. app_id] = false
    return nil
end

local function clear_runtime_caches()
    json_cache = {}
end

local function file_exists(path)
    local file = io.open(path, "r")
    if file then file:close(); return true end
    return false
end

local function write_empty_json(path)
    local file = io.open(path, "w")
    if not file then return false end
    file:write("{}")
    file:close()
    return true
end

local function local_pcgw_cache_entry(remote)
    return {
        page = remote.page,
        url = remote.url,
        saves = remote.saves or {},
        configs = remote.configs or {},
        source = "pcgw",
        timestamp = os.time(),
    }
end

local function load_settings()
    return read_json_file(SETTINGS_FILE)
end

local function write_json_file(path, value)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(safe_encode(value or {}))
    file:close()
    if path == UBISOFT_IDS_FILE or path == LS_STEAM_FILE or path == UBISOFT_IDS_UPDATER_CACHE_FILE then json_cache[path] = nil end
    return true
end

local function decode_arg_table(value)
    if type(value) == "string" and value ~= "" and value:sub(1, 4) == "set|" then
        local rockstar, ubisoft = value:match("^set|(.-)|(.*)$")
        return { rockstarId = rockstar or "", ubisoftId = ubisoft or "", clearEmpty = true }
    end
    if type(value) == "string" and value ~= "" and value:find("|", 1, true) then
        local rockstar, ubisoft = value:match("^(.-)|(.*)$")
        return { rockstarId = rockstar or "", ubisoftId = ubisoft or "" }
    end
    if type(value) == "table" then
        if value.rockstarId ~= nil or value.ubisoftId ~= nil or value.rockstar_id ~= nil or value.ubisoft_id ~= nil or value.app_id ~= nil or value.appId ~= nil or value.force_remote ~= nil or value.forceRemote ~= nil or value.path ~= nil or value.backupRoot ~= nil or value.allowMultipleBackups ~= nil or value.item ~= nil or value.save ~= nil then return value end
        if type(value.argumentList) == "string" then
            local decoded = decode_arg_table(value.argumentList)
            if next(decoded) ~= nil then return decoded end
        end
        if type(value.argumentList) == "table" then
            local args = value.argumentList
            if args.rockstarId ~= nil or args.ubisoftId ~= nil or args.rockstar_id ~= nil or args.ubisoft_id ~= nil or args.app_id ~= nil or args.appId ~= nil or args.force_remote ~= nil or args.forceRemote ~= nil or args.backupRoot ~= nil or args.allowMultipleBackups ~= nil or args.item ~= nil or args.save ~= nil then return args end
            if type(args[1]) == "table" then
                local decoded = decode_arg_table(args[1])
                if next(decoded) ~= nil then return decoded end
            end
            if type(args[1]) == "string" and args[1] ~= "" then
                local decoded = decode_arg_table(args[1])
                if next(decoded) ~= nil then return decoded end
            end
            if type(args[2]) == "string" and args[2] ~= "" then
                local decoded = decode_arg_table(args[2])
                if next(decoded) ~= nil then return decoded end
            end
            return args
        end
        return value
    end
    if type(value) == "string" and value ~= "" then
        local ok, parsed = pcall(json.decode, value)
        if ok and type(parsed) == "table" then return parsed end
    end
    return {}
end

local function first_value(args, ...)
    for _, key in ipairs({ ... }) do
        local value = args[key]
        if value ~= nil then return value end
    end
    return nil
end

local function save_settings(settings)
    local file = io.open(SETTINGS_FILE, "w")
    if not file then return false end
    file:write(safe_encode(settings or {}))
    file:close()
    return true
end

local function first_present(args, ...)
    if type(args) ~= "table" then return nil end
    for _, key in ipairs({ ... }) do
        if args[key] ~= nil then return args[key] end
    end
    return nil
end

local function apply_settings()
    local settings = load_settings()
    paths.set_launcher_ids(settings.rockstarId or "", settings.ubisoftId or "")
    return settings
end

local function merge_launcher_ids_with_settings(rockstar_id, ubisoft_id, rockstar_supplied, ubisoft_supplied)
    local settings = apply_settings()
    local settings_rockstar = trim(settings.rockstarId or "")
    local settings_ubisoft = trim(settings.ubisoftId or "")
    rockstar_id = trim(rockstar_id or "")
    ubisoft_id = trim(ubisoft_id or "")
    if settings_rockstar ~= "" then rockstar_id = settings_rockstar
    elseif not rockstar_supplied and rockstar_id == "" then rockstar_id = settings_rockstar end
    if settings_ubisoft ~= "" then ubisoft_id = settings_ubisoft
    elseif not ubisoft_supplied and ubisoft_id == "" then ubisoft_id = settings_ubisoft end
    paths.set_launcher_ids(rockstar_id, ubisoft_id)
    return rockstar_id, ubisoft_id
end

local function launcher_id(context, launcher)
    if launcher == "rockstar" then return trim(context and context.rockstar_id or "") end
    if launcher == "ubisoft" then return trim(context and context.ubisoft_id or "") end
    return ""
end

local function is_ubisoft_launcher_path(raw_path, context)
    local expanded = paths.expand(raw_path, context)
    local lower = tostring(expanded or raw_path or ""):lower()
    return lower:find("ubisoft", 1, true) ~= nil or lower:find("ubisoft game launcher", 1, true) ~= nil
end

local function explicit_launcher_path(raw_path, context)
    local value = paths.expand(raw_path, context)
    local lower = value:lower()
    local rockstar_id = launcher_id(context, "rockstar")
    local ubisoft_id = launcher_id(context, "ubisoft")
    if rockstar_id ~= "" and lower:find("rockstar", 1, true) and lower:find("\\profiles", 1, true) then
        local prefix = value:match("^(.-\\[Pp]rofiles)")
        if prefix and prefix ~= "" then return prefix .. "\\" .. rockstar_id end
    end
    if ubisoft_id ~= "" and is_ubisoft_launcher_path(raw_path, context) and lower:find("\\savegames", 1, true) then
        local prefix = value:match("^(.-\\[Ss]avegames)")
        if prefix and prefix ~= "" then
            local suffix = value:sub(#prefix + 1):gsub("[\\/]+$", "")
            local game_id = suffix:match("\\[^\\<>%[%]%*]+\\(%d+)$") or suffix:match("\\(%d+)$")
            if game_id then return prefix .. "\\" .. ubisoft_id .. "\\" .. game_id end
            return prefix .. "\\" .. ubisoft_id
        end
    end
    return ""
end

local function store_user_candidates(raw_path, context)
    local result = {}
    local value = tostring(raw_path or "")
    local lower = value:lower():gsub("/", "\\")
    if not lower:find("__steam_store_user_id__", 1, true) and not lower:find("<storeuserid>", 1, true) then return result end
    value = value:gsub("__STEAM_STORE_USER_ID__", "<storeUserId>")
    local ids = paths.steam_user_ids(context and context.steam_root or "", context and context.account_id or "")
    if context and context.steam_id64 and context.steam_id64 ~= "" then table.insert(ids, context.steam_id64) end
    local prefer_steam64 = not (lower:find("\\steam\\", 1, true) or lower:find("<base>", 1, true))
    local ordered = {}
    local function add_ordered(id, front)
        id = tostring(id or "")
        if id == "" then return end
        if front then table.insert(ordered, 1, id) else table.insert(ordered, id) end
    end
    for _, id in ipairs(ids) do
        local text = tostring(id or "")
        add_ordered(text, prefer_steam64 and text:match("^7656119%d+$") ~= nil)
    end
    local seen_ids = {}
    for _, id in ipairs(ordered) do
        if id ~= "" and not seen_ids[id] then
            seen_ids[id] = true
            local candidate = value:gsub("<[Ss]tore[Uu]ser[Ii]d>", id)
            local candidate_context = {}
            for key, context_value in pairs(context or {}) do candidate_context[key] = context_value end
            candidate_context.account_id = id
            if tostring(id):match("^7656119%d+$") then candidate_context.store_user_id_kind = "steam64" end
            candidate = paths.expand(candidate, candidate_context)
            if candidate ~= "" then table.insert(result, candidate) end
        end
    end
    return result
end

local folder_has_meaningful_save_content

local function is_ls_install_dir_path(raw_path)
    local lower = tostring(raw_path or ""):lower():gsub("/", "\\")
    return lower:find("<base>", 1, true) ~= nil
        or lower:find("<path-to-game>", 1, true) ~= nil
        or lower:find("<path to game>", 1, true) ~= nil
        or lower:find("<game folder>", 1, true) ~= nil
        or lower:find("<game directory>", 1, true) ~= nil
        or lower:find("<install dir>", 1, true) ~= nil
        or lower:find("<install directory>", 1, true) ~= nil
end

local function path_inside_game_dir(path, context)
    local game_dir = paths.game_install_dir(context and context.steam_root or "", context and context.app_id or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    local value = tostring(path or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    if game_dir == "" or value == "" then return false end
    local lower_game = game_dir:lower()
    local lower_value = value:lower()
    return lower_value == lower_game or lower_value:sub(1, #lower_game + 1) == lower_game .. "\\"
end

local function install_dir_save_score(path)
    local leaf = tostring(path or ""):gsub("^.*[\\/]", ""):lower()
    local lower = tostring(path or ""):lower()
    local score = 0
    if leaf:match("^%d+$") then score = score + 35 end
    if lower:find("save", 1, true) then score = score + 30 end
    if lower:find("profile", 1, true) then score = score + 15 end
    if lower:find("saved", 1, true) then score = score + 15 end
    if lower:find("binaries", 1, true) or lower:find("engine", 1, true) or lower:find("content", 1, true) or lower:find("plugins", 1, true) then score = score - 80 end
    if folder_has_meaningful_save_content(path) then score = score + 60 end
    return score
end

local function ls_install_dir_fallback(raw_path, context)
    if not is_ls_install_dir_path(raw_path) then return "", false end
    local expanded = paths.expand(raw_path, context):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    if expanded == "" or paths.exists(expanded) or not path_inside_game_dir(expanded, context) then return "", false end

    local parent = expanded
    if paths.has_unresolved(parent) or parent:find("__STEAM_STORE_USER_ID__", 1, true) then
        parent = parent:gsub("__STEAM_STORE_USER_ID__.*$", "")
        parent = parent:gsub("<[Ss]tore[Uu]ser[Ii]d>.*$", "")
        parent = parent:gsub("<[^>]+>.*$", "")
    else
        parent = parent:match("^(.*)\\[^\\]+$") or ""
    end
    parent = tostring(parent or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    if parent == "" or not path_inside_game_dir(parent, context) or not paths.exists(parent) then return "", false end

    local game_dir = paths.game_install_dir(context and context.steam_root or "", context and context.app_id or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    local parent_is_game_root = game_dir ~= "" and parent:lower() == game_dir:lower()
    local best = ""
    local best_score = -999
    local child_count = 0
    for _, child in ipairs(paths.children(parent)) do
        if path_inside_game_dir(child, context) and paths.exists(child) then
            child_count = child_count + 1
            local score = install_dir_save_score(child)
            if score > best_score then
                best = child
                best_score = score
            end
        end
    end
    if best ~= "" and best_score >= 75 then return best, false end
    if not parent_is_game_root and child_count > 1 then return parent, true end
    if not parent_is_game_root and folder_has_meaningful_save_content(parent) then return parent, true end
    return "", false
end

local function ls_install_dir_file_parent(raw_path, path, context)
    if not is_ls_install_dir_path(raw_path) then return "" end
    local value = tostring(path or ""):gsub("[\\/]+", "\\"):gsub("\\+$", "")
    if value == "" or not path_inside_game_dir(value, context) then return "" end
    local leaf = value:match("[^\\]+$") or ""
    if leaf == "" or leaf:find("%.") or leaf:find("*", 1, true) then return "" end
    local parent = value:match("^(.*)\\[^\\]+$") or ""
    if parent ~= "" and path_inside_game_dir(parent, context) and paths.exists(parent) then return parent end
    return ""
end

local function unique_ubisoft_profile_path_for_game_id(raw_path, context)
    local normalized = tostring(raw_path or ""):gsub("/", "\\")
    local game_id = normalized:match("[Ss]avegames\\<[^>]+>\\(%d+)")
        or normalized:match("[Ss]avegames\\%[[^%]]+%]\\(%d+)")
        or normalized:match("[Ss]avegames\\%%[^%%]+%%\\(%d+)")
        or normalized:match("[Ss]avegames\\[^\\<>%[%]%%]+\\(%d+)")
        or ""
    if game_id == "" then return "" end
    local root = paths.ubisoft_connect_folder()
    if root == "" then return "" end
    local savegames = root .. "\\savegames"
    if not paths.exists(savegames) then return "" end
    local match = ""
    local count = 0
    for _, profile in ipairs(paths.children(savegames)) do
        local candidate = profile .. "\\" .. game_id
        if paths.exists(candidate) then
            count = count + 1
            match = candidate
            if count > 1 then return "" end
        end
    end
    if count == 1 then return match end
    return ""
end

local function documents_store_user_fallback(raw_path, context)
    local raw = tostring(raw_path or ""):gsub("/", "\\")
    if raw == "" then return "" end
    local lower = raw:lower()
    if not lower:find("<windocuments>", 1, true) and not lower:find("documents", 1, true) then return "" end
    if not lower:find("<storeuserid>", 1, true) and not lower:find("__steam_store_user_id__", 1, true) then return "" end
    local parent_template = raw:gsub("__STEAM_STORE_USER_ID__", "<storeUserId>"):gsub("<[Ss]tore[Uu]ser[Ii]d>.*$", "")
    parent_template = parent_template:gsub("[\\/]+$", "")
    local parent = paths.expand(parent_template, context):gsub("[\\/]+$", "")
    if parent == "" or paths.has_unresolved(parent) or not paths.exists(parent) then return "" end
    local best = ""
    for _, child in ipairs(paths.children(parent)) do
        local leaf = tostring(child or ""):gsub("^.*[\\/]", "")
        if leaf:match("^%d+$") and folder_has_meaningful_save_content(child) then
            if leaf:match("^7656119%d+$") then return child end
            if best == "" then best = child end
        end
    end
    return best
end

local function add_item(items, seen, kind, label, raw_path, context, options)
    local ok, err = pcall(function()
        if kind == "save" and (not label or label == "") then label = "Save folder" end
        if kind == "config" and (not label or label == "") then label = "Config folder" end
        if not raw_path or raw_path == "" then return end
        options = options or {}
        local candidates = paths.resolve_candidates(raw_path, context)
        local store_user_candidates_list = store_user_candidates(raw_path, context)
        for index = #store_user_candidates_list, 1, -1 do table.insert(candidates, 1, store_user_candidates_list[index]) end
        local explicit = explicit_launcher_path(raw_path, context)
        if explicit ~= "" then table.insert(candidates, 1, explicit) end
        local chosen = candidates[1] or paths.expand(raw_path, context)
        if chosen:find("__STEAM_STORE_USER_ID__", 1, true) then chosen = chosen:gsub("__STEAM_STORE_USER_ID__", tostring(context and context.account_id or "")) end
        local open_path = ""
        local chosen_exists = false
        local partial = false

        for _, candidate in ipairs(candidates) do
            if paths.exists(candidate) then
                chosen = candidate
                open_path = candidate
                chosen_exists = true
                partial = false
                break
            end
        end

        if not chosen_exists then
            local documents_fallback = documents_store_user_fallback(raw_path, context)
            if documents_fallback ~= "" then
                chosen = documents_fallback
                open_path = documents_fallback
                chosen_exists = true
                partial = false
                logger:info("add_item Documents store-user fallback raw=" .. tostring(raw_path or "") .. ", path=" .. tostring(documents_fallback or ""))
            end
            if open_path == "" and options.source == "ls" and is_ls_install_dir_path(raw_path) then
                local fallback_path, fallback_partial = ls_install_dir_fallback(raw_path, context)
                if fallback_path ~= "" then
                    chosen = fallback_path
                    open_path = fallback_path
                    chosen_exists = not fallback_partial
                    partial = fallback_partial
                    logger:info("add_item LS install-dir fallback raw=" .. tostring(raw_path or "") .. ", path=" .. tostring(fallback_path or "") .. ", partial=" .. tostring(fallback_partial))
                end
            end
            if options.launcher ~= "ubisoft" then
                local missing_id_parent = ""
                if paths.has_unresolved(chosen) or chosen:find("__STEAM_STORE_USER_ID__", 1, true) then missing_id_parent = paths.launcher_parent_for_missing_id(chosen) end
                if missing_id_parent ~= "" then
                    chosen = paths.expand(raw_path, context)
                    open_path = missing_id_parent
                    partial = true
                end
                local launcher_parent = paths.launcher_parent_for_unknown_user(paths.expand(raw_path, context))
                if open_path == "" and launcher_parent ~= "" then
                    chosen = paths.expand(raw_path, context)
                    open_path = launcher_parent
                    partial = true
                end
            end
            if open_path == "" and options.launcher == "ubisoft" then
                if trim(context and context.ubisoft_id or "") ~= "" then
                    logger:info("add_item Ubisoft selected profile missing specific folder raw=" .. tostring(raw_path or ""))
                else
                    local unique_path = unique_ubisoft_profile_path_for_game_id(raw_path, context)
                    if unique_path ~= "" then
                        chosen = unique_path
                        open_path = unique_path
                        chosen_exists = true
                        partial = false
                        logger:info("add_item Ubisoft resolved by unique profile game-id raw=" .. tostring(raw_path or "") .. ", path=" .. tostring(unique_path or ""))
                    else
                        logger:info("add_item Ubisoft missing specific folder; not falling back to profile root raw=" .. tostring(raw_path or ""))
                        if paths.has_unresolved(chosen) then return end
                    end
                end
            end
        end

        if options.source == "ls" and kind == "save" then
            local parent = ls_install_dir_file_parent(raw_path, open_path ~= "" and open_path or chosen, context)
            if parent ~= "" then
                chosen = parent
                open_path = parent
                chosen_exists = true
                partial = false
                label = "Save folder"
            end
        end

        if chosen == "" then return end
        local key = (open_path ~= "" and open_path or chosen):lower()
        if key == "" then return end

        local item = {
            kind = kind,
            label = label,
            path = chosen,
            openPath = open_path ~= "" and open_path or nil,
            exists = chosen_exists,
            partial = partial,
            fallback = options.fallback or false,
            source = options.source,
            launcher = options.launcher,
            rawPath = raw_path,
            rawLooksFile = tostring(raw_path or ""):gsub("/", "\\"):match("[^\\]+%.[^\\%.]+$") ~= nil,
            unresolved = paths.has_unresolved(chosen),
        }
        if options.source == "ls" then
            logger:info("add_item LS item label=" .. tostring(label or "") .. ", exists=" .. tostring(chosen_exists) .. ", partial=" .. tostring(partial) .. ", unresolved=" .. tostring(item.unresolved) .. ", path=" .. tostring(chosen or "") .. ", openPath=" .. tostring(item.openPath or ""))
        end
        if options.launcher == "ubisoft" then
            logger:info("add_item Ubisoft item label=" .. tostring(label or "") .. ", exists=" .. tostring(chosen_exists) .. ", partial=" .. tostring(partial) .. ", unresolved=" .. tostring(item.unresolved) .. ", path=" .. tostring(chosen or "") .. ", openPath=" .. tostring(item.openPath or ""))
        end
        table.insert(items, item)
    end)
    if not ok then logger:error("add_item failed for " .. tostring(raw_path) .. ": " .. tostring(err)) end
end

folder_has_meaningful_save_content = function(path)
    if path == "" or not paths.exists(path) then return false end
    local meaningful = 0
    local cloud_metadata = 0
    for _, child in ipairs(paths.children(path)) do
        local leaf = tostring(child or ""):gsub("^.*[\\/]", ""):lower()
        if leaf ~= "" then
            if leaf == "remote" or leaf == "remotecache.vdf" or leaf == "steam_autocloud.vdf" or leaf:match("%.vdf$") or leaf:match("%.tmp$") or leaf:match("%.log$") then
                cloud_metadata = cloud_metadata + 1
            else
                meaningful = meaningful + 1
            end
        end
    end
    if meaningful > 0 then return true end
    if cloud_metadata > 0 then logger:info("GetSaveFolders ignoring metadata-only folder=" .. tostring(path)) end
    return false
end

local function userdata_has_save_content(path)
    return folder_has_meaningful_save_content(path)
end

local function add_steam_userdata(items, seen, context)
    if tostring(context.app_id or "") == "" then return 0 end
    local count = 0
    for _, path in ipairs(paths.userdata_app_dirs(context.steam_root, context.app_id, context.account_id)) do
        if userdata_has_save_content(path) then
            logger:info("GetSaveFolders Steam userdata path=" .. path)
            add_item(items, seen, "save", "Steam userdata", path, context, { source = "steam-userdata" })
            count = count + 1
        end
    end
    return count
end

local function infer_ubisoft_game_id(raw_path, context)
    local value = tostring(raw_path or ""):gsub("/", "\\")
    value = value:gsub("%s*\\%s*", "\\"):gsub("\\+$", "")
    local lower = value:lower()
    local function numeric_id(value)
        value = tostring(value or "")
        if value:match("^%d+$") then return value end
        return nil
    end
    local function tail_after_user_marker(prefix)
        local tail = value:match(prefix .. "\\(.+)$")
        if not tail then return nil end
        local segments = {}
        for segment in tail:gmatch("[^\\]+") do table.insert(segments, segment) end
        for index = 1, #segments - 1 do
            local segment = tostring(segments[index] or "")
            local lower_segment = segment:lower()
            local is_user = lower_segment == "<user-id>"
                or lower_segment == "<user id>"
                or lower_segment == "<storeuserid>"
                or lower_segment == "[userid]"
                or lower_segment == "[user-id]"
                or segment:match("^%%[^%%]+%%$") ~= nil
            local next_segment = tostring(segments[index + 1] or "")
            if is_user and next_segment:match("^%d+$") then return next_segment end
        end
        return nil
    end
    local explicit = tail_after_user_marker("[Ss]avegames")
    if explicit then return explicit end
    explicit = tail_after_user_marker("[Gg]ames")
    if explicit then return explicit end
    if not lower:find("savegames", 1, true) then return "" end
    local tail = value:match("[Ss]avegames\\(%d+)$")
    return numeric_id(tail) or ""
end

local function ubisoft_game_ids_from_data(data, context)
    local ids = {}
    local seen = {}
    local function add(id)
        id = trim(id)
        if id ~= "" and not seen[id] then
            local numeric = id:match("^%d+$") ~= nil
            if numeric then
                seen[id] = true
                table.insert(ids, id)
            end
        end
    end
    for _, raw in ipairs(data and data.saves or {}) do add(infer_ubisoft_game_id(raw, context)) end
    for _, raw in ipairs(data and data.configs or {}) do add(infer_ubisoft_game_id(raw, context)) end
    return ids
end

local function ls_ubisoft_game_ids(context)
    local app_id = tostring(context and context.app_id or "")
    if app_id == "" then return {} end
    local entry = read_ls_entry(app_id)
    if type(entry) ~= "table" or type(entry.files) ~= "table" then return {} end
    local ids = {}
    local seen = {}
    local function add(raw)
        raw = tostring(raw or ""):gsub("/", "\\")
        local lower = raw:lower()
        local is_ubisoft_root = lower:match("^<root>\\savegames\\<storeuserid>\\%d+") ~= nil
        local is_ubisoft_named = lower:find("ubisoft", 1, true) ~= nil and lower:find("savegames", 1, true) ~= nil
        if not is_ubisoft_root and not is_ubisoft_named then return end
        local id = infer_ubisoft_game_id(raw, context)
        if id ~= "" and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    for _, file in ipairs(entry.files) do
        if type(file) == "table" then add(file.path) end
    end
    return ids
end

local function cached_ubisoft_game_ids(app_id)
    return {}
end

local function save_ubisoft_ids_cache(app_id, lookup)
    app_id = tostring(app_id or "")
    local ids = type(lookup) == "table" and lookup.ids or {}
    if app_id == "" or #ids == 0 then return false end
    local cache = read_json_file(UBISOFT_IDS_CACHE_FILE)
    cache[app_id] = { ids = ids, page = lookup.page, url = lookup.url, source = "pcgw", timestamp = os.time() }
    return write_json_file(UBISOFT_IDS_CACHE_FILE, cache)
end


local function updater_cache_fresh(cache)
    local timestamp = tonumber(cache and cache.timestamp or 0) or 0
    return timestamp > 0 and os.time() - timestamp < UBISOFT_IDS_UPDATER_TTL
end

local function normalize_updater_ids(value)
    if value == nil or value == false then return { blocked = true, ids = {} } end
    if type(value) == "number" then return { blocked = false, ids = { tostring(value) } } end
    if type(value) == "string" then
        value = trim(value)
        if value == "" then return { blocked = true, ids = {} } end
        return { blocked = false, ids = { value } }
    end
    if type(value) == "table" then
        local result = {}
        local source = value.ids or value
        for _, item in ipairs(source) do
            item = trim(item)
            if item ~= "" and item:match("^%d+$") then table.insert(result, item) end
        end
        return { blocked = #result == 0, ids = result }
    end
    return { blocked = true, ids = {} }
end

update_ubisoft_ids_from_remote = function(force)
    local cache = read_json_file(UBISOFT_IDS_UPDATER_CACHE_FILE)
    if not force and updater_cache_fresh(cache) then return cache end
    local response, err = http.get(UBISOFT_IDS_UPDATER_URL, {
        timeout = 6,
        follow_redirects = true,
        user_agent = "MySaveMillenniumPlugin/0.1.0 (Ubisoft game ID updater)",
        headers = { ["Accept"] = "application/json, */*;q=0.8" },
    })
    if not response or response.status ~= 200 then
        logger:error("Ubisoft ID updater failed: " .. tostring(err or (response and response.status) or "unknown"))
        return cache
    end
    local ok, parsed = pcall(json.decode, response.body or "")
    if not ok or type(parsed) ~= "table" then
        logger:error("Ubisoft ID updater returned invalid JSON")
        return cache
    end
    local normalized = { timestamp = os.time(), source = UBISOFT_IDS_UPDATER_URL, data = {} }
    for app_id, value in pairs(parsed) do
        app_id = tostring(app_id or "")
        if app_id:match("^%d+$") then
            local entry = normalize_updater_ids(value)
            normalized.data[app_id] = entry.blocked and { blocked = true, ids = {} } or { ids = entry.ids }
        end
    end
    write_json_file(UBISOFT_IDS_UPDATER_CACHE_FILE, normalized)
    local count = 0
    for _ in pairs(normalized.data or {}) do count = count + 1 end
    logger:info("Ubisoft ID updater stored entries=" .. tostring(count))
    return normalized
end

local function remote_ubisoft_game_ids(app_id)
    local cache = update_ubisoft_ids_from_remote(false)
    local entry = type(cache) == "table" and type(cache.data) == "table" and cache.data[tostring(app_id or "")] or nil
    if type(entry) ~= "table" then return nil end
    if entry.blocked then return { blocked = true, ids = {} } end
    local result = {}
    for _, item in ipairs(entry.ids or {}) do
        item = trim(item)
        if item ~= "" and item:match("^%d+$") then table.insert(result, item) end
    end
    return { blocked = #result == 0, ids = result }
end
local function local_ubisoft_game_ids(app_id)
    local remote = remote_ubisoft_game_ids(app_id)
    if remote and remote.blocked then return {} end
    if remote and #remote.ids > 0 then return remote.ids end
    local data = read_json_file(UBISOFT_IDS_FILE)
    local value = data[tostring(app_id or "")]
    if type(value) == "number" then return { tostring(value) } end
    if type(value) == "string" and value ~= "" then return { value } end
    if type(value) == "table" then
        local result = {}
        for _, item in ipairs(value) do
            item = trim(item)
            if item ~= "" then table.insert(result, item) end
        end
        return result
    end
    local cache = read_json_file(UBISOFT_IDS_CACHE_FILE)
    local cached = cache[tostring(app_id or "")]
    if type(cached) == "table" then
        if cached.page == "Home" or cached.error ~= nil then return {} end
        local result = {}
        for _, item in ipairs(cached.ids or cached) do
            item = trim(item)
            if item ~= "" and item:match("^%d+$") then table.insert(result, item) end
        end
        if #result > 0 then return result end
        if cached.timestamp ~= nil then return {} end
    end
    return {}
end

local function is_transient_pcgw_error(text)
    text = tostring(text or ""):lower()
    return text:find("throttled", 1, true) ~= nil
        or text:find("rate%-limited") ~= nil
        or text:find("429", 1, true) ~= nil
        or text:find("try again", 1, true) ~= nil
end

local function ubisoft_cache_blocks_refresh(app_id)
    local cached = read_json_file(UBISOFT_IDS_CACHE_FILE)[tostring(app_id or "")]
    if type(cached) ~= "table" or cached.timestamp == nil then return false end
    if cached.page == "Home" then return false end
    local error_text = tostring(cached.error or "")
    if error_text:find("PCGW page doesn't exist", 1, true) then return false end
    if error_text:find("PCGW AppID page did not contain", 1, true) then return false end
    if error_text:find("No Ubisoft save ID found", 1, true) then return false end
    if is_transient_pcgw_error(error_text) then return false end
    return true
end

local function existing_ubisoft_game_ids(context)
    local launcher = paths.ubisoft_connect_folder()
    local profile_id = trim(context and context.ubisoft_id or "")
    if launcher == "" or profile_id == "" then return {} end
    local profile_dir = launcher .. "\\savegames\\" .. profile_id
    if not paths.exists(profile_dir) then return {} end
    local result = {}
    local seen = {}
    for _, child in ipairs(paths.children(profile_dir)) do
        local id = tostring(child or ""):gsub("^.*\\", "")
        if id:match("^%d+$") and not seen[id] then
            seen[id] = true
            table.insert(result, id)
        end
    end
    return result
end

local function merged_ubisoft_game_ids(data, context)
    local ids = {}
    local seen = {}
    local function add(id)
        id = trim(id)
        if id ~= "" and id:match("^%d+$") and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    local ls_ids = ls_ubisoft_game_ids(context)
    if #ls_ids > 0 then
        for _, id in ipairs(ls_ids) do add(id) end
        return ids
    end
    for _, id in ipairs(local_ubisoft_game_ids(context and context.app_id or "")) do add(id) end
    for _, id in ipairs(ubisoft_game_ids_from_data(data, context)) do add(id) end
    return ids
end

local function should_add_ubisoft_savegames(data, context)
    if #local_ubisoft_game_ids(context and context.app_id or "") > 0 or #ls_ubisoft_game_ids(context) > 0 then return true end
    for _, raw in ipairs(data and data.saves or {}) do
        local lower = tostring(raw or ""):lower()
        if lower:find("ubisoft", 1, true) or lower:find("savegamedatalocation", 1, true) then return true end
        if lower:find("savegames", 1, true) and infer_ubisoft_game_id(raw, context) ~= "" then return true end
    end
    for _, raw in ipairs(data and data.configs or {}) do
        local lower = tostring(raw or ""):lower()
        if lower:find("ubisoft", 1, true) or lower:find("savegamedatalocation", 1, true) then return true end
        if lower:find("savegames", 1, true) and infer_ubisoft_game_id(raw, context) ~= "" then return true end
    end
    return false
end

local function filter_existing_ubisoft_game_ids(game_ids, context)
    game_ids = type(game_ids) == "table" and game_ids or {}
    local profile_id = trim(context and context.ubisoft_id or "")
    if profile_id == "" then return game_ids end
    local root = paths.ubisoft_connect_folder()
    if root == "" then return game_ids end
    local profile = root .. "\\savegames\\" .. profile_id
    if not paths.exists(profile) then return game_ids end
    local existing = {}
    for _, game_id in ipairs(game_ids) do
        game_id = trim(game_id)
        if game_id ~= "" and paths.exists(profile .. "\\" .. game_id) then table.insert(existing, game_id) end
    end
    if #existing > 0 then return existing end
    return game_ids
end

local function ubisoft_profile_paths_for_game_id(game_id)
    local result = {}
    game_id = trim(game_id or "")
    if game_id == "" then return result end
    local root = paths.ubisoft_connect_folder()
    if root == "" then return result end
    local savegames = root .. "\\savegames"
    if not paths.exists(savegames) then return result end
    for _, profile in ipairs(paths.children(savegames)) do
        local profile_id = tostring(profile or ""):gsub("^.*[\\/]", "")
        local candidate = profile .. "\\" .. game_id
        if profile_id ~= "" and paths.exists(candidate) then
            table.insert(result, { profile = profile_id, path = candidate })
        end
    end
    table.sort(result, function(a, b) return tostring(a.profile) < tostring(b.profile) end)
    return result
end

local function add_ubisoft_savegames(items, seen, context, game_ids)
    local launcher = paths.ubisoft_connect_folder()
    if launcher == "" then return 0 end
    local savegames = launcher .. "\\savegames"
    if not paths.exists(savegames) then return 0 end

    local count = 0
    game_ids = type(game_ids) == "table" and game_ids or {}
    if #game_ids == 0 then game_ids = local_ubisoft_game_ids(context.app_id) end
    local profile_id = trim(context and context.ubisoft_id or "")
    if profile_id ~= "" then game_ids = filter_existing_ubisoft_game_ids(game_ids, context) end
    if #game_ids == 0 then
        local target = profile_id ~= "" and "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\<game-id>" or "<Ubisoft-Connect-folder>\\savegames"
        table.insert(items, {
            kind = "save",
            label = profile_id ~= "" and "Ubisoft save folder" or "Ubisoft savegames",
            path = target,
            rawPath = target,
            openPath = "",
            exists = false,
            partial = false,
            unresolved = true,
            source = "ubisoft-savegames",
            launcher = "ubisoft",
        })
        logger:info("GetSaveFolders Ubisoft game id unknown; not opening profile root")
        return 1
    end
    for _, game_id in ipairs(game_ids) do
        game_id = trim(game_id)
        if game_id ~= "" then
            if profile_id == "" then
                local profile_paths = ubisoft_profile_paths_for_game_id(game_id)
                if #profile_paths == 1 then
                    local found = profile_paths[1]
                    add_item(items, seen, "save", "Ubisoft save folder", found.path, context, { source = "ubisoft-savegames", launcher = "ubisoft" })
                    count = count + 1
                else
                    local template_path = "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\" .. game_id
                    logger:info("GetSaveFolders Ubisoft profile ambiguous or missing; not adding unresolved template path=" .. template_path)
                end
            else
                local template_path = "<Ubisoft-Connect-folder>\\savegames\\" .. profile_id .. "\\" .. game_id
                logger:info("GetSaveFolders Ubisoft template path=" .. template_path)
                add_item(items, seen, "save", "Ubisoft save folder " .. game_id, template_path, context, { source = "ubisoft-savegames", launcher = "ubisoft" })
                count = count + 1
            end
        end
    end
    return count
end

local function normalize_label(value)
    local normalized = tostring(value or ""):lower()
    normalized = normalized:gsub("&", "and")
    normalized = normalized:gsub("[^%w]+", " ")
    normalized = normalized:gsub("^%s+", "")
    normalized = normalized:gsub("%s+$", "")
    return normalized
end

local function labels_match(path_label, target)
    local leaf = tostring(path_label or ""):gsub("^.*[\\/]", "")
    return normalize_label(leaf) == target
end

local function label_has_copy_suffix(path_label)
    local leaf = tostring(path_label or ""):gsub("^.*[\\/]", ""):lower()
    return leaf:find("- copy", 1, true) ~= nil
        or leaf:find("_copy", 1, true) ~= nil
        or leaf:find("(copy)", 1, true) ~= nil
        or leaf:find(" copy", 1, true) ~= nil
end

local function label_contains_target(path_label, target)
    local leaf = tostring(path_label or ""):gsub("^.*[\\/]", "")
    if label_has_copy_suffix(leaf) then return false end
    local normalized_leaf = normalize_label(leaf)
    local normalized_target = normalize_label(target)
    if normalized_leaf == normalized_target then return true end
    if normalized_target == "" then return false end
    local leaf_tokens = {}
    for token in normalized_leaf:gmatch("%S+") do leaf_tokens[token] = true end
    for token in normalized_target:gmatch("%S+") do
        if #token > 1 and not leaf_tokens[token] then return false end
    end
    return true
end

local function add_matching_descendant_contains(items, seen, kind, label, root, target_name, context, options)
    local base = paths.expand(root, context)
    if base == "" or not paths.exists(base) then return 0 end
    local count = 0
    for _, candidate in ipairs(paths.children(base)) do
        candidate = tostring(candidate or "")
        local leaf = candidate:gsub("^.*[\\/]", "")
        if label_contains_target(leaf, target_name) then
            add_item(items, seen, kind, label, candidate, context, options)
            count = count + 1
        end
    end
    return count
end

local function add_matching_grandchild_contains(items, seen, kind, label, root, target_name, context, options)
    local base = paths.expand(root, context)
    if base == "" or not paths.exists(base) then return 0 end
    local count = 0
    local account_id = tostring(context and context.account_id or "")
    for _, parent in ipairs(paths.children(base)) do
        for _, candidate in ipairs(paths.children(parent)) do
            candidate = tostring(candidate or "")
            local leaf = candidate:gsub("^.*[\\/]", "")
            if label_contains_target(leaf, target_name) then
                local account_path = account_id ~= "" and (candidate .. string.char(92) .. account_id) or ""
                if account_path ~= "" and paths.exists(account_path) and folder_has_meaningful_save_content(account_path) then
                    add_item(items, seen, kind, label, account_path, context, options)
                    count = count + 1
                else
                    local has_numeric_child = false
                    for _, child in ipairs(paths.children(candidate)) do
                        local child_leaf = tostring(child or ""):gsub("^.*[\\/]", "")
                        if child_leaf:match("^%d+$") then has_numeric_child = true end
                    end
                    if not has_numeric_child then
                        add_item(items, seen, kind, label, candidate, context, options)
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

local function add_matching_descendant(items, seen, kind, label, root, target_name, context, options)
    local base = paths.expand(root, context)
    if base == "" or not paths.exists(base) then return 0 end
    local target = normalize_label(target_name)
    if target == "" then return 0 end
    local count = 0
    for _, candidate in ipairs(paths.children(base)) do
        candidate = tostring(candidate or "")
        local leaf = candidate:gsub("^.*[\\/]", "")
        if labels_match(leaf, target) then
            add_item(items, seen, kind, label, candidate, context, options)
            count = count + 1
        end
    end
    return count
end

local function add_unity_locallow(items, seen, context)
    local game = tostring(context.game_name or context.game_folder or "")
    local count = 0
    for _, company_dir in ipairs(paths.children(paths.expand("%USERPROFILE%\\AppData\\LocalLow", context))) do
        count = count + add_matching_descendant(items, seen, "save", "LocalLow folder", company_dir, game, context, { fallback = true, source = "unity-locallow" })
    end
    return count
end

local function add_unreal_installdir(items, seen, context)
    local game_dir = paths.game_install_dir(context.steam_root, context.app_id)
    if game_dir == "" then return 0 end
    local count = 0
    for _, candidate in ipairs({ game_dir .. "\\Saved", game_dir .. "\\" .. (game_dir:match("([^\\]+)$") or "") .. "\\Saved" }) do
        if paths.exists(candidate) then
            add_item(items, seen, "save", "Unreal Saved folder", candidate, context, { fallback = true, source = "unreal" })
            count = count + 1
        end
    end
    return count
end

local function add_common_user_folders(items, seen, context, deep_scan)
    local name = tostring(context.game_name or context.game_folder or "")
    local count = 0
    local candidates = {
        { "save", "Saved Games folder", "%USERPROFILE%\\Saved Games\\" .. name },
        { "save", "Documents folder", "%DOCUMENTS%\\" .. name },
        { "config", "Local AppData folder", "%LOCALAPPDATA%\\" .. name },
        { "config", "AppData folder", "%APPDATA%\\" .. name },
    }
    for _, item in ipairs(candidates) do
        local expanded = paths.expand(item[3], context)
        if expanded ~= "" and paths.exists(expanded) then
            add_item(items, seen, item[1], item[2], item[3], context, { fallback = true, source = "heuristic" })
            count = count + 1
        end
    end
    if deep_scan ~= true then return count end
    local fallback_options = { fallback = true, source = "heuristic" }
    count = count + add_matching_descendant(items, seen, "save", "Saved Games folder", "%USERPROFILE%\\Saved Games", name, context, fallback_options)
    count = count + add_matching_descendant(items, seen, "save", "Documents My Games folder", "%DOCUMENTS%" .. string.char(92) .. "My Games", name, context, fallback_options)
    count = count + add_matching_descendant_contains(items, seen, "save", "Documents My Games folder", "%DOCUMENTS%" .. string.char(92) .. "My Games", name, context, fallback_options)
    count = count + add_matching_grandchild_contains(items, seen, "save", "Documents publisher folder", "%DOCUMENTS%", name, context, fallback_options)
    count = count + add_matching_descendant(items, seen, "config", "Local AppData folder", "%LOCALAPPDATA%", name, context, fallback_options)
    count = count + add_matching_descendant_contains(items, seen, "config", "Local AppData folder", "%LOCALAPPDATA%", name, context, fallback_options)
    count = count + add_matching_grandchild_contains(items, seen, "config", "Local AppData folder", "%LOCALAPPDATA%", name, context, fallback_options)
    count = count + add_matching_descendant(items, seen, "config", "AppData folder", "%APPDATA%", name, context, fallback_options)
    count = count + add_matching_descendant_contains(items, seen, "config", "AppData folder", "%APPDATA%", name, context, fallback_options)
    count = count + add_matching_grandchild_contains(items, seen, "config", "AppData folder", "%APPDATA%", name, context, fallback_options)
    return count
end

local function ls_openable_path(raw_path, context)
    local raw = tostring(raw_path or ""):gsub("/", "\\")
    if raw == "" then return "" end
    local lower_raw = raw:lower()
    if lower_raw:find("hkey_", 1, true) == 1 or lower_raw:find("hkey\\", 1, true) == 1 then return "" end
    if lower_raw:find("<home>/library/", 1, true) == 1 or lower_raw:find("<home>\\library\\", 1, true) == 1 then return "" end
    if lower_raw:find("/library/containers/", 1, true) or lower_raw:find("\\library\\containers\\", 1, true) then return "" end

    local user_dirs = paths.user_dirs()
    raw = raw:gsub("<[Hh]ome>", user_dirs.home or "")
    raw = raw:gsub("<[Ww]in[Ll]ocal[Aa]pp[Dd]ata[Ll]ow>", user_dirs.localLow or "")
    raw = raw:gsub("<[Ww]in[Ll]ocal[Aa]pp[Dd]ata>", user_dirs.localAppData or "")
    raw = raw:gsub("<[Ww]in[Dd]ocuments>", user_dirs.documents or "")
    raw = raw:gsub("<[Ww]in[Aa]pp[Dd]ata>", user_dirs.appData or "")

    local ubisoft_suffix = raw:match("^<[Rr]oot>\\[Ss]avegames\\<[Ss]tore[Uu]ser[Ii]d>\\(.+)$")
    if ubisoft_suffix and ubisoft_suffix ~= "" then
        return "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\" .. ubisoft_suffix
    end

    if raw:lower():find("rockstar games", 1, true) then
        raw = raw:gsub("<[Ss]tore[Uu]ser[Ii]d>", "<user-id>")
    else
        raw = raw:gsub("<[Ss]tore[Uu]ser[Ii]d>", "__STEAM_STORE_USER_ID__")
    end

    local parent = raw:match("^(.*)\\[^\\]*%*[^\\]*$")
        or raw:match("^(.*)\\[^\\]+%.[^\\]+$")
    if parent and parent ~= "" then return parent end

    return raw
end

local function ls_item_label(kind, raw_path)
    local lower = tostring(raw_path or ""):lower()
    if kind == "save" then
        if lower:find("<winlocalappdatalow>", 1, true) or lower:find("locallow", 1, true) then return "Save folder (LocalLow)" end
        if lower:find("<winlocalappdata>", 1, true) or lower:find("appdata\\local", 1, true) then return "Save folder (Local AppData)" end
        if lower:find("<windocuments>", 1, true) or lower:find("documents", 1, true) then return "Save folder (Documents)" end
        return "Save folder"
    end
    if kind == "config" then
        if lower:find("<base>", 1, true) or lower:find("<path%-to%-game>", 1, false) then return "Config folder (install dir)" end
        if lower:find("<winlocalappdata>", 1, true) or lower:find("appdata\\local", 1, true) then return "Config folder (Local AppData)" end
        if lower:find("<winappdata>", 1, true) or lower:find("appdata\\roaming", 1, true) then return "Config folder (AppData)" end
        return "Config folder"
    end
    return "Folder"
end

local function ls_is_nightreign_config(raw_path, app_id)
    local lower = tostring(raw_path or ""):lower()
    local id = tostring(app_id or "")
    return (id == "2622380" or id == "3515610" or id == "3531720") and lower:find("graphicsconfig%.xml") ~= nil
end

local function ls_is_install_dir_config(raw_path)
    local lower = tostring(raw_path or ""):lower()
    return lower:find("<base>", 1, true) ~= nil or lower:find("<path-to-game>", 1, true) ~= nil
end

local function ls_config_has_better_child(seen_configs, config_key)
    if config_key == "" then return false end
    for seen_key, _ in pairs(seen_configs or {}) do
        if seen_key ~= config_key and seen_key:sub(1, #config_key + 1) == config_key .. "\\" then return true end
    end
    return false
end

local function ls_remove_parent_config(items, seen_configs, config_key)
    if config_key == "" then return end
    for index = #items, 1, -1 do
        local item = items[index]
        if item and item.kind == "config" and item.source == "ls" then
            local key = tostring(item.openPath or item.path or ""):gsub("[\\/]+", "\\"):gsub("\\+$", ""):lower()
            if key ~= config_key and config_key:sub(1, #key + 1) == key .. "\\" then
                table.remove(items, index)
                if seen_configs then seen_configs[key] = nil end
            end
        end
    end
end

local function ls_has_steam_path(entry)
    if type(entry) ~= "table" or type(entry.files) ~= "table" then return false end
    for _, file in ipairs(entry.files) do
        local lower = tostring(type(file) == "table" and file.path or ""):lower():gsub("/", "\\")
        if lower:find("\\steam\\", 1, true) or lower:find("<root>\\userdata\\", 1, true) then return true end
    end
    return false
end

local function ls_is_non_steam_store_path(raw_path, entry)
    if not ls_has_steam_path(entry) then return false end
    local lower = tostring(raw_path or ""):lower():gsub("/", "\\")
    return lower:find("\\eos\\", 1, true) ~= nil
        or lower:find("epic games", 1, true) ~= nil
        or lower:find("epicgames", 1, true) ~= nil
end

local function add_ls_manifest_items(items, seen, context)
    local app_id = tostring(context and context.app_id or "")
    if app_id == "" then return 0 end
    local entry = read_ls_entry(app_id)
    if type(entry) ~= "table" or type(entry.files) ~= "table" then return 0 end
    local count = 0
    local seen_ls_configs = {}
    for _, file in ipairs(entry.files) do
        local raw = ls_openable_path(file.path, context)
        if raw ~= "" and not ls_is_non_steam_store_path(file.path, entry) then
            local tags = type(file.tags) == "table" and file.tags or {}
            local has_save = false
            local has_config = false
            for _, tag in ipairs(tags) do
                if tag == "save" then has_save = true end
                if tag == "config" then has_config = true end
            end
            if has_save then
                local save_launcher = is_ubisoft_launcher_path(raw, context) and "ubisoft" or nil
                add_item(items, seen, "save", ls_item_label("save", file.path), raw, context, { source = "ls", launcher = save_launcher })
                count = count + 1
            end
            if has_config and not ls_is_install_dir_config(file.path) then
                local config_raw = raw
                local config_folder = paths.expand(raw, context):gsub("[\\/]+", "\\")
                if config_folder:match("%.[^\\%.]+$") or config_folder:find("*", 1, true) then
                    config_folder = config_folder:match("^(.*)\\[^\\]+$") or config_folder
                    if config_folder ~= "" then config_raw = config_folder end
                end
                local config_key = config_folder:gsub("[\\/]+", "\\"):gsub("\\+$", ""):lower()
                if config_key ~= "" and not ls_config_has_better_child(seen_ls_configs, config_key) then
                    ls_remove_parent_config(items, seen_ls_configs, config_key)
                    if not seen_ls_configs[config_key] then
                        seen_ls_configs[config_key] = true
                        add_item(items, seen, "config", ls_item_label("config", file.path), config_raw, context, { source = "ls" })
                        count = count + 1
                    end
                end
            end
        end
    end
    if count > 0 then logger:info("GetSaveFolders LS items app_id=" .. app_id .. ", count=" .. tostring(count)) end
    return count
end

local function is_online_only_app(app_id)
    local data = read_json_file(ONLINE_ONLY_FILE)
    return data[tostring(app_id or "")] ~= nil
end

local function online_only_name(app_id)
    local data = read_json_file(ONLINE_ONLY_FILE)
    return tostring(data[tostring(app_id or "")] or "")
end

local function has_usable_save_item(items)
    for _, item in ipairs(items or {}) do
        if item.kind == "save" and item.exists then return true end
    end
    return false
end

local function has_usable_item(items)
    for _, item in ipairs(items or {}) do
        if item.exists then return true end
    end
    return false
end

local function url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function pcgw_appid_url(app_id, game_name)
    local query = trim(game_name or "")
    if query == "" and tostring(app_id or "") ~= "" then query = "Steam AppID " .. tostring(app_id) end
    if query == "" then return nil end
    return "https://www.pcgamingwiki.com/wiki/Special:Search?search=" .. url_encode(query)
end

local function normalize_item_path(item)
    if type(item) ~= "table" then return "" end
    local normalized = tostring(item.openPath or item.path or item.rawPath or "")
    normalized = normalized:gsub("[\\/]+", "\\")
    normalized = normalized:gsub("\\+$", "")
    normalized = normalized:lower()
    normalized = normalized:gsub("\\appdata\\locallow\\kojimaproductions\\deathstrandingdc\\%d+$", "\\appdata\\kojimaproductions\\deathstrandingdc")
    normalized = normalized:gsub("\\appdata\\local\\kojimaproductions\\deathstrandingdc\\%d+$", "\\appdata\\kojimaproductions\\deathstrandingdc")
    normalized = normalized:gsub("\\appdata\\locallow\\kojimaproductions\\deathstranding\\%d+$", "\\appdata\\kojimaproductions\\deathstranding")
    normalized = normalized:gsub("\\appdata\\local\\kojimaproductions\\deathstranding\\%d+$", "\\appdata\\kojimaproductions\\deathstranding")
    return normalized
end

local function item_score(item)
    local score = 0
    local kind = tostring(item and item.kind or "")
    local source = tostring(item and item.source or "")
    local path = normalize_item_path(item or {})
    local label = tostring(item and item.label or ""):lower()

    if kind == "save" then score = score + 60 end
    if kind == "config" then score = score + 35 end

    if item and item.exists then score = score + 100 end
    if item and item.openPath and item.openPath ~= "" then score = score + 45 end
    if item and item.partial then score = score - 10 end
    if item and item.unresolved then score = score - 30 end
    if item and item.fallback then score = score - 5 end

    if path:find("documents", 1, true) or path:find("my games", 1, true) or path:find("saved games", 1, true) then score = score + 35 end
    if path:find("appdata", 1, true) or path:find("localappdata", 1, true) or path:find("locallow", 1, true) then score = score + 30 end
    if path:find("ubisoft", 1, true) or path:find("rockstar", 1, true) then score = score + 25 end
    if source == "ls" then score = score + 60 end
    if source == "ls" and kind == "save" and path:find("\\saves", 1, true) then score = score + 40 end
    if source == "ls" and kind == "save" and label:find("save folder", 1, true) then score = score + 10 end
    if source == "ls" and kind == "save" and path:find("assassin's creed brotherhood", 1, true) and not path:find("\\saves", 1, true) then score = score - 80 end
    if source == "pcgw" or source == "local" then score = score + 20 end
    if source == "heuristic" then score = score + 10 end
    if source == "steam-userdata" or path:find("\\userdata\\", 1, true) then score = score - 25 end
    if source == "steam-cloud" or label:find("cloud", 1, true) then score = score - 200 end
    if path:find("compatdata", 1, true) or path:find("compactdata", 1, true) or path:find("proton", 1, true) then score = score - 1000 end
    return score
end

local function item_game_id_key(item)
    if type(item) ~= "table" then return "" end
    local value = tostring(item.path or item.rawPath or ""):gsub("/", "\\"):gsub("\\+$", "")
    local lower = value:lower()
    if not lower:find("savegames", 1, true) then return "" end
    local profile, id = value:match("[Ss]avegames\\([^\\]+)\\(%d+)$")
    if not id or id == "" then id = infer_ubisoft_game_id(value, {}) end
    if id == "" then return "" end
    profile = tostring(profile or "")
    local profile_lower = profile:lower()
    if profile == "" or profile_lower:find("<", 1, true) or profile_lower:find(">", 1, true) or profile_lower:find("%[", 1, false) or profile_lower:find("%%", 1, true) or profile_lower == "__steam_store_user_id__" then
        profile = "*"
    end
    return "ubisoft:" .. profile:lower() .. ":" .. id
end

local function dedupe_items(items)
    table.sort(items or {}, function(a, b)
        local score_a = item_score(a)
        local score_b = item_score(b)
        if score_a ~= score_b then return score_a > score_b end
        local path_a = normalize_item_path(a)
        local path_b = normalize_item_path(b)
        if path_a ~= path_b then return path_a < path_b end
        local label_a = tostring(a and a.label or "")
        local label_b = tostring(b and b.label or "")
        if label_a ~= label_b then return label_a < label_b end
        return tostring(a and a.kind or "") < tostring(b and b.kind or "")
    end)
    local seen = {}
    local seen_game_ids = {}
    local result = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" then
            item.score = item_score(item)
            local key = normalize_item_path(item)
            local kind_key = tostring(item.kind or "") .. ":" .. key
            local real_key = tostring(item.path or item.rawPath or ""):gsub("[\\/]+", "\\"):gsub("\\+$", ""):lower()
            local real_kind_key = real_key ~= "" and (tostring(item.kind or "") .. ":" .. real_key) or ""
            local game_id_key = item_game_id_key(item)
            if key ~= "" and not seen[kind_key] and (real_kind_key == "" or not seen[real_kind_key]) and (game_id_key == "" or not seen_game_ids[game_id_key]) then
                local has_better_child = false
                if tostring(item.kind or "") == "save" and key ~= "" then
                    for _, other in ipairs(result) do
                        local other_key = normalize_item_path(other)
                        if tostring(other.kind or "") == "save" and other_key ~= "" and other_key:sub(1, #key + 1) == key .. "\\" then
                            has_better_child = true
                            break
                        end
                    end
                end
                if not has_better_child then
                    seen[kind_key] = true
                    if real_kind_key ~= "" then seen[real_kind_key] = true end
                    if game_id_key ~= "" then seen_game_ids[game_id_key] = true end
                    table.insert(result, item)
                end
            end
        end
    end
    return result
end

function GetSaveFolders(app_id, fallback_name, steam_account_id, force_remote)
    local success, result = pcall(function()
        local rockstar_supplied = false
        local ubisoft_supplied = false
        local backup_command = ""
        local backup_source_path = ""
        local backup_allow_multiple = nil
        local steam_id64 = ""
        if type(app_id) == "string" and app_id ~= "" then
            local decoded = decode_arg_table(app_id)
            if next(decoded) ~= nil then app_id = decoded end
        end
        if type(app_id) == "table" then
            local args = app_id
            if type(args.argumentList) == "table" and type(args.argumentList[1]) == "string" then args = decode_arg_table(args.argumentList[1])
            elseif type(args.argumentList) == "table" then args = args.argumentList
            elseif type(args.argumentList) == "string" then args = decode_arg_table(args.argumentList) end
            if type(args[1]) == "table" then args = args[1] end
            if type(args[1]) == "string" then
                local decoded_first = decode_arg_table(args[1])
                if next(decoded_first) ~= nil then args = decoded_first end
            end
            backup_command = tostring(args.backup_command or args.backupCommand or "")
            app_id = args.app_id or args.appId or args[1] or ""
            fallback_name = args.fallback_name or args.gameName or args.game_name or args[2] or ""
            steam_account_id = args.steam_account_id or args.steamAccountId or args.steam_accountID or ""
            steam_id64 = trim(args.steam_id64 or args.steamId64 or args.steamID64 or args.steam_id or args.steamId or "")
            force_remote = args.force_remote or args.forceRemote or false
            backup_allow_multiple = first_present(args, "allowMultipleBackups", "allow_multiple", "multipleBackups", "multiple", "allow_multiple_backups")
            if steam_account_id == "" and type(args[3]) ~= "boolean" then steam_account_id = args[3] or "" end
            if not force_remote and type(args[3]) == "boolean" then force_remote = args[3] end
            if not force_remote then force_remote = args[4] or false end
            rockstar_supplied = args.rockstarId ~= nil or args.rockstar_id ~= nil or args.rockstar ~= nil or args[5] ~= nil
            ubisoft_supplied = args.ubisoftId ~= nil or args.ubisoft_id ~= nil or args.ubisoft ~= nil or args[6] ~= nil
            rockstar_id = trim(args.rockstarId or args.rockstar_id or args.rockstar or args[5] or "")
            ubisoft_id = trim(args.ubisoftId or args.ubisoft_id or args.ubisoft or args[6] or "")
            paths.set_launcher_ids(rockstar_id, ubisoft_id)
            logger:info("GetSaveFolders decoded args rockstar=" .. tostring(rockstar_id or "") .. ", ubisoft=" .. tostring(ubisoft_id or "") .. ", supplied=" .. tostring(ubisoft_supplied))
        end

        app_id = tostring(app_id or "")
        fallback_name = tostring(fallback_name or "")
        if type(steam_account_id) == "boolean" then
            force_remote = steam_account_id
            steam_account_id = ""
        end
        if tostring(force_remote or ""):lower() == "true" then force_remote = true end
        if tostring(fallback_name or "") == "create_dir" or tostring(fallback_name or "") == "create_current" or tostring(fallback_name or "") == "list_backups" or tostring(fallback_name or "") == "preview_restore" or tostring(fallback_name or "") == "restore_backup" then
            backup_command = tostring(fallback_name or "")
            local backup_payload = tostring(steam_account_id or "")
            local parsed_name, parsed_source, parsed_backup = backup_payload:match("^(.-)||(.+)||(.+)$")
            if parsed_name then
                fallback_name = parsed_name
                backup_source_path = parsed_source or ""
                backup_restore_path = parsed_backup or ""
                if backup_command == "create_dir" then
                    local source, multiple = tostring(backup_restore_path or ""):match("^(.-)||multiple=([01])$")
                    if source then
                        backup_source_path = source
                        backup_restore_path = ""
                        backup_allow_multiple = multiple ~= "0"
                    end
                end
            else
                parsed_name, parsed_source = backup_payload:match("^(.-)||(.+)$")
                fallback_name = parsed_name or backup_payload
                backup_source_path = parsed_source or ""
            end
            steam_account_id = ""
        end
        if (backup_command == "create_dir" or backup_command == "create_current") and backup_source_path == "" then
            local parsed_name, parsed_source = fallback_name:match("^(.-)||(.+)$")
            if parsed_name then
                fallback_name = parsed_name
                backup_source_path = parsed_source or ""
            end
        end
        if backup_command == "restore_backup" and backup_source_path == "" then
            local parsed_name, parsed_source, parsed_backup = fallback_name:match("^(.-)||(.+)||(.+)$")
            if parsed_name then
                fallback_name = parsed_name
                backup_source_path = parsed_source or ""
                backup_restore_path = parsed_backup or ""
            end
        end
        if app_id == "" then return safe_encode({ success = false, error = "Missing AppID", items = {} }) end
        if backup_command == "preview_restore" or backup_command == "restore_backup" then
            local root = backup_root(load_settings())
            if root == "" then return safe_encode({ success = false, error = "Choose a backup folder first", items = {} }) end
            if backup_source_path == "" or backup_restore_path == "" then return safe_encode({ success = false, error = "Missing restore paths", items = {} }) end
            if backup_source_path:find('"', 1, true) or paths.has_unresolved(backup_source_path) or not paths.is_absolute_windows_path(backup_source_path) or not paths.exists(backup_source_path) then
                return safe_encode({ success = false, error = "Current save path is invalid", items = {} })
            end
            if backup_restore_path:find('"', 1, true) or paths.has_unresolved(backup_restore_path) or not paths.is_absolute_windows_path(backup_restore_path) or not paths.exists(backup_restore_path) then
                return safe_encode({ success = false, error = "Selected backup path is invalid", items = {} })
            end
            local backup_save_folder = backup_restore_path:gsub("[\\/]+$", "") .. "\\Save folder"
            if not paths.exists(backup_save_folder) then return safe_encode({ success = false, error = "Selected backup has no Save folder", items = {} }) end
            local game_backup_folder = backup_game_folder(root, app_id, fallback_name ~= "" and fallback_name or "Game")
            local pre_restore = game_backup_folder .. "\\pre-restore-" .. timestamp_name()
            if backup_command == "preview_restore" then
                return safe_encode({ success = true, backupCommand = backup_command, appId = app_id, selectedBackupPath = backup_restore_path, backupSaveFolder = backup_save_folder, currentSavePath = backup_source_path, preRestorePath = pre_restore, items = {} })
            end
            if not ensure_dir(pre_restore) then return safe_encode({ success = false, error = "Unable to create pre-restore backup", items = {} }) end
            local pre_ok, pre_err = copy_folder(backup_source_path, pre_restore)
            if not pre_ok then return safe_encode({ success = false, error = pre_err or "Unable to create pre-restore backup", preRestorePath = pre_restore, items = {} }) end
            write_backup_metadata(pre_restore, { appId = app_id, gameName = fallback_name ~= "" and fallback_name or "Game", createdAt = timestamp_name(), sourcePath = backup_source_path, preRestore = true })
            local restore_ok, restore_err = copy_folder(backup_save_folder, backup_source_path)
            if not restore_ok then return safe_encode({ success = false, error = restore_err or "Restore failed", preRestorePath = pre_restore, items = {} }) end
            logger:info("GetSaveFolders restore_backup app_id=" .. app_id .. ", backup=" .. backup_restore_path .. ", target=" .. backup_source_path .. ", pre=" .. pre_restore)
            return safe_encode({ success = true, backupCommand = backup_command, appId = app_id, restoredFrom = backup_restore_path, targetPath = backup_source_path, preRestorePath = pre_restore, items = {} })
        end
        if backup_command == "list_backups" then
            local root = backup_root(load_settings())
            if root == "" then return safe_encode({ success = false, error = "Choose a backup folder first", backups = {}, items = {} }) end
            local folder = backup_game_folder(root, app_id, fallback_name ~= "" and fallback_name or "Game")
            local backups = {}
            for _, child in ipairs(paths.children(folder)) do
                if paths.exists(child) then
                    local backup_save_folder = tostring(child):gsub("[\\/]+$", "") .. "\\Save folder"
                    if paths.exists(backup_save_folder) then
                        local name = tostring(child):match("([^\\/]+)$") or child
                        local meta = read_backup_metadata(child)
                        table.insert(backups, { label = snapshot_label_from_name(meta.createdAt or name), gameFolder = tostring(folder):match("([^\\/]+)$") or tostring(folder), path = child, createdAt = meta.createdAt or name, sourcePath = meta.sourcePath or "" })
                    end
                end
            end
            table.sort(backups, function(a, b) return tostring(a.createdAt or "") > tostring(b.createdAt or "") end)
            return safe_encode({ success = true, backupCommand = backup_command, appId = app_id, backupRoot = folder, backups = backups, items = {} })
        end
        if backup_command == "create_dir" or backup_command == "create_current" then
            local settings = load_settings()
            local root = backup_root(settings)
            if root == "" then return safe_encode({ success = false, error = "Choose a backup folder first" }) end
            local base_folder = backup_game_folder(root, app_id, fallback_name ~= "" and fallback_name or "Game")
            clean_pre_restore_backups(base_folder)
            local allow = backup_command ~= "create_current"
            local folder = allow == false and (base_folder .. "\\Current") or unique_path(base_folder .. "\\" .. timestamp_name())
            if allow == false and paths.exists(folder .. "\\Save folder") and not remove_folder(folder .. "\\Save folder") then return safe_encode({ success = false, error = "Unable to replace Current backup" }) end
            if not ensure_dir(folder) then return safe_encode({ success = false, error = "Unable to create backup folder" }) end
            local created_at = timestamp_name()
            if backup_source_path == "" then return safe_encode({ success = false, error = "Missing save path" }) end
            if backup_source_path:find('"', 1, true) or paths.has_unresolved(backup_source_path) or not paths.is_absolute_windows_path(backup_source_path) or not paths.exists(backup_source_path) then
                return safe_encode({ success = false, error = "Invalid save path" })
            end
            local target = folder .. "\\Save folder"
            local copied, copy_err = copy_folder(backup_source_path, target)
            if not copied then return safe_encode({ success = false, error = copy_err or "Copy failed", backupPath = folder }) end
            write_backup_metadata(folder, { appId = app_id, gameName = fallback_name ~= "" and fallback_name or "Game", createdAt = created_at, phase = "copied-recursive", sourcePath = backup_source_path, targetPath = target })
            local source_file = io.open(folder .. "\\source-path.txt", "w")
            if source_file then
                source_file:write(backup_source_path)
                source_file:close()
            end
            logger:info("GetSaveFolders backup copied app_id=" .. app_id .. ", path=" .. folder .. ", source=" .. tostring(backup_source_path or ""))
            return safe_encode({ success = true, backupCommand = backup_command, appId = app_id, backupPath = folder, createdAt = created_at, copied = true, sourcePath = backup_source_path, items = {} })
        end
        rockstar_id, ubisoft_id = merge_launcher_ids_with_settings(rockstar_id, ubisoft_id, rockstar_supplied, ubisoft_supplied)
        local steam_root = paths.steam_root()
        local account_id = paths.resolve_account_id(steam_root, tostring(steam_account_id ~= "" and steam_account_id or steam_id64 or ""))
        if steam_id64 == "" then steam_id64 = paths.account_id_to_steam64(account_id) end
        local game_dir = paths.game_install_dir(steam_root, app_id)
        local game_folder = tostring(game_dir or ""):match("([^\\]+)$") or ""
        local context = { steam_root = steam_root, account_id = account_id, steam_id64 = steam_id64, app_id = app_id, game_folder = game_folder, game_name = fallback_name, rockstar_id = rockstar_id or "", ubisoft_id = ubisoft_id or "" }
        logger:info("GetSaveFolders launcher ids rockstar=" .. tostring(rockstar_id or "") .. ", ubisoft=" .. tostring(ubisoft_id or ""))
        local data = nil
        local pcgw_ok, pcgw_result = pcall(function()
            return pcgw.lookup(app_id, fallback_name, { remote = false })
        end)
        if pcgw_ok and type(pcgw_result) == "table" then
            data = pcgw_result
        else
            local reason = "PCGW lookup failed safely: " .. tostring(pcgw_result)
            logger:error(reason)
            data = { found = false, source = "pcgw-error", reason = reason, saves = {}, configs = {} }
        end
        local items = {}
        local seen = {}
        local local_count = 0
        local_count = local_count + add_ls_manifest_items(items, seen, context)

        local likely_ubisoft_game = should_add_ubisoft_savegames({ saves = {}, configs = {} }, context)
        local likely_rockstar_game = tostring(fallback_name or ""):lower():find("red dead", 1, true) ~= nil
            or tostring(fallback_name or ""):lower():find("grand theft auto", 1, true) ~= nil
            or tostring(fallback_name or ""):lower():find("gta", 1, true) ~= nil
            or tostring(fallback_name or ""):lower():find("rockstar", 1, true) ~= nil
        if false and local_count == 0 and not has_usable_save_item(items) and data and data.source == "pcgw-skipped" and not likely_ubisoft_game and not likely_rockstar_game then
            logger:info("GetSaveFolders local detection empty; fetching PCGW on demand")
            local remote_ok, remote_result = pcall(function()
                return pcgw.lookup(app_id, fallback_name, { remote = true })
            end)
            if remote_ok and type(remote_result) == "table" then
                data = remote_result
            else
                local reason = "PCGW on-demand lookup failed safely: " .. tostring(remote_result)
                logger:error(reason)
                data = { found = false, source = "pcgw-error", reason = reason, saves = {}, configs = {} }
            end
        end

        logger:info("GetSaveFolders app_id=" .. app_id .. ", game=" .. fallback_name .. ", provided_account=" .. tostring(steam_account_id or "") .. ", account=" .. account_id .. ", force_remote=" .. tostring(force_remote == true) .. ", source=" .. tostring(data and data.source) .. ", reason=" .. tostring(data and data.reason))

        if data and data.source ~= "pcgw-skipped" and is_transient_pcgw_error(data.reason) and ((data.source == nil or data.source == "pcgw-error") or (#(data.saves or {}) == 0 and #(data.configs or {}) == 0)) then
            logger:info("GetSaveFolders PCGW transient error ignored; continuing with local/launcher fallbacks: " .. tostring(data.reason or ""))
            data = { found = false, source = "pcgw-error", reason = data.reason, saves = {}, configs = {} }
        end

        logger:info("GetSaveFolders pcgw counts saves=" .. tostring(data and data.saves and #data.saves or 0) .. ", configs=" .. tostring(data and data.configs and #data.configs or 0))
        for index, raw in ipairs(data and data.saves or {}) do
            if index <= 3 then logger:info("GetSaveFolders pcgw save[" .. tostring(index) .. "]=" .. tostring(raw)) end
        end
        for index, raw in ipairs(data and data.configs or {}) do
            if index <= 3 then logger:info("GetSaveFolders pcgw config[" .. tostring(index) .. "]=" .. tostring(raw)) end
        end

        local ubisoft_ids = merged_ubisoft_game_ids(data, context)
        local use_ubisoft_savegames = should_add_ubisoft_savegames(data, context)
        if use_ubisoft_savegames and #ubisoft_ids == 0 then
            logger:info("GetSaveFolders Ubisoft ids not found in local/cache; skipping automatic PCGW Ubisoft refresh")
        end
        logger:info("GetSaveFolders ubisoft game ids=" .. table.concat(ubisoft_ids, ","))
        local added_ubisoft = false
        if use_ubisoft_savegames and #ubisoft_ids > 0 then
            local_count = local_count + add_ubisoft_savegames(items, seen, context, ubisoft_ids)
            added_ubisoft = true
        end

        if data and data.saves then
            local has_ls_ubisoft_ids = #ls_ubisoft_game_ids(context) > 0
            for _, raw in ipairs(data.saves) do
                local launcher = is_ubisoft_launcher_path(raw, context) and "ubisoft" or nil
                if not (launcher == "ubisoft" and has_ls_ubisoft_ids) then
                    add_item(items, seen, "save", "Save folder", raw, context, { launcher = launcher })
                    local_count = local_count + 1
                end
            end
        end
        if data and data.configs then
            local seen_config_folders = {}
            for _, raw in ipairs(data.configs) do
                local display_raw = raw
                local folder = paths.expand(raw, context):gsub("[\\/]+", "\\")
                if folder:match("%.[^\\%.]+$") or folder:find("*", 1, true) then
                    folder = folder:match("^(.*)\\[^\\]+$") or folder
                    if folder ~= "" then display_raw = folder end
                end
                local key = folder:gsub("\\+$", ""):lower()
                if key == "" or not seen_config_folders[key] then
                    if key ~= "" then seen_config_folders[key] = true end
                    add_item(items, seen, "config", "Config folder", display_raw, context)
                    local_count = local_count + 1
                end
            end
        end

        if local_count == 0 and not has_usable_save_item(items) then local_count = local_count + add_common_user_folders(items, seen, context, force_remote == true) end
        if force_remote == true and not has_usable_save_item(items) then local_count = local_count + add_steam_userdata(items, seen, context) end
        if use_ubisoft_savegames and not added_ubisoft then local_count = local_count + add_ubisoft_savegames(items, seen, context, ubisoft_ids) end
        if force_remote == true and not has_usable_save_item(items) then local_count = local_count + add_unity_locallow(items, seen, context) end
        if force_remote == true and not has_usable_save_item(items) then local_count = local_count + add_unreal_installdir(items, seen, context) end

        local final_items = dedupe_items(items)
        for index, item in ipairs(final_items) do
            logger:info("GetSaveFolders final[" .. tostring(index) .. "] kind=" .. tostring(item.kind) .. ", label=" .. tostring(item.label) .. ", exists=" .. tostring(item.exists) .. ", source=" .. tostring(item.source) .. ", path=" .. tostring(item.path or item.rawPath or "") .. ", openPath=" .. tostring(item.openPath or ""))
        end
        local online_only = is_online_only_app(app_id) and not has_usable_save_item(final_items)
        logger:info("GetSaveFolders returning app_id=" .. app_id .. ", items=" .. tostring(#final_items))
        return safe_encode({
            success = true,
            appId = app_id,
            gameName = fallback_name,
            steamRoot = steam_root,
            steamAccountId = account_id,
            userDirs = paths.user_dirs(),
            pcgwPage = data and data.page or nil,
            pcgwUrl = data and data.url or pcgw_appid_url(app_id, fallback_name),
            reason = online_only and "Online only" or (data and data.reason or nil),
            onlineOnly = online_only,
            onlineOnlyName = online_only and online_only_name(app_id) or nil,
            remoteAvailable = false,
            ubisoftRefreshSuggested = use_ubisoft_savegames and #ubisoft_ids == 0 and read_json_file(UBISOFT_IDS_CACHE_FILE)[tostring(app_id or "")] == nil,
            items = final_items,
        })
    end)
    if not success then
        logger:error("GetSaveFolders error: " .. tostring(result))
        return safe_encode({ success = false, error = tostring(result), items = {} })
    end
    return result
end

local function profile_summary(path)
    local folders = 0
    local files = 0
    for _, child in ipairs(paths.children(path)) do
        local leaf = tostring(child or ""):gsub("^.*[\\/]", "")
        if leaf ~= "" then
            if paths.exists(child) then folders = folders + 1 else files = files + 1 end
        end
    end
    return folders, files
end

local function discover_ubisoft_profiles()
    local result = {}
    local root = paths.ubisoft_connect_folder()
    local savegames = root ~= "" and (root .. "\\savegames") or ""
    if savegames == "" or not paths.exists(savegames) then return result end
    for _, child in ipairs(paths.children(savegames)) do
        local id = tostring(child or ""):gsub("^.*[\\/]", "")
        if id:match("^[%w%-]+$") and paths.exists(child) then
            local folders = 0
            local files = 0
            for _, game_folder in ipairs(paths.children(child)) do
                local game_id = tostring(game_folder or ""):gsub("^.*[\\/]", "")
                if game_id:match("^%d+$") then folders = folders + 1 end
            end
            table.insert(result, { id = id, folders = folders, label = tostring(folders) .. " save folders" })
        end
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

local function discover_rockstar_profiles()
    local result = {}
    local docs = paths.documents_dir()
    local roots = {
        docs .. "\\Rockstar Games\\Red Dead Redemption 2\\Profiles",
        docs .. "\\Rockstar Games\\GTA V\\Profiles",
        docs .. "\\Rockstar Games\\Launcher\\Profiles",
    }
    local seen = {}
    for _, root in ipairs(roots) do
        if root ~= "" and paths.exists(root) then
            for _, child in ipairs(paths.children(root)) do
                local id = tostring(child or ""):gsub("^.*[\\/]", "")
                if id:match("^[%w%-]+$") and not seen[id] then
                    seen[id] = true
                    local folders, files = profile_summary(child)
                    table.insert(result, { id = id, folders = folders, files = files, label = tostring(folders + files) .. " entries" })
                end
            end
        end
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

function DiscoverLauncherProfileIds()
    local success, result = pcall(function()
        return safe_encode({ success = true, ubisoft = discover_ubisoft_profiles(), rockstar = discover_rockstar_profiles() })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result), ubisoft = {}, rockstar = {} })
end

function GetSettings()
    local success, result = pcall(function()
        local settings = load_settings()
        return safe_encode({ success = true, rockstarId = settings.rockstarId or "", ubisoftId = settings.ubisoftId or "", backupRoot = backup_root(settings), allowMultipleBackups = settings.allowMultipleBackups ~= false })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function ClearLauncherProfileIds()
    local success, result = pcall(function()
        local settings = load_settings()
        settings.rockstarId = ""
        settings.ubisoftId = ""
        local saved = save_settings(settings)
        paths.set_launcher_ids("", "")
        logger:info("ClearLauncherProfileIds cleared launcher profile ids, saved=" .. tostring(saved))
        if not saved then return safe_encode({ success = false, error = "Unable to write settings", rockstarId = "", ubisoftId = "" }) end
        return safe_encode({ success = true, rockstarId = "", ubisoftId = "" })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result), rockstarId = "", ubisoftId = "" })
end

function SetLauncherProfileIds(rockstar, ubisoft)
    local success, result = pcall(function()
        local args = decode_arg_table(rockstar)
        if next(args) ~= nil then
            if type(args.argumentList) == "table" then args = decode_arg_table(args.argumentList) end
            if type(args[1]) == "table" then args = decode_arg_table(args[1]) end
            if type(args[1]) == "string" and args[1] ~= "" and args.rockstarId == nil and args.ubisoftId == nil then args = decode_arg_table(args[1]) end
            rockstar = first_value(args, "rockstarId", "rockstar_id", "rockstar", 1)
            ubisoft = first_value(args, "ubisoftId", "ubisoft_id", "ubisoft", 2)
        elseif type(rockstar) == "string" and tostring(rockstar):find("|", 1, true) then
            local parsed_rockstar, parsed_ubisoft = tostring(rockstar):match("^(.-)|(.*)$")
            rockstar = parsed_rockstar
            ubisoft = parsed_ubisoft
        end
        local settings = load_settings()
        settings.rockstarId = trim(rockstar or "")
        settings.ubisoftId = trim(ubisoft or "")
        local saved = save_settings(settings)
        paths.set_launcher_ids(settings.rockstarId, settings.ubisoftId)
        logger:info("SetLauncherProfileIds stored rockstar=" .. tostring(settings.rockstarId or "") .. ", ubisoft=" .. tostring(settings.ubisoftId or "") .. ", saved=" .. tostring(saved))
        if not saved then return safe_encode({ success = false, error = "Unable to write settings", rockstarId = settings.rockstarId, ubisoftId = settings.ubisoftId }) end
        return safe_encode({ success = true, rockstarId = settings.rockstarId, ubisoftId = settings.ubisoftId })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result), rockstarId = "", ubisoftId = "" })
end

function SaveSettings(args)
    local success, result = pcall(function()
        args = decode_arg_table(args)
        if type(args.argumentList) == "table" then args = decode_arg_table(args.argumentList) end
        if type(args[1]) == "table" then args = decode_arg_table(args[1]) end
        if type(args[1]) == "string" and args[1] ~= "" then args = decode_arg_table(args[1]) end
        if type(args[1]) == "string" and tostring(args[1]):find("rockstarId", 1, true) then args = decode_arg_table(args[1]) end
        local settings = load_settings()
        local rockstar = first_value(args, "rockstarId", "rockstar_id", "rockstar", 1)
        local ubisoft = first_value(args, "ubisoftId", "ubisoft_id", "ubisoft", 2)
        logger:info("SaveSettings received rockstar=" .. tostring(rockstar or "") .. ", ubisoft=" .. tostring(ubisoft or ""))
        if rockstar ~= nil then settings.rockstarId = trim(rockstar) end
        if ubisoft ~= nil then settings.ubisoftId = trim(ubisoft) end
        settings.rockstarId = settings.rockstarId or ""
        settings.ubisoftId = settings.ubisoftId or ""
        local saved = save_settings(settings)
        paths.set_launcher_ids(settings.rockstarId, settings.ubisoftId)
        logger:info("SaveSettings stored rockstar=" .. tostring(settings.rockstarId or "") .. ", ubisoft=" .. tostring(settings.ubisoftId or "") .. ", saved=" .. tostring(saved))
        if not saved then return safe_encode({ success = false, error = "Unable to write settings", rockstarId = settings.rockstarId, ubisoftId = settings.ubisoftId }) end
        return safe_encode({ success = true, rockstarId = settings.rockstarId, ubisoftId = settings.ubisoftId })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function UpdateUbisoftGameIds(args)
    local success, result = pcall(function()
        args = decode_arg_table(args)
        if type(args[1]) == "table" then args = args[1] end
        if type(args[1]) == "string" and args[1] ~= "" then args = decode_arg_table(args[1]) end
        local app_id = tostring(args.app_id or args.appId or args[1] or "")
        if app_id == "" then return safe_encode({ success = false, error = "Missing AppID", ids = {} }) end
        logger:info("UpdateUbisoftGameIds app_id=" .. app_id)
        local lookup = pcgw.lookup_ubisoft_ids_for_app(app_id)
        local ids = type(lookup) == "table" and lookup.ids or {}
        if #ids == 0 then
            local transient_error = is_transient_pcgw_error(lookup and (lookup.reason or lookup.error) or "")
            if not transient_error then
                local cache = read_json_file(UBISOFT_IDS_CACHE_FILE)
                cache[app_id] = { ids = {}, page = lookup and lookup.page or nil, url = lookup and lookup.url or nil, source = "pcgw", timestamp = os.time(), error = lookup and (lookup.reason or lookup.error) or "No Ubisoft Steam save IDs found on PCGW" }
                write_json_file(UBISOFT_IDS_CACHE_FILE, cache)
            end
            return safe_encode({ success = false, appId = app_id, error = lookup and lookup.reason or "No Ubisoft Steam save IDs found on PCGW", page = lookup and lookup.page or nil, url = lookup and lookup.url or nil, ids = {} })
        end
        local cache = read_json_file(UBISOFT_IDS_CACHE_FILE)
        cache[app_id] = { ids = ids, page = lookup.page, url = lookup.url, source = "pcgw", timestamp = os.time() }
        local saved = write_json_file(UBISOFT_IDS_CACHE_FILE, cache)
        logger:info("UpdateUbisoftGameIds stored app_id=" .. app_id .. ", ids=" .. table.concat(ids, ",") .. ", saved=" .. tostring(saved))
        return safe_encode({ success = saved, appId = app_id, ids = ids, page = lookup.page, url = lookup.url, error = saved and nil or "Unable to write Ubisoft ID cache" })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result), ids = {} })
end


function ClearCache()
    local success, result = pcall(function()
        local cleared = {}
        if write_empty_json(CACHE_FILE) then table.insert(cleared, "runtime") end
        if write_empty_json(UBISOFT_IDS_CACHE_FILE) then table.insert(cleared, "ubisoft") end
        if write_empty_json(PCGW_LOCAL_DATA_FILE) then table.insert(cleared, "pcgw") end
        clear_runtime_caches()
        logger:info("ClearCache cleared " .. table.concat(cleared, ","))
        return safe_encode({ success = true, cleared = cleared })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

local function build_pcgw_cache_for_installed(limit, cursor)
    limit = tonumber(limit or 1) or 1
    if limit < 1 then limit = 1 end
    if limit > 3 then limit = 3 end
    local steam_root = paths.steam_root()
    local app_ids = paths.installed_app_ids(steam_root)
    local data = read_json_file(PCGW_LOCAL_DATA_FILE)
    cursor = tonumber(cursor or 1) or 1
    if cursor < 1 then cursor = 1 end
    if cursor > #app_ids + 1 then cursor = #app_ids + 1 end
    if cursor > #app_ids then
        return {
            success = true,
            installed = #app_ids,
            checked = 0,
            updated = 0,
            skipped = 0,
            failed = 0,
            cursor = #app_ids + 1,
            nextCursor = #app_ids + 1,
            remaining = 0,
            done = true,
            rateLimited = false,
        }
    end

    local checked = 0
    local updated = 0
    local skipped = 0
    local failed = 0
    local rate_limited = false
    local last_error = nil
    local last_app_id = nil
    local index = cursor

    while index <= #app_ids do
        local app_id = tostring(app_ids[index] or "")
        last_app_id = app_id
        if app_id == "" then
            index = index + 1
        elseif data[app_id] then
            skipped = skipped + 1
            index = index + 1
            if checked + skipped >= limit then break end
        else
            if checked >= limit then break end
            checked = checked + 1
            local remote = pcgw.remote_lookup(app_id)
            if remote and remote.found then
                data[app_id] = local_pcgw_cache_entry(remote)
                updated = updated + 1
                index = index + 1
            else
                failed = failed + 1
                last_error = tostring(remote and (remote.reason or remote.error) or "PCGW lookup failed")
                if is_transient_pcgw_error(last_error) then
                    rate_limited = true
                    break
                end
                index = index + 1
            end
        end
    end

    write_json_file(PCGW_LOCAL_DATA_FILE, data)
    clear_runtime_caches()
    return {
        success = true,
        installed = #app_ids,
        checked = checked,
        updated = updated,
        skipped = skipped,
        failed = failed,
        cursor = index,
        nextCursor = index,
        remaining = math.max(0, #app_ids - index + 1),
        done = index > #app_ids,
        rateLimited = rate_limited,
        appId = last_app_id,
        error = last_error,
    }
end

function BuildPcgwCache(args)
    local success, result = pcall(function()
        args = decode_arg_table(args)
        if type(args[1]) == "table" then args = args[1] end
        local summary = build_pcgw_cache_for_installed(args.limit or args.batchSize or 1, args.cursor or args.nextCursor or 1)
        logger:info("BuildPcgwCache checked=" .. tostring(summary.checked) .. ", updated=" .. tostring(summary.updated) .. ", failed=" .. tostring(summary.failed) .. ", remaining=" .. tostring(summary.remaining) .. ", cursor=" .. tostring(summary.cursor))
        return safe_encode(summary)
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function GetBackupSettings()
    local success, result = pcall(function()
        local settings = load_settings()
        local allow = settings.allowMultipleBackups
        if allow == nil then allow = true end
        return safe_encode({ success = true, backupRoot = backup_root(settings), allowMultipleBackups = allow == true })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function SaveBackupSettings(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        local settings = load_settings()
        local root_arg = first_value(args, "backupRoot", "backup_root", "path", 1)
        local root = trim(root_arg or settings.backupRoot or "")
        if root == "" then root = default_backup_root() end
        if root ~= "" then
            root = root:gsub("[\\/]+", "\\"):gsub("\\+$", "")
            if not paths.is_absolute_windows_path(root) then return safe_encode({ success = false, error = "Backup folder must be an absolute path" }) end
            if paths.has_unresolved(root) or root:find('"', 1, true) then return safe_encode({ success = false, error = "Invalid backup folder" }) end
        end
        local allow = first_value(args, "allowMultipleBackups", "multiple", "allow_multiple", 2)
        if not ensure_dir(root) then return safe_encode({ success = false, error = "Unable to create backup folder" }) end
        if root_arg ~= nil then settings.backupRoot = root end
        settings.allowMultipleBackups = allow ~= false and tostring(allow) ~= "false" and tostring(allow) ~= "0"
        local saved = save_settings(settings)
        if not saved then return safe_encode({ success = false, error = "Unable to write settings" }) end
        return safe_encode({ success = true, backupRoot = backup_root(settings), allowMultipleBackups = settings.allowMultipleBackups })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function CreateBackupFolderPreview(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        local app_id = tostring(args.app_id or args.appId or "")
        if app_id == "" then return safe_encode({ success = false, error = "Missing app ID" }) end
        local root = backup_root(load_settings())
        if root == "" then return safe_encode({ success = false, error = "Choose a backup folder first" }) end
        local folder = backup_game_folder(root, app_id, "Game") .. "\\" .. timestamp_name()
        folder = unique_path(folder)
        if not ensure_dir(folder) then return safe_encode({ success = false, error = "Unable to create backup folder" }) end
        logger:info("CreateBackupFolderPreview app_id=" .. app_id .. ", path=" .. folder)
        return safe_encode({ success = true, appId = app_id, backupPath = folder, createdAt = timestamp_name() })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function BackupCurrentSave(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        local app_id = tostring(args.app_id or args.appId or "")
        local game_name = tostring(args.gameName or args.game_name or "Game")
        local item = backup_item_from_args(args)
        local source, original_source = backup_source_for_item(item)
        if not source then return safe_encode({ success = false, error = original_source }) end
        local settings = load_settings()
        local root = backup_root(settings)
        if root == "" then return safe_encode({ success = false, error = "Unable to find a backup root folder" }) end
        local game_folder = backup_game_folder(root, app_id, game_name)
        local allow = settings.allowMultipleBackups
        if allow == nil then allow = true end
        local created_at = timestamp_name()
        local snapshot = allow == true and created_at or "Current"
        local destination = game_folder .. "\\" .. snapshot
        if allow == true then destination = unique_path(destination) end
        if not ensure_dir(destination) then return safe_encode({ success = false, error = "Unable to create backup folder" }) end
        local ok, copy_err = copy_folder(source, destination)
        if not ok then return safe_encode({ success = false, error = copy_err or "Copy failed" }) end
        write_backup_metadata(destination, { appId = app_id, gameName = game_name, createdAt = created_at, sourcePath = original_source, backupSourcePath = source, label = tostring(item.label or "Save folder") })
        logger:info("BackupCurrentSave app_id=" .. app_id .. ", path=" .. destination)
        return safe_encode({ success = true, appId = app_id, gameName = game_name, backupPath = destination, createdAt = created_at })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function ListSaveBackups(args)
    local success, result = pcall(function()
        args = decode_arg_table(args)
        if type(args.argumentList) == "table" then args = args.argumentList end
        if type(args[1]) == "table" then args = args[1] end
        if type(args[1]) == "string" and args[1] ~= "" then args = decode_arg_table(args[1]) end
        local app_id = tostring(args.app_id or args.appId or "")
        local game_name = tostring(args.gameName or args.game_name or "Game")
        local folder = backup_game_folder(backup_root(load_settings()), app_id, game_name)
        local backups = {}
        for _, child in ipairs(paths.children(folder)) do
            if paths.exists(child) then
                local name = tostring(child):match("([^\\/]+)$") or child
                local meta = read_backup_metadata(child)
                table.insert(backups, { label = snapshot_label_from_name(meta.createdAt or name), path = child, createdAt = meta.createdAt or name })
            end
        end
        table.sort(backups, function(a, b) return tostring(a.createdAt or "") > tostring(b.createdAt or "") end)
        return safe_encode({ success = true, backupRoot = folder, backups = backups })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result), backups = {} })
end

function RestoreSaveBackup(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        local backup_path = tostring(args.backupPath or args.backup_path or args.path or "")
        local item = backup_item_from_args(args)
        local target, err = valid_save_source(item)
        if not target then return safe_encode({ success = false, error = err }) end
        if backup_path == "" or backup_path:find('"', 1, true) or paths.has_unresolved(backup_path) or not paths.is_absolute_windows_path(backup_path) or not paths.exists(backup_path) then
            return safe_encode({ success = false, error = "Invalid backup path" })
        end
        local app_id = tostring(args.app_id or args.appId or "")
        local game_name = tostring(args.gameName or args.game_name or "Game")
        local pre_restore = backup_game_folder(backup_root(load_settings()), app_id, game_name) .. "\\pre-restore-" .. timestamp_name()
        if not ensure_dir(pre_restore) then return safe_encode({ success = false, error = "Unable to create pre-restore backup" }) end
        local pre_ok, pre_err = copy_folder(target, pre_restore)
        if not pre_ok then return safe_encode({ success = false, error = pre_err or "Unable to create pre-restore backup" }) end
        write_backup_metadata(pre_restore, { appId = app_id, gameName = game_name, createdAt = timestamp_name(), sourcePath = target, preRestore = true })
        local ok, copy_err = copy_folder(backup_path, target)
        if not ok then return safe_encode({ success = false, error = copy_err or "Restore failed", preRestoreBackupPath = pre_restore }) end
        logger:info("RestoreSaveBackup app_id=" .. app_id .. ", restored=" .. backup_path .. ", target=" .. target)
        return safe_encode({ success = true, restoredFrom = backup_path, targetPath = target, preRestoreBackupPath = pre_restore })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function ChooseBackupFolder(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        if args.mode == "create" then
            local app_id = tostring(args.app_id or args.appId or "")
            if app_id == "" then return safe_encode({ success = false, error = "Missing app ID" }) end
            local root = backup_root(load_settings())
            if root == "" then return safe_encode({ success = false, error = "Choose a backup folder first" }) end
            local folder = unique_path(backup_game_folder(root, app_id, "Game") .. "\\" .. timestamp_name())
            if not ensure_dir(folder) then return safe_encode({ success = false, error = "Unable to create backup folder" }) end
            logger:info("ChooseBackupFolder create preview app_id=" .. app_id .. ", path=" .. folder)
            return safe_encode({ success = true, backupPath = folder, createdAt = timestamp_name() })
        end
        if args.mode ~= "choose" and args.mode ~= nil then
            logger:error("ChooseBackupFolder received unknown mode args=" .. safe_encode(args))
            return safe_encode({ success = false, error = "Unknown backup folder command" })
        end
        local initial = trim(args.initialPath or args.backupRoot or args.path or "")
        if initial:sub(1, 10) == "__debug__|" then
            logger:info("ChooseBackupFolder debug args=" .. safe_encode(args))
            return safe_encode({ success = true, debug = true, initialPath = initial, args = args })
        end
        if initial:find('"', 1, true) then initial = backup_root(load_settings()) end
        local temp_file = os.getenv("TEMP") .. "\\my-save-folder-choice-" .. tostring(os.time()) .. ".txt"
        local escaped_initial = initial:gsub("'", "''")
        local escaped_temp = temp_file:gsub("'", "''")
        local script = "Add-Type -AssemblyName System.Windows.Forms; $owner = New-Object System.Windows.Forms.Form; $owner.TopMost = $true; $owner.StartPosition = 'CenterScreen'; $owner.ShowInTaskbar = $false; $owner.WindowState = 'Minimized'; $owner.Show(); $owner.Activate(); $dialog = New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description = 'Select My Save backup folder'; $dialog.ShowNewFolderButton = $true; $dialog.SelectedPath = '" .. escaped_initial .. "'; $selected = ''; if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $selected = $dialog.SelectedPath }; Set-Content -LiteralPath '" .. escaped_temp .. "' -Value $selected -NoNewline; $owner.Close()"
        if not run_powershell_hidden(script) then return safe_encode({ success = false, error = "Folder picker unavailable" }) end
        local file = nil
        for _ = 1, 480 do
            file = io.open(temp_file, "r")
            if file then break end
            if kernel32 then kernel32.Sleep(250) end
        end
        if not file then return safe_encode({ success = false, cancelled = true }) end
        local chosen = trim(file:read("*all") or "")
        file:close()
        os.remove(temp_file)
        if chosen == "" then return safe_encode({ success = false, cancelled = true }) end
        if not paths.is_absolute_windows_path(chosen) or paths.has_unresolved(chosen) or chosen:find('"', 1, true) then return safe_encode({ success = false, error = "Invalid folder selected" }) end
        chosen = chosen:gsub("[\\/]+", "\\"):gsub("\\+$", "")
        if not ensure_dir(chosen) then return safe_encode({ success = false, error = "Unable to create selected folder" }) end
        local settings = load_settings()
        settings.backupRoot = chosen
        if settings.allowMultipleBackups == nil then settings.allowMultipleBackups = true end
        if not save_settings(settings) then return safe_encode({ success = false, error = "Unable to write settings" }) end
        return safe_encode({ success = true, path = chosen, saved = true })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function OpenBackupFolder(args)
    local success, result = pcall(function()
        args = normalize_backup_args(args)
        local root = trim(args.backupRoot or args.path or backup_root(load_settings()))
        if root == "" then root = backup_root(load_settings()) end
        root = root:gsub("[\\/]+", "\\"):gsub("\\+$", "")
        if root == "" or root:find('"', 1, true) or paths.has_unresolved(root) or not paths.is_absolute_windows_path(root) then
            return safe_encode({ success = false, error = "Invalid backup folder" })
        end
        ensure_dir(root)
        if not paths.exists(root) then return safe_encode({ success = false, error = "Folder does not exist" }) end
        local opened = open_folder_silent(root)
        return safe_encode({ success = opened, path = root })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function OpenFolder(args)
    local success, result = pcall(function()
        local path = ""
        if type(args) == "string" then
            path = args
        elseif type(args) == "table" then
            if type(args.argumentList) == "string" then path = args.argumentList end
            if path == "" and type(args.argumentList) == "table" then
                path = tostring(args.argumentList.path or args.argumentList[1] or "")
            end
            if path == "" then
                local decoded = decode_arg_table(args)
                if type(decoded) == "table" then path = tostring(decoded.path or decoded[1] or "") end
            end
            if path == "" then path = tostring(args.path or args[1] or "") end
        end
        logger:info("OpenFolder received path=" .. path)
        if path == "" then return safe_encode({ success = false, error = "Missing path" }) end
        if paths.has_unresolved(path) then return safe_encode({ success = false, error = "Path has unresolved placeholders" }) end
        if not paths.is_absolute_windows_path(path) then return safe_encode({ success = false, error = "Path must be absolute" }) end
        if not paths.exists(path) then return safe_encode({ success = false, error = "Folder does not exist" }) end
        if path:find('"', 1, true) then return safe_encode({ success = false, error = "Invalid path" }) end
        local opened = open_folder_silent(path)
        return safe_encode({ success = opened, path = path })
    end)
    if success then return result end
    return safe_encode({ success = false, error = tostring(result) })
end

function on_load()
    logger:info("My Save plugin loaded")
    millennium.ready()
end

local function initialize()
    on_load()
end

return {
    Initialize = initialize,
    on_load = on_load,
    GetSaveFolders = GetSaveFolders,
    GetSettings = GetSettings,
    SaveSettings = SaveSettings,
    UpdateUbisoftGameIds = UpdateUbisoftGameIds,
    ClearCache = ClearCache,
    GetBackupSettings = GetBackupSettings,
    ChooseBackupFolder = ChooseBackupFolder,
    OpenBackupFolder = OpenBackupFolder,
    OpenFolder = OpenFolder,
}
