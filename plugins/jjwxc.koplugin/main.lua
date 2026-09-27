local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Event = require("ui/event")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ReadHistory = require("readhistory")

local ok_client, Client = pcall(require, "client")
local ok_html, Html = pcall(require, "html")
local ok_epub, Epub = pcall(require, "epub")
local ok_simpleui, SimpleUI = pcall(require, "simpleui")

local backend_load_error = nil
if not ok_client then
    backend_load_error = "client.lua: " .. tostring(Client)
    Client = nil
end
if not ok_html then
    backend_load_error = (backend_load_error and (backend_load_error .. "\n") or "")
        .. "html.lua: " .. tostring(Html)
    Html = nil
end
if not ok_epub then
    backend_load_error = (backend_load_error and (backend_load_error .. "\n") or "")
        .. "epub.lua: " .. tostring(Epub)
    Epub = nil
end
if not ok_simpleui then
    SimpleUI = nil
end

local function invalidate_simpleui_book_cache()
    local ok, store = pcall(require, "infra/sui_store")
    if ok and store and store.del then
        pcall(function() store:del("simpleui_stale_books_v1") end)
    end
    -- Deleting the persisted value is not enough: Simple UI also keeps the
    -- last book list in memory. A fresh prefetch replaces both copies.
    local ok_books, books = pcall(require, "modules/module_books_shared")
    if ok_books and books and books.prefetchBooks then
        pcall(function() books.prefetchBooks(true,true,12,{exclude_current=true}) end)
    end
end

local JJ = WidgetContainer:extend{ name="jjwxc", is_doc_only=false }
local PLUGIN_VERSION = "0.4.41"

local function msg(text, timeout)
    UIManager:show(InfoMessage:new{ text=tostring(text), timeout=timeout })
end

function JJ:backendReady(show_error)
    if self.client and Html then return true end
    if show_error ~= false then
        msg("晋江插件菜单已经正常加载，但功能模块未能加载。\n\n"
            .. tostring(self.backend_error or backend_load_error or "未知错误")
            .. "\n\n请打开：晋江文学城 → 调试信息")
    end
    return false
end
local function safe_name(s)
    s=tostring(s or "晋江小说")
    return (s:gsub("[\\/:*?\"<>|]","_"))
end
local function html_meta_text(t)
    t=tostring(t or "")
    t=t:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    return util.trim(t)
end

function JJ:init()
    self.settings_file=DataStorage:getSettingsDir().."/jjwxc.lua"
    self.settings=LuaSettings:open(self.settings_file)
    self.token=self.settings:readSetting("token","")
    self.account=self.settings:readSetting("account","")
    self.download_dir=self.settings:readSetting("download_dir",DataStorage:getDataDir().."/JJWXC")
    self.progress=self.settings:readSetting("progress",{}) or {}
    self.paragraph_drafts=self.settings:readSetting("paragraph_drafts",{}) or {}
    self.chapter_lists={}
    self.novel_meta={}
    self.backend_error=backend_load_error
    self.simpleui_error=nil
    self.highlight_error=nil

    self:onDispatcherRegisterActions()

    -- Critical: this is the standard KOReader plugin entry and is registered first.
    self.ui.menu:registerToMainMenu(self)

    if Client and Html then
        local ok, obj=pcall(function() return Client:new{token=self.token} end)
        if ok and obj then
            self.client=obj
            self.backend_error=nil
        else
            self.client=nil
            self.backend_error="Client:new: "..tostring(obj)
        end
    end

    if self.document and self.ui.highlight then
        local ok, err=pcall(function() self:addToHighlightDialog() end)
        if not ok then self.highlight_error=tostring(err) end
    end

    -- Simple UI is optional. Failure here must never hide the JJWXC plugin itself.
    if SimpleUI then
        local ok, err=pcall(function() SimpleUI:register(self) end)
        if not ok then self.simpleui_error=tostring(err) end
    elseif not ok_simpleui then
        self.simpleui_error="simpleui.lua 未加载"
    end

    for _,delay in ipairs({1.0,3.0,7.0}) do
        UIManager:scheduleIn(delay,function()
            pcall(function() self:collapseLegacyChapterHistory() end)
        end)
    end
end

-- Expose the useful reader operations to KOReader's gesture/key dispatcher.
-- They will appear in gesture configuration without depending on Simple UI.
function JJ:onDispatcherRegisterActions()
    Dispatcher:registerAction("jjwxc_show_shelf", {
        category="none", event="JJWXCShowShelf", title="晋江：我的书架", general=true,
    })
    Dispatcher:registerAction("jjwxc_show_toc", {
        category="none", event="JJWXCShowToc", title="晋江：当前小说目录", reader=true,
    })
    Dispatcher:registerAction("jjwxc_previous_chapter", {
        category="none", event="JJWXCPreviousChapter", title="晋江：上一章", reader=true,
    })
    Dispatcher:registerAction("jjwxc_next_chapter", {
        category="none", event="JJWXCNextChapter", title="晋江：下一章", reader=true,
    })
    Dispatcher:registerAction("jjwxc_paragraph_comments", {
        category="none", event="JJWXCParagraphComments", title="晋江：当前段落段评", reader=true,
    })
    Dispatcher:registerAction("jjwxc_refresh_toc", {
        category="none", event="JJWXCRefreshToc", title="晋江：刷新目录/购买状态", reader=true,
    })
    Dispatcher:registerAction("jjwxc_cache_paragraph_comments", {
        category="none", event="JJWXCCacheParagraphComments", title="晋江：下载本章离线段评", reader=true,
    })
    Dispatcher:registerAction("jjwxc_download_novel", {
        category="none", event="JJWXCDownloadNovel", title="晋江：下载本书全部可读章节", reader=true,
    })
    Dispatcher:registerAction("jjwxc_download_novel_comments", {
        category="none", event="JJWXCDownloadNovelComments", title="晋江：下载本书全部段评", reader=true,
    })
    Dispatcher:registerAction("jjwxc_generate_epub", {
        category="none", event="JJWXCGenerateEpub", title="晋江：生成/更新离线 EPUB", reader=true,
    })
    Dispatcher:registerAction("jjwxc_open_epub", {
        category="none", event="JJWXCOpenEpub", title="晋江：打开本书离线 EPUB", reader=true,
    })
end

function JJ:onJJWXCShowShelf()
    if self:backendReady() then self:showShelf() end
    return true
end

function JJ:onJJWXCShowToc()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("请先打开晋江插件生成的小说正文。") return true end
    self:showChapters(ctx.novel_id,ctx.book~="" and ctx.book or "晋江小说",
        ctx.author or "",true,ctx.chapter_id)
    return true
end

function JJ:onJJWXCPreviousChapter()
    return self:openAdjacentChapter(true)
end

function JJ:onJJWXCNextChapter()
    return self:openAdjacentChapter(false)
end

function JJ:onJJWXCParagraphComments()
    self:paragraphFromCurrentSelection(nil)
    return true
end

function JJ:onJJWXCRefreshToc()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("请先打开晋江插件生成的小说正文。") return true end
    self.chapter_lists[tostring(ctx.novel_id)]=nil
    self:showChapters(ctx.novel_id,ctx.book~="" and ctx.book or "晋江小说",
        ctx.author or "",true,ctx.chapter_id)
    return true
end

function JJ:onJJWXCCacheParagraphComments()
    self:cacheCurrentChapterParagraphComments(true,true)
    return true
end

function JJ:onJJWXCDownloadNovel()
    self:downloadCurrentNovel(); return true
end

function JJ:onJJWXCDownloadNovelComments()
    self:downloadCurrentNovelComments(); return true
end

function JJ:onJJWXCGenerateEpub()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("请先打开晋江插件生成的在线正文。") return true end
    self:generateOfflineEpub(ctx.novel_id,ctx.book,ctx.author,false)
    return true
end

function JJ:onJJWXCOpenEpub()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("请先打开本书的晋江在线 HTML。") return true end
    self:openOfflineEpub(ctx.novel_id,ctx.book)
    return true
end
function JJ:save()
    self.settings:saveSetting("token",self.token)
    self.settings:saveSetting("account",self.account)
    self.settings:saveSetting("download_dir",self.download_dir)
    self.settings:saveSetting("progress",self.progress)
    self.settings:saveSetting("paragraph_drafts",self.paragraph_drafts)
    self.settings:flush()
end

function JJ:addToMainMenu(menu_items)
    menu_items.jjwxc={
        -- Put JJWXC directly in KOReader's main Tools section. The star also
        -- sorts it ahead of ordinary third-party plugin names in that section.
        text="★ 晋江文学城",
        sorting_hint="tools",
        sub_item_table={
            {text="📚  我的书架",callback=function()
                if self:backendReady() then self:showShelf() end
            end},
            {text="🔎  按小说 ID 打开",callback=function()
                if self:backendReady() then self:promptNovel() end
            end},
            {text="→  下一章",callback=function()
                if self:backendReady() then self:openAdjacentChapter(false) end
            end, enabled_func=function()
                local c=self:getCurrentChapterContext(); return c and c.next_id~=nil
            end},
            {text="←  上一章",callback=function()
                if self:backendReady() then self:openAdjacentChapter(true) end
            end, enabled_func=function()
                local c=self:getCurrentChapterContext(); return c and c.prev_id~=nil
            end},
            {text="☰  当前小说目录",callback=function()
                if self:backendReady() then self:onJJWXCShowToc() end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil end},
            {text="▣  打开本书离线 EPUB",callback=function()
                local c=self:getCurrentChapterContext()
                if c then self:openOfflineEpub(c.novel_id,c.book) end
            end, enabled_func=function()
                local c=self:getCurrentChapterContext()
                return c and lfs.attributes(self:offlineEpubPath(c.novel_id,c.book),"mode")=="file"
            end},
            {text="⬇  下载本书全部可读章节",callback=function()
                if self:backendReady() then self:downloadCurrentNovel() end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil and self.token~="" end},
            {text="☁  下载本书全部段评",callback=function()
                if self:backendReady() then self:downloadCurrentNovelComments() end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil and self.token~="" end},
            {text="▣  生成 / 更新离线 EPUB",callback=function()
                if self:backendReady() then self:onJJWXCGenerateEpub() end
            end, enabled_func=function() return Epub~=nil and self:getCurrentChapterContext()~=nil end},
            {text="↻  刷新目录 / 购买状态",callback=function()
                if self:backendReady() then self:onJJWXCRefreshToc() end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil end},
            {text="✎  当前正文段评",callback=function()
                if self:backendReady() then self:paragraphFromCurrentSelection(nil) end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil end},
            {text="🧪  当前章节段评诊断",callback=function()
                if self:backendReady() then self:showParagraphDiagnostics() end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil end},
            {text="⬇  下载 / 刷新本章离线段评",callback=function()
                if self:backendReady() then self:cacheCurrentChapterParagraphComments(true,true) end
            end, enabled_func=function() return self:getCurrentChapterContext()~=nil and self.token~="" end},
            {text_func=function()
                return self.token~="" and "账号：已登录" or "登录晋江"
            end,callback=function()
                if self:backendReady() then self:startLogin() end
            end},
            {text="↻  刷新书架",callback=function()
                if self:backendReady() then self:showShelf() end
            end, enabled_func=function() return self.token~="" end},
            {text="退出登录",callback=function()
                if self:backendReady() then self:logout() end
            end, enabled_func=function() return self.token~="" end},
            {text="🛠  调试信息",callback=function() self:showDiagnostics() end},
            {text="关于 / 使用说明",callback=function() self:showHelp() end},
        }
    }
end
function JJ:runOnline(fn)
    if NetworkMgr:willRerunWhenOnline(fn) then return end
    fn()
end

function JJ:startLogin()
    local d
    d=InputDialog:new{
        title="晋江登录 · 账号",
        input=self.account or "",
        description="输入晋江账号（手机号/邮箱）。密码只用于本次登录请求，不会保存到 Kobo。",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="下一步",is_enter_default=true,callback=function()
                local account=util.trim(d:getInputText() or "")
                if account=="" then msg("请输入账号") return end
                UIManager:close(d)
                self:promptPassword(account)
            end},
        }}
    }
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:promptPassword(account)
    local d
    d=InputDialog:new{
        title="晋江登录 · 密码",
        input="",
        input_type="password",
        description="密码不会写入 KOReader 设置；成功后只保存晋江 token。",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="登录",is_enter_default=true,callback=function()
                local password=d:getInputText() or ""
                if password=="" then msg("请输入密码") return end
                UIManager:close(d)
                self:doLogin(account,password,"",nil)
            end},
        }}
    }
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:promptVerificationMethod(account,password,notice)
    local d
    d=InputDialog:new{
        title="晋江设备验证",
        input="",
        description=tostring(notice or "晋江要求设备验证。请选择验证码发送方式。"),
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="发到手机",callback=function()
                UIManager:close(d)
                self:sendVerification(account,password,"phone")
            end},
            {text="发到邮箱",callback=function()
                UIManager:close(d)
                self:sendVerification(account,password,"email")
            end},
        }}
    }
    UIManager:show(d)
end

function JJ:sendVerification(account,password,checktype)
    if not self:backendReady() then return end
    self:runOnline(function()
        msg("正在请求晋江验证码…",1)
        local notice, err=self.client:sendVerificationCode(account,checktype)
        if not notice then
            msg("验证码没有发送成功：\n"..tostring(err or "未知错误"))
            self:promptVerificationMethod(account,password,"发送失败。你可以换另一种方式再试。\n\n"..tostring(err or ""))
            return
        end
        self:promptVerifyCode(account,password,checktype,notice)
    end)
end

function JJ:promptVerifyCode(account,password,checktype,notice)
    local d
    d=InputDialog:new{
        title="输入晋江验证码",
        input="",
        description=tostring(notice or "验证码已发送，请输入收到的验证码。"),
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="重新发送",callback=function()
                UIManager:close(d)
                self:sendVerification(account,password,checktype)
            end},
            {text="验证并登录",is_enter_default=true,callback=function()
                local code=util.trim(d:getInputText() or "")
                if code=="" then msg("请输入验证码") return end
                UIManager:close(d)
                self:doLogin(account,password,code,checktype)
            end},
        }}
    }
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:doLogin(account,password,code,checktype)
    if not self:backendReady() then return end
    self:runOnline(function()
        msg("正在登录晋江…",1)
        local r=self.client:login(account,password,code,checktype)
        if r.ok then
            self.token=r.token or self.client.token or ""
            self.account=account
            self.client:setToken(self.token)
            self:save()
            msg("登录成功。正在打开我的书架…",2)
            self:showShelf()
        elseif r.need_verification then
            self:promptVerificationMethod(account,password,r.message)
        else
            msg("登录失败：\n"..tostring(r.error or "未知错误"))
        end
    end)
end

function JJ:promptNovel()
    local d
    d=InputDialog:new{title="输入晋江小说 ID",input="",buttons={{
        {text="取消",id="close",callback=function() UIManager:close(d) end},
        {text="打开",is_enter_default=true,callback=function()
            local id=(d:getInputText() or ""):match("(%d+)")
            if not id then msg("请输入数字小说 ID") return end
            UIManager:close(d); self:showNovel(id)
        end},
    }}}
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:bookDir(novel_id, novel_title)
    return self.download_dir.."/"..safe_name(novel_title).."_"..tostring(novel_id)
end

function JJ:bookShellPath(novel_id, novel_title)
    return self:bookDir(novel_id, novel_title).."/"..safe_name(novel_title)..".html"
end

function JJ:chapterProgressPercent(novel_id, chapter_id)
    local chapters=self.chapter_lists[tostring(novel_id)]
    if not chapters then
        local list=self.client:getChapterList(novel_id)
        if type(list)=="table" then
            chapters=list
            self.chapter_lists[tostring(novel_id)]=list
        end
    end
    if type(chapters)~="table" then return 0 end
    local clean={}
    for _,c in ipairs(chapters) do
        local cid=c.chapterid or c.chapterId or c.id
        if cid and tostring(c.chaptertype or c.chapterType or "0")~="1" then
            clean[#clean+1]=tostring(cid)
        end
    end
    if #clean==0 then return 0 end
    for i,cid in ipairs(clean) do
        if cid==tostring(chapter_id) then return (i/#clean)*100 end
    end
    return 0
end

function JJ:ensureBookShell(novel_id, novel_title, author, chapter_id, chapter_title, cover)
    local dir=self:bookDir(novel_id,novel_title)
    if not self:ensureDir(self.download_dir) or not self:ensureDir(dir) then return nil end
    local shell=self:bookShellPath(novel_id,novel_title)
    local pct=self:chapterProgressPercent(novel_id,chapter_id)
    local f=io.open(shell,"w")
    if not f then return nil end
    f:write(Html.book_shell{
        novel_id=tostring(novel_id), book=novel_title, author=author or "", chapter_title=chapter_title or "",
        percent=pct, cover=cover or "",
    })
    f:close()
    local ok,ds=pcall(function() return DocSettings:open(shell) end)
    if ok and ds then
        ds:saveSetting("percent_finished",math.max(0,math.min(1,pct/100)))
        local props=ds:readSetting("doc_props") or {}
        props.title=novel_title
        props.authors=author or ""
        props.display_title=novel_title
        ds:saveSetting("doc_props",props)
        ds:flush()
    end
    return shell
end

function JJ:ensureStableBookCover(file, cover_url, book_dir)
    cover_url=tostring(cover_url or "")
    if cover_url=="" or not file or not book_dir then return end
    local png_file=book_dir.."/jjwxc-cover.png"
    local jpg_file=book_dir.."/jjwxc-cover.jpg"
    local cover_file=lfs.attributes(png_file,"mode")=="file" and png_file
        or (lfs.attributes(jpg_file,"mode")=="file" and jpg_file or nil)
    if not cover_file then
        local body=self.client:request(cover_url,{headers={
            ["User-Agent"]="Mozilla/5.0 KOReader-JJWXC/"..PLUGIN_VERSION,
            ["Accept-Encoding"]="identity",
        }})
        if not body or #body<512 then return end
        -- novelimage.php currently returns PNG even though it has no filename
        -- extension. Keep the local suffix consistent with the actual bytes so
        -- KOReader's custom-cover loader chooses the correct decoder.
        if body:sub(1,8)=="\137PNG\r\n\26\n" then cover_file=png_file else cover_file=jpg_file end
        local f=io.open(cover_file,"wb")
        if not f then return end
        f:write(body); f:close()
    end
    if lfs.attributes(cover_file,"mode")=="file" then
        pcall(function() DocSettings:flushCustomCover(file,cover_file) end)
        pcall(function() UIManager:broadcastEvent(Event:new("InvalidateMetadataCache",file)) end)
    end
end

function JJ:forceChapterStart(expected_file)
    for _,delay in ipairs({0.05,0.25,0.8}) do
        UIManager:scheduleIn(delay,function()
            local current=self.ui and self.ui.document and self.ui.document.file or nil
            if self.ui and (not expected_file or current==expected_file) then
                pcall(function() self.ui:handleEvent(Event:new("GotoPage",1)) end)
            end
        end)
    end
end

function JJ:forceChapterEnd(expected_file)
    for _,delay in ipairs({0.08,0.3,0.9}) do
        UIManager:scheduleIn(delay,function()
            local current=self.ui and self.ui.document and self.ui.document.file or nil
            if self.ui and (not expected_file or current==expected_file) then
                pcall(function()
                    local info=self.ui.document and self.ui.document.info or {}
                    local last_page=tonumber(info.number_of_pages)
                    if last_page and last_page>0 then
                        self.ui:handleEvent(Event:new("GotoPage",last_page))
                    else
                        self.ui:handleEvent(Event:new("GotoPercent",100))
                    end
                end)
            end
        end)
    end
end

function JJ:clearStableChapterPosition(file)
    local ok,ds=pcall(function() return DocSettings:open(file) end)
    if not ok or not ds then return end
    ds:delSetting("last_xpointer")
    ds:delSetting("last_percent")
    ds:saveSetting("percent_finished",0)
    ds:flush()
end


function JJ:updateStableBookMetadata(file, novel_title, author, pct)
    local ok,ds=pcall(function() return DocSettings:open(file) end)
    if ok and ds then
        ds:saveSetting("percent_finished",math.max(0,math.min(1,(tonumber(pct) or 0)/100)))
        local props=ds:readSetting("doc_props") or {}
        props.title=novel_title
        props.authors=author or ""
        props.display_title=novel_title
        ds:saveSetting("doc_props",props)
        ds:flush()
    end
end

function JJ:applyReaderBookMetadata(ctx)
    if not (ctx and self.ui and self.ui.doc_settings) then return end
    local props=self.ui.doc_settings:readSetting("doc_props") or {}
    props.title=ctx.book
    props.display_title=ctx.book
    props.authors=ctx.author or ""
    props.language="zh-CN"
    self.ui.doc_settings:saveSetting("doc_props",props)
    self.ui.doc_settings:flush()
    self.ui.doc_props=props
    pcall(function() UIManager:broadcastEvent(Event:new("InvalidateMetadataCache",ctx.file)) end)
end

function JJ:removeLegacyChapterEntries(novel_id, novel_title, keep_file)
    local dir=self:bookDir(novel_id,novel_title).."/"
    local doomed={}
    for _,v in ipairs(ReadHistory.hist or {}) do
        local f=v.file
        if f and f~=keep_file and f:sub(1,#dir)==dir then
            doomed[#doomed+1]=f
        end
    end
    for _,f in ipairs(doomed) do
        pcall(function() ReadHistory:removeItemByPath(f) end)
    end
    if keep_file then
        pcall(function() ReadHistory:removeItemByPath(keep_file) end)
        pcall(function() ReadHistory:addItem(keep_file,os.time()) end)
    end
    invalidate_simpleui_book_cache()
end

function JJ:normalizeBookHistory(novel_id, novel_title, author, chapter_id, chapter_title, chapter_file, ts)
    local stable=self:bookShellPath(novel_id,novel_title)
    if lfs.attributes(stable,"mode")~="file" and chapter_file then stable=chapter_file end
    self:removeLegacyChapterEntries(novel_id,novel_title,stable)
end

function JJ:collapseLegacyChapterHistory()
    if not (ReadHistory and ReadHistory.hist) then return end
    local groups={}
    local all_files={}
    for _,v in ipairs(ReadHistory.hist) do
        local file=v.file
        if file and file:sub(1,#self.download_dir)==self.download_dir and file:match("%.html$") then
            -- Old builds may have deleted the chapter file already, leaving a
            -- dead ReadHistory row. Detect non-stable names from the directory
            -- convention (<title>_<novelId>/<title>.html) without opening it.
            local parent=file:match("/([^/]+)/[^/]+$") or ""
            local base=file:match("/([^/]+)%.html$") or ""
            local expected=parent:gsub("_%d+$","")
            local is_comment_cache=file:find("/评论缓存/",1,true)~=nil
            if not is_comment_cache and expected~="" and base~=expected then
                all_files[#all_files+1]=file
            end
            local f=io.open(file,"r")
            if f then
                local raw=f:read("*a"); f:close()
                local nid=raw:match('<meta name="jjwxc%-novel%-id" content="([^"]*)">')
                local cid=raw:match('<meta name="jjwxc%-chapter%-id" content="([^"]*)">')
                local book=html_meta_text(raw:match('<meta name="jjwxc%-book" content="([^"]*)">') or "")
                local author=html_meta_text(raw:match('<meta name="jjwxc%-author" content="([^"]*)">') or "")
                local ctitle=html_meta_text(raw:match('<meta name="jjwxc%-chapter%-title" content="([^"]*)">') or "")
                if nid and nid~="" and book~="" then
                    groups[nid]=groups[nid] or {nid=nid,book=book,author=author,cid=cid,ctitle=ctitle,time=v.time or os.time()}
                    if (v.time or 0)>(groups[nid].time or 0) then
                        groups[nid].cid=cid; groups[nid].ctitle=ctitle; groups[nid].time=v.time or os.time()
                    end
                    local stable=self:bookShellPath(nid,book)
                    if file~=stable then all_files[#all_files+1]=file end
                end
            end
        end
    end
    for _,file in ipairs(all_files) do
        pcall(function() ReadHistory:removeItemByPath(file) end)
    end
    for _,g in pairs(groups) do
        local stable=self:bookShellPath(g.nid,g.book)
        if lfs.attributes(stable,"mode")=="file" then
            pcall(function() ReadHistory:addItem(stable,g.time or os.time()) end)
        end
    end
    invalidate_simpleui_book_cache()
end

function JJ:showShelf()
    if not self:backendReady() then return end
    if self.token=="" then self:startLogin(); return end
    self:runOnline(function()
        msg("正在同步晋江书架…",1)
        local books,err=self.client:getShelf()
        if not books then msg("书架同步失败：\n"..tostring(err)); return end
        local items={{
            text="◆ 表示 VIP 章节；是否已购会在打开正文时确认",
            enabled_func=function() return false end,
        }}
        for _,b in ipairs(books) do
            local id=b.novelId or b.novelid or b.id
            local title=b.novelName or b.novelname or b.name or ("小说 "..tostring(id or "?"))
            local author=b.authorName or b.authorname or b.author or ""
            local latest=b.chapternameNewest or b.chapterNameNewest or b.lastChapter or ""
            if id then
                local nid=tostring(id)
                local mark=self.progress[nid] and "●" or "○"
                items[#items+1]={
                    text=mark.."  "..title..(author~="" and ("  ·  "..author) or "")..(latest~="" and ("\n最新  "..latest) or ""),
                    callback=function() self:showNovel(nid) end,
                }
            end
        end
        if #items==0 then msg("书架返回为空，或接口字段已变化。") return end
        local menu
        menu=Menu:new{title="📚 我的晋江书架  ·  "..#items.." 本",item_table=items,items_max_lines=2,
            close_callback=function() UIManager:close(menu) end}
        UIManager:show(menu)
    end)
end

function JJ:showNovel(novel_id)
    if not self:backendReady() then return end
    self:runOnline(function()
        msg("读取作品信息…",1)
        local info,err=self.client:getNovelInfo(novel_id)
        if not info then msg("读取失败："..tostring(err)); return end
        local title=info.novelName or info.novelname or ("小说 "..novel_id)
        local author=info.authorName or info.authorname or info.author or ""
        self.novel_meta[tostring(novel_id)]={
            title=title,
            author=author,
            cover=info.novelCover or info.novelcover or info.cover or "",
        }
        local intro=info.novelIntro or info.novelintro or ""
        local menu
        local items={}
        local pr=self.progress[tostring(novel_id)]
        if pr and pr.chapter_id then
            items[#items+1]={text="▶ 打开在线 HTML  ·  "..tostring(pr.chapter_title or ("第"..pr.chapter_id.."章")),callback=function() UIManager:close(menu); self:openChapter(tostring(novel_id),tostring(pr.chapter_id),title,tostring(pr.chapter_title or "继续阅读"),author) end}
        end
        items[#items+1]={text="☰ 章节目录",callback=function() UIManager:close(menu); self:showChapters(novel_id,title,author) end}
        items[#items+1]={text="▣ 打开离线 EPUB",callback=function()
            UIManager:close(menu); self:openOfflineEpub(novel_id,title)
        end, enabled_func=function()
            return lfs.attributes(self:offlineEpubPath(novel_id,title),"mode")=="file"
        end}
        items[#items+1]={text="⬇ 下载全部免费章和已购章",callback=function()
            UIManager:close(menu); self:downloadNovel(novel_id,title,author)
        end, enabled_func=function() return self.token~="" end}
        items[#items+1]={text="☁ 下载已缓存章节的全部段评",callback=function()
            UIManager:close(menu); self:downloadNovelComments(novel_id,title,author)
        end, enabled_func=function() return self.token~="" end}
        items[#items+1]={text="▣ 生成 / 更新离线 EPUB",callback=function()
            UIManager:close(menu); self:generateOfflineEpub(novel_id,title,author,false)
        end, enabled_func=function() return Epub~=nil end}
        items[#items+1]={text="ℹ 作品简介",callback=function() msg(title.."\n作者："..author.."\n\n"..tostring(intro)) end}
        menu=Menu:new{title=title..(author~="" and (" · "..author) or ""),item_table=items,
            close_callback=function() UIManager:close(menu) end}
        UIManager:show(menu)
    end)
end

function JJ:showChapters(novel_id,novel_title,author,direct_open,current_chapter_id)
    if not self:backendReady() then return end
    local manifest=self:loadOfflineManifest(novel_id,novel_title)
    local function display_chapters(chapters,offline)
        self.chapter_lists[tostring(novel_id)]=chapters
        local states=manifest and manifest.states or {}
        local items={}
        local menu
        for _,c in ipairs(chapters) do
            local cid=c.chapterid or c.chapterId or c.id
            local cname=c.chaptername or c.chapterName or c.name or ("第 "..tostring(cid).." 章")
            local vip=c.isvip or c.isVip
            local is_vip=tostring(vip or "0")~="0" and tostring(vip or "")~="false"
            if cid and tostring(c.chaptertype or c.chapterType or "0")~="1" then
                local chapter_id=tostring(cid)
                local current=tostring(current_chapter_id or "")==chapter_id
                local state=states[chapter_id]
                local state_text=state=="purchased" and "  [已购·已缓存]"
                    or state=="free" and "  [免费·已缓存]"
                    or state=="unavailable" and "  [未购/不可读]" or ""
                items[#items+1]={text=(current and "▶ " or (is_vip and "◆ " or ""))..cname..state_text,
                    callback=function()
                        if direct_open then
                            UIManager:close(menu)
                            self:openChapter(novel_id,chapter_id,novel_title,cname,author)
                        else
                            self:chapterMenu(novel_id,chapter_id,novel_title,cname,is_vip,author)
                        end
                    end}
            end
        end
        menu=Menu:new{title=novel_title..(offline and " · 离线目录" or " · 目录"),item_table=items,items_per_page=14,
            close_callback=function() UIManager:close(menu) end}
        UIManager:show(menu)
    end
    local online=not NetworkMgr.isOnline or NetworkMgr:isOnline()
    if not online then
        if manifest and type(manifest.chapters)=="table" then
            display_chapters(manifest.chapters,true)
        else
            msg("当前没有网络，也没有已保存的整本目录。请联网刷新一次或先下载整本正文。")
        end
        return
    end
    self:runOnline(function()
        msg("加载章节目录…",1)
        local chapters,err=self.client:getChapterList(novel_id)
        if chapters then
            display_chapters(chapters,false)
        elseif manifest and type(manifest.chapters)=="table" then
            msg("在线目录读取失败，改用已保存目录。",2)
            display_chapters(manifest.chapters,true)
        else
            msg("目录读取失败："..tostring(err))
        end
    end)
end

function JJ:offlineManifestFile(novel_id,novel_title)
    return self:bookDir(novel_id,novel_title).."/offline_manifest.json"
end

function JJ:loadOfflineManifest(novel_id,novel_title)
    local file=self:offlineManifestFile(novel_id,novel_title)
    local f=io.open(file,"rb"); if not f then return nil end
    local raw=f:read("*a"); f:close()
    local ok,data=pcall(JSON.decode,raw or "")
    return ok and type(data)=="table" and data or nil
end

function JJ:saveOfflineManifest(novel_id,novel_title,manifest)
    local dir=self:bookDir(novel_id,novel_title)
    if not self:ensureDir(self.download_dir) or not self:ensureDir(dir) then return nil end
    local ok,raw=pcall(JSON.encode,manifest); if not ok then return nil end
    local f=io.open(self:offlineManifestFile(novel_id,novel_title),"wb"); if not f then return nil end
    f:write(raw); f:close(); return true
end

function JJ:chapterCacheFile(novel_id,novel_title,chapter_id,create)
    local dir=self:bookDir(novel_id,novel_title).."/chapters"
    if create and (not self:ensureDir(self.download_dir)
            or not self:ensureDir(self:bookDir(novel_id,novel_title)) or not self:ensureDir(dir)) then return nil end
    return dir.."/"..safe_name(tostring(chapter_id))..".json"
end

function JJ:loadChapterCache(novel_id,novel_title,chapter_id)
    local f=io.open(self:chapterCacheFile(novel_id,novel_title,chapter_id,false),"rb")
    if not f then return nil end
    local raw=f:read("*a"); f:close()
    local ok,data=pcall(JSON.decode,raw or "")
    return ok and type(data)=="table" and data or nil
end

function JJ:saveChapterCache(novel_id,novel_title,chapter_id,data)
    local file=self:chapterCacheFile(novel_id,novel_title,chapter_id,true); if not file then return nil end
    local ok,raw=pcall(JSON.encode,data); if not ok then return nil end
    local f=io.open(file,"wb"); if not f then return nil end
    f:write(raw); f:close(); return true
end

function JJ:downloadCurrentNovel()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是晋江插件正文。") return end
    self:downloadNovel(ctx.novel_id,ctx.book,ctx.author)
end

function JJ:offlineEpubPath(novel_id,novel_title)
    return self:bookDir(novel_id,novel_title).."/"..safe_name(novel_title).."_离线版.epub"
end

function JJ:openOfflineEpub(novel_id,novel_title)
    local path=self:offlineEpubPath(novel_id,novel_title)
    if lfs.attributes(path,"mode")~="file" then
        msg("这本书还没有离线 EPUB。\n\n请先选择“下载本书全部可读章节”或“生成 / 更新离线 EPUB”。")
        return
    end
    if self.ui and self.ui.document then self.ui:switchDocument(path)
    elseif self.ui then self.ui:openFile(path)
    else msg("无法从当前界面打开 EPUB，请在书库的 JJWXC 文件夹中打开。") end
end

function JJ:generateOfflineEpub(novel_id,novel_title,author,quiet)
    if not Epub then
        if not quiet then msg("EPUB 功能模块未能加载：\n"..tostring(backend_load_error or "未知错误")) end
        return nil
    end
    local manifest=self:loadOfflineManifest(novel_id,novel_title)
    if not manifest or type(manifest.chapters)~="table" then
        if not quiet then msg("还没有整本缓存。请先选择“下载全部免费章和已购章”。") end
        return nil
    end
    local chapters={}
    for _,c in ipairs(manifest.chapters) do
        local cid=c.chapterid or c.chapterId or c.id
        if cid and tostring(c.chaptertype or c.chapterType or "0")~="1" then
            local id=tostring(cid)
            local state=manifest.states and manifest.states[id]
            if state=="free" or state=="purchased" then
                local data=self:loadChapterCache(novel_id,novel_title,id)
                if data then
                    local title=c.chaptername or c.chapterName or c.name or ("第 "..id.." 章")
                    local comments_by_paragraph={}
                    local comment_cache=self:loadParagraphChapterCache(novel_id,id)
                    local comment_root=type(comment_cache)=="table"
                        and (type(comment_cache.data)=="table" and comment_cache.data or comment_cache) or {}
                    local comment_rows=comment_root.commentList or comment_root.commentlist or comment_root.list or {}
                    if type(comment_rows)=="table" then
                        for _,row in ipairs(comment_rows) do
                            local pid=tonumber(row._jj_pid or row.paragraph_id or row.paragraphId or row.paragraphid)
                            if pid then
                                comments_by_paragraph[pid]=comments_by_paragraph[pid] or {}
                                comments_by_paragraph[pid][#comments_by_paragraph[pid]+1]=row
                            end
                        end
                    end
                    chapters[#chapters+1]={
                        title=tostring(title),
                        paragraphs=Html.paragraph_lines(data.content or data.chapterContent or ""),
                        comments=comments_by_paragraph,
                        say=data.sayBodyV2 or data.sayBody or data.authorSay or "",
                    }
                end
            end
        end
    end
    if #chapters==0 then
        if not quiet then msg("缓存中没有可写入 EPUB 的章节。请先下载整本。") end
        return nil
    end
    local path=self:offlineEpubPath(novel_id,novel_title)
    local epub_meta={
        novel_id=tostring(novel_id), title=tostring(novel_title).."（离线版）", author=author or "",
    }
    for _,cover in ipairs({
        {self:bookDir(novel_id,novel_title).."/jjwxc-cover.png","png"},
        {self:bookDir(novel_id,novel_title).."/jjwxc-cover.jpg","jpg"},
    }) do
        local f=io.open(cover[1],"rb")
        if f then epub_meta.cover_data=f:read("*a"); f:close(); epub_meta.cover_ext=cover[2]; break end
    end
    local ok,err=Epub.build(path,epub_meta,chapters)
    if not ok then
        if not quiet then msg("离线 EPUB 生成失败：\n"..tostring(err or "未知错误")) end
        return nil
    end
    local ok_ds,ds=pcall(function() return DocSettings:open(path) end)
    if ok_ds and ds then
        local props=ds:readSetting("doc_props") or {}
        props.title=tostring(novel_title).."（离线版）"
        props.display_title=props.title
        props.authors=author or ""
        props.language="zh-CN"
        ds:saveSetting("doc_props",props); ds:flush()
    end
    pcall(function() ReadHistory:addItem(path,os.time()) end)
    pcall(function() UIManager:broadcastEvent(Event:new("InvalidateMetadataCache",path)) end)
    invalidate_simpleui_book_cache()
    if not quiet then msg("离线 EPUB 已更新。\n\n章节："..tostring(#chapters).."\n文件："..path,6) end
    return path,#chapters
end

local function download_bar(done,total)
    local width=20
    local filled=total>0 and math.floor((done/total)*width+0.5) or 0
    return string.rep("■",filled)..string.rep("□",width-filled)
end

local function explicitly_unpurchased(err)
    err=tostring(err or "")
    return err:find("未购买",1,true) or err:find("请购买",1,true)
        or err:find("购买后",1,true) or err:find("尚未订阅",1,true)
        or err:find("需要订阅",1,true)
end

function JJ:showDownloadProgress(task)
    if task.dialog then
        task.refreshing=true; UIManager:close(task.dialog); task.dialog=nil; task.refreshing=false
    end
    local percent=task.total>0 and math.floor((task.done/task.total)*100+0.5) or 0
    local status=task.paused and "已暂停" or "正在下载（点窗口任意位置可暂停）"
    local counters
    if task.kind=="comments" then
        counters="段评已缓存 "..task.cached.."  ·  失败 "..task.failed
            .."  ·  评论 "..task.comments_total.." 条"
    else
        counters="已缓存 "..task.readable.."  ·  明确未购 "..task.skipped.."  ·  失败 "..task.failed
    end
    local title=status.."  "..tostring(task.done).." / "..tostring(task.total).."  ·  "..percent.."%\n"
        ..download_bar(task.done,task.total).."\n\n"
        ..tostring(task.current_title or "准备中…").."\n"
        ..counters
        ..(task.last_error and ("\n最近错误："..tostring(task.last_error):sub(1,100)) or "")
    local dialog
    dialog=ButtonDialog:new{
        title=title,
        buttons={{
            {text=task.paused and "继续下载" or "暂停",callback=function()
                if task.finished then return end
                task.paused=not task.paused
                self:showDownloadProgress(task)
                if not task.paused then UIManager:scheduleIn(0.05,function()
                    if task.kind=="comments" then self:downloadNovelCommentsStep(task)
                    else self:downloadNovelStep(task) end
                end) end
            end},
            {text="停止任务",callback=function()
                if task.finished then return end
                task.finished=true; task.paused=true; self.download_task=nil
                task.refreshing=true; UIManager:close(dialog); task.dialog=nil
                msg("整本下载已停止。\n\n已经完成的章节均已保留；以后重新下载会自动跳过缓存。",4)
            end},
        }},
        close_callback=function()
            if not task.refreshing and not task.finished then task.paused=true end
        end,
    }
    task.dialog=dialog; UIManager:show(dialog)
end

function JJ:downloadNovelStep(task)
    if task.finished or task.paused or task.running then return end
    if task.done>=task.total then
        task.finished=true
        task.manifest.updated=os.time()
        self:saveOfflineManifest(task.novel_id,task.novel_title,task.manifest)
        local epub_path,epub_count=self:generateOfflineEpub(task.novel_id,task.novel_title,task.author,true)
        if task.dialog then task.refreshing=true; UIManager:close(task.dialog); task.dialog=nil end
        self.download_task=nil
        msg("整本正文下载完成。\n\n已缓存可读章节："..task.readable
            .."\n晋江明确返回未购："..task.skipped.."\n其他失败："..task.failed
            ..(task.last_error and ("\n最近错误："..tostring(task.last_error):sub(1,180)) or "")
            ..(epub_path and ("\n离线 EPUB：已更新（"..tostring(epub_count).." 章）") or "\n离线 EPUB：未生成"),6)
        return
    end
    task.running=true
    local c=task.chapters[task.done+1]
    local id=tostring(c.chapterid or c.chapterId or c.id)
    task.current_title=tostring(c.chaptername or c.chapterName or id)
    if not task.dialog then self:showDownloadProgress(task) end
    local vip=tostring(c.isvip or c.isVip or "0")~="0" and tostring(c.isvip or c.isVip or "")~="false"
    local cached=self:loadChapterCache(task.novel_id,task.novel_title,id)
    if cached then
        task.manifest.states[id]=task.manifest.states[id] or (vip and "purchased" or "free")
        task.readable=task.readable+1
    else
        local ok_tr,Trapper=pcall(require,"ui/trapper")
        local function fetch_one()
            self.client.bulk_download=true
            local data,chapter_err=self.client:getChapter(task.novel_id,id)
            self.client.bulk_download=false
            if data and self:saveChapterCache(task.novel_id,task.novel_title,id,data) then
                return {state=vip and "purchased" or "free"}
            end
            local failure=tostring(chapter_err or "写入失败")
            return {state=(vip and explicitly_unpurchased(failure)) and "unavailable" or "error",error=failure}
        end
        local completed,result
        if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
            -- Keep one stable dialog on screen. Trapper makes that existing
            -- widget dismissible, so a tap cancels the current subprocess
            -- without creating/closing a second flashing overlay.
            completed,result=Trapper:dismissableRunInSubprocess(fetch_one,task.dialog)
        else
            completed=true; result=fetch_one()
        end
        if not completed then
            task.running=false; task.paused=true
            task.current_title="已暂停，可稍后继续"
            self:showDownloadProgress(task)
            return
        end
        local state=type(result)=="table" and result.state or "error"
        task.manifest.states[id]=state
        if state=="free" or state=="purchased" then
            task.readable=task.readable+1
        elseif state=="unavailable" then
            task.skipped=task.skipped+1
        else
            task.failed=task.failed+1
            task.last_error=tostring(type(result)=="table" and result.error or "后台下载失败")
            task.manifest.last_error=task.last_error
        end
    end
    task.done=task.done+1; task.running=false
    self:saveOfflineManifest(task.novel_id,task.novel_title,task.manifest)
    -- E-ink friendly: do not tear down and recreate the window after every
    -- chapter. Refresh the visible counters occasionally; the fixed dialog
    -- remains tappable throughout all intervening requests.
    if task.done%10==0 or task.done>=task.total then self:showDownloadProgress(task) end
    if not task.paused then UIManager:scheduleIn(0.15,function() self:downloadNovelStep(task) end) end
end

function JJ:downloadNovel(novel_id,novel_title,author)
    if self.download_task and not self.download_task.finished then
        self:showDownloadProgress(self.download_task); return
    end
    self:runOnline(function()
        local chapters,err
        local ok_tr,Trapper=pcall(require,"ui/trapper")
        local function fetch_toc()
            self.client.bulk_download=true
            local list,list_err=self.client:getChapterList(novel_id)
            self.client.bulk_download=false
            return list,list_err
        end
        if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
            local completed
            completed,chapters,err=Trapper:dismissableRunInSubprocess(fetch_toc,
                "正在读取整本目录…\n\n点屏幕可取消")
            if not completed then msg("已取消整本下载。",2); return end
        else
            chapters,err=fetch_toc()
        end
        if not chapters then msg("目录读取失败："..tostring(err)); return end
        self.chapter_lists[tostring(novel_id)]=chapters
        local clean={}
        for _,c in ipairs(chapters) do
            local cid=c.chapterid or c.chapterId or c.id
            if cid and tostring(c.chaptertype or c.chapterType or "0")~="1" then clean[#clean+1]=c end
        end
        local manifest=self:loadOfflineManifest(novel_id,novel_title) or {states={}}
        manifest.states=manifest.states or {}; manifest.chapters=chapters
        local task={novel_id=novel_id,novel_title=novel_title,author=author,chapters=clean,
            kind="chapters",total=#clean,done=0,readable=0,skipped=0,failed=0,
            paused=false,running=false,
            finished=false,manifest=manifest,current_title="准备下载…"}
        self.download_task=task
        self:showDownloadProgress(task)
        UIManager:scheduleIn(0.05,function() self:downloadNovelStep(task) end)
    end)
end

function JJ:downloadCurrentNovelComments()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是晋江插件正文。") return end
    self:downloadNovelComments(ctx.novel_id,ctx.book,ctx.author)
end

local function is_temporary_network_error(err)
    local s=tostring(err or ""):lower()
    return s:find("host or service not provided",1,true)
        or s:find("name or service not known",1,true)
        or s:find("could not resolve",1,true)
        or s:find("network is unreachable",1,true)
        or s:find("connection timed out",1,true)
        or s:find("timeout",1,true)
        or s:find("temporary failure",1,true)
end

function JJ:downloadNovelCommentsStep(task)
    if task.finished or task.paused or task.running then return end
    if task.done>=task.total then
        task.finished=true
        local epub_path,epub_count=self:generateOfflineEpub(task.novel_id,task.novel_title,task.author,true)
        if task.dialog then task.refreshing=true; UIManager:close(task.dialog); task.dialog=nil end
        self.download_task=nil
        local done_text="整本段评下载完成。\n\n已缓存章节："..task.cached
            .."\n评论总数："..task.comments_total
            .."\n失败章节："..task.failed
            ..(task.last_error and ("\n最近错误："..tostring(task.last_error):sub(1,180)) or "")
            ..(epub_path and ("\n离线 EPUB：已写入段评（"..tostring(epub_count).." 章）")
                or "\n离线 EPUB：未能更新")
        -- Whole-book downloads used to update only the EPUB. If this novel's
        -- stable HTML is open, rebuild that chapter too so its badges appear
        -- immediately without leaving and reopening the book.
        local current=self:getCurrentChapterContext()
        local refreshed=false
        if current and tostring(current.novel_id)==tostring(task.novel_id) then
            local body=self:loadChapterCache(current.novel_id,current.book,current.chapter_id)
            if body then
                refreshed=true
                self:renderChapterData(current.novel_id,current.chapter_id,
                    current.book or task.novel_title,current.title or "当前章节",
                    current.author or task.author,body,true,true,false)
            end
        end
        if refreshed then
            UIManager:scheduleIn(1.2,function() msg(done_text.."\n当前 HTML：已刷新",6) end)
        else
            msg(done_text,6)
        end
        return
    end
    task.running=true
    local advance=true
    local c=task.chapters[task.done+1]
    local id=tostring(c.chapterid or c.chapterId or c.id)
    local title=tostring(c.chaptername or c.chapterName or c.name or id)
    task.current_title=title.." · 下载段评"
    if not task.dialog then self:showDownloadProgress(task) end
    local existing=self:loadParagraphChapterCache(task.novel_id,id)
    if existing then
        local root=type(existing.data)=="table" and existing.data or existing
        task.cached=task.cached+1
        task.comments_total=task.comments_total+(tonumber(root.commentTotal or 0) or 0)
    else
        local ctx={novel_id=task.novel_id,chapter_id=id,title=title}
        local function fetch_comments()
            self.client.bulk_download=true
            local ok_fetch,data,comment_err=pcall(function()
                local result,result_err=self:downloadChapterParagraphComments(ctx)
                return result,result_err
            end)
            self.client.bulk_download=false
            if not ok_fetch then return {ok=false,error=tostring(data)} end
            if not data then return {ok=false,error=tostring(comment_err or "未知错误")} end
            local saved,save_err=self:saveParagraphChapterCache(ctx,data)
            if not saved then return {ok=false,error=tostring(save_err or "写入失败")} end
            local root=type(data.data)=="table" and data.data or data
            return {ok=true,total=tonumber(root.commentTotal or 0) or 0}
        end
        local ok_tr,Trapper=pcall(require,"ui/trapper")
        local completed,result
        if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
            completed,result=Trapper:dismissableRunInSubprocess(fetch_comments,task.dialog)
        else
            completed=true; result=fetch_comments()
        end
        if not completed then
            task.running=false; task.paused=true
            task.current_title="已暂停，可稍后继续"
            self:showDownloadProgress(task)
            return
        end
        if type(result)=="table" and result.ok then
            task.cached=task.cached+1
            task.comments_total=task.comments_total+(result.total or 0)
        else
            task.last_error=tostring(type(result)=="table" and result.error or "后台下载失败")
            if is_temporary_network_error(task.last_error) then
                -- Do not burn through the rest of the book while DNS/Wi-Fi is
                -- unavailable. Keep the current index so Continue retries it.
                advance=false
                task.paused=true
                task.current_title=title.." · 网络错误，已暂停；联网后点继续"
            else
                task.failed=task.failed+1
            end
        end
    end
    if advance then task.done=task.done+1 end
    task.running=false
    if task.paused then
        self:showDownloadProgress(task)
        return
    end
    if task.done%5==0 or task.done>=task.total then self:showDownloadProgress(task) end
    if not task.paused then UIManager:scheduleIn(0.15,function() self:downloadNovelCommentsStep(task) end) end
end

function JJ:downloadNovelComments(novel_id,novel_title,author)
    if self.download_task and not self.download_task.finished then
        self:showDownloadProgress(self.download_task); return
    end
    local manifest=self:loadOfflineManifest(novel_id,novel_title)
    if not manifest or type(manifest.chapters)~="table" then
        msg("还没有整本正文缓存。\n\n请先运行“下载全部免费章和已购章”，再单独下载整本段评。")
        return
    end
    local clean={}
    for _,c in ipairs(manifest.chapters) do
        local cid=c.chapterid or c.chapterId or c.id
        if cid and tostring(c.chaptertype or c.chapterType or "0")~="1"
                and self:loadChapterCache(novel_id,novel_title,tostring(cid)) then
            clean[#clean+1]=c
        end
    end
    if #clean==0 then
        msg("没有找到已缓存的可读正文。请先下载整本正文。")
        return
    end
    self:runOnline(function()
        local first=clean[1]
        local first_title=tostring(first.chaptername or first.chapterName or first.name
            or first.chapterid or first.chapterId or first.id or "第 1 章")
        local task={kind="comments",novel_id=novel_id,novel_title=novel_title,author=author,
            chapters=clean,total=#clean,done=0,cached=0,failed=0,comments_total=0,
            paused=false,running=false,finished=false,
            current_title="第 1 / "..tostring(#clean).." 章："..first_title
                .."\n正在读取本章全部段评；评论多时可能需要数分钟，可点暂停。"}
        self.download_task=task
        self:showDownloadProgress(task)
        UIManager:scheduleIn(0.05,function() self:downloadNovelCommentsStep(task) end)
    end)
end

function JJ:chapterMenu(novel_id,chapter_id,novel_title,chapter_title,is_vip,author)
    local menu
    local items={
        {text=is_vip and "阅读正文（仅已购章节）" or "阅读正文",callback=function()
            self:openChapter(novel_id,chapter_id,novel_title,chapter_title,author)
        end},
        {text="按段查看段评",callback=function() self:promptParagraph(novel_id,chapter_id,chapter_title) end},
        {text="☁ 本章评论",callback=function() self:showComments(novel_id,chapter_id,chapter_title) end},
    }
    menu=Menu:new{title=chapter_title,item_table=items,close_callback=function() UIManager:close(menu) end}
    UIManager:show(menu)
end

function JJ:ensureDir(path)
    if lfs.attributes(path,"mode")~="directory" then
        local ok=lfs.mkdir(path)
        if not ok and lfs.attributes(path,"mode")~="directory" then return false end
    end
    return true
end

function JJ:getChapterNav(novel_id, chapter_id)
    novel_id=tostring(novel_id); chapter_id=tostring(chapter_id)
    local chapters=self.chapter_lists[novel_id]
    if not chapters then
        chapters=self.client:getChapterList(novel_id)
        if type(chapters)~="table" then return nil,nil end
        self.chapter_lists[novel_id]=chapters
    end
    local clean={}
    for _,c in ipairs(chapters) do
        local cid=c.chapterid or c.chapterId or c.id
        if cid and tostring(c.chaptertype or c.chapterType or "0")~="1" then
            clean[#clean+1]={
                id=tostring(cid),
                title=tostring(c.chaptername or c.chapterName or c.name or ("第"..tostring(cid).."章")),
                vip=tostring(c.isvip or c.isVip or "0")~="0" and tostring(c.isvip or c.isVip or "")~="false",
            }
        end
    end
    for i,c in ipairs(clean) do
        if c.id==chapter_id then return clean[i-1],clean[i+1] end
    end
    return nil,nil
end

function JJ:openAdjacentChapter(prev)
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是晋江插件正文。") return true end
    local id=prev and ctx.prev_id or ctx.next_id
    local title=prev and ctx.prev_title or ctx.next_title
    if not id or id=="" then msg(prev and "已经是第一章。" or "已经是最后一章。") return true end
    self:openChapter(ctx.novel_id,id,ctx.book or "晋江小说",title or ("第"..id.."章"),ctx.author or "",prev)
    return true
end

-- KOReader fires EndOfBook when the user turns past the final page.
-- For JJWXC chapter documents we consume that event and load the adjacent chapter,
-- so page-turning feels like a normal continuous book instead of separate HTML files.
function JJ:onEndOfBook()
    local ctx=self:getCurrentChapterContext()
    if not ctx then return false end
    if self._switching_chapter then return true end
    if ctx.next_id and ctx.next_id~="" then
        self._switching_chapter=true
        UIManager:scheduleIn(8.0,function() self._switching_chapter=false end)
        UIManager:nextTick(function() self:openAdjacentChapter(false) end)
    else
        msg("已经是最后一章。",2)
    end
    return true
end

function JJ:openChapter(novel_id,chapter_id,novel_title,chapter_title,author,open_at_end)
    if not self:backendReady() then return end
    local manifest=self:loadOfflineManifest(novel_id,novel_title)
    if manifest and type(manifest.chapters)=="table" then
        self.chapter_lists[tostring(novel_id)]=manifest.chapters
    end
    local cached=self:loadChapterCache(novel_id,novel_title,chapter_id)
    if cached then
        self:renderChapterData(novel_id,chapter_id,novel_title,chapter_title,author,cached,true,false,open_at_end)
        return
    end
    self:runOnline(function()
        msg("下载章节…",1)
        local data,err=self.client:getChapter(novel_id,chapter_id)
        if not data then msg("正文读取失败：\\n"..tostring(err)); return end
        self:saveChapterCache(novel_id,novel_title,chapter_id,data)
        self:renderChapterData(novel_id,chapter_id,novel_title,chapter_title,author,data,false,false,open_at_end)
    end)
end

function JJ:renderChapterData(novel_id,chapter_id,novel_title,chapter_title,author,data,from_cache,preserve_position,open_at_end)
        if not self:ensureDir(self.download_dir) then msg("无法创建目录："..self.download_dir); return end
        local book_dir=self:bookDir(novel_id,novel_title)
        self:ensureDir(book_dir)
        local novel_meta=self.novel_meta[tostring(novel_id)]
        if not novel_meta and not from_cache then
            local info=self.client:getNovelInfo(novel_id)
            if type(info)=="table" then
                novel_meta={
                    title=info.novelName or info.novelname or novel_title,
                    author=info.authorName or info.authorname or info.author or author,
                    cover=info.novelCover or info.novelcover or info.cover or "",
                }
                self.novel_meta[tostring(novel_id)]=novel_meta
            end
        end
        if novel_meta then
            novel_title=novel_meta.title or novel_title
            author=novel_meta.author or author
            book_dir=self:bookDir(novel_id,novel_title)
            self:ensureDir(book_dir)
        end
        local prev_ch,next_ch=self:getChapterNav(novel_id,chapter_id)

        -- Never block chapter opening on comment endpoints. Use the offline
        -- chapter-comment cache when available; manual comment downloads can
        -- refresh it without making every page turn wait on the network.
        local paragraph_counts={}
        local comment_cache=self:loadParagraphChapterCache(novel_id,chapter_id)
        local comment_root=type(comment_cache)=="table"
            and (type(comment_cache.data)=="table" and comment_cache.data or comment_cache) or {}
        local comment_rows=comment_root.commentList or comment_root.commentlist or comment_root.list or {}
        if type(comment_rows)=="table" then
            for _,row in ipairs(comment_rows) do
                local pid=tonumber(row._jj_pid or row.paragraph_id or row.paragraphId or row.paragraphid)
                if pid then paragraph_counts[pid]=(paragraph_counts[pid] or 0)+1 end
            end
        end

        -- 关键改动：每本晋江小说始终只使用一个固定 HTML 文件。
        -- 换章时覆盖同一个文件，KOReader/Simple UI 因而只会看到“一本书”。
        local file=self:bookShellPath(novel_id,novel_title)
        local f=io.open(file,"w")
        if not f then msg("无法写入："..file); return end
        f:write(Html.chapter(chapter_title,data.content,data.sayBodyV2 or data.sayBody,{
            book=novel_title,author=author,novel_id=novel_id,chapter_id=chapter_id,
            prev_id=prev_ch and prev_ch.id or "",prev_title=prev_ch and prev_ch.title or "",
            next_id=next_ch and next_ch.id or "",next_title=next_ch and next_ch.title or "",
            paragraph_counts=paragraph_counts,
        })); f:close()

        local pct=self:chapterProgressPercent(novel_id,chapter_id)
        self:updateStableBookMetadata(file,novel_title,author,pct)
        self:ensureStableBookCover(file,novel_meta and novel_meta.cover or "",book_dir)
        self.progress[tostring(novel_id)]={chapter_id=tostring(chapter_id),chapter_title=chapter_title,
            percent=pct,updated=os.time()}
        self:save()

        -- Remove old per-chapter history entries before returning to Simple UI.
        self:removeLegacyChapterEntries(novel_id,novel_title,file)

        local current=self.ui.document and self.ui.document.file or nil
        if current==file and self.ui.reloadDocument then
            self._switching_chapter=true
            local before_reload=nil
            if not preserve_position then
                before_reload=function() self:clearStableChapterPosition(file) end
            end
            self.ui:reloadDocument(before_reload,true,function()
                if open_at_end then
                    self:forceChapterEnd(file)
                elseif not preserve_position then
                    self:forceChapterStart(file)
                end
                UIManager:scheduleIn(1.0,function() self._switching_chapter=false end)
            end)
        elseif self.ui.document then
            self:clearStableChapterPosition(file)
            self._switching_chapter=true
            self.ui:switchDocument(file)
            if open_at_end then self:forceChapterEnd(file) else self:forceChapterStart(file) end
            UIManager:scheduleIn(1.0,function() self._switching_chapter=false end)
        else
            self:clearStableChapterPosition(file)
            self.ui:openFile(file)
            if open_at_end then self:forceChapterEnd(file) else self:forceChapterStart(file) end
        end

        -- KOReader may update history again during ReaderUI init; clean once more afterwards.
        for _,delay in ipairs({0.4,1.3,3.0}) do
            UIManager:scheduleIn(delay,function()
                self:removeLegacyChapterEntries(novel_id,novel_title,file)
            end)
        end
end


local function decode_html_text(t)
    t=tostring(t or "")
    t=t:gsub("<[^>]+>", " ")
    t=t:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    t=t:gsub("%s+", " ")
    return util.trim(t)
end

function JJ:getCurrentChapterContext()
    local doc=(self.ui and self.ui.document) or self.document
    local file=doc and doc.file
    if not file or not tostring(file):match("%.html$") then return nil end
    local f=io.open(file,"r")
    if not f then return nil end
    local raw=f:read("*a"); f:close()
    local novel_id=raw:match('<meta name="jjwxc%-novel%-id" content="([^"]*)">')
    local chapter_id=raw:match('<meta name="jjwxc%-chapter%-id" content="([^"]*)">')
    local book=decode_html_text(raw:match('<meta name="jjwxc%-book" content="([^"]*)">') or "")
    local author=decode_html_text(raw:match('<meta name="jjwxc%-author" content="([^"]*)">') or "")
    local prev_id=raw:match('<meta name="jjwxc%-prev%-id" content="([^"]*)">')
    local prev_title=decode_html_text(raw:match('<meta name="jjwxc%-prev%-title" content="([^"]*)">') or "")
    local next_id=raw:match('<meta name="jjwxc%-next%-id" content="([^"]*)">')
    local next_title=decode_html_text(raw:match('<meta name="jjwxc%-next%-title" content="([^"]*)">') or "")
    if not novel_id or novel_id=="" or not chapter_id or chapter_id=="" then return nil end
    local title=decode_html_text(raw:match('<meta name="jjwxc%-chapter%-title" content="([^"]*)">') or "当前章节")
    local paras={}
    for num,body in raw:gmatch('<p id="p(%d+)"[^>]*>(.-)</p>') do
        body=body:gsub('<a[^>]-class="pcnt"[^>]*>.-</a>','')
        body=body:gsub('<span class="pcnt">.-</span>','')
        paras[tonumber(num)]=decode_html_text(body)
    end
    return {novel_id=novel_id,chapter_id=chapter_id,title=title,paragraphs=paras,file=file,book=book,author=author,prev_id=(prev_id~="" and prev_id or nil),prev_title=prev_title,next_id=(next_id~="" and next_id or nil),next_title=next_title}
end

local function paragraph_link_id(link)
    local seen={}
    local function scan(value,depth)
        if depth>4 or value==nil then return nil end
        if type(value)=="string" then
            return tonumber(value:match("#jjwxc%-paragraph%-(%d+)"))
        end
        if type(value)~="table" or seen[value] then return nil end
        seen[value]=true
        for _,key in ipairs({"href","url","target","link","uri","dest","destination","src"}) do
            local pid=scan(value[key],depth+1)
            if pid then return pid end
        end
        for _,child in pairs(value) do
            local pid=scan(child,depth+1)
            if pid then return pid end
        end
    end
    return scan(link,0)
end

function JJ:removeParagraphTapHandler()
    if self._paragraph_tap_installed and self.ui then
        pcall(function()
            self.ui:unRegisterTouchZones({{id="jjwxc_paragraph_badge_tap",overrides={"tap_link"}}})
        end)
    end
    self._paragraph_tap_installed=nil
end

function JJ:installParagraphTapHandler()
    if not self.ui or not self.ui.link or self._paragraph_tap_installed then return end
    local ctx=self:getCurrentChapterContext()
    if not ctx then return end
    self.ui:registerTouchZones({{
        id="jjwxc_paragraph_badge_tap",
        ges="tap",
        screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
        overrides={"tap_link"},
        handler=function(ges)
            local ok,link=pcall(function() return self.ui.link:getLinkFromGes(ges) end)
            if not ok or not link then return false end
            local pid=paragraph_link_id(link)
            if not pid then return false end
            local current=self:getCurrentChapterContext()
            if not current then return false end
            local paragraph=current.paragraphs and current.paragraphs[pid] or ""
            self:showParagraphComments(current.novel_id,current.chapter_id,current.title,pid,paragraph)
            return true
        end,
    }})
    self._paragraph_tap_installed=true
end

-- A stable one-file-per-novel HTML intentionally contains only the chapter that
-- is currently being read. KOReader's built-in ToC therefore sees one heading.
-- For JJWXC documents, route the native ToC button to the novel's online chapter
-- list while leaving ReaderToc untouched for every other document.
function JJ:removeTocHandler()
    if self._toc_handler_owner and self._original_show_toc then
        self._toc_handler_owner.onShowToc=self._original_show_toc
    end
    self._toc_handler_owner=nil
    self._original_show_toc=nil
end

function JJ:installTocHandler()
    if not (self.ui and self.ui.toc and self.ui.toc.onShowToc) then return end
    if self._toc_handler_owner then return end
    local toc=self.ui.toc
    local original=toc.onShowToc
    local plugin=self
    toc.onShowToc=function(toc_self,...)
        local ctx=plugin:getCurrentChapterContext()
        if not ctx then return original(toc_self,...) end
        plugin:showChapters(ctx.novel_id,ctx.book~="" and ctx.book or "晋江小说",
            ctx.author or "",true,ctx.chapter_id)
        return true
    end
    self._toc_handler_owner=toc
    self._original_show_toc=original
end

-- ReaderRolling only emits EndOfBook at the forward boundary. It has no
-- matching event at the beginning, so intercept the shared relative-page
-- method. This covers taps, swipes, gestures and physical page-turn buttons.
function JJ:removePreviousChapterBoundaryHandler()
    if self._page_boundary_owner and self._original_goto_view_rel then
        self._page_boundary_owner.onGotoViewRel=self._original_goto_view_rel
    end
    self._page_boundary_owner=nil
    self._original_goto_view_rel=nil
end

function JJ:installPreviousChapterBoundaryHandler()
    local rolling=self.ui and self.ui.rolling
    if not rolling or not rolling.onGotoViewRel or self._page_boundary_owner then return end
    local original=rolling.onGotoViewRel
    local plugin=self
    rolling.onGotoViewRel=function(rolling_self,diff,...)
        if tonumber(diff) and tonumber(diff)<0 and not plugin._switching_chapter then
            local ctx=plugin:getCurrentChapterContext()
            local is_scroll=rolling_self.view and rolling_self.view.view_mode=="scroll"
            local at_start=is_scroll and (tonumber(rolling_self.current_pos) or 0)<=0
                or (not is_scroll and (tonumber(rolling_self.current_page) or 1)<=1)
            if ctx and at_start then
                if ctx.prev_id and ctx.prev_id~="" then
                    plugin._switching_chapter=true
                    UIManager:scheduleIn(8.0,function() plugin._switching_chapter=false end)
                    UIManager:nextTick(function() plugin:openAdjacentChapter(true) end)
                else
                    msg("已经是第一章。",2)
                end
                return true
            end
        end
        return original(rolling_self,diff,...)
    end
    self._page_boundary_owner=rolling
    self._original_goto_view_rel=original
end

function JJ:onReaderReady()
    local doc=(self.ui and self.ui.document) or self.document
    local file=doc and doc.file
    self:removeParagraphTapHandler()
    self:removeTocHandler()
    self:removePreviousChapterBoundaryHandler()
    if not file or not tostring(file):match("%.html$") then return end
    local f=io.open(file,"r")
    if not f then return end
    local raw=f:read("*a"); f:close()

    local nid=raw:match('<meta name="jjwxc%-novel%-id" content="([^"]*)">')
    local cid=raw:match('<meta name="jjwxc%-chapter%-id" content="([^"]*)">')
    local book=html_meta_text(raw:match('<meta name="jjwxc%-book" content="([^"]*)">') or "")
    local author=html_meta_text(raw:match('<meta name="jjwxc%-author" content="([^"]*)">') or "")
    local ctitle=html_meta_text(raw:match('<meta name="jjwxc%-chapter%-title" content="([^"]*)">') or "")

    local is_old_shell=raw:find('name="jjwxc%-book%-shell" content="1"')~=nil
    if is_old_shell and nid and nid~="" then
        local pr=self.progress[tostring(nid)]
        if pr and pr.chapter_id then
            UIManager:scheduleIn(0.15,function()
                local current=self.ui and self.ui.document and self.ui.document.file or nil
                if current==file then
                    self:openChapter(nid,tostring(pr.chapter_id),book~="" and book or "晋江小说",
                        tostring(pr.chapter_title or ("第"..pr.chapter_id.."章")),author)
                end
            end)
        end
        return
    end

    if nid and cid and book~="" then
        local stable=self:bookShellPath(nid,book)
        if file~=stable then
            -- 这是旧版本遗留的“单章文件”：自动迁移到固定整本书文件。
            UIManager:scheduleIn(0.15,function()
                local current=self.ui and self.ui.document and self.ui.document.file or nil
                if current==file then
                    self:openChapter(nid,cid,book,ctitle~="" and ctitle or ("第"..cid.."章"),author)
                end
            end)
        else
            local current_ctx=self:getCurrentChapterContext()
            self:applyReaderBookMetadata(current_ctx)
            self:installParagraphTapHandler()
            self:installTocHandler()
            self:installPreviousChapterBoundaryHandler()
            for _,delay in ipairs({0.15,0.8,2.0}) do
                UIManager:scheduleIn(delay,function()
                    self:removeLegacyChapterEntries(nid,book,stable)
                end)
            end
        end
    end
end

function JJ:onCloseDocument()
    local ctx=self:getCurrentChapterContext()
    if ctx then
        local pr=self.progress[tostring(ctx.novel_id)] or {}
        local pct=tonumber(pr.percent) or 0
        -- The HTML only contains one chapter, but Simple UI/KOReader history
        -- should show whole-novel progress rather than progress within that chapter.
        if self.ui and self.ui.doc_settings then
            pcall(function()
                self.ui.doc_settings:saveSetting("percent_finished",math.max(0,math.min(1,pct/100)))
                self.ui.doc_settings:flush()
            end)
        end
        pcall(function() self:updateStableBookMetadata(ctx.file,ctx.book,ctx.author,pct) end)
        pcall(function() UIManager:broadcastEvent(Event:new("InvalidateMetadataCache",ctx.file)) end)
        pcall(invalidate_simpleui_book_cache)
    end
    self:removeParagraphTapHandler()
    self:removeTocHandler()
    self:removePreviousChapterBoundaryHandler()
end

function JJ:addToHighlightDialog()
    if not (self.ui and self.ui.highlight) then return end
    self.ui.highlight:addToHighlightDialog("11_5_jjwxc_paragraph", function(this)
        return {
            text="晋江段评",
            show_in_highlight_dialog_func=function()
                return self:getCurrentChapterContext()~=nil
            end,
            callback=function()
                this:highlightFromHoldPos()
                local selected=this.selected_text and util.cleanupSelectedText(this.selected_text.text or "") or ""
                this:onClose(true)
                self:paragraphFromCurrentSelection(selected)
            end,
        }
    end)
end

function JJ:paragraphFromCurrentSelection(selected)
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是由晋江插件生成的正文。") return end
    selected=util.trim(tostring(selected or ""))
    local pid=nil
    if selected~="" then
        local needle=selected:gsub("%s+","")
        for i,t in pairs(ctx.paragraphs or {}) do
            if tostring(t):gsub("%s+",""):find(needle,1,true) then pid=i break end
        end
    end
    if not pid then
        self:promptParagraph(ctx.novel_id,ctx.chapter_id,ctx.title,ctx)
        return
    end
    self:paragraphActionDialog(ctx,pid,selected)
end

function JJ:paragraphActionDialog(ctx,pid,selected)
    local paragraph=(ctx.paragraphs and ctx.paragraphs[tonumber(pid)]) or selected or ""
    local dlg
    dlg=ButtonDialog:new{
        title="第 "..tostring(pid).." 段 · 晋江段评",
        buttons={
            {{text="查看真实段评",callback=function() UIManager:close(dlg); self:showParagraphComments(ctx.novel_id,ctx.chapter_id,ctx.title,pid,paragraph) end}},
            {{text="保存本地段评草稿",callback=function() UIManager:close(dlg); self:saveParagraphDraft(ctx,pid,paragraph) end}},
            {{text="关闭",callback=function() UIManager:close(dlg) end}},
        }
    }
    UIManager:show(dlg)
end

function JJ:promptParagraph(novel_id,chapter_id,chapter_title,ctx)
    ctx=ctx or self:getCurrentChapterContext()
    local d
    local maxp=ctx and ctx.paragraphs and #ctx.paragraphs or nil
    d=InputDialog:new{
        title="查看段评",
        input="",
        description=maxp and ("输入段落号（1–"..tostring(maxp).."）。也可以直接在正文用笔/长按选中文字，再点“晋江段评”。") or "输入正文段落号。",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="查看",is_enter_default=true,callback=function()
                local pid=tonumber(util.trim(d:getInputText() or ""))
                if not pid or pid<1 then msg("请输入有效段落号") return end
                local paragraph=ctx and ctx.paragraphs and ctx.paragraphs[pid] or ""
                UIManager:close(d)
                self:showParagraphComments(novel_id,chapter_id,chapter_title,pid,paragraph)
            end},
        }}
    }
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:showParagraphComments(novel_id,chapter_id,chapter_title,paragraph_id,paragraph_text)
    if not self:backendReady() then return end
    local cached=self:loadParagraphChapterCache(novel_id,chapter_id)
    if cached then
        self:showParagraphCommentsPopup(chapter_title,paragraph_id,paragraph_text,
            self:paragraphDataFromChapterCache(cached,paragraph_id))
        return
    end
    self:runOnline(function()
        msg("读取第 "..tostring(paragraph_id).." 段段评…",1)
        local data,err=self.client:getParagraphComments(novel_id,chapter_id,paragraph_id,2)
        if not data then msg("段评读取失败：\n"..tostring(err)); return end
        self:showParagraphCommentsPopup(chapter_title,paragraph_id,paragraph_text,data)
    end)
end

function JJ:showParagraphCommentsPopup(chapter_title,paragraph_id,paragraph_text,data)
        local root=type(data)=="table" and (type(data.data)=="table" and data.data or data) or {}
        local list=root.commentList or root.commentlist or root.list or {}
        if type(list)~="table" then list={} end
        local total=tonumber(root.commentTotal or root.commenttotal or root.total) or #list
        local lines={}
        if paragraph_text and paragraph_text~="" then
            lines[#lines+1]="原文"
            lines[#lines+1]="「"..decode_html_text(paragraph_text).."」"
            lines[#lines+1]=""
        end
        lines[#lines+1]="共 "..tostring(total).." 条段评"
        if type(list)=="table" then
            for i,c in ipairs(list) do
                local author=decode_html_text(c.commentAuthor or c.commentauthor or c.author or "匿名")
                local body=decode_html_text(c.commentBody or c.commentbody or c.body or "")
                local date=decode_html_text(c.commentDate or c.commentdate or c.date or "")
                local agree=c.agreenum or c.agreeNum or c.agree or 0
                lines[#lines+1]=""
                lines[#lines+1]="──────────"
                lines[#lines+1]=tostring(i)..". "..author
                    ..(date~="" and ("  ·  "..date) or "").."  ·  ♡ "..tostring(agree)
                lines[#lines+1]=body~="" and body or "（空内容）"
                local replies=c.replyAll or c.reply or {}
                if type(replies)=="table" then
                    for _,reply in ipairs(replies) do
                        local ra=decode_html_text(reply.replyAuthor or reply.commentauthor or reply.author or "")
                        local rb=decode_html_text(reply.replyBody or reply.commentbody or reply.body or "")
                        if rb~="" then lines[#lines+1]="  ↳ "..(ra~="" and (ra.."：") or "")..rb end
                    end
                end
            end
        end
        if #list==0 then
            lines[#lines+1]=""
            lines[#lines+1]="这一段暂时没有返回段评。"
        end
        UIManager:show(TextViewer:new{
            title=tostring(chapter_title or "当前章节").." · 第 "..tostring(paragraph_id).." 段",
            title_multilines=true,
            text=table.concat(lines,"\n"),
            text_type="book_info",
            add_default_buttons=true,
        })
end

function JJ:paragraphCacheFile(novel_id,chapter_id,create_dir)
    local dir=self.download_dir.."/段评缓存"
    if create_dir then
        if not self:ensureDir(self.download_dir) or not self:ensureDir(dir) then return nil end
    end
    return dir.."/"..safe_name(tostring(novel_id)).."_"..safe_name(tostring(chapter_id))..".json"
end

function JJ:loadParagraphChapterCache(novel_id,chapter_id)
    local file=self:paragraphCacheFile(novel_id,chapter_id,false)
    if not file or lfs.attributes(file,"mode")~="file" then return nil end
    local f=io.open(file,"rb"); if not f then return nil end
    local raw=f:read("*a"); f:close()
    local ok,wrapper=pcall(JSON.decode,raw or "")
    if not ok or type(wrapper)~="table" then return nil end
    return type(wrapper.data)=="table" and wrapper.data or wrapper
end

function JJ:saveParagraphChapterCache(ctx,data)
    local file=self:paragraphCacheFile(ctx.novel_id,ctx.chapter_id,true)
    if not file then return nil,"无法创建段评缓存目录" end
    local wrapper={cache_version=1,saved_at=os.time(),novel_id=tostring(ctx.novel_id),
        chapter_id=tostring(ctx.chapter_id),chapter_title=ctx.title,data=data}
    local ok,raw=pcall(JSON.encode,wrapper)
    if not ok or type(raw)~="string" then return nil,"段评缓存序列化失败："..tostring(raw) end
    local f=io.open(file,"wb"); if not f then return nil,"无法写入段评缓存" end
    f:write(raw); f:close()
    return true,file
end

function JJ:paragraphDataFromChapterCache(data,paragraph_id)
    local root=type(data.data)=="table" and data.data or data
    local rows=root.commentList or root.commentlist or root.list or {}
    local selected={}
    if type(rows)=="table" then
        for _,row in ipairs(rows) do
            local pid=tonumber(row._jj_pid or row.paragraph_id or row.paragraphId or row.paragraphid)
            if pid==tonumber(paragraph_id) then selected[#selected+1]=row end
        end
    end
    return {data={commentTotal=#selected,commentList=selected},cached=true}
end

function JJ:downloadChapterParagraphComments(ctx)
    local summary,summary_err=self.client:getParagraphCommentSummaryDiagnostic(ctx.novel_id,ctx.chapter_id)
    if not summary then return nil,"段评索引读取失败："..tostring(summary_err) end
    if type(summary)~="table" then return nil,"段评索引返回格式异常" end
    local sroot=type(summary.data)=="table" and summary.data or summary
    local index=sroot.paragraphList or sroot.paragraph_list or sroot.list or sroot
    if type(index)~="table" then return nil,"段评索引没有返回段落列表" end
    local combined={}
    local indexed=0
    for _,row in ipairs(index) do
        local pid=tonumber(row.paragraph_id or row.paragraphId or row.paragraphid)
        local expected=tonumber(row.comment_total or row.commentTotal or row.total or 0) or 0
        if pid and expected>0 then
            indexed=indexed+1
            local offset=0
            while offset<expected do
                local page,page_err=self.client:getParagraphComments(ctx.novel_id,ctx.chapter_id,pid,2,offset,100)
                if not page then return nil,"第 "..tostring(pid).." 段下载失败："..tostring(page_err) end
                local proot=type(page.data)=="table" and page.data or page
                local rows=proot.commentList or proot.commentlist or proot.list or {}
                if type(rows)~="table" then
                    return nil,"第 "..tostring(pid).." 段没有返回评论列表"
                end
                for _,comment in ipairs(rows) do
                    comment._jj_pid=pid
                    combined[#combined+1]=comment
                end
                if #rows<100 then break end
                offset=offset+#rows
            end
        end
    end
    return {code=summary.code,message=summary.message,
        data={commentTotal=#combined,commentList=combined,indexedParagraphs=indexed}},nil
end

function JJ:cacheCurrentChapterParagraphComments(force,show_result)
    local ctx=self:getCurrentChapterContext()
    if not ctx then if show_result then msg("当前不是晋江插件正文。") end return end
    if not force and self:loadParagraphChapterCache(ctx.novel_id,ctx.chapter_id) then return end
    self:runOnline(function()
        if show_result then msg("正在下载本章全部段评…",1) end
        local data,err=self:downloadChapterParagraphComments(ctx)
        if not data then if show_result then msg("离线段评下载失败：\n"..tostring(err)) end return end
        local ok,save_err=self:saveParagraphChapterCache(ctx,data)
        if not ok then if show_result then msg(tostring(save_err)) end return end
        -- Rebuild and reload the stable HTML immediately so newly downloaded
        -- badges appear without closing the book. Paragraph ids stay stable,
        -- therefore KOReader can preserve the current xpointer/page.
        local current=self:getCurrentChapterContext()
        local body=self:loadChapterCache(ctx.novel_id,ctx.book,ctx.chapter_id)
        if current and body and tostring(current.novel_id)==tostring(ctx.novel_id)
                and tostring(current.chapter_id)==tostring(ctx.chapter_id) then
            self:renderChapterData(ctx.novel_id,ctx.chapter_id,ctx.book or "晋江小说",
                ctx.title or "当前章节",ctx.author or "",body,true,true,false)
        end
        if show_result then
            local root=data.data or data
            msg("本章离线段评已保存。\n\n评论："..tostring(root.commentTotal or 0)
                .." 条\n有段评段落："..tostring(root.indexedParagraphs or 0).." 个",3)
        end
    end)
end

function JJ:saveParagraphDraft(ctx,pid,paragraph)
    local key=tostring(ctx.novel_id)..":"..tostring(ctx.chapter_id)..":"..tostring(pid)
    local d
    d=InputDialog:new{
        title="本地段评草稿 · 第 "..tostring(pid).." 段",
        input=self.paragraph_drafts[key] or "",
        description="这条先只保存在 Kobo 本机，不会自动发到晋江。你仍可以用 KOReader 的“Add note”保存私人笔记。",
        buttons={{
            {text="取消",id="close",callback=function() UIManager:close(d) end},
            {text="保存草稿",is_enter_default=true,callback=function()
                self.paragraph_drafts[key]=d:getInputText() or ""
                self:save(); UIManager:close(d); msg("段评草稿已保存在 Kobo 本机。")
            end},
        }}
    }
    UIManager:show(d); d:onShowKeyboard()
end

function JJ:showComments(novel_id,chapter_id,chapter_title)
    if not self:backendReady() then return end
    self:runOnline(function()
        msg("加载评论…",1)
        local raw,err=self.client:getChapterCommentsHTML(novel_id,chapter_id,1)
        if not raw then msg("评论读取失败："..tostring(err)); return end
        if not self:ensureDir(self.download_dir) then msg("无法创建评论缓存目录") return end
        local cdir=self.download_dir.."/评论缓存"; self:ensureDir(cdir)
        local file=cdir.."/"..tostring(novel_id).."_"..tostring(chapter_id).."_comments.html"
        local f=io.open(file,"w")
        if not f then msg("无法写入评论缓存") return end
        f:write(Html.comments(chapter_title,raw)); f:close()
        if self.ui.document then self.ui:switchDocument(file) else self.ui:openFile(file) end
    end)
end

function JJ:logout()
    self.token=""; self.account=""; self.client:setToken(""); self:save(); msg("已退出晋江登录")
end

function JJ:showDiagnostics()
    local lines={
        "JJWXC for KOReader v"..PLUGIN_VERSION,
        "",
        "主插件：已加载",
        "标准 KOReader 菜单：已注册",
        "功能模块："..((self.client and Html) and "正常" or "失败"),
        "登录状态："..((self.token or "")~="" and "已有 token" or "未登录"),
        "Simple UI："..(self.simpleui_error and "可选集成异常" or "未阻塞主插件"),
        "KOReader 手势/按键：已注册 9 个晋江动作",
        "离线 EPUB："..(Epub and "功能正常" or "模块加载失败"),
        "原生目录接管："..(self._toc_handler_owner and "当前已启用" or "仅在晋江正文启用"),
    }
    if self.backend_error then
        lines[#lines+1]=""
        lines[#lines+1]="功能模块错误："
        lines[#lines+1]=tostring(self.backend_error)
    end
    if self.highlight_error then
        lines[#lines+1]=""
        lines[#lines+1]="高亮菜单错误："
        lines[#lines+1]=tostring(self.highlight_error)
    end
    if self.simpleui_error then
        lines[#lines+1]=""
        lines[#lines+1]="Simple UI 错误："
        lines[#lines+1]=tostring(self.simpleui_error)
    end
    msg(table.concat(lines,"\n"))
end

local function diagnostic_value(data, keys)
    if type(data)~="table" then return nil end
    for _,key in ipairs(keys) do
        if data[key]~=nil then return data[key] end
    end
    if type(data.data)=="table" then
        for _,key in ipairs(keys) do
            if data.data[key]~=nil then return data.data[key] end
        end
    end
end

function JJ:showParagraphDiagnostics()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是由晋江插件生成的正文。") return end
    self:runOnline(function()
        msg("正在请求当前章节段评诊断…",1)
        local switch_data,switch_err=self.client:getParagraphSwitchDiagnostic(ctx.novel_id)
        local summary,summary_err=self.client:getParagraphCommentSummaryDiagnostic(ctx.novel_id,ctx.chapter_id)
        local all,all_err=self.client:getAllParagraphComments(ctx.novel_id,ctx.chapter_id,true)
        local lines={
            "当前章节段评诊断（v"..PLUGIN_VERSION.." / 网页端段评）",
            "novelId："..tostring(ctx.novel_id),
            "chapterId："..tostring(ctx.chapter_id),
            "",
            "作者段评开关接口："..(switch_data and "成功" or "失败"),
        }
        if switch_data then
            lines[#lines+1]="code："..tostring(switch_data.code or "(无)")
            lines[#lines+1]="message："..tostring(switch_data.message or "(无)")
            lines[#lines+1]="paragraph_switch："..tostring(diagnostic_value(switch_data,{"paragraph_switch","paragraphSwitch"}) or "(未返回)")
        else
            lines[#lines+1]="原始错误："..tostring(switch_err or "未知错误")
        end
        lines[#lines+1]=""
        lines[#lines+1]="段评数量接口："..(summary and "成功" or "失败")
        if summary then
            lines[#lines+1]="code："..tostring(summary.code or "(无)")
            lines[#lines+1]="message："..tostring(summary.message or "(无)")
            local root=type(summary.data)=="table" and summary.data or summary
            local list=root.paragraphList or root.paragraph_list or root.list or root
            lines[#lines+1]="data 数量："..tostring(#list)
            local shown=0
            for _,p in ipairs(list) do
                if type(p)=="table" and shown<8 then
                    local pid=p.paragraph_id or p.paragraphId or p.paragraphid
                    local total=p.comment_total or p.commentTotal or p.total
                    lines[#lines+1]="paragraph_id="..tostring(pid or "?").." / comment_total="..tostring(total or "?")
                    shown=shown+1
                end
            end
            if #list>shown then lines[#lines+1]="……另有 "..tostring(#list-shown).." 项" end
        else
            lines[#lines+1]="原始错误："..tostring(summary_err or "未知错误")
        end
        lines[#lines+1]=""
        lines[#lines+1]="旧安卓普通章评（仅作对照）："..(all and "成功" or "失败")
        if all then
            local root=type(all.data)=="table" and all.data or all
            local rows=root.commentList or root.commentlist or root.list or {}
            local paragraphs,matched,quoted=self.client:matchParagraphComments(all,ctx.paragraphs)
            local paragraph_total=0
            for _ in pairs(paragraphs) do paragraph_total=paragraph_total+1 end
            lines[#lines+1]="评论数量："..tostring(#rows)
            lines[#lines+1]="含引用原文："..tostring(quoted)
            lines[#lines+1]="成功匹配评论："..tostring(matched)
            lines[#lines+1]="有段评的段落："..tostring(paragraph_total)
            local shown=0
            for pid,total in pairs(paragraphs) do
                if shown>=8 then break end
                lines[#lines+1]="paragraph_id="..tostring(pid).." / comment_total="..tostring(total)
                shown=shown+1
            end
        else
            lines[#lines+1]="原始错误："..tostring(all_err or "未知错误")
        end
        msg(table.concat(lines,"\n"))
    end)
end

function JJ:refreshCurrentParagraphIndex()
    local ctx=self:getCurrentChapterContext()
    if not ctx then msg("当前不是由晋江插件生成的正文。") return end
    self:runOnline(function()
        msg("正在刷新本章段评索引…",1)
        local data,err=self.client:getParagraphCommentSummaryDiagnostic(ctx.novel_id,ctx.chapter_id)
        if not data then msg("段评索引读取失败：\n"..tostring(err or "未知错误")); return end
        local root=type(data.data)=="table" and data.data or data
        local list=root.paragraphList or root.paragraph_list or root.list or root
        local counts={}
        if type(list)=="table" then for _,row in ipairs(list) do
            local pid=tonumber(row.paragraph_id or row.paragraphId or row.paragraphid)
            local total=tonumber(row.comment_total or row.commentTotal or row.total or 0) or 0
            if pid and total>0 then counts[pid]=total end
        end end
        local paragraph_total=0
        for _ in pairs(counts) do paragraph_total=paragraph_total+1 end
        msg("段评索引已读取："..tostring(paragraph_total).." 个段落。\n正在刷新正文…",2)
        UIManager:scheduleIn(0.2,function()
            self:openChapter(ctx.novel_id,ctx.chapter_id,ctx.book or "晋江小说",ctx.title or "当前章节",ctx.author or "")
        end)
    end)
end

function JJ:showHelp()
    msg([[JJWXC for KOReader v0.4.41

• “晋江文学城”现在是标准 KOReader 插件菜单项，不依赖 Simple UI。
• 主菜单优先加载；网络、段评、HTML 或 Simple UI 出错时，整个插件不会再消失。
• 每本晋江小说只使用一个固定阅读文件，换章不会再生成新的“第XX章”书籍记录。
• 正文前面不显示段落序号；段落 ID 只在内部用于匹配段评。
• 有段评的段落末尾显示带下划线的纯数字；轻点数字即可打开段评弹窗。
• “当前章节段评诊断”会显示晋江网页端真实段评开关、code/message 和段落计数。
• v0.4.8 修正段评数量接口主机（不再访问会返回 403 的 .com 主机）。
• v0.4.9 可一次下载本章全部段评，并在本地按 paragraph_id 分组，不再依赖开关/数量摘要成功。
• v0.4.10 参考微读的原文定位方式：用 paragraph_content 与正文做精确/模糊匹配。
• v0.4.11 修复原文匹配器在 LuaJIT 下的加载语法错误。
• v0.4.12 不再把普通章评当段评；改用 android.jjwxc.net 的真实段评索引接口。
• v0.4.13 按晋江当前网页阅读器实现，改用已实测可返回 paragraph_id 的 Pc 段评接口。
• v0.4.14 换章后强制回到第一页；首页固定显示整本书名，并保存晋江作品封面。
• v0.4.15 将“晋江文学城”移到主工具菜单并优先排序，不再放在“更多工具”。
• v0.4.16 正文中的 💬数字可直接轻点打开该段段评，不再依赖长按选词。
• v0.4.17 阅读页的原生“目录”改为整本晋江在线目录，点章节可直接切换正文。
• v0.4.18 加入 Simple UI 快捷操作（书架/目录/上下章/段评）和 KOReader 手势/按键动作。
• v0.4.18 将整本章节进度写回 KOReader 书籍元数据，供 Simple UI 首页与历史记录显示。
• KOReader 原生词典、当前章搜索、阅读统计继续可用；书签/高亮暂不跨章节迁移。
• v0.4.19 增加晋江专用 Simple UI 图标，以及“刷新目录/购买状态”快捷操作。
• 目录会显示免费章和 VIP 章；插件不负责购买，未购章需在晋江 App/网页购买后刷新。
• v0.4.20 段评改为正文上方的可滚动弹窗；关闭后仍停留在原章节和原页。
• v0.4.21 联网时自动缓存当前整章段评；缓存完成后断网也能打开各段段评弹窗。
• 可用“下载 / 刷新本章离线段评”手动更新缓存；缓存按小说和章节分别保存。
• v0.4.22 兼容新旧 Simple UI 注册路径，并让“★ 晋江文学城”出现在创建快捷方式的插件列表。
• v0.4.23 可批量下载全书免费章和已购 VIP 章；目录会标出已购/免费缓存及未购状态。
• 已缓存正文可离线切换章节，仍只使用一个稳定阅读文件，不产生单章首页项目。
• v0.4.24 段评标记改为带下划线的纯数字，移除不兼容的气泡符号和整段正文虚线。
• v0.4.25 加入双模式：原有 HTML 用于联网阅读和段评弹窗；缓存章节可生成普通离线 EPUB。
• “下载全部免费章和已购章”结束后会自动重建 EPUB；也可单独选择“生成 / 更新离线 EPUB”。
• EPUB 会作为独立书籍出现在 KOReader / Simple UI，支持原生目录、书签、高亮、搜索和阅读统计；交互段评仍在 HTML 模式使用。
• v0.4.26 整本下载加入章节数、百分比和可视进度条，并可随时暂停或继续；已完成缓存不会丢失。
• v0.4.27 每章网络请求改在 KOReader 可取消的后台子进程中执行；下载时界面不再被网络请求锁住，点提示即可暂停。
• v0.4.28 保持自动连续下载，同时加入可取消的目录请求、明确的“暂停/继续”和“停止任务”；无需每几章手动确认。
• v0.4.29 修复 VIP 状态误判：只有晋江明确返回“未购买/需订阅”才显示未购；超时、登录或接口错误会显示真实失败原因并可重试。
• v0.4.30 下载期间只保留一个固定进度窗口，不再逐章关闭重开；点窗口任意位置即可暂停，进度每 10 章刷新一次以减少墨水屏闪烁。
• v0.4.32 将整本正文与整本段评拆成两个独立下载任务；段评任务只处理已经缓存成功的正文，支持暂停、继续、停止，并自动跳过已有段评缓存。
• v0.4.33 修正整本段评首章长时间显示“准备中”的误导状态；启动后立即显示第一章及耗时提示。
• v0.4.34 已缓存段评会写入离线 EPUB；正文后的数字使用 EPUB 脚注链接，轻点可在 KOReader 中弹窗查看。整本段评完成后自动更新同一个 EPUB。
• v0.4.35 移除会与 KOReader 页面 Show 事件冲突的兼容入口；翻到章节末尾后不再误触发“同步晋江书架”。延迟的旧章节迁移与跳首页动作也会核对当前文件，避免 HTML 与 EPUB 互相拉回。
• v0.4.36 菜单可直接打开本书离线 EPUB；在线 HTML 入口标识更清楚；断网或在线目录失败时自动使用整本下载保存的离线目录。
• v0.4.37 换章会在关闭旧文档后清除 last_xpointer，并在打开完成后立即跳到第一页；切章期间拦截重复的章节末尾事件。取消打开章节时自动下载整章段评，避免网络请求造成翻页卡顿。
• v0.4.38 离线 EPUB 段评补充标准 role/epub:type 与 CREngine 脚注提示，并扩大数字点击区域，减少点空后被当作普通翻页。
• v0.4.39 下载本章段评后会原地刷新并保留当前页；在 HTML 第一页继续向前翻会进入上一章末页。
• v0.4.40 整本段评遇到 DNS、断网或超时会停在当前章并自动暂停；联网后点继续即可重试，不再连续制造失败记录。
• v0.4.41 整本段评完成后立即刷新当前 HTML；EPUB 脚注内容从正文排版中隐藏，只在轻点数字时作为弹窗目标显示。
• v0.4.31 支持晋江已购 VIP 章节的整包动态 DES 加密响应，并兼容未标记 encryptType 的正文二次加密。
• 字体继续跟随 KOReader 当前字体，包括 Kobo 自定义字体。
• 如果有异常，请打开“晋江文学城 → 调试信息”。

公开发布段评仍暂不自动提交，避免误发。]])
end
return JJ
