local JSON = require("json")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Crypto = require("crypto")
local ok_sha2, sha2 = pcall(require, "ffi/sha2")

local Client = {}
Client.__index = Client

local function urlencode(s)
    s = tostring(s or "")
    return (s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function header_value(headers,name)
    if type(headers)~="table" then return nil end
    name=name:lower()
    for k,v in pairs(headers) do
        if tostring(k):lower()==name then return tostring(v) end
    end
end

local function decrypt_response_envelope(body,headers)
    if not (ok_sha2 and sha2 and sha2.md5) then return nil,"KOReader MD5 模块不可用" end
    local accesskey=header_value(headers,"accesskey")
    local keystring=header_value(headers,"keystring")
    body=tostring(body or "")
    if not accesskey or accesskey=="" or not keystring or keystring=="" or #body<=12 then
        return nil,"加密响应缺少 Accesskey/Keystring 响应头"
    end
    local sum=0
    for i=1,#accesskey do sum=sum+accesskey:byte(i) end
    local start=sum%#keystring
    local count=math.floor(sum/65)
    local finish=math.min(#keystring,start+count)
    local keypart=keystring:sub(start+1,finish)
    local salt,cipher
    if (accesskey:byte(-1) or 0)%2==1 then
        salt=body:sub(-12); cipher=body:sub(1,-13)
    else
        salt=body:sub(1,12); cipher=body:sub(13)
    end
    local key=sha2.md5(keypart..salt):sub(1,8)
    local iv=sha2.md5(salt):sub(1,8)
    return Crypto.des_cbc_pkcs7_base64_decrypt(cipher,key,iv)
end

local function decode_json(body,headers)
    local ok, data = pcall(JSON.decode, body or "")
    if ok then return data end
    local plain,derr=decrypt_response_envelope(body,headers)
    if plain then
        local decoded_ok,decoded=pcall(JSON.decode,plain)
        if decoded_ok then return decoded end
        return nil,"已解密响应，但 JSON 解析失败"
    end
    return nil,"JSON 解析失败（疑似晋江加密响应）："..tostring(derr or "未知格式")
end

local function random_digits(n)
    local t={}
    for i=1,n do t[i]=tostring(math.random(0,9)) end
    return table.concat(t)
end
local function random_hex(n)
    local h="0123456789abcdef"; local t={}
    for i=1,n do local p=math.random(1,16); t[i]=h:sub(p,p) end
    return table.concat(t)
end

function Client:new(opts)
    opts = opts or {}
    math.randomseed(os.time())
    return setmetatable({ token = opts.token or "", paragraph_chapter_cache = {} }, self)
end

function Client:setToken(token) self.token = token or "" end

function Client:request(url, opts)
    opts = opts or {}
    local sink = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or ("Mobile " .. tostring(os.time()))
    if opts.body then headers["content-length"] = tostring(#opts.body) end
    -- Bulk chapter downloads run in a cancellable subprocess. Keep their
    -- timeout bounded so a dead endpoint cannot leave a device waiting long.
    socketutil:set_timeout(opts.block_timeout or (self.bulk_download and 8 or 20),
        opts.total_timeout or (self.bulk_download and 20 or 45))
    local req = {
        url = url,
        method = opts.method or "GET",
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if opts.body then req.source = ltn12.source.string(opts.body) end
    local transport = url:match("^https://") and https or http
    local _, code, resp_headers, status = transport.request(req)
    socketutil:reset_timeout()
    local body = table.concat(sink)
    if tonumber(code) ~= 200 then
        return nil, string.format("HTTP %s %s", tostring(code), tostring(status or "")), resp_headers
    end
    return body, nil, resp_headers
end

function Client:getJSON(url, opts)
    local body, err, headers = self:request(url, opts)
    if not body then return nil, err, headers end
    local data, jerr = decode_json(body,headers)
    return data, jerr, headers
end

-- Login returns one of:
-- { ok=true, token=... }
-- { need_verification=true, message=... }
-- { error=... }
function Client:login(account, password, verify_code, checktype)
    account = tostring(account or "")
    password = tostring(password or "")
    verify_code = tostring(verify_code or "")
    checktype = tostring(checktype or "")
    if account == "" or password == "" then return { error="账号或密码不能为空" } end

    local key, iv = "KW8Dvm2N", "1ae2c94b"
    local enc_password = Crypto.des_cbc_pkcs7_base64(password, key, iv)
    local identifiers = random_digits(20) .. ":" .. random_hex(16) .. "d4:"
    local sign_plain = tostring(os.time()*1000) .. "_" .. identifiers .. "_"
    local sign = Crypto.des_cbc_pkcs7_base64(sign_plain, key, iv)
    local url = "https://app.jjwxc.org/androidapi/login?versionCode=402"
        .. "&loginName=" .. urlencode(account)
        .. "&encode=1&loginPassword=" .. urlencode(enc_password)
        .. "&sign=" .. urlencode(sign)
        .. "&identifiers=" .. urlencode(identifiers)
        .. "&autologin=1"
    if verify_code ~= "" and (checktype == "phone" or checktype == "email") then
        url = url .. "&checktype=" .. checktype .. "&checkdevicecode=" .. urlencode(verify_code)
    end
    local headers = {
        ["User-Agent"] = "Mobile " .. tostring(os.time()*1000),
        ["Accept-Encoding"] = "identity",
        ["Referer"] = "http://android.jjwxc.net?v=402",
    }
    local data, err = self:getJSON(url, {headers=headers})
    if not data then return { error=err or "登录请求失败" } end
    if data.token and tostring(data.token) ~= "" then
        self.token = tostring(data.token)
        return {ok=true, token=self.token, message=data.message}
    end
    if tostring(data.code or "") == "221003" and verify_code == "" then
        return {need_verification=true, message=data.message or "晋江要求设备验证，请选择手机或邮箱接收验证码。"}
    end
    return {error=(data.message or ("登录失败（code="..tostring(data.code or "?").."）"))}
end

function Client:sendVerificationCode(account, checktype)
    account = tostring(account or "")
    checktype = tostring(checktype or "phone")
    if account == "" then return nil, "账号不能为空" end
    if checktype ~= "phone" and checktype ~= "email" then return nil, "未知验证码方式" end

    -- Current third-party clients use versionCode=401 on the device-security endpoint.
    local verify_url = "https://app.jjwxc.org//appDevicesecurityAndroid/getDeviceSecurityCode"
    local body = "versionCode=401&username=" .. urlencode(account) .. "&checktype=" .. checktype
    local headers = {
        ["User-Agent"] = "Mobile " .. tostring(os.time()*1000),
        ["Accept-Encoding"] = "identity",
        ["Content-Type"] = "application/x-www-form-urlencoded",
    }
    local data, err = self:getJSON(verify_url, {method="POST", body=body, headers=headers})
    if not data then return nil, err or "验证码发送请求失败" end
    local message = (data.data and data.data.message) or data.message
    -- Do not treat an error response as though a code was sent.
    local code = tostring(data.code or "")
    if code == "1004" or (message and (message:find("失败",1,true) or message:find("错误",1,true))) then
        return nil, message or ("验证码发送失败（code="..code.."）")
    end
    if not message or message == "" then
        return nil, "晋江没有确认验证码已发送（code="..code.."）"
    end
    return message, nil
end

function Client:getShelf()
    if self.token == "" then return nil, "请先登录晋江" end
    local url = "https://app.jjwxc.org/androidapi/incrementFavorite?versionCode=185&token="
        .. urlencode(self.token) .. "&backupTime=1041350400&order=1"
    local data, err = self:getJSON(url)
    if not data then return nil, err end
    local list = data.addData or (data.data and (data.data.addData or data.data.list)) or data.list
    if type(list) ~= "table" then return nil, data.message or "未识别到书架数据；晋江接口可能已变化" end
    return list
end

function Client:getNovelInfo(novel_id)
    local url = "https://app.jjwxc.net/androidapi/novelbasicinfo?novelId=" .. urlencode(novel_id)
    return self:getJSON(url)
end

function Client:getChapterList(novel_id)
    local url = "https://app.jjwxc.net/androidapi/chapterList?novelId=" .. urlencode(novel_id) .. "&more=0&whole=1"
    local data, err = self:getJSON(url)
    if not data then return nil, err end
    return data.chapterlist or data.data or data
end

function Client:getChapter(novel_id, chapter_id)
    local url = "https://app.jjwxc.net/androidapi/chapterContent?novelId=" .. urlencode(novel_id)
        .. "&chapterId=" .. urlencode(chapter_id) .. "&versionCode=381"
    if self.token ~= "" then url = url .. "&token=" .. urlencode(self.token) end
    local data, err = self:getJSON(url, {headers={
        ["Referer"]="http://android.jjwxc.net?v=381",
        ["User-Agent"]="JINJIANG-Android/381 KOReader-JJWXC/0.3.1",
        ["Accept-Encoding"]="identity",
    }})
    if not data then return nil, err end
    -- Some server variants wrap chapter fields in `data`; normalize before
    -- checking content so a valid purchased chapter is not mistaken as empty.
    if type(data.data)=="table" and (data.data.content~=nil or data.data.encryptType~=nil) then
        local envelope=data
        data=data.data
        data.code=data.code or envelope.code
        data.message=data.message or envelope.message
    end
    -- Purchased chapters can be returned with fields encrypted by the same DES key used by the app.
    if data.encryptType == "jj" and type(data.encryptField) == "table" then
        local key,iv="KW8Dvm2N","1ae2c94b"
        for _,f in ipairs(data.encryptField) do
            if (f=="content" or f=="sayBodyV2" or f=="sayBody") and type(data[f])=="string" and data[f]~="" then
                local plain,derr=Crypto.des_cbc_pkcs7_base64_decrypt(data[f],key,iv)
                if plain then data[f]=plain else return nil,"已购章节解密失败："..tostring(derr) end
            end
        end
    end
    -- VIP responses do not always advertise encryptType even though the
    -- individual content fields are still DES/Base64 encrypted.
    for _,f in ipairs({"content","sayBodyV2","sayBody"}) do
        local value=data[f]
        if type(value)=="string" and #value>=16 and #value%4==0
                and value:match("^[A-Za-z0-9+/=]+$") then
            local plain=Crypto.des_cbc_pkcs7_base64_decrypt(value,"KW8Dvm2N","1ae2c94b")
            if plain and not plain:find("[%z\1-\8\11\12\14-\31]") then data[f]=plain end
        end
    end
    if not data.content or data.content == "" then
        return nil, tostring(data.message or ("本章没有返回正文（code="..tostring(data.code or "无").."）"))
    end
    return data
end


local function comments_root(data)
    if type(data)~="table" then return nil,nil end
    local root=(type(data.data)=="table") and data.data or data
    local list=root.commentList or root.commentlist or root.list or root.body
    return root,list
end

local function paragraph_number_from_comment(c)
    if type(c)~="table" then return nil end
    -- The API has changed names across app versions. Search recursively for a
    -- numeric field whose key mentions paragraph, rather than pinning one spelling.
    local function scan(t,depth)
        if depth>3 or type(t)~="table" then return nil end
        for k,v in pairs(t) do
            local lk=tostring(k):lower():gsub("[_%-]","")
            if lk:find("paragraph",1,true) then
                local n=tonumber(v)
                if n and n>=0 then return n end
            end
        end
        for _,v in pairs(t) do
            if type(v)=="table" then
                local n=scan(v,depth+1); if n then return n end
            end
        end
    end
    return scan(c,0)
end

function Client:getChapterCommentData(novel_id, chapter_id, sort_mode)
    if self.token == "" then return nil, "请先登录晋江" end
    sort_mode=sort_mode or 2
    local params="versionCode=439&limit=200&offset=0&commentSort="..tostring(sort_mode)
        .."&token="..urlencode(self.token).."&novelId="..urlencode(novel_id).."&chapterId="..urlencode(chapter_id)
    local headers={
        ["User-Agent"]="JINJIANG-Android/439 KOReader-JJWXC/0.4.2",
        ["Referer"]="http://android.jjwxc.net/?v=439",
        ["Accept-Encoding"]="identity",
        ["versiontype"]="reading",
        ["Content-Type"]="application/x-www-form-urlencoded",
    }
    -- Current clients primarily use the GET form; POST is a compatibility fallback.
    local url="https://android.jjwxc.net/comment/getCommentList?"..params
    local data,err=self:getJSON(url,{headers=headers})
    if not data then
        data,err=self:getJSON("https://android.jjwxc.net/comment/getCommentList",{method="POST",body=params,headers=headers})
    end
    if not data then return nil,err end
    return data
end

local function normalized_runes(value)
    value=tostring(value or "")
    value=value:gsub("<[^>]+>",""):gsub("&nbsp;"," "):gsub("&amp;","&")
    value=value:gsub("[%s%p]","")
    value=value:gsub("，",""):gsub("。",""):gsub("！",""):gsub("？","")
        :gsub("；",""):gsub("：",""):gsub("、",""):gsub("‘",""):gsub("’","")
        :gsub("“",""):gsub("”",""):gsub("（",""):gsub("）",""):gsub("【","")
        :gsub("】",""):gsub("《",""):gsub("》",""):gsub("…",""):gsub("—",""):gsub("·","")
    local out={}; local i=1
    while i<=#value do
        local b=value:byte(i); local n=(b<0x80 and 1) or (b<0xE0 and 2) or (b<0xF0 and 3) or 4
        out[#out+1]=value:sub(i,i+n-1); i=i+n
    end
    return out,table.concat(out)
end

local function similarity(a,b)
    local ar,as=normalized_runes(a); local br,bs=normalized_runes(b)
    if #ar==0 or #br==0 then return 0 end
    if #ar>=6 and (as:find(bs,1,true) or bs:find(as,1,true)) then return 1 end
    local function grams(r)
        local g={}; for i=1,#r-1 do local k=r[i]..r[i+1]; g[k]=(g[k] or 0)+1 end; return g
    end
    local ag,bg=grams(ar),grams(br); local common,total=0,0
    for _,n in pairs(ag) do total=total+n end
    for _,n in pairs(bg) do total=total+n end
    for k,n in pairs(ag) do common=common+math.min(n,bg[k] or 0) end
    return total>0 and (2*common/total) or 0
end

local function comment_quote(row)
    return row.paragraph_content or row.paragraphContent or row.paragraph_text or row.paragraphText
        or row.quote_content or row.quoteContent or row.contextAbstract or row.abstract or ""
end

function Client:matchParagraphComments(data, paragraphs)
    local root=type(data)=="table" and (data.data or data) or nil
    local list=type(root)=="table" and (root.commentList or root.commentlist or root.list) or nil
    local counts={}; local matched=0; local quoted=0
    if type(list)~="table" or type(paragraphs)~="table" then return counts,matched,quoted end
    for _,row in ipairs(list) do
        local pid=tonumber(row.paragraph_id or row.paragraphId or row.paragraphid)
        local quote=comment_quote(row)
        if quote~="" then quoted=quoted+1 end
        if not pid or pid<=0 or not paragraphs[pid] then
            local best,best_score=nil,0
            if quote~="" then
                for i,text in ipairs(paragraphs) do
                    local score=similarity(quote,text)
                    if score>best_score then best,best_score=i,score end
                    if score==1 then break end
                end
            end
            if best and best_score>=0.52 then pid=best end
        end
        if pid and pid>0 and paragraphs[pid] then
            row._jj_pid=pid
            counts[pid]=(counts[pid] or 0)+1
            matched=matched+1
        end
    end
    return counts,matched,quoted
end

function Client:getParagraphCommentSummary(novel_id, chapter_id, paragraphs)
    if self.token == "" then return {} end
    local counts={}
    local data=self:getParagraphCommentSummaryDiagnostic(novel_id,chapter_id)
    if type(data)=="table" then
        local root=type(data.data)=="table" and data.data or data
        local list=root.paragraphList or root.paragraph_list or root.list or root
        if type(list)=="table" then for _,p in ipairs(list) do
            local pid=tonumber(p.paragraph_id or p.paragraphId or p.paragraphid)
            local total=tonumber(p.comment_total or p.commentTotal or p.total or 0) or 0
            if pid and pid >= 0 and total > 0 then counts[pid]=total end
        end end
    end
    return counts
end

function Client:getAllParagraphComments(novel_id, chapter_id, force)
    if self.token == "" then return nil,"请先登录晋江" end
    local cache_key=tostring(novel_id)..":"..tostring(chapter_id)
    if not force and self.paragraph_chapter_cache[cache_key] then
        return self.paragraph_chapter_cache[cache_key]
    end
    local version="489"
    local limit=500
    local combined={}
    local total=nil
    local last_envelope=nil
    for offset=0,4500,limit do
        local params="versionCode="..version
            .."&offset="..tostring(offset).."&limit="..tostring(limit).."&commentSort=0"
            .."&token="..urlencode(self.token)
            .."&novelId="..urlencode(novel_id)
            .."&chapterId="..urlencode(chapter_id)
        local headers={
            ["versionCode"]=version,["version-code"]=version,["source"]="android",
            ["versiontype"]="reading",
            ["User-Agent"]="JINJIANG-Android/"..version.." KOReader-JJWXC/0.4.10",
            ["Referer"]="http://android.jjwxc.net/?v="..version,
            ["Accept-Encoding"]="identity",
            ["Content-Type"]="application/x-www-form-urlencoded",
        }
        local endpoint="https://app.jjwxc.org/app.jjwxc/android/reading/comment/getCommentList"
        local page,err=self:getJSON(endpoint.."?"..params,{headers=headers})
        if not page then page,err=self:getJSON(endpoint,{method="POST",body=params,headers=headers}) end
        if not page then return nil,err end
        last_envelope=page
        local root=type(page.data)=="table" and page.data or page
        local rows=root.commentList or root.commentlist or root.list
        if type(rows)~="table" then return nil,page.message or "整章段评接口没有返回评论列表" end
        total=tonumber(root.commentTotal or root.commenttotal or root.total) or total or #rows
        for _,row in ipairs(rows) do combined[#combined+1]=row end
        if #rows<limit or #combined>=total then break end
    end
    local result={
        code=last_envelope and last_envelope.code,
        message=last_envelope and last_envelope.message,
        data={commentTotal=total or #combined,commentList=combined},
    }
    self.paragraph_chapter_cache[cache_key]=result
    return result,nil
end

function Client:getParagraphSwitchDiagnostic(novel_id)
    -- The public chapter page uses the PC endpoint. It requires authorid as
    -- well as novelid, so obtain it from the existing novel-info endpoint.
    local info,info_err=self:getNovelInfo(novel_id)
    if not info then return nil,"作者信息读取失败："..tostring(info_err or "未知错误") end
    local root=type(info.data)=="table" and info.data or info
    local author_id=root.authorid or root.authorId or root.author_id
    if not author_id and type(root.novelInfo)=="table" then
        author_id=root.novelInfo.authorid or root.novelInfo.authorId or root.novelInfo.author_id
    end
    if not author_id or tostring(author_id)=="" then return nil,"作品信息未返回 authorid" end
    local url="https://www.jjwxc.net/app.jjwxc/Pc/authorNovelSetting/getSetting"
        .."?authorid="..urlencode(author_id)
        .."&novelid="..urlencode(novel_id)
        .."&setting_type=author_paragraph_comment_switch"
    return self:getJSON(url,{headers={
        ["User-Agent"]="Mozilla/5.0 KOReader-JJWXC/0.4.39",
        ["Referer"]="https://www.jjwxc.net/onebook.php?novelid="..urlencode(novel_id),
        ["Accept-Encoding"]="identity",
    }})
end

function Client:getParagraphCommentSummaryDiagnostic(novel_id, chapter_id)
    -- This is the endpoint used by onebook.paragraph.comment.js on JJWXC's
    -- current desktop reader. Unlike the Android route, it returns the real
    -- paragraph index without a device signature.
    local endpoint="https://www.jjwxc.net/app.jjwxc/Pc/comment/getNovelParagraphCommentNum"
    local params="novelid="..urlencode(novel_id).."&chapterid="..urlencode(chapter_id)
    local headers={
        ["User-Agent"]="Mozilla/5.0 KOReader-JJWXC/0.4.39",
        ["Referer"]="https://www.jjwxc.net/onebook.php?novelid="..urlencode(novel_id).."&chapterid="..urlencode(chapter_id),
        ["Accept-Encoding"]="identity",
    }
    local data,err=self:getJSON(endpoint.."?"..params,{headers=headers})
    if not data then return nil,err end
    return data,nil
end

function Client:getParagraphComments(novel_id, chapter_id, paragraph_id, sort_mode, offset, limit)
    if self.token == "" then return nil, "请先登录晋江" end
    offset=tonumber(offset) or 0
    limit=tonumber(limit) or 100
    local url="https://www.jjwxc.net/app.jjwxc/Pc/comment/getCommentList"
        .."?novelId="..urlencode(novel_id)
        .."&chapterId="..urlencode(chapter_id)
        .."&paragraph_id="..urlencode(paragraph_id)
        .."&offset="..tostring(offset).."&limit="..tostring(limit)
    local data,err=self:getJSON(url,{headers={
        ["User-Agent"]="Mozilla/5.0 KOReader-JJWXC/0.4.39",
        ["Referer"]="https://www.jjwxc.net/onebook.php?novelid="..urlencode(novel_id).."&chapterid="..urlencode(chapter_id),
        ["Accept-Encoding"]="identity",
    }})
    if not data then return nil,err end
    return data
end

function Client:getChapterCommentsHTML(novel_id, chapter_id, page)
    page = page or 1
    local url = "https://www.jjwxc.net/comment.php?novelid=" .. urlencode(novel_id)
        .. "&chapterid=" .. urlencode(chapter_id) .. "&page=" .. tostring(page)
    return self:request(url)
end

return Client
