-- Simple UI integration for JJWXC for KOReader.
-- Registers JJWXC actions with Simple UI's Quick Actions registry when available.

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {
    RETRY_INTERVAL = 2,
    MAX_ATTEMPTS = 6,
    _attempts = 0,
    _registered = false,
    _retry_scheduled = false,
}

local QA_MODULES = {"features/sui_quickactions", "sui_quickactions"}
local CONFIG_MODULES = {"infra/sui_config", "sui_config"}

local function getQA()
    for _,module_name in ipairs(QA_MODULES) do
        local QA = package.loaded[module_name]
        if not QA then
            local ok, mod = pcall(require, module_name)
            QA = ok and mod or nil
        end
        if type(QA) == "table" and type(QA.register) == "function" then
            return QA
        end
    end
end

-- FileManager and ReaderUI each create their own plugin instance. Quick Action
-- descriptors live for the whole process, so never permanently capture the
-- first (usually FileManager) instance when an active reader instance exists.
local function currentPlugin()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.jjwxc then
        return ReaderUI.instance.jjwxc
    end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager.instance and FileManager.instance.jjwxc then
        return FileManager.instance.jjwxc
    end
    return M._plugin
end

function M:_schedule(plugin)
    if self._retry_scheduled or self._attempts >= self.MAX_ATTEMPTS then return end
    self._retry_scheduled = true
    UIManager:scheduleIn(self.RETRY_INTERVAL, function()
        self._retry_scheduled = false
        self:register(plugin)
    end)
end

function M:register(plugin)
    self._plugin = plugin
    if self._registered then return true end
    self._attempts = self._attempts + 1
    local QA = getQA()
    if not QA then
        self:_schedule(plugin)
        return false
    end

    local plugin_icon=(plugin.path or "").."/icons/jjwxc.svg"
    local descriptors = {
        {
            id = "jjwxc_shelf",
            label = "晋江书架",
            icon = plugin_icon,
            get_label = function()
                local p=currentPlugin()
                return p and p.token ~= "" and "晋江书架" or "登录晋江"
            end,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if not p then return end
                if p.token == "" then p:startLogin() else p:showShelf() end
            end,
        },
        {
            id = "jjwxc_open_id",
            label = "晋江：按小说ID打开",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function() local p=currentPlugin(); if p then p:promptNovel() end end,
        },
        {
            id = "jjwxc_toc",
            label = "晋江目录",
            icon = plugin_icon,
            get_label = function()
                local p=currentPlugin()
                return p and p:getCurrentChapterContext() and "当前晋江目录" or "晋江目录"
            end,
            is_in_place = true,
            is_async_in_place = true,
            execute = function() local p=currentPlugin(); if p then p:onJJWXCShowToc() end end,
        },
        {
            id = "jjwxc_previous_chapter",
            label = "晋江上一章",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function() local p=currentPlugin(); if p then p:onJJWXCPreviousChapter() end end,
        },
        {
            id = "jjwxc_next_chapter",
            label = "晋江下一章",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function() local p=currentPlugin(); if p then p:onJJWXCNextChapter() end end,
        },
        {
            id = "jjwxc_paragraph_comments",
            label = "当前晋江段评",
            icon = plugin_icon,
            get_label = function()
                local p=currentPlugin()
                return p and p:getCurrentChapterContext() and "当前晋江段评" or "晋江段评"
            end,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCParagraphComments() end
            end,
        },
        {
            id = "jjwxc_refresh_toc",
            label = "刷新晋江目录",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function() local p=currentPlugin(); if p then p:onJJWXCRefreshToc() end end,
        },
        {
            id = "jjwxc_cache_paragraph_comments",
            label = "下载本章离线段评",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCCacheParagraphComments() end
            end,
        },
        {
            id = "jjwxc_download_novel",
            label = "下载晋江整本可读章节",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCDownloadNovel() end
            end,
        },
        {
            id = "jjwxc_download_novel_comments",
            label = "下载晋江整本段评",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCDownloadNovelComments() end
            end,
        },
        {
            id = "jjwxc_generate_epub",
            label = "更新晋江离线 EPUB",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCGenerateEpub() end
            end,
        },
        {
            id = "jjwxc_open_epub",
            label = "打开晋江离线 EPUB",
            icon = plugin_icon,
            is_in_place = true,
            is_async_in_place = true,
            execute = function()
                local p=currentPlugin(); if p then p:onJJWXCOpenEpub() end
            end,
        },
    }

    local ok, err = pcall(function()
        for _, d in ipairs(descriptors) do QA.register(d) end
        for _,module_name in ipairs(CONFIG_MODULES) do
            local okc, Config = pcall(require, module_name)
            if okc and type(Config) == "table" and Config.invalidateTabsCache then
                Config.invalidateTabsCache()
                break
            end
        end
    end)
    if not ok then
        logger.warn("jjwxc: Simple UI registration failed: " .. tostring(err))
        return false
    end
    self._registered = true
    logger.dbg("jjwxc: registered Simple UI quick actions")
    return true
end

return M
