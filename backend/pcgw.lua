local json = require("json")
local logger = require("logger")
local http = require("http")
local io = require("io")

local M = {}

local API_URL = "https://www.pcgamingwiki.com/w/api.php"
local APPID_URL = "https://www.pcgamingwiki.com/api/appid.php?appid="
local STEAM_EXTURL_PREFIX = "store.steampowered.com/app/"
local CACHE_TTL = 86400
local MAX_REQUESTS_PER_MINUTE = 3
local USER_AGENT = "MySaveMillenniumPlugin/0.1.0 (local Millennium plugin; PCGamingWiki API client)"

local LAST_ERROR = nil
local request_times = {}
local backoff_until = 0

local function set_error(message)
    LAST_ERROR = message
    logger:error(message)
end

local function transient_result(source)
    return { found = false, reason = LAST_ERROR or "PCGW temporarily unavailable", saves = {}, configs = {}, source = source or "pcgw-error", transient = true }
end

local function clear_error()
    LAST_ERROR = nil
end

local function backend_path()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", ""):gsub("/", "\\")
    return source:match("^(.*)\\[^\\]+$") or ".\\backend"
end

local CACHE_FILE = backend_path() .. "\\my-save-cache.json"
local LOCAL_DATA_FILE = backend_path() .. "\\pcgw-paths.json"

local function urlencode(value)
    value = tostring(value or "")
    value = value:gsub("\n", "\r\n")
    return value:gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function percent_decode(value)
    return tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function build_url(base, params)
    local query = {}
    for key, value in pairs(params or {}) do
        table.insert(query, urlencode(key) .. "=" .. urlencode(value))
    end
    return base .. "?" .. table.concat(query, "&")
end

local function options(follow_redirects)
    return {
        timeout = 8,
        follow_redirects = follow_redirects,
        user_agent = USER_AGENT,
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept"] = "application/json, text/html;q=0.9, */*;q=0.8",
        },
    }
end

local json_file_cache = {}

local function load_json_file(path)
    if path == LOCAL_DATA_FILE then
        local cached = json_file_cache[path]
        if cached ~= nil then return cached end
        local file = io.open(path, "r")
        if not file then json_file_cache[path] = nil; return nil end
        local content = file:read("*all")
        file:close()
        if not content or content == "" then json_file_cache[path] = nil; return nil end
        local ok, parsed = pcall(json.decode, content)
        if ok and type(parsed) == "table" then json_file_cache[path] = parsed; return parsed end
        return nil
    end
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then return nil end
    local ok, parsed = pcall(json.decode, content)
    if ok and type(parsed) == "table" then return parsed end
    return nil
end

local function save_json_file(path, data)
    local ok, encoded = pcall(json.encode, data)
    if not ok then return end
    local file = io.open(path, "w")
    if not file then return end
    file:write(encoded)
    file:close()
end

local function cache_get(key)
    local cache = load_json_file(CACHE_FILE) or {}
    local entry = cache[key]
    if entry and entry.timestamp and os.time() - entry.timestamp < CACHE_TTL then
        local data = entry.data
        if type(data) == "table" and (data.page == "Home" or data.url == "https://www.pcgamingwiki.com/wiki/Home") then return nil end
        return data
    end
    return nil
end

local function cache_set(key, data)
    local cache = load_json_file(CACHE_FILE) or {}
    cache[key] = { timestamp = os.time(), data = data }
    save_json_file(CACHE_FILE, cache)
end

local function response_snippet(response)
    return tostring(response and response.body or ""):gsub("%s+", " "):sub(1, 160)
end

local function request_allowed()
    local now = os.time()
    if backoff_until > now then
        set_error("PCGW is rate-limited; try again in " .. tostring(backoff_until - now) .. " seconds")
        return false
    end
    local recent = {}
    for _, timestamp in ipairs(request_times) do
        if now - timestamp < 60 then table.insert(recent, timestamp) end
    end
    request_times = recent
    if #request_times >= MAX_REQUESTS_PER_MINUTE then
        local retry_after = math.max(1, 60 - (now - request_times[1]))
        set_error("PCGW throttled locally; try again in " .. tostring(retry_after) .. " seconds")
        return false
    end
    table.insert(request_times, now)
    return true
end

local function pcgw_get(url, follow_redirects, accept)
    if not request_allowed() then return nil end
    local opts = options(follow_redirects)
    opts.headers["Accept"] = accept or opts.headers["Accept"]
    local response, err = http.get(url, opts)
    if not response then
        set_error("PCGW request failed: " .. tostring(err or "unknown"))
        return nil
    end
    if response.status == 429 then
        backoff_until = os.time() + 60
        set_error("PCGW returned HTTP 429 Too Many Requests; backing off before retrying")
        return nil
    end
    if response.status == 403 then
        set_error("PCGW returned HTTP 403 Forbidden; the request may be blocked despite the custom User-Agent")
        return nil
    end
    if response.status ~= 200 and response.status ~= 301 and response.status ~= 302 then
        set_error("PCGW returned HTTP " .. tostring(response.status) .. ": " .. response_snippet(response))
        return nil
    end
    return response
end

local function get_json(params)
    params = params or {}
    params.origin = params.origin or "*"
    local response = pcgw_get(build_url(API_URL, params), true, "application/json, */*;q=0.8")
    if not response then return nil end
    local ok, parsed = pcall(json.decode, response.body or "")
    if ok and type(parsed) == "table" then
        if parsed.error then
            set_error("PCGW API error: " .. tostring(parsed.error.code or "unknown") .. " - " .. tostring(parsed.error.info or ""))
            return nil
        end
        return parsed
    end
    set_error("PCGW API response parse failed: " .. response_snippet(response))
    return nil
end

local function normalize_title(title)
    return tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function page_url(title)
    if not title or title == "" then return nil end
    return "https://www.pcgamingwiki.com/wiki/" .. tostring(title):gsub(" ", "_")
end

local html_decode

local function title_from_url(source)
    local title = tostring(source or ""):match('/wiki/([^%s%?#"]+)')
    if not title then return nil end
    return normalize_title(percent_decode(title:gsub("_", " ")))
end

local function title_from_html(html)
    local title = tostring(html or ""):match("<title>%s*(.-)%s*%- PCGamingWiki")
    if not title or title == "" then return nil end
    return normalize_title(html_decode(title))
end

local function local_data_lookup(app_id)
    local data = load_json_file(LOCAL_DATA_FILE)
    local entry = data and data[tostring(app_id)]
    if not entry then return nil end
    return {
        found = true,
        source = "local",
        page = entry.page,
        url = entry.url or page_url(entry.page),
        saves = entry.saves or {},
        configs = entry.configs or {},
    }
end

html_decode = function(value)
    value = tostring(value or "")
    value = value:gsub("&amp;", "&")
    value = value:gsub("&lt;", "<")
    value = value:gsub("&gt;", ">")
    value = value:gsub("&quot;", '"')
    value = value:gsub("&#039;", "'")
    value = value:gsub("&#(%d+);", function(code) return string.char(tonumber(code) or 32) end)
    value = value:gsub("&#x(%x+);", function(code) return string.char(tonumber(code, 16) or 32) end)
    return value
end

local function html_to_lines(html)
    local text = tostring(html or "")
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("</li>", "\n")
    text = text:gsub("</p>", "\n")
    text = text:gsub("</tr>", "\n")
    text = text:gsub("</td>", "\t")
    text = text:gsub("</th>", "\t")
    text = text:gsub("<[^>]+>", " ")
    text = html_decode(text)
    text = text:gsub("\194\160", " ")
    text = text:gsub("\r", "")
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then table.insert(lines, line) end
    end
    return lines
end

local template_to_path

local function clean_path(value)
    value = tostring(value or "")
    value = value:gsub("/", "\\")
    value = value:gsub("^%s*Windows%s*", "")
    value = value:gsub("^:%s*", "")
    value = value:gsub("^%-%s*", "")
    value = value:gsub("%s*%(([^%%<%a:~]*notes?[^%%<%a:~]*)%)", "")
    value = value:gsub("%s*\\%s*", "\\")
    value = value:gsub("%s+", " ")
    value = value:gsub("^[Gg]ames\\<[Uu]ser%-id>\\", "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\")
    value = value:gsub("^[Gg]ames\\<[Uu]ser [Ii][Dd]>\\", "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\")
    value = value:gsub("^[Gg]ames\\%[userid%]\\", "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\")
    local lower_value = value:lower()
    if lower_value:find("compatdata", 1, true) or lower_value:find("compactdata", 1, true) then return "" end
    if value:match("^[\\/]My Games[\\/]") then value = "%DOCUMENTS%" .. value end
    if value:match("^[\\/]Packages[\\/]") then return "" end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function useful(path)
    if not path or path == "" then return false end
    if path:find("{{") or path:find("}}") then return false end
    local lower = path:lower()
    if lower:find("linux") or lower:find("macos") then return false end
    return path:find("\\") ~= nil or path:find("%%") ~= nil or path:find("<") ~= nil or lower:find("saved games") ~= nil
end

local function add_path(result, seen, path)
    path = clean_path(path)
    if not useful(path) then return end
    local key = path:lower()
    if seen[key] then return end
    seen[key] = true
    table.insert(result, path)
end

local function line_mentions_non_windows_platform(line)
    local lower = tostring(line or ""):lower()
    return lower:find("linux", 1, true) ~= nil
        or lower:find("steam play", 1, true) ~= nil
        or lower:find("proton", 1, true) ~= nil
        or lower:find("compatdata", 1, true) ~= nil
        or lower:find("compactdata", 1, true) ~= nil
        or lower:find("macos", 1, true) ~= nil
        or lower:find("mac os", 1, true) ~= nil
end

local function line_mentions_steam(line)
    local lower = tostring(line or ""):lower()
    return lower:find("steam", 1, true) ~= nil and not line_mentions_non_windows_platform(line)
end

local function extract_paths_from_lines(lines, steam_only)
    local result = {}
    local seen = {}
    local patterns = {
        "(%%DOCUMENTS%%\\[^\n\t]+)",
        "(%%USERPROFILE%%\\[^\n\t]+)",
        "(%%APPDATA%%\\[^\n\t]+)",
        "(%%LOCALAPPDATA%%\\[^\n\t]+)",
        "(%%PROGRAMDATA%%\\[^\n\t]+)",
        "(%%PUBLIC%%\\[^\n\t]+)",
        "(%%USERPROFILE%%\\Saved Games\\[^\n\t]+)",
        "(<[Pp]ath%-to%-game>\\[^\n\t]+)",
        "(<[Pp]ath to game>\\[^\n\t]+)",
        "(<Steam%-folder>\\[^\n\t]+)",
        "(<[Uu]bisoft%-[Cc]onnect%-folder>\\[^\n\t]+)",
        "(<[Uu]bisoft [Cc]onnect folder>\\[^\n\t]+)",
        "(<[Uu]bisoft%-[Gg]ame%-[Ll]auncher%-folder>\\[^\n\t]+)",
        "(<[Uu]bisoft [Gg]ame [Ll]auncher folder>\\[^\n\t]+)",
        "([Gg]ames%s*\\%s*<[Uu]ser%-id>%s*\\[^\n\t]+)",
        "([Gg]ames%s*\\%s*<[Uu]ser [Ii][Dd]>%s*\\[^\n\t]+)",
        "([Gg]ames%s*\\%s*%[userid%]%s*\\[^\n\t]+)",
        "(%a:\\[^\n\t]+)",
    }
    for _, raw in ipairs(lines or {}) do
        if not steam_only or line_mentions_steam(raw) then
            local line = template_to_path(raw:gsub("/", "\\"))
            for _, pattern in ipairs(patterns) do
                for path in line:gmatch(pattern) do add_path(result, seen, path) end
            end
        end
    end
    return result
end

local function get_wikitext(title)
    local data = get_json({ action = "query", format = "json", prop = "revisions", titles = title, rvprop = "content", rvslots = "main" })
    local pages = data and data.query and data.query.pages
    if type(pages) ~= "table" then return nil end
    for _, page in pairs(pages) do
        local rev = page.revisions and page.revisions[1]
        if rev then
            if rev.slots and rev.slots.main and rev.slots.main["*"] then return rev.slots.main["*"] end
            if rev["*"] then return rev["*"] end
        end
    end
    return nil
end

local function game_data_template_path(line)
    line = tostring(line or "")
    local start_pos, pos = line:find("{{%s*[Gg]ame data/[Ss]aves%s*|%s*[^|]+%s*|")
    if not start_pos then start_pos, pos = line:find("{{%s*[Gg]ame data/[Cc]onfig%s*|%s*[^|]+%s*|") end
    if not pos then return nil end
    local depth = 1
    local i = pos + 1
    local path_start = i
    while i <= #line do
        local two = line:sub(i, i + 1)
        if two == "{{" then
            depth = depth + 1
            i = i + 2
        elseif two == "}}" then
            depth = depth - 1
            if depth == 0 then return line:sub(path_start, i - 1) end
            i = i + 2
        elseif two == "|" and depth == 1 then
            return line:sub(path_start, i - 1)
        else
            i = i + 1
        end
    end
    return line:sub(path_start)
end

local function template_alias_path(name)
    local key = tostring(name or ""):lower()
    key = key:gsub("[_%-]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local slash = string.char(92)
    local map = {
        ["userprofile"] = "%USERPROFILE%",
        ["user profile"] = "%USERPROFILE%",
        ["profile"] = "%USERPROFILE%",
        ["home"] = "%USERPROFILE%",
        ["documents"] = "%DOCUMENTS%",
        ["my documents"] = "%DOCUMENTS%",
        ["personal"] = "%DOCUMENTS%",
        ["savedgames"] = "%USERPROFILE%" .. slash .. "Saved Games",
        ["saved games"] = "%USERPROFILE%" .. slash .. "Saved Games",
        ["localappdata"] = "%LOCALAPPDATA%",
        ["local appdata"] = "%LOCALAPPDATA%",
        ["local app data"] = "%LOCALAPPDATA%",
        ["appdata"] = "%APPDATA%",
        ["app data"] = "%APPDATA%",
        ["roamingappdata"] = "%APPDATA%",
        ["roaming appdata"] = "%APPDATA%",
        ["roaming app data"] = "%APPDATA%",
        ["programdata"] = "%PROGRAMDATA%",
        ["program data"] = "%PROGRAMDATA%",
        ["public"] = "%PUBLIC%",
        ["game"] = "<path-to-game>",
        ["steam"] = "<Steam-folder>",
        ["steam folder"] = "<Steam-folder>",
    }
    return map[key]
end

template_to_path = function(value)
    local slash = string.char(92)
    value = tostring(value or "")
    value = value:gsub("{{%s*[Pp]%s*|%s*([^}|]+)%s*}}", function(name) return template_alias_path(name) or "" end)
    value = value:gsub("{{%s*[Ff]olderID%s*|%s*([^}|]+)%s*}}", function(name) return template_alias_path(name) or "" end)
    value = value:gsub("{{%s*[Ff]older[Ii]d%s*|%s*([^}|]+)%s*}}", function(name) return template_alias_path(name) or "" end)
    value = value:gsub("%%USERPROFILE%%" .. slash .. "Documents", "%%DOCUMENTS%%")
    value = value:gsub("%%USERPROFILE%%" .. slash .. "My Documents", "%%DOCUMENTS%%")
    value = value:gsub("%%USERPROFILE%%" .. slash .. "AppData" .. slash .. "Local", "%%LOCALAPPDATA%%")
    value = value:gsub("%%USERPROFILE%%" .. slash .. "AppData" .. slash .. "Roaming", "%%APPDATA%%")
    value = value:gsub("%%USERPROFILE%%" .. slash .. "AppData" .. slash .. "LocalLow", "%%LOCALAPPDATA%%" .. slash .. ".." .. slash .. "LocalLow")
    value = value:gsub("{{%s*[Gg]ame data/saves%s*|%s*[^|]+%s*|%s*(.-)%s*}}", "%1")
    value = value:gsub("{{%s*[Gg]ame data/config%s*|%s*[^|]+%s*|%s*(.-)%s*}}", "%1")
    value = value:gsub("{{[Ss]team userdata[^}]*}}", "<Steam-folder>" .. slash .. "userdata" .. slash .. "<user-id>")
    value = value:gsub("{{[^}]+}}", "")
    value = value:gsub("%[%[[^%]|]+|([^%]]+)%]%]", "%1")
    value = value:gsub("%[%[([^%]]+)%]%]", "%1")
    return value
end

local function extract_infobox_field(wikitext, field)
    local pattern = "\n%s*|%s*" .. field .. "%s*=%s*(.-)\n%s*|%s*[%w_%- ]+%s*="
    local value = tostring(wikitext or ""):match(pattern)
    if not value then value = tostring(wikitext or ""):match("\n%s*|%s*" .. field .. "%s*=%s*(.-)\n%s*}}") end
    return value
end

local function fallback_paths(wikitext, field_names)
    local result = {}
    local seen = {}
    for _, field in ipairs(field_names) do
        local value = extract_infobox_field(wikitext, field)
        if value then
            value = template_to_path(value)
            for line in value:gmatch("[^\n]+") do
                local windows = line:match("|%s*Windows%s*[|=]%s*(.-)%s*|") or line:match("|%s*Windows%s*[|=]%s*(.-)%s*}}") or line
                add_path(result, seen, windows)
            end
        end
    end
    return result
end

local function page_from_appid(app_id)
    local api_url = build_url(API_URL, {
        action = "query",
        list = "exturlusage",
        euquery = STEAM_EXTURL_PREFIX .. tostring(app_id or ""),
        eulimit = "10",
        format = "json",
    })
    local response = pcgw_get(api_url, true, "application/json, */*;q=0.8")
    if response then
        local ok, data = pcall(json.decode, tostring(response.body or ""))
        local usage = ok and data and data.query and data.query.exturlusage or nil
        if type(usage) == "table" then
            for _, item in ipairs(usage) do
                local title = tostring(item.title or "")
                local url = tostring(item.url or "")
                if title ~= "" and url:find("/app/" .. tostring(app_id), 1, true) then return title, "" end
            end
            for _, item in ipairs(usage) do
                local title = tostring(item.title or "")
                if title ~= "" then return title, "" end
            end
        end
    end

    response = pcgw_get(APPID_URL .. urlencode(app_id), true, "text/html, */*;q=0.8")
    if not response then return nil, nil end
    local title = title_from_url(response.url or "") or title_from_html(response.body)
    if not title or title == "Home" then
        set_error("PCGW page doesn't exist for this Steam AppID")
        return nil, nil
    end
    return title, tostring(response.body or "")
end

local function section_lines_from_html(html, ids)
    html = tostring(html or "")
    local start = nil
    for _, id in ipairs(ids or {}) do
        start = html:find('id="' .. id .. '"', 1, true) or html:find("id='" .. id .. "'", 1, true)
        if start then break end
    end
    if not start then return {} end
    local next_heading = html:find("<h[23][^>]->", start + 1)
    if not next_heading then next_heading = #html + 1 end
    return html_to_lines(html:sub(start, next_heading - 1))
end

local function wikitext_section(wikitext, heading)
    local target = tostring(heading or ""):lower()
    local capture = false
    local lines = {}
    for line in (tostring(wikitext or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        local current = line:match("^%s*=+%s*(.-)%s*=+%s*$")
        if current then
            if capture then break end
            if current:lower() == target then capture = true end
        elseif capture then
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

local function extract_paths_from_wikitext_section(wikitext, heading)
    local section = wikitext_section(wikitext, heading)
    if section == "" then return {} end
    local steam_lines = {}
    local windows_lines = {}
    for line in section:gmatch("[^\n]+") do
        local lower = line:lower()
        if line_mentions_steam(line) then
            table.insert(steam_lines, line)
        elseif lower:find("windows", 1, true) and not line_mentions_non_windows_platform(line) then
            table.insert(windows_lines, line)
        end
    end
    local source_lines = #steam_lines > 0 and steam_lines or windows_lines
    if #source_lines == 0 then
        for line in section:gmatch("[^\n]+") do
            if not line_mentions_non_windows_platform(line) then table.insert(source_lines, line) end
        end
    end

    local result = {}
    local seen = {}
    for _, line in ipairs(source_lines) do
        local template_path = game_data_template_path(line)
        if template_path then
            add_path(result, seen, template_to_path(template_path))
        else
            for _, path in ipairs(extract_paths_from_lines({ line }, false)) do
                add_path(result, seen, path)
            end
        end
    end
    return result
end

local function extract_paths_from_wikitext(wikitext)
    local saves = extract_paths_from_wikitext_section(wikitext, "Save game data location")
    if #saves == 0 then saves = fallback_paths(wikitext, { "Save game data location", "Save game data location notes" }) end
    local steam_saves = {}
    local seen = {}
    for _, field in ipairs({ "Save game data location", "Save game data location notes" }) do
        local value = extract_infobox_field(wikitext, field)
        if value then
            value = template_to_path(value)
            for line in value:gmatch("[^\n]+") do
                if line_mentions_steam(line) then
                    for _, path in ipairs(extract_paths_from_lines({ line }, false)) do add_path(steam_saves, seen, path) end
                end
            end
        end
    end
    if #steam_saves > 0 then saves = steam_saves end
    local configs = extract_paths_from_wikitext_section(wikitext, "Configuration file(s) location")
    if #configs == 0 then configs = fallback_paths(wikitext, { "Configuration file(s) location", "Configuration file location", "Configuration files location" }) end
    return saves, configs
end

local function remote_lookup(app_id)
    local title, html = page_from_appid(app_id)
    if not title then return { found = false, reason = LAST_ERROR or "PCGamingWiki lookup unavailable", saves = {}, configs = {} } end

    local save_lines = section_lines_from_html(html, { "Save_game_data_location" })
    local config_lines = section_lines_from_html(html, { "Configuration_file(s)_location", "Configuration_file.28s.29_location", "Configuration_files_location" })
    local saves = extract_paths_from_lines(save_lines, true)
    if #saves == 0 then saves = extract_paths_from_lines(save_lines, false) end
    local configs = extract_paths_from_lines(config_lines, false)

    if #saves == 0 or #configs == 0 then
        local wikitext = get_wikitext(title)
        if wikitext then
            local text_saves, text_configs = extract_paths_from_wikitext(wikitext)
            if #saves == 0 then saves = text_saves end
            if #configs == 0 then configs = text_configs end
        end
    end

    return { found = true, source = "pcgw", page = title, url = page_url(title), saves = saves, configs = configs, reason = LAST_ERROR }
end

function M.lookup(app_id, game_name, options)
    clear_error()
    local ok, result = pcall(function()
        options = options or {}
        app_id = tostring(app_id or "")
        if app_id == "" then return { found = false, reason = "Missing AppID", saves = {}, configs = {}, source = "pcgw-error" } end

        local local_entry = local_data_lookup(app_id)
        if local_entry and not options.remote then return local_entry end

        local cache_key = "pcgw-clean-v3:" .. app_id
        local cached = cache_get(cache_key)
        if cached and cached.found and not options.remote then return cached end

        if not options.remote then
            return { found = false, reason = "PCGamingWiki remote lookup available on demand", remoteAvailable = true, saves = {}, configs = {}, source = "pcgw-skipped" }
        end

        if backoff_until > os.time() then
            return transient_result("pcgw-error")
        end

        local remote = remote_lookup(app_id)
        if remote and remote.found and (#(remote.saves or {}) > 0 or #(remote.configs or {}) > 0) then cache_set(cache_key, remote) end
        if remote and remote.found then return remote end
        if local_entry then return local_entry end
        return remote or { found = false, reason = LAST_ERROR or "PCGamingWiki lookup unavailable", saves = {}, configs = {}, source = "pcgw-error" }
    end)
    if ok and type(result) == "table" then return result end
    set_error("PCGW lookup crashed safely: " .. tostring(result))
    return { found = false, reason = LAST_ERROR or "PCGamingWiki lookup failed", saves = {}, configs = {}, source = "pcgw-error" }
end

local function infer_ubisoft_game_id_from_path(raw_path)
    local value = tostring(raw_path or ""):gsub("/", "\\")
    value = value:gsub("%s*\\%s*", "\\")
    local function numeric_id(value)
        value = tostring(value or "")
        if value:match("^%d+$") then return value end
        return nil
    end
    local function tail_after_user_marker(prefix)
        local tail = value:match(prefix .. "\\[^\\<>%[%]]+\\(%d+)")
            or value:match(prefix .. "\\<[Uu]ser%-id>\\(%d+)")
            or value:match(prefix .. "\\<[Uu]ser [Ii][Dd]>\\(%d+)")
            or value:match(prefix .. "\\%%[^%%]+%%\\(%d+)")
            or value:match(prefix .. "\\%[userid%]\\(%d+)")
            or value:match(prefix .. "\\%[user%-id%]\\(%d+)")
        return numeric_id(tail)
    end
    return tail_after_user_marker("[Ss]avegames") or tail_after_user_marker("[Gg]ames") or numeric_id(value:match("[Ss]avegames\\(%d+)$")) or ""
end

function M.extract_ubisoft_game_ids_from_paths(paths)
    local ids = {}
    local seen = {}
    local function add(id)
        id = tostring(id or "")
        if id ~= "" and id:match("^%d+$") and not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    for _, path in ipairs(type(paths) == "table" and paths or {}) do add(infer_ubisoft_game_id_from_path(path)) end
    return ids
end

local function extract_wikitext_section(wikitext, heading)
    local target = tostring(heading or ""):lower()
    local capture = false
    local lines = {}
    for line in (tostring(wikitext or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        local current = line:match("^%s*=+%s*(.-)%s*=+%s*$")
        if current then
            if capture then break end
            if current:lower() == target then capture = true end
        elseif capture then
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

local function extract_steam_ubisoft_paths_from_wikitext(wikitext)
    local result = {}
    local seen = {}
    local fallback_ids = {}
    local section = extract_wikitext_section(wikitext, "Save game data location")
    local sources = { section }
    for _, field in ipairs({ "Save game data location", "Save game data location notes" }) do
        local value = extract_infobox_field(wikitext, field)
        if value then table.insert(sources, value) end
    end
    local function ids_from_line(raw_line)
        local ids = {}
        for id in tostring(raw_line or ""):gmatch("[Ss]avegames.-\\(%d+)") do table.insert(ids, id) end
        return ids
    end
    for _, value in ipairs(sources) do
        if value and value ~= "" then
            for raw_line in tostring(value):gmatch("[^\n]+") do
                local platform = raw_line:match("{{%s*[Gg]ame data/saves%s*|%s*([^|]+)%s*|")
                if platform and raw_line:lower():find("savegames", 1, true) then
                    local ids = ids_from_line(raw_line)
                    if platform:lower():find("steam", 1, true) then
                        for _, id in ipairs(ids) do add_path(result, seen, "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\" .. id) end
                    elseif platform:lower():find("windows", 1, true) and #ids > 1 then
                        table.insert(fallback_ids, ids[#ids])
                    end
                end
            end

            value = template_to_path(value)
            for line in value:gmatch("[^\n]+") do
                if line_mentions_steam(line) then
                    for _, path in ipairs(extract_paths_from_lines({ line }, false)) do add_path(result, seen, path) end
                end
            end
            local normalized = value:gsub("\r", "")
            for block in normalized:gmatch("([^\n]*[Ss]team[^\n]*\n[^\n]*[Ss]avegames[^\n]*\n?[^\n]*)") do
                for _, path in ipairs(extract_paths_from_lines({ block }, false)) do add_path(result, seen, path) end
            end
            for block in normalized:gmatch("([^\n]*[Ss]avegames[^\n]*\n[^\n]*[Ss]team[^\n]*\n?[^\n]*)") do
                for _, path in ipairs(extract_paths_from_lines({ block }, false)) do add_path(result, seen, path) end
            end
        end
    end
    if #result == 0 then
        for _, id in ipairs(fallback_ids) do add_path(result, seen, "<Ubisoft-Connect-folder>\\savegames\\<user-id>\\" .. id) end
    end
    return result
end

function M.remote_lookup(app_id)
    clear_error()
    app_id = tostring(app_id or "")
    if app_id == "" then return { found = false, reason = "Missing AppID", saves = {}, configs = {}, source = "pcgw-error" } end
    local ok, result = pcall(function()
        return remote_lookup(app_id)
    end)
    if ok and type(result) == "table" then return result end
    set_error("PCGW remote lookup crashed safely: " .. tostring(result))
    return { found = false, reason = LAST_ERROR or "PCGW lookup failed", saves = {}, configs = {}, source = "pcgw-error" }
end

function M.lookup_ubisoft_ids_for_app(app_id)
    clear_error()
    app_id = tostring(app_id or "")
    if app_id == "" then return { success = false, appId = app_id, error = "Missing AppID", ids = {} } end
    if backoff_until > os.time() then return { success = false, appId = app_id, error = LAST_ERROR or "PCGW temporarily unavailable", ids = {}, transient = true } end

    local title, appid_url = page_from_appid(app_id)
    if not title then return { success = false, appId = app_id, error = LAST_ERROR or "PCGW page not found", ids = {} } end

    local steam_paths = {}
    local wikitext = get_wikitext(title)
    if wikitext then steam_paths = extract_steam_ubisoft_paths_from_wikitext(wikitext) end
    local ids = M.extract_ubisoft_game_ids_from_paths(steam_paths)

    if #ids == 0 then
        return {
            success = false,
            appId = app_id,
            page = title,
            url = page_url(title),
            source = "pcgw",
            reason = "No Ubisoft save ID found on Steam-specific PCGW row",
            ids = {},
            saves = steam_paths,
            configs = {},
        }
    end

    return {
        success = true,
        appId = app_id,
        page = title,
        url = page_url(title),
        source = "pcgw",
        reason = LAST_ERROR,
        ids = ids,
        saves = steam_paths,
        configs = {},
    }
end

return M
