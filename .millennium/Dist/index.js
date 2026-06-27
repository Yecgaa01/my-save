const MILLENNIUM_IS_CLIENT_MODULE = true, pluginName = "my-save";

function InitializePlugins() {
    var e, t;
    let n;
    (e = window.PLUGIN_LIST || (window.PLUGIN_LIST = {}))[pluginName] || (e[pluginName] = {});
    (t = window.MILLENNIUM_PLUGIN_SETTINGS_STORE || (window.MILLENNIUM_PLUGIN_SETTINGS_STORE = {}))[pluginName] || (t[pluginName] = {});
    window.MILLENNIUM_SIDEBAR_NAVIGATION_PANELS || (window.MILLENNIUM_SIDEBAR_NAVIGATION_PANELS = {});
    (function(e) { e[e.CallServerMethod = 0] = "CallServerMethod"; })(n || (n = {}));
    let a = window.MILLENNIUM_PLUGIN_SETTINGS_STORE[pluginName], i = `Millennium.Internal.IPC.[${pluginName}]`;
    const l = { DropDown: ["string", "number", "boolean"], NumberTextInput: ["number"], StringTextInput: ["string"], FloatTextInput: ["number"], CheckBox: ["boolean"], NumberSlider: ["number"], FloatSlider: ["number"] };
    function o(e, t, a) { return MILLENNIUM_BACKEND_IPC.postMessage(n.CallServerMethod, { pluginName: e, methodName: "__builtins__.__update_settings_value__", argumentList: { name: t, value: a } }); }
    a.ignoreProxyFlag = false;
    (async function() {
        while (typeof MainWindowBrowserManager === "undefined") await new Promise(e => setTimeout(e, 0));
        MainWindowBrowserManager?.m_browser?.on("message", (e, t) => {
            if (e !== i) return;
            const { name: n, value: l } = JSON.parse(t);
            a.ignoreProxyFlag = true;
            a.settingsStore[n] = l;
            o(pluginName, n, l);
            a.ignoreProxyFlag = false;
        });
    })();
    const r = e => new Proxy(e, {
        set(e, t, n) {
            if (!(t in e)) throw new TypeError(`Property ${String(t)} does not exist on plugin settings`);
            const r = l[e[t].type], s = e[t]?.range;
            if (r.includes("number") && typeof n === "number" && (s && (n = Math.max(s[0], Math.min(s[1], n))), n || (n = 0)), !r.includes(typeof n)) throw new TypeError(`Expected ${r.join(" or ")}, got ${typeof n}`);
            e[t].value = n;
            ((e, t) => { a.ignoreProxyFlag || (o(pluginName, e, t), typeof MainWindowBrowserManager !== "undefined" && MainWindowBrowserManager?.m_browser?.PostMessage(i, JSON.stringify({ name: e, value: t }))); })(String(t), n);
            return true;
        },
        get: (e, t) => t === "__raw_get_internals__" ? e : t in e ? e[t].value : void 0
    });
    a.DefinePluginSetting = r;
    a.settingsStore = r({});
}

InitializePlugins();
const __call_server_method__ = (e, t) => Millennium.callServerMethod(pluginName, e, t);
function __wrapped_callable__(e) {
    return e.startsWith("webkit:") ? MILLENNIUM_API.callable((e, t) => MILLENNIUM_API.__INTERNAL_CALL_WEBKIT_METHOD__(pluginName, e, t), e.replace(/^webkit:/, "")) : MILLENNIUM_API.callable(__call_server_method__, e);
}

let PluginEntryPointMain = function() {
    return function(exports, jsx, React, API) {
        "use strict";

        const FRONTEND_BUILD = "dropdown-fixed-width-2026-05-16-1";
        const LOG = "[My Save]";
        const PANEL_ID = "my-save-for-millennium";
        const BUTTON_ID = "my-save-button";
        const DROPDOWN_ID = "my-save-dropdown";
        const STYLE_ID = "my-save-styles";
        const GAME_CONTAINER_SELECTOR = ".NZMJ6g2iVnFsOOp-lDmIP";
        const STEAM_ID64_BASE = 76561197960265728n;
        const ROUTE_INTERVAL_MS = 1000;
        const RENDER_DEBOUNCE_MS = 100;
        const PROFILE_IDS_STORAGE_KEY = "my-save.launcherProfileIds";
        const MULTIPLE_BACKUPS_STORAGE_KEY = "my-save.createMultipleBackups";

        let GET_SAVE_FOLDERS = __wrapped_callable__("GetSaveFolders");
        let GET_SETTINGS = __wrapped_callable__("GetSettings");
        let UPDATE_UBISOFT_GAME_IDS = __wrapped_callable__("UpdateUbisoftGameIds");
        let SET_PROFILE_IDS = __wrapped_callable__("SetLauncherProfileIds");
        let CLEAR_PROFILE_IDS = __wrapped_callable__("ClearLauncherProfileIds");
        let DISCOVER_PROFILE_IDS = __wrapped_callable__("DiscoverLauncherProfileIds");
        let CLEAR_CACHE = __wrapped_callable__("ClearCache");
        let GET_BACKUP_SETTINGS = __wrapped_callable__("GetBackupSettings");
        let CHOOSE_BACKUP_FOLDER = __wrapped_callable__("ChooseBackupFolder");
        let OPEN_BACKUP_FOLDER = __wrapped_callable__("OpenBackupFolder");
        let OPEN_FOLDER = __wrapped_callable__("OpenFolder");
        let activeDoc = null;
        let activeTimer = null;
        let renderDebounceTimer = null;
        let lastRenderKey = "";
        let activeAppId = null;
        let dropdownCloseHandler = null;
        let dropdownScrollHandler = null;
        let profileIdsCache = { rockstarId: "", ubisoftId: "" };
        let lastBackendFailureAt = 0;
        let firstBackendCallSettled = false;
        let activeLoadPromise = null;
        let activeLoadKey = "";
        const firstBackendReadyAt = Date.now() + 3500;
        const responseCache = new Map();
        const RESPONSE_CACHE_TTL_MS = 30000;

        function log(...args) { console.log(LOG, ...args); }
        function error(...args) { console.error(LOG, ...args); }
        log("frontend build", FRONTEND_BUILD);

        function steam64ToAccountId(value) {
            try {
                const text = String(value || "").trim();
                if (!/^7656119\d{10}$/.test(text)) return "";
                const result = BigInt(text) - STEAM_ID64_BASE;
                return result >= 0n ? result.toString() : "";
            } catch (_) {
                return "";
            }
        }

        function steamAccountId(value) {
            const text = String(value || "").trim();
            return /^\d{1,10}$/.test(text) ? text : "";
        }

        function currentSteamIds(doc) {
            const view = doc?.defaultView || window;
            const ids = { accountId: "", steamId64: "" };
            try {
                ids.accountId = steamAccountId(view.g_AccountID || window.g_AccountID);
                const current = String(view.App?.m_CurrentUser?.strSteamID || window.App?.m_CurrentUser?.strSteamID || "").trim();
                if (/^7656119\d{10}$/.test(current)) ids.steamId64 = current;
                const steamId = String(view.g_steamID || window.g_steamID || "").trim();
                if (!ids.steamId64 && /^7656119\d{10}$/.test(steamId)) ids.steamId64 = steamId;
                if (!ids.accountId && ids.steamId64) ids.accountId = steam64ToAccountId(ids.steamId64);
            } catch (e) {
                error("Steam account detection failed", e);
            }
            return ids;
        }

        function currentSteamAccountId(doc) {
            return currentSteamIds(doc).accountId;
        }

        function lastLocationPath() {
            try {
                return MainWindowBrowserManager?.m_lastLocation?.pathname || "";
            } catch (_) {
                return "";
            }
        }

        function appName(appId, doc) {
            try {
                const name = window.appStore?.GetAppOverviewByAppID(Number(appId))?.display_name;
                if (name) return name;
            } catch (_) {}
            const title = doc?.querySelector(".apphub_AppName, [class*=AppName], h1");
            return title ? title.textContent.trim() : "";
        }

        function detectAppFromImages(doc) {
            const selectors = [
                'img[src*="library_hero"]',
                'img[src*="/assets/"]',
                '[style*="/assets/"]'
            ];
            for (const selector of selectors) {
                const el = doc.querySelector(selector);
                if (!el) continue;
                const value = String(el.src || el.style?.backgroundImage || "");
                const match = value.match(/\/assets\/(\d+)\//);
                if (match) return match[1];
            }
            return "";
        }

        function detectGame(doc) {
            const candidates = [
                lastLocationPath(),
                String(doc?.location?.href || ""),
                String(window.location?.href || "")
            ];
            for (const value of candidates) {
                const match = value.match(/\/app\/(\d+)/);
                if (match) {
                    const appId = match[1];
                    const container = doc.querySelector(GAME_CONTAINER_SELECTOR);
                    return container ? { appId, container, gameName: appName(appId, doc) } : null;
                }
            }
            const imageAppId = detectAppFromImages(doc);
            if (imageAppId) {
                const container = doc.querySelector(GAME_CONTAINER_SELECTOR);
                return container ? { appId: imageAppId, container, gameName: appName(imageAppId, doc) } : null;
            }
            return null;
        }

        function isMillenniumSettings(doc) {
            const text = [
                String(doc?.location?.href || ""),
                String(window.location?.href || ""),
                lastLocationPath()
            ].join(" ").toLowerCase();
            return text.includes("millennium") || text.includes("/plugins") || text.includes("/themes");
        }

        function removeDropdown(doc) {
            if (dropdownScrollHandler) {
                try { doc?.removeEventListener("scroll", dropdownScrollHandler, true); } catch (_) {}
                try { doc?.defaultView?.removeEventListener("resize", dropdownScrollHandler); } catch (_) {}
                dropdownScrollHandler = null;
            }
            if (dropdownCloseHandler) {
                try { doc?.removeEventListener("click", dropdownCloseHandler); } catch (_) {}
                dropdownCloseHandler = null;
            }
            const existing = doc?.getElementById(DROPDOWN_ID);
            if (!existing) return false;
            existing.remove();
            return true;
        }

        let loadToken = 0;

        function removeButton(doc) {
            removeDropdown(doc);
            const panel = doc?.getElementById(PANEL_ID);
            if (panel) {
                panel.remove();
                return;
            }
            const existing = doc?.getElementById(BUTTON_ID);
            if (existing) existing.remove();
        }

        function steamSystem() {
            return activeDoc?.defaultView?.SteamClient?.System || window.SteamClient?.System || null;
        }

        function openUrl(url) {
            if (!url) return;
            log("Opening URL", url);
            const system = steamSystem();
            if (system?.OpenInSystemBrowser) system.OpenInSystemBrowser(url);
            else window.open(url, "_blank");
        }

        function openFolderInFrontend(path) {
            const system = steamSystem();
            if (system?.OpenLocalDirectoryInSystemExplorer) {
                log("Opening folder", path);
                system.OpenLocalDirectoryInSystemExplorer(path);
                return true;
            }
            error("SteamClient folder opener unavailable", path);
            return false;
        }

        async function openFolder(path) {
            const value = String(path || "");
            if (!/^[A-Za-z]:\\/.test(value)) return;
            if (openFolderInFrontend(value)) return;
            try {
                const parsed = parseBackendResponse(await withTimeout(OPEN_FOLDER(value), 3000, "Folder open timed out"), "Invalid open-folder response");
                if (parsed.success) return;
                error("backend folder open rejected", parsed.error || parsed);
            } catch (backendError) {
                error("backend folder open failed", backendError);
            }
        }

        function parseBackendResponse(value, fallbackError) {
            if (value && typeof value === "object") {
                if (typeof value.returnValue === "string") return parseBackendResponse(value.returnValue, fallbackError);
                if (value.returnValue && typeof value.returnValue === "object") return value.returnValue;
                return value;
            }
            try {
                return JSON.parse(String(value || "{}"));
            } catch (parseError) {
                error("backend returned invalid JSON", parseError, value);
                return { success: false, error: fallbackError || "Invalid backend response" };
            }
        }

        function localProfileIds(doc) {
            try {
                const storage = doc?.defaultView?.localStorage || window.localStorage;
                const raw = storage.getItem(PROFILE_IDS_STORAGE_KEY);
                if (raw === null) return null;
                return normalizeProfileIds(JSON.parse(raw || "{}"));
            } catch (_) { return null; }
        }

        function clearProfileIdsCache(doc) {
            saveLocalProfileIds(doc, { rockstarId: "", ubisoftId: "" });
        }

        function saveLocalProfileIds(doc, ids) {
            profileIdsCache = normalizeProfileIds(ids);
            try {
                const storage = doc?.defaultView?.localStorage || window.localStorage;
                storage.setItem(PROFILE_IDS_STORAGE_KEY, JSON.stringify(profileIdsCache));
            } catch (_) {}
        }

        function normalizeProfileIds(ids) {
            return {
                rockstarId: String(ids?.rockstarId ?? "").trim(),
                ubisoftId: String(ids?.ubisoftId ?? "").trim()
            };
        }

        async function loadProfileIds(doc) {
            const local = localProfileIds(doc);
            if (local !== null) return normalizeProfileIds(local);
            try {
                return normalizeProfileIds(parseBackendResponse(await GET_SETTINGS(), "Invalid settings response"));
            } catch (e) {
                error("settings load failed", e);
                return { rockstarId: "", ubisoftId: "" };
            }
        }
        function row(label, onClick, disabled, title, keepOpen) {
            const doc = activeDoc || document;
            const el = doc.createElement("button");
            el.type = "button";
            el.textContent = label;
            if (title) el.title = title;
            el.disabled = !!disabled;
            el.className = disabled ? "my-save-row my-save-disabled" : "my-save-row";
            if (!disabled) {
                el.addEventListener("click", event => {
                    event.stopPropagation();
                    if (!keepOpen) removeDropdown(doc);
                    Promise.resolve().then(() => onClick && onClick(event, doc, el)).catch(error);
                });
            }
            return el;
        }

        async function resolveLauncherOpenPath(item, path) {
            const ids = await loadProfileIds(activeDoc || document);
            const value = String(path || "").replace(/[\/]+/g, "\\").replace(/\\+$/g, "");
            const rawValue = String(item?.path || item?.rawPath || path || "").replace(/[\/]+/g, "\\").replace(/\\+$/g, "");
            const lower = value.toLowerCase();
            const rawLower = rawValue.toLowerCase();
            if (ids.rockstarId && lower.includes("rockstar") && lower.includes("\\profiles")) {
                const prefix = value.match(/^(.*?\\Profiles)/i)?.[1];
                if (prefix) return prefix + "\\" + ids.rockstarId;
            }
            const isUbisoftItem = item?.launcher === "ubisoft" || rawLower.includes("ubisoft") || lower.includes("ubisoft") || rawLower.includes("<ubisoft-connect-folder>") || rawLower.includes("<ubisoft game launcher folder>");
            if (ids.ubisoftId && isUbisoftItem && (lower.includes("\\savegames") || rawLower.includes("\\savegames"))) {
                const source = rawLower.includes("\\savegames") ? rawValue : value;
                const prefix = (value.match(/^(.*?\\savegames)/i) || source.match(/^(.*?\\savegames)/i))?.[1];
                if (prefix) {
                    const suffix = source.slice((source.match(/^(.*?\\savegames)/i)?.[1] || prefix).length).replace(/\\+$/g, "");
                    const gameId = suffix.match(/\\(?:[^\\<>[\]*]+)\\(\d+)$/)?.[1]
                        || suffix.match(/\\(\d+)$/)?.[1]
                        || String(item?.label || "").match(/\b(\d+)\b/)?.[1];
                    return prefix + "\\" + ids.ubisoftId + (gameId ? "\\" + gameId : "");
                }
            }
            return path;
        }

        function isUbisoftItem(item) {
            const text = [item?.launcher, item?.source, item?.label, item?.openPath, item?.path, item?.rawPath]
                .map(value => String(value || "").toLowerCase())
                .join(" ");
            return text.includes("ubisoft") || text.includes("<ubisoft-connect-folder>") || text.includes("<ubisoft game launcher folder>");
        }

        function itemLabel(item, path) {
            if (item.label) return item.label;
            if (item.kind === "config") return "Config folder";
            if (item.kind === "save") return "Save folder";
            return "Folder";
        }

        function rowsFromResponse(response) {
            const rows = [];
            if (!response || !response.success) {
                const message = (response && response.error) ? "Unable to load: " + response.error : "Unable to load save folders";
                const errorRow = row(message, null, true);
                errorRow.classList.add("my-save-error");
                return [errorRow];
            }
            const items = Array.isArray(response.items) ? response.items : [];
            const localItems = items;
            log("GetSaveFolders items", localItems.map(item => ({ label: item.label, kind: item.kind, source: item.source, launcher: item.launcher, exists: item.exists, unresolved: item.unresolved, path: item.path, openPath: item.openPath, rawPath: item.rawPath })));
            const usable = item => {
                const open = String(item.openPath || "");
                if (isUbisoftItem(item)) return item.exists && !item.unresolved;
                return (item.exists && !item.unresolved) || /^[A-Za-z]:\\/.test(open);
            };
            const normalizeKey = item => {
                let path = String(item.openPath || item.path || item.rawPath || "").replace(/[\\/]+/g, "\\").replace(/\\+$/g, "").toLowerCase();
                path = path.replace(/\\appdata\\locallow\\kojimaproductions\\deathstrandingdc\\\d+$/g, "\\appdata\\kojimaproductions\\deathstrandingdc");
                path = path.replace(/\\appdata\\local\\kojimaproductions\\deathstrandingdc\\\d+$/g, "\\appdata\\kojimaproductions\\deathstrandingdc");
                path = path.replace(/\\appdata\\locallow\\kojimaproductions\\deathstranding\\\d+$/g, "\\appdata\\kojimaproductions\\deathstranding");
                path = path.replace(/\\appdata\\local\\kojimaproductions\\deathstranding\\\d+$/g, "\\appdata\\kojimaproductions\\deathstranding");
                return path || "";
            };
            const dedupe = source => {
                const seen = new Set();
                const unique = source.filter(item => {
                    const key = normalizeKey(item);
                    if (!key || seen.has(key)) return false;
                    seen.add(key);
                    return true;
                });
                return unique.filter((item, index) => {
                    const key = normalizeKey(item);
                    if (!key || isUbisoftItem(item)) return true;
                    return !unique.some((other, otherIndex) => {
                        if (index === otherIndex || isUbisoftItem(other)) return false;
                        const otherKey = normalizeKey(other);
                        if (!otherKey) return false;
                        if (item.kind === other.kind && otherKey.startsWith(key + "\\")) return true;
                        return false;
                    });
                });
            };
            const found = dedupe(localItems.filter(item => usable(item) && (!item.fallback || item.exists)));
            const foundSaveKeys = found
                .filter(item => item.kind === "save")
                .map(normalizeKey)
                .filter(Boolean);
            const isRedundantMissingSave = item => {
                if (item.kind !== "save") return false;
                const key = normalizeKey(item);
                if (!key) return false;
                return foundSaveKeys.some(foundKey => foundKey === key || foundKey.startsWith(key + "\\") || key.startsWith(foundKey + "\\"));
            };
            const missing = dedupe(localItems.filter(item => !usable(item) && !item.fallback && !isRedundantMissingSave(item)));

            for (const item of found) {
                const path = item.openPath || item.path;
                const title = item.partial ? ((item.path || "") + "\nOpening nearest existing folder: " + path) : path;
                rows.push(row(itemLabel(item, path), async () => openFolder(await resolveLauncherOpenPath(item, path)), false, title, false));
            }
            for (const item of missing) rows.push(row("not on disk yet: " + itemLabel(item, item.path), null, true, item.path));
            const currentSaveItem = found.find(item => item.kind === "save" && item.exists && !item.unresolved && /^[A-Za-z]:\\/.test(String(item.openPath || ""))) || null;
            if (response.onlineOnly) rows.push(row("Online only", null, true, response.onlineOnlyName || response.gameName || "Online only"));
            if (rows.length === 0) {
                const details = [response.gameName, response.appId ? "AppID " + response.appId : "", response.pcgwPage].filter(Boolean).join(" · ");
                rows.push(row(response.reason || "No save/config folders found", null, true));
                if (details) rows.push(row(details, null, true));
            }
            if (response.pcgwUrl) {
                rows.push(row("── Reference ──", null, true));
                rows.push(row("Open PCGamingWiki page", () => openUrl(response.pcgwUrl), false));
            }
            rows.push(row("── Advanced ──", null, true));
            rows.push(row("Launcher profile IDs...", (event, doc) => showSettings(doc), false, "Set Rockstar/Ubisoft profile folder names", true));
            rows.push(row("Backup/Restore Save", (event, doc) => showBackupRestore(doc, response, currentSaveItem), false, "Backup/restore panel preview", true));
            return rows;
        }

        function addStyles(doc) {
            if (!doc?.head || doc.getElementById(STYLE_ID)) return;
            const style = doc.createElement("style");
            style.id = STYLE_ID;
            style.textContent = `
#${PANEL_ID} {
  position: absolute;
  right: 68px;
  bottom: 56px;
  z-index: 101;
  display: flex;
  justify-content: flex-end;
  align-items: flex-end;
}
#${PANEL_ID} #${BUTTON_ID} {
  width: 44px;
  height: 38px;
  padding: 7px 9px;
  border-radius: 7px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  background: rgba(5, 8, 12, 0.58);
  color: #ffffff;
  cursor: pointer;
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.42), inset 0 1px 0 rgba(255, 255, 255, 0.08);
  backdrop-filter: blur(8px) saturate(140%);
  display: flex;
  align-items: center;
  justify-content: center;
}
#${PANEL_ID} #${BUTTON_ID}:hover { background: rgba(18, 24, 31, 0.72); border-color: rgba(255, 255, 255, 0.3); }
#${PANEL_ID} #${BUTTON_ID}.my-save-loading { opacity: 0.65; }
#${PANEL_ID} #${BUTTON_ID} svg {
  width: 25px;
  height: 25px;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.35;
  stroke-linecap: round;
  stroke-linejoin: round;
  display: block;
}
#${DROPDOWN_ID} {
  position: fixed;
  z-index: 999999;
  min-width: 260px;
  max-width: 360px;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 6px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  background: rgba(5, 8, 12, 0.66);
  color: #ffffff;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45), inset 0 1px 0 rgba(255, 255, 255, 0.08);
  -webkit-backdrop-filter: blur(12px) saturate(145%);
  backdrop-filter: blur(12px) saturate(145%);
}
#${DROPDOWN_ID}.my-save-popup {
  overflow-y: auto;
  overscroll-behavior: contain;
}
#${DROPDOWN_ID} .my-save-row {
  display: block;
  width: 100%;
  border: 0;
  border-radius: 5px;
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.03);
  color: #ffffff;
  text-align: left;
  cursor: pointer;
  font-size: 12px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
#${DROPDOWN_ID} .my-save-error {
  white-space: normal;
  overflow: visible;
  text-overflow: clip;
  word-break: break-word;
  line-height: 1.35;
}
#${DROPDOWN_ID} .my-save-row:hover { background: rgba(255, 255, 255, 0.12); }
#${DROPDOWN_ID} .my-save-disabled { color: rgba(255, 255, 255, 0.55); cursor: default; }
#${DROPDOWN_ID} .my-save-disabled:hover { background: transparent; }
#${DROPDOWN_ID} .my-save-settings {
  white-space: normal;
  display: flex;
  flex-direction: column;
  gap: 8px;
  box-sizing: border-box;
  border: 1px solid rgba(0, 0, 0, 0.72);
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.06);
}
#${DROPDOWN_ID} .my-save-settings strong {
  font-size: 13px;
}
#${DROPDOWN_ID} .my-save-settings label {
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.86);
}
#${DROPDOWN_ID} .my-save-settings input {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.08);
  color: #fff;
  padding: 6px;
  font-size: 12px;
}
#${DROPDOWN_ID} .my-save-settings .my-save-id-line {
  display: flex;
  gap: 6px;
  align-items: center;
}
#${DROPDOWN_ID} .my-save-settings .my-save-id-line input {
  flex: 1;
  min-width: 0;
}
#${DROPDOWN_ID} .my-save-settings .my-save-id-line button,
#${DROPDOWN_ID} .my-save-settings .my-save-profile-status button {
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.08);
  color: #d7d7d7;
  border-radius: 5px;
  padding: 5px 7px;
  cursor: pointer;
  white-space: nowrap;
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-status {
  display: flex;
  flex-direction: column;
  gap: 5px;
  margin: 6px 0;
  color: #acb2b8;
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-choice {
  text-align: left;
  padding: 5px 8px;
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-choice strong {
  display: block;
  color: #ffffff;
  font-size: 12px;
  line-height: 1.25;
  font-weight: 500;
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-choice small {
  display: block;
  margin: 1px 0 0;
  font-size: 10px;
  line-height: 1.25;
  opacity: 0.78;
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-choice.my-save-selected-backup {
  background: rgba(102, 192, 244, 0.22);
  border-color: rgba(102, 192, 244, 0.55);
}
#${DROPDOWN_ID} .my-save-settings .my-save-profile-choice.my-save-selected-backup strong {
  color: #66c0f4;
}
#${DROPDOWN_ID} .my-save-settings small { color: rgba(255, 255, 255, 0.68); line-height: 1.35; }
#${DROPDOWN_ID} .my-save-settings .my-save-save-id {
  align-self: flex-start;
  width: auto;
  padding: 6px 10px;
  margin-top: 2px;
}
#${DROPDOWN_ID} .my-save-backup-list {
  max-height: 118px;
  overflow-y: auto;
  overflow-x: hidden;
  padding-right: 2px;
}
#${DROPDOWN_ID} .my-save-check-line {
  flex-direction: row;
  align-items: center;
  gap: 7px;
}
#${DROPDOWN_ID} .my-save-check-line input {
  width: auto;
}
`;
            doc.head.appendChild(style);
        }

        function folderIconSvg() {
            return `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
                <path d="M5 3.75h12.4L20.25 6.6v13.65H3.75V3.75H5Z"/>
                <path d="M7 3.75v6.5h10v-6.5"/>
                <path d="M8 14h8v6.25H8V14Z"/>
                <path d="M15 5.25v3.25"/>
            </svg>`;
        }

        function positionDropdown(doc, button, box) {
            const viewportWidth = doc.documentElement.clientWidth || window.innerWidth;
            const viewportHeight = doc.documentElement.clientHeight || window.innerHeight;
            const rect = button.getBoundingClientRect();
            const isPopup = box.classList.contains("my-save-popup");
            const defaultWidth = isPopup ? 380 : 260;
            const minWidth = isPopup ? 340 : 260;
            const maxWidth = isPopup ? 420 : 360;
            let width = Number(box.dataset.mySaveWidth || "0");
            if (!width) {
                width = Math.min(maxWidth, Math.max(minWidth, box.offsetWidth || defaultWidth));
                box.dataset.mySaveWidth = String(width);
            }
            width = Math.min(maxWidth, Math.max(minWidth, width));
            const gap = 6;
            const topMargin = 56;
            const bottomMargin = 12;
            const availableBelow = Math.max(80, viewportHeight - rect.bottom - gap - bottomMargin);
            const popupMax = isPopup ? Math.min(460, availableBelow) : 320;
            const contentHeight = Math.min(box.scrollHeight || 240, popupMax);
            const spaceAbove = Math.max(0, rect.top - gap - topMargin);
            const spaceBelow = Math.max(0, viewportHeight - rect.bottom - gap - bottomMargin);
            const openAbove = !isPopup && (spaceAbove >= contentHeight || spaceAbove >= spaceBelow);
            const maxHeight = Math.max(80, Math.min(popupMax, openAbove ? spaceAbove : spaceBelow));
            const top = isPopup ? (rect.bottom + gap) : (openAbove ? Math.max(topMargin, rect.top - Math.min(contentHeight, maxHeight) - gap) : Math.min(rect.bottom + gap, viewportHeight - maxHeight - bottomMargin));
            const left = Math.min(Math.max(8, rect.right - width), viewportWidth - width - 8);
            box.style.width = width + "px";
            box.style.maxHeight = maxHeight + "px";
            box.style.left = Math.round(left) + "px";
            box.style.top = Math.round(top) + "px";
        }


        function bindDropdownAnchor(doc, button, box) {
            if (dropdownScrollHandler) {
                try { doc?.removeEventListener("scroll", dropdownScrollHandler, true); } catch (_) {}
                try { doc?.defaultView?.removeEventListener("resize", dropdownScrollHandler); } catch (_) {}
            }
            dropdownScrollHandler = () => {
                if (!doc?.body?.contains(box) || !doc?.body?.contains(button)) {
                    removeDropdown(doc);
                    return;
                }
                doc.defaultView?.requestAnimationFrame?.(() => positionDropdown(doc, button, box)) || positionDropdown(doc, button, box);
            };
            doc?.addEventListener("scroll", dropdownScrollHandler, true);
            doc?.defaultView?.addEventListener("resize", dropdownScrollHandler);
        }

        function showDropdown(doc, button, rows) {
            activeDoc = doc;
            removeDropdown(doc);
            const box = doc.createElement("div");
            box.id = DROPDOWN_ID;
            box.addEventListener("click", event => event.stopPropagation());
            box.addEventListener("pointerdown", event => event.stopPropagation());
            box.addEventListener("mousedown", event => event.stopPropagation());
            for (const item of rows) box.appendChild(item);
            doc.body.appendChild(box);
            positionDropdown(doc, button, box);
            bindDropdownAnchor(doc, button, box);
        }

        async function showSettings(doc, anchor) {
            doc = doc || activeDoc || document;
            const button = doc.getElementById(BUTTON_ID) || anchor;
            removeDropdown(doc);
            const box = doc.createElement("div");
            box.id = DROPDOWN_ID;
            const panel = doc.createElement("div");
            panel.className = "my-save-row my-save-settings";
            panel.addEventListener("click", event => event.stopPropagation());
            panel.addEventListener("pointerdown", event => event.stopPropagation());
            panel.addEventListener("mousedown", event => event.stopPropagation());
            panel.innerHTML = `
                <strong>Launcher profile IDs</strong>
                <small>If Rockstar or Ubisoft ID is empty, use Get ID to find local profile folders. If multiple profiles are found, choose one manually; My Save will not guess.</small>
                <label>Rockstar profile ID<span class="my-save-id-line"><input data-my-save="rockstar" placeholder="Profile folder name"><button data-my-save="get-rockstar" type="button">Get ID</button></span></label>
                <label>Ubisoft profile ID<span class="my-save-id-line"><input data-my-save="ubisoft" placeholder="Savegames folder name"><button data-my-save="get-ubisoft" type="button">Get ID</button></span></label>
                <div data-my-save="profile-status" class="my-save-profile-status"></div>
                <button class="my-save-row my-save-save-id" data-my-save="save" type="button">Save ID</button>
            `;
            box.appendChild(panel);
            doc.body.appendChild(box);
            positionDropdown(doc, button, box);
            bindDropdownAnchor(doc, button, box);
            try {
                const parsed = await loadProfileIds(doc);
                panel.querySelector('input[data-my-save="rockstar"]').value = parsed.rockstarId || "";
                panel.querySelector('input[data-my-save="ubisoft"]').value = parsed.ubisoftId || "";
            } catch (e) { error("settings load failed", e); }
            const status = panel.querySelector('[data-my-save="profile-status"]');
            const setStatus = text => { status.textContent = text || ""; };
            const shortenId = id => {
                id = String(id || "");
                return id.length > 18 ? id.slice(0, 8) + "..." + id.slice(-6) : id;
            };
            const chooseProfileId = async type => {
                const input = panel.querySelector(`input[data-my-save="${type}"]`);
                const button = panel.querySelector(`[data-my-save="get-${type}"]`);
                button.disabled = true;
                button.textContent = "Scanning...";
                status.innerHTML = "";
                try {
                    const parsed = parseBackendResponse(await withTimeout(DISCOVER_PROFILE_IDS(), 4000, "Profile scan timed out"), "Invalid profile scan response");
                    const candidates = Array.isArray(parsed[type]) ? parsed[type] : [];
                    if (!parsed.success) {
                        setStatus(parsed.error || "Profile scan failed.");
                    } else if (candidates.length === 0) {
                        setStatus("No " + type + " profile folders found.");
                    } else if (candidates.length === 1) {
                        input.value = candidates[0].id || "";
                        input.dataset.selectedProfileId = input.value;
                        setStatus((type === "ubisoft" ? "Ubisoft" : "Rockstar") + " profile ID found. Click Save ID to keep it.");
                    } else {
                        const header = doc.createElement("small");
                        header.textContent = "Multiple " + type + " profiles found. Choose one, then click Save ID.";
                        status.appendChild(header);
                        for (const candidate of candidates.slice(0, 8)) {
                            const choice = doc.createElement("button");
                            choice.type = "button";
                            choice.className = "my-save-profile-choice";
                            choice.innerHTML = `<strong>${shortenId(candidate.id)}</strong><small>${candidate.label || "profile folder"}</small>`;
                            choice.addEventListener("click", event => {
                                event.stopPropagation();
                                input.value = candidate.id || "";
                                input.dataset.selectedProfileId = input.value;
                                setStatus("Selected " + shortenId(candidate.id) + ". Click Save ID to keep it.");
                            });
                            status.appendChild(choice);
                        }
                    }
                } catch (e) {
                    error("profile discovery failed", e);
                    setStatus("Profile scan failed: " + safeErrorText(e));
                } finally {
                    button.disabled = false;
                    button.textContent = "Get ID";
                }
            };
            panel.querySelector('[data-my-save="get-rockstar"]').addEventListener("click", event => { event.stopPropagation(); chooseProfileId("rockstar"); });
            panel.querySelector('[data-my-save="get-ubisoft"]').addEventListener("click", event => { event.stopPropagation(); chooseProfileId("ubisoft"); });
            panel.querySelector('[data-my-save="save"]').addEventListener("click", async event => {
                event.stopPropagation();
                const saveButton = event.currentTarget;
                const rockstarInput = panel.querySelector('input[data-my-save="rockstar"]');
                const ubisoftInput = panel.querySelector('input[data-my-save="ubisoft"]');
                const rockstarId = (rockstarInput.value || rockstarInput.dataset.selectedProfileId || "").trim();
                const ubisoftId = (ubisoftInput.value || ubisoftInput.dataset.selectedProfileId || "").trim();
                saveButton.disabled = true;
                saveButton.textContent = "Saving...";
                try {
                    const ids = normalizeProfileIds({ rockstarId, ubisoftId });
                    saveLocalProfileIds(doc, ids);
                    profileIdsCache = ids;
                    panel.querySelector('input[data-my-save="rockstar"]').value = ids.rockstarId;
                    panel.querySelector('input[data-my-save="ubisoft"]').value = ids.ubisoftId;
                    saveButton.textContent = "Saved locally";
                    try {
                        if (!ids.rockstarId && !ids.ubisoftId) {
                            const result = await CLEAR_PROFILE_IDS();
                            log("ClearLauncherProfileIds result", result);
                        } else {
                            const result = await SET_PROFILE_IDS(ids);
                            log("SetLauncherProfileIds result", result);
                        }
                    } catch (e) {
                        error("backend settings save failed", e);
                    }
                    responseCache.clear();
                    setStatus("Saved. Reopen My Save in about 3 seconds to refresh folders.");
                } catch (e) {
                    error("settings save failed", e);
                    saveButton.textContent = "Save failed";
                } finally {
                    setTimeout(() => {
                        saveButton.disabled = false;
                        saveButton.textContent = "Save ID";
                    }, 1200);
                }
            });
        }

        async function showBackupRestore(doc, response, currentSaveItem) {
            doc = doc || activeDoc || document;
            const button = doc.getElementById(BUTTON_ID);
            removeDropdown(doc);
            const box = doc.createElement("div");
            box.id = DROPDOWN_ID;
            box.className = "my-save-popup";
            const panel = doc.createElement("div");
            panel.className = "my-save-row my-save-settings my-save-backup-panel";
            panel.addEventListener("click", event => event.stopPropagation());
            panel.addEventListener("pointerdown", event => event.stopPropagation());
            panel.addEventListener("mousedown", event => event.stopPropagation());
            const savePath = currentSaveItem?.openPath || currentSaveItem?.path || "";
            panel.innerHTML = `
                <strong>Backup/Restore Save</strong>
                <small>Restore makes a safety copy first, then puts the selected backup over your current save. Old pre-restore safety copies are cleaned up when you make a new backup.</small>
                <button class="my-save-row my-save-save-id" data-my-save="backup-current" type="button">Backup current save</button>
                <label>Restore<span class="my-save-id-line"><button data-my-save="load-backups" type="button">Show backups</button><button data-my-save="restore-preview" type="button" disabled>Restore selected</button></span></label>
                <div data-my-save="backup-list" class="my-save-profile-status my-save-backup-list">Restore list will appear here.</div>
                <label class="my-save-check-line"><input data-my-save="multiple-backups" type="checkbox" disabled> Create multiple backups</label>
                <small>When checked, new backup copies will keep the previous backup instead of overwriting it.</small>
                <label>Backup folder<span class="my-save-id-line"><input data-my-save="backup-root" placeholder="Backup folder" readonly><button data-my-save="choose-backup-root" type="button">Choose...</button><button data-my-save="open-backup-root" type="button">Open</button></span></label>
                <small>Choose where backups will be stored. The selected folder is saved immediately.</small>
                <div data-my-save="backup-status" class="my-save-profile-status">${savePath ? "Current save: " + savePath : "No current save folder found."}</div>
            `;
            box.appendChild(panel);
            doc.body.appendChild(box);
            positionDropdown(doc, button, box);
            bindDropdownAnchor(doc, button, box);
            const status = panel.querySelector('[data-my-save="backup-status"]');
            const rootInput = panel.querySelector('input[data-my-save="backup-root"]');
            const multipleBackupsInput = panel.querySelector('input[data-my-save="multiple-backups"]');
            const setStatus = text => { status.textContent = text || ""; };
            let backupSettings = { backupRoot: "", allowMultipleBackups: true };
            try {
                const storedMultiple = localStorage.getItem(MULTIPLE_BACKUPS_STORAGE_KEY);
                if (storedMultiple === "false") backupSettings.allowMultipleBackups = false;
                if (storedMultiple === "true") backupSettings.allowMultipleBackups = true;
            } catch (_) {}
            const syncMultipleBackups = () => {
                if (!multipleBackupsInput) return;
                multipleBackupsInput.checked = backupSettings.allowMultipleBackups !== false;
            };
            try {
                const settings = parseBackendResponse(await withTimeout(GET_BACKUP_SETTINGS(), 4000, "Backup settings timed out"), "Invalid backup settings response");
                if (settings.success) {
                    backupSettings.backupRoot = settings.backupRoot || "";
                    rootInput.value = backupSettings.backupRoot;
                    syncMultipleBackups();
                    if (multipleBackupsInput) multipleBackupsInput.disabled = false;
                }
            } catch (e) {
                if (multipleBackupsInput) multipleBackupsInput.disabled = true;
                setStatus("Settings load failed: " + friendlyBackendError(e));
            }
            multipleBackupsInput?.addEventListener("change", event => {
                event.stopPropagation();
                backupSettings.allowMultipleBackups = multipleBackupsInput.checked;
                try { localStorage.setItem(MULTIPLE_BACKUPS_STORAGE_KEY, multipleBackupsInput.checked ? "true" : "false"); } catch (_) {}
                setStatus(multipleBackupsInput.checked ? "Multiple backups enabled." : "Multiple backups disabled. Next backup uses Current.");
            });
            const createBackupPayload = command => ({
                backup_command: command,
                app_id: response.appId || "",
                fallback_name: (response.gameName || "") + "||" + savePath
            });
            const createButton = panel.querySelector('[data-my-save="backup-current"]');
            createButton?.addEventListener("click", async event => {
                event.stopPropagation();
                createButton.disabled = true;
                createButton.textContent = "Creating...";
                setStatus("Creating backup folder...");
                try {
                    const payload = createBackupPayload(backupSettings.allowMultipleBackups === false ? "create_current" : "create_dir");
                    const parsed = parseBackendResponse(await withTimeout(GET_SAVE_FOLDERS(payload), 10000, "Create backup folder timed out"), "Invalid create-folder response");
                    setStatus(parsed.success ? "Backup copied: " + (parsed.backupPath || "") : "Backup failed: " + (parsed.error || "unknown error"));
                } catch (e) {
                    setStatus("Create failed: " + friendlyBackendError(e));
                } finally {
                    createButton.disabled = false;
                    createButton.textContent = "Backup current save";
                }
            });
            const loadBackupsButton = panel.querySelector('[data-my-save="load-backups"]');
            const restorePreviewButton = panel.querySelector('[data-my-save="restore-preview"]');
            let selectedBackup = null;
            const backupList = panel.querySelector('[data-my-save="backup-list"]');
            loadBackupsButton?.addEventListener("click", async event => {
                event.stopPropagation();
                backupList.textContent = "Loading backups...";
                setStatus("Loading backups...");
                try {
                    const payload = createBackupPayload("list_backups");
                    const parsed = parseBackendResponse(await withTimeout(GET_SAVE_FOLDERS(payload), 10000, "List backups timed out"), "Invalid backup list response");
                    const backups = Array.isArray(parsed.backups) ? parsed.backups : [];
                    backupList.innerHTML = "";
                    if (!parsed.success) {
                        backupList.textContent = parsed.error || "Unable to list backups.";
                    } else if (backups.length === 0) {
                        backupList.textContent = "No backups found.";
                    } else {
                        for (const backup of backups) {
                            const choice = doc.createElement("button");
                            choice.type = "button";
                            choice.className = "my-save-profile-choice";
                            const label = backup.label || backup.createdAt || "Backup";
                            const gameFolder = backup.gameFolder || response.gameName || "Game";
                            choice.dataset.backupLabel = label;
                            choice.title = backup.path || "";
                            choice.innerHTML = `<strong>${label}</strong><small>${gameFolder}</small>`;
                            choice.addEventListener("click", event => {
                                event.stopPropagation();
                                backupList.querySelectorAll(".my-save-selected-backup").forEach(el => {
                                    el.classList.remove("my-save-selected-backup");
                                    const strong = el.querySelector("strong");
                                    if (strong) strong.textContent = el.dataset.backupLabel || strong.textContent.replace(/^✓\s*/, "");
                                });
                                choice.classList.add("my-save-selected-backup");
                                const strong = choice.querySelector("strong");
                                if (strong) strong.textContent = "✓ " + label;
                                selectedBackup = backup;
                                restorePreviewButton.disabled = false;
                                setStatus("Selected backup: " + label + " — " + (backup.path || ""));
                            });
                            backupList.appendChild(choice);
                        }
                    }
                    setStatus(parsed.success ? "Backups loaded." : "Backup list failed.");
                } catch (e) {
                    backupList.textContent = "List failed.";
                    setStatus("List failed: " + friendlyBackendError(e));
                }
            });
            restorePreviewButton?.addEventListener("click", async event => {
                event.stopPropagation();
                if (!selectedBackup) {
                    setStatus("Select a backup first.");
                    return;
                }
                restorePreviewButton.disabled = true;
                restorePreviewButton.textContent = "Checking...";
                setStatus("Checking restore preview...");
                try {
                    const payload = {
                        backup_command: "restore_backup",
                        app_id: response.appId || "",
                        fallback_name: (response.gameName || "") + "||" + savePath + "||" + (selectedBackup.path || "")
                    };
                    const parsed = parseBackendResponse(await withTimeout(GET_SAVE_FOLDERS(payload), 30000, "Restore timed out"), "Invalid restore response");
                    setStatus(parsed.success ? "Restore completed. Pre-restore backup: " + (parsed.preRestorePath || "") : "Restore failed: " + (parsed.error || "unknown error"));
                } catch (e) {
                    setStatus("Restore preview failed: " + friendlyBackendError(e));
                } finally {
                    restorePreviewButton.disabled = false;
                    restorePreviewButton.textContent = "Restore selected";
                }
            });
            panel.querySelector('[data-my-save="open-backup-root"]').addEventListener("click", async event => {
                event.stopPropagation();
                const root = rootInput.value.trim();
                setStatus("Opening backup folder...");
                if (openFolderInFrontend(root)) {
                    setStatus("Backup folder opened.");
                    return;
                }
                try {
                    const parsed = parseBackendResponse(await withTimeout(OPEN_BACKUP_FOLDER("open-backup-root|" + root), 5000, "Open backup folder timed out"), "Invalid open-folder response");
                    setStatus(parsed.success ? "Backup folder opened." : "Open failed: " + (parsed.error || "unknown error"));
                } catch (e) {
                    setStatus("Open failed: " + friendlyBackendError(e));
                }
            });
            panel.querySelector('[data-my-save="choose-backup-root"]').addEventListener("click", async event => {
                event.stopPropagation();
                setStatus("Choose a backup folder...");
                try {
                    const parsed = parseBackendResponse(await withTimeout(CHOOSE_BACKUP_FOLDER("choose-backup-root|" + rootInput.value.trim()), 120000, "Folder picker timed out"), "Invalid folder picker response");
                    if (parsed.success && parsed.path) {
                        rootInput.value = parsed.path;
                        setStatus(parsed.saved ? "Folder selected and saved." : "Folder selected.");
                    } else if (parsed.cancelled) {
                        setStatus("Folder selection cancelled.");
                    } else {
                        setStatus("Folder picker failed: " + (parsed.error || "unknown error"));
                    }
                } catch (e) {
                    setStatus("Folder picker failed: " + friendlyBackendError(e));
                }
            });
        }

        function withTimeout(promise, ms, label) {
            let timer = null;
            const timeout = new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error(label || "Backend timeout")), ms);
            });
            return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
        }

        function safeErrorText(value) {
            const text = String(value?.message || value?.toString?.() || value || "Backend unavailable");
            return text.replace(/\s+/g, " ").slice(0, 180);
        }

        function friendlyBackendError(value) {
            const text = safeErrorText(value);
            const lower = text.toLowerCase();
            if (lower.includes("failed to fetch") || lower.includes("backend unavailable") || lower.includes("networkerror")) return "Backend starting, try again in a moment";
            if (lower.includes("timed out") || lower.includes("timeout")) return "Backend timed out, try again in a moment";
            return text;
        }

        async function callGetSaveFoldersSafely(request) {
            if (Date.now() - lastBackendFailureAt < 3000) throw new Error("Backend starting, try again in a moment");
            const call = Array.isArray(request) ? GET_SAVE_FOLDERS(...request) : GET_SAVE_FOLDERS(request);
            try {
                return await withTimeout(call, 10000, "Backend request timed out");
            } catch (e) {
                lastBackendFailureAt = Date.now();
                throw e;
            }
        }

        async function loadAndShow(doc, button, appId, gameName) {
            activeDoc = doc;
            const token = ++loadToken;
            showDropdown(doc, button, [row("Loading...", null, true)]);
            try {
                const steamIds = currentSteamIds(doc);
                const accountId = steamIds.accountId;
                log("Loading folders for", appId, gameName || "", "account", accountId || "backend fallback", "steam64", steamIds.steamId64 || "", "local/cache");
                const ids = await loadProfileIds(doc);
                const payload = { app_id: String(appId), fallback_name: gameName || "", steam_account_id: accountId, steam_id64: steamIds.steamId64 || "", force_remote: false, rockstarId: ids.rockstarId || "", rockstar_id: ids.rockstarId || "", rockstar: ids.rockstarId || "", ubisoftId: ids.ubisoftId || "", ubisoft_id: ids.ubisoftId || "", ubisoft: ids.ubisoftId || "" };
                const cacheKey = FRONTEND_BUILD + ":" + JSON.stringify(payload);
                const cached = responseCache.get(cacheKey);
                if (cached && Date.now() - cached.timestamp < RESPONSE_CACHE_TTL_MS) {
                    log("GetSaveFolders cache hit", appId);
                    firstBackendCallSettled = true;
                    showDropdown(doc, button, rowsFromResponse(cached.parsed));
                    return;
                }
                log("GetSaveFolders payload", payload);
                const result = await callGetSaveFoldersSafely(payload);
                if (token !== loadToken) return;
                let parsed = parseBackendResponse(result, "Invalid backend response");
                log("GetSaveFolders response", parsed);
                responseCache.set(cacheKey, { timestamp: Date.now(), parsed });
                firstBackendCallSettled = true;
                showDropdown(doc, button, rowsFromResponse(parsed));
            } catch (e) {
                if (token !== loadToken) return;
                error("GetSaveFolders failed", e);
                const message = "Unable to load: " + friendlyBackendError(e);
                const errorRow = row(message, null, true);
                errorRow.classList.add("my-save-error");
                showDropdown(doc, button, [errorRow]);
            }
        }

        function createButton(doc, appId, gameName) {
            const button = doc.createElement("button");
            button.id = BUTTON_ID;
            button.dataset.appId = String(appId);
            button.dataset.gameName = gameName || "";
            const initialDelay = firstBackendCallSettled ? 0 : Math.max(0, firstBackendReadyAt - Date.now());
            button.dataset.readyAt = String(Date.now() + initialDelay);
            button.title = "My Save folders" + (gameName ? ": " + gameName : "") + (initialDelay > 0 ? " (initializing...)" : "");
            button.innerHTML = folderIconSvg();
            setTimeout(() => {
                if (button.isConnected) button.title = "My Save folders" + (gameName ? ": " + gameName : "");
            }, initialDelay);
            button.addEventListener("click", event => {
                event.preventDefault();
                event.stopPropagation();
                if (removeDropdown(doc)) return;
                const readyAt = Number(button.dataset.readyAt || "0");
                if (Date.now() < readyAt) {
                    const waitRow = row("Still waking things up — try again in a few seconds.", null, true);
                    waitRow.classList.add("my-save-error");
                    showDropdown(doc, button, [waitRow]);
                    return;
                }
                const key = String(appId) + "|" + (gameName || "");
                if (activeLoadPromise && activeLoadKey === key) {
                    showDropdown(doc, button, [row("Still loading...", null, true)]);
                    return;
                }
                loadToken++;
                button.classList.add("my-save-loading");
                activeLoadKey = key;
                activeLoadPromise = loadAndShow(doc, button, appId, gameName)
                    .finally(() => {
                        button.classList.remove("my-save-loading");
                        activeLoadPromise = null;
                        activeLoadKey = "";
                    });
            });
            return button;
        }

        function renderKey(doc) {
            return [lastLocationPath(), String(doc?.location?.href || ""), String(window.location?.href || "")].join("|");
        }

        function scheduleRender(doc, force) {
            if (renderDebounceTimer) clearTimeout(renderDebounceTimer);
            renderDebounceTimer = setTimeout(() => {
                renderDebounceTimer = null;
                const key = renderKey(doc);
                if (!force && key === lastRenderKey && activeAppId && doc?.getElementById(BUTTON_ID)) return;
                lastRenderKey = key;
                render(doc);
            }, RENDER_DEBOUNCE_MS);
        }

        function render(doc) {
            try {
                if (!doc?.body || isMillenniumSettings(doc)) {
                    removeButton(doc);
                    activeAppId = null;
                    return;
                }
                const detected = detectGame(doc);
                if (!detected?.appId || !detected.container) {
                    removeButton(doc);
                    activeAppId = null;
                    return;
                }
                addStyles(doc);
                const existing = doc.getElementById(BUTTON_ID);
                if (existing && existing.dataset.appId === String(detected.appId)) return;
                loadToken++;
                removeDropdown(doc);
                removeButton(doc);
                activeDoc = doc;
                activeAppId = String(detected.appId);
                detected.container.style.position = "relative";
                const panel = doc.createElement("div");
                panel.id = PANEL_ID;
                panel.appendChild(createButton(doc, detected.appId, detected.gameName || ""));
                detected.container.appendChild(panel);
                log("Injected for", detected.appId, detected.gameName || "");
            } catch (e) {
                error("render failed", e);
                removeButton(doc);
            }
        }

        function stopActiveLoop() {
            if (activeTimer) clearInterval(activeTimer);
            if (renderDebounceTimer) clearTimeout(renderDebounceTimer);
            if (activeDoc) removeButton(activeDoc);
            activeTimer = null;
            renderDebounceTimer = null;
            lastRenderKey = "";
            activeDoc = null;
            activeAppId = null;
        }

        function setupWindow(win) {
            const name = String(win?.m_strName || "");
            if (!name.startsWith("SP ")) return;
            let attempts = 0;
            const start = () => {
                const doc = win.m_popup?.document;
                if (!doc?.body) {
                    if (attempts++ < 20) setTimeout(start, 500);
                    return;
                }
                if (activeDoc && activeDoc !== doc) stopActiveLoop();
                if (activeDoc === doc && activeTimer) return;
                activeDoc = doc;
                scheduleRender(doc, true);
                activeTimer = setInterval(() => scheduleRender(doc, false), ROUTE_INTERVAL_MS);
            };
            start();
        }

        function Content() {
            const [status, setStatus] = React.useState("");
            const runClearCache = async () => {
                setStatus("Clearing cache...");
                try {
                    responseCache.clear();
window.localStorage?.removeItem("my-save.pcgwCacheCursor");
                    const parsed = parseBackendResponse(await CLEAR_CACHE(), "Invalid clear-cache response");
                    setStatus(parsed.success ? "Cache cleared. Launcher profile IDs were kept." : "Clear cache failed.");
                } catch (e) {
                    error("clear cache failed", e);
                    setStatus("Clear cache failed.");
                }
            };
            const buttonStyle = { display: "block", margin: "18px 0 8px", padding: "9px 14px", borderRadius: "6px", border: "1px solid rgba(255,255,255,.18)", background: "rgba(255,255,255,.08)", color: "#fff", cursor: "pointer" };
            const textStyle = { margin: "0 0 12px", color: "#acb2b8", lineHeight: 1.45 };
            const sectionStyle = { marginTop: "18px", paddingTop: "14px", borderTop: "1px solid rgba(255,255,255,.12)" };
            return jsx.jsxs("div", { style: { padding: "20px", fontSize: "13px", color: "#d7d7d7", maxWidth: "620px" }, children: [
                jsx.jsx("h2", { style: { margin: "0 0 12px", fontSize: "18px" }, children: "My Save" }),
                jsx.jsx("p", { style: textStyle, children: "Open a Steam game page to show save and config folders." }),
                jsx.jsxs("div", { style: sectionStyle, children: [
                    jsx.jsx("button", { type: "button", style: buttonStyle, onClick: runClearCache, children: "Clear cache" }),
                    jsx.jsx("p", { style: textStyle, children: "Removes cached folder lookups and PCGW/Ubisoft cache data. Launcher profile IDs are kept. Use this when folder detection looks stale or wrong, then reopen the game page." }),
                ] }),
                jsx.jsxs("div", { style: sectionStyle, children: [
                    jsx.jsx("p", { style: textStyle, children: "PCGamingWiki is used automatically only when local LS/Steam detection does not find a usable save folder." }),
                ] }),
                status ? jsx.jsx("p", { style: { ...textStyle, marginTop: "16px", color: "#9fd49f" }, children: status }) : null,
            ] });
        }

        const Plugin = API.definePlugin(() => {
            log("loading...");
            API.Millennium.AddWindowCreateHook?.(setupWindow);
            return { title: "My Save", icon: jsx.jsx(API.IconsModule.Settings, {}), content: jsx.jsx(Content, {}) };
        });

        exports.default = Plugin;
        Object.defineProperty(exports, "__esModule", { value: true });
        return exports;
    }({}, SP_JSX_FACTORY, window.SP_REACT, window.MILLENNIUM_API);
};

function ExecutePluginModule() {
    let e = window.MILLENNIUM_PLUGIN_SETTINGS_STORE[pluginName];
    e.OnPluginConfigChange = function(t, n, a) {
        if (t in e.settingsStore) {
            e.ignoreProxyFlag = true;
            e.settingsStore[t] = a;
            e.ignoreProxyFlag = false;
        }
    };
    MILLENNIUM_BACKEND_IPC.postMessage(0, { pluginName: pluginName, methodName: "__builtins__.__millennium_plugin_settings_parser__" }).then(async t => {
        if (typeof t.returnValue === "string") {
            e.ignoreProxyFlag = true;
            e.settingsStore = e.DefinePluginSetting(Object.fromEntries(JSON.parse(atob(t.returnValue)).map(e => [e.functionName, e])));
            e.ignoreProxyFlag = false;
        }
        let n = PluginEntryPointMain();
        Object.assign(window.PLUGIN_LIST[pluginName], { ...n, __millennium_internal_plugin_name_do_not_use_or_change__: pluginName });
        let a = await n.default();
        if (a && a.title !== void 0 && a.icon !== void 0 && a.content !== void 0) {
            window.MILLENNIUM_SIDEBAR_NAVIGATION_PANELS[pluginName] = a;
            MILLENNIUM_BACKEND_IPC.postMessage(1, { pluginName: pluginName });
        } else {
            console.warn(`Plugin ${pluginName} does not contain proper SidebarNavigation props and therefore can't be mounted by Millennium.`);
        }
    });
}

ExecutePluginModule();
