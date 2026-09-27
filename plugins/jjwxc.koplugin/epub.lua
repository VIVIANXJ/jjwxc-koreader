local bit=require("bit")

local E={}
local function le16(n) return string.char(bit.band(n,255),bit.band(bit.rshift(n,8),255)) end
local function le32(n) return le16(bit.band(n,65535))..le16(bit.band(bit.rshift(n,16),65535)) end
local crc_table={}
for i=0,255 do
    local c=i
    for _=1,8 do c=bit.bxor(bit.rshift(c,1),bit.band(c,1)~=0 and 0xEDB88320 or 0) end
    crc_table[i]=c
end
local function crc32(s)
    local c=0xFFFFFFFF
    for i=1,#s do c=bit.bxor(bit.rshift(c,8),crc_table[bit.band(bit.bxor(c,s:byte(i)),255)]) end
    return bit.band(bit.bnot(c),0xFFFFFFFF)
end
local function esc(s)
    return (tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
local function comment_text(s)
    s=tostring(s or "")
    s=s:gsub("<br%s*/?>","\n"):gsub("<[^>]+>","")
    s=s:gsub("&nbsp;"," "):gsub("&amp;","&"):gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"')
    return s
end
local function zip_store(path,files)
    local f=io.open(path,"wb"); if not f then return nil,"无法写入 EPUB" end
    local central={}; local offset=0
    for _,e in ipairs(files) do
        local name,data=e[1],e[2]; local crc=crc32(data)
        local local_header="PK\003\004"..le16(20)..le16(0)..le16(0)..le16(0)..le16(0)
            ..le32(crc)..le32(#data)..le32(#data)..le16(#name)..le16(0)..name
        f:write(local_header,data)
        central[#central+1]="PK\001\002"..le16(20)..le16(20)..le16(0)..le16(0)..le16(0)..le16(0)
            ..le32(crc)..le32(#data)..le32(#data)..le16(#name)..le16(0)..le16(0)..le16(0)
            ..le16(0)..le32(0)..le32(offset)..name
        offset=offset+#local_header+#data
    end
    local cd=table.concat(central)
    f:write(cd,"PK\005\006",le16(0),le16(0),le16(#files),le16(#files),le32(#cd),le32(offset),le16(0))
    f:close(); return true
end

function E.build(path,meta,chapters)
    local files={{"mimetype","application/epub+zip"}}
    files[#files+1]={"META-INF/container.xml",[[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]]}
    local nav,manifest,spine={},{},{}
    if meta.cover_data and meta.cover_data~="" then
        local ext=meta.cover_ext=="png" and "png" or "jpg"
        local media=ext=="png" and "image/png" or "image/jpeg"
        files[#files+1]={"OEBPS/cover."..ext,meta.cover_data}
        manifest[#manifest+1]='<item id="cover-image" href="cover.'..ext..'" media-type="'..media..'" properties="cover-image"/>'
    end
    for i,ch in ipairs(chapters) do
        local name=string.format("chapter-%04d.xhtml",i)
        nav[#nav+1]='<li><a href="'..name..'">'..esc(ch.title)..'</a></li>'
        manifest[#manifest+1]='<item id="c'..i..'" href="'..name..'" media-type="application/xhtml+xml"/>'
        spine[#spine+1]='<itemref idref="c'..i..'"/>'
        local ps={}
        local notes={}
        for paragraph_id,line in ipairs(ch.paragraphs or {}) do
            local comments=type(ch.comments)=="table" and ch.comments[paragraph_id] or nil
            local badge=""
            if type(comments)=="table" and #comments>0 then
                local note_id="note-"..tostring(i).."-"..tostring(paragraph_id)
                badge=' <a class="pcnt" epub:type="noteref" href="#'..note_id..'">'..tostring(#comments)..'</a>'
                local rows={}
                for _,c in ipairs(comments) do
                    local author=comment_text(c.commentAuthor or c.commentauthor or c.author or "匿名")
                    local body=comment_text(c.commentBody or c.commentbody or c.body or "")
                    local date=comment_text(c.commentDate or c.commentdate or c.date or "")
                    rows[#rows+1]='<p><strong>'..esc(author)..'</strong>'
                        ..(date~="" and (' <small>'..esc(date)..'</small>') or "")
                        ..'<br/>'..esc(body)..'</p>'
                    local replies=c.replyList or c.replylist or c.replies
                    if type(replies)=="table" then
                        for _,reply in ipairs(replies) do
                            local ra=comment_text(reply.replyAuthor or reply.commentauthor or reply.author or "")
                            local rb=comment_text(reply.replyBody or reply.commentbody or reply.body or "")
                            rows[#rows+1]='<p class="reply">↳ '..esc(ra)..'：'..esc(rb)..'</p>'
                        end
                    end
                end
                notes[#notes+1]='<aside class="footnote" epub:type="footnote" id="'..note_id..'"><h2>第 '
                    ..tostring(paragraph_id)..' 段 · '..tostring(#comments)..' 条段评</h2>'
                    ..table.concat(rows,"\n")..'</aside>'
            end
            ps[#ps+1]="<p>"..esc(line)..badge.."</p>"
        end
        if ch.say and ch.say~="" then ps[#ps+1]="<hr/><h2>作者有话说</h2><p>"..esc(ch.say).."</p>" end
        files[#files+1]={"OEBPS/"..name,'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN"><head><title>'..esc(ch.title)..'</title><link rel="stylesheet" type="text/css" href="style.css"/></head><body><h1>'..esc(ch.title)..'</h1>'..table.concat(ps,"\n")..table.concat(notes,"\n")..'</body></html>'}
    end
    files[#files+1]={"OEBPS/style.css","body{line-height:1.7;margin:5%;}h1{font-size:1.4em;}p{text-align:justify;margin:.75em 0;}.pcnt{text-decoration:underline;font-size:.8em;}.footnote{display:none}.reply{margin-left:1.2em;font-size:.9em}small{opacity:.7}"}
    files[#files+1]={"OEBPS/nav.xhtml",'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><h1>目录</h1><ol>'..table.concat(nav)..'</ol></nav></body></html>'}
    files[#files+1]={"OEBPS/package.opf",'<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">jjwxc-'..esc(meta.novel_id)..'</dc:identifier><dc:title>'..esc(meta.title)..'</dc:title><dc:creator>'..esc(meta.author)..'</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">'..os.date("!%Y-%m-%dT%H:%M:%SZ")..'</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="style.css" media-type="text/css"/>'..table.concat(manifest)..'</manifest><spine>'..table.concat(spine)..'</spine></package>'}
    return zip_store(path,files)
end
return E
