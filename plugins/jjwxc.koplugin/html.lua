local H = {}
local function esc(s)
    s=tostring(s or "")
    return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"))
end
local function lines(s)
    s=tostring(s or "")
    s=s:gsub("&lt;br&gt;","\n"):gsub("<br%s*/?>","\n")
    local t={}
    for line in (s.."\n"):gmatch("(.-)\n") do
        line=line:gsub("^%s+",""):gsub("%s+$","")
        if line~="" then t[#t+1]=line end
    end
    return t
end
function H.paragraph_lines(content)
    return lines(content)
end
function H.chapter(title, content, saybody, meta)
    meta=meta or {}
    local ps={}
    local paragraph_texts=lines(content)
    local counts=meta.paragraph_counts or {}
    for i,line in ipairs(paragraph_texts) do
        local n=counts[i] or 0
        local badge=n>0 and ('<a id="jjwxc-paragraph-'..tostring(i)..'" class="pcnt" href="#jjwxc-paragraph-'..tostring(i)..'">'..tostring(n)..'</a>') or ""
        local class=n>0 and ' class="has-comments"' or ""
        ps[#ps+1]=string.format('<p id="p%d" data-jj-paragraph="%d"%s>%s%s</p>',i,i,class,esc(line),badge)
    end
    local say=""
    if saybody and tostring(saybody)~="" then
        local ss={}; for _,line in ipairs(lines(saybody)) do ss[#ss+1]="<p>"..esc(line).."</p>" end
        say='<section class="author"><h3>作者有话说</h3>'..table.concat(ss,'\n')..'</section>'
    end
    local sub={}
    if meta.book then sub[#sub+1]=esc(meta.book) end
    if meta.author then sub[#sub+1]=esc(meta.author) end
    local metas=string.format('<meta name="author" content="%s"><meta name="jjwxc-novel-id" content="%s"><meta name="jjwxc-chapter-id" content="%s"><meta name="jjwxc-book" content="%s"><meta name="jjwxc-author" content="%s"><meta name="jjwxc-chapter-title" content="%s"><meta name="jjwxc-prev-id" content="%s"><meta name="jjwxc-prev-title" content="%s"><meta name="jjwxc-next-id" content="%s"><meta name="jjwxc-next-title" content="%s">',esc(meta.author or ""),esc(meta.novel_id or ""),esc(meta.chapter_id or ""),esc(meta.book or ""),esc(meta.author or ""),esc(title or ""),esc(meta.prev_id or ""),esc(meta.prev_title or ""),esc(meta.next_id or ""),esc(meta.next_title or ""))
    -- Keep the document title stable across chapter replacements. KOReader
    -- uses <title> for home/history metadata, while the visible h1 remains
    -- the current chapter title.
    local document_title=meta.book or title
    return [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">]]..metas..[[<title>]]..esc(document_title)..[[</title>
<style>
body{line-height:1.72;margin:5.5%;max-width:46em;}header{border-bottom:1px solid #999;margin-bottom:1.4em;padding-bottom:.75em}h1{font-size:1.38em;margin:.15em 0}.sub{font-size:.83em;opacity:.68}.pcnt{font-size:.68em;vertical-align:super;opacity:.72;margin-left:.22em;padding:.12em .18em;text-decoration:underline;color:inherit}p{margin:.76em 0;text-align:justify}.author{margin-top:2.3em;padding-top:1.1em;border-top:1px dashed #888}.author h3{font-size:1em}.hint{margin-top:2.4em;padding:.7em;border:1px solid #aaa;font-size:.78em;opacity:.72}
</style></head><body><header><h1>]]..esc(title)..[[</h1><div class="sub">]]..table.concat(sub," · ")..[[</div></header>]]..table.concat(ps,"\n")..say..[[<div class="hint">字体：直接使用 KOReader 的字体菜单切换，包括你放在 Kobo 上的自定义字体。<br>段评：有段评的段落末尾会显示带下划线的数字，轻点数字即可查看。<br>翻章：读到最后一页后继续向后翻，会自动加载下一章。</div></body></html>]]
end

function H.comments(title, raw)
    raw=tostring(raw or "")
    raw=raw:gsub("<script.-</script>"," "):gsub("<style.-</style>"," ")
    raw=raw:gsub("<br%s*/?>","\n"):gsub("</p>","\n"):gsub("</div>","\n"):gsub("</li>","\n")
    raw=raw:gsub("<[^>]+>"," "):gsub("&nbsp;"," "):gsub("&lt;","<"):gsub("&gt;",">"):gsub("&amp;","&")
    raw=raw:gsub("\r",""):gsub("[ \t]+"," "):gsub("\n%s*\n+","\n")
    local rows={}
    for line in (raw.."\n"):gmatch("(.-)\n") do
        line=line:gsub("^%s+",""):gsub("%s+$","")
        if #line>2 then rows[#rows+1]="<p>"..esc(line).."</p>" end
        if #rows>=260 then break end
    end
    return [[<!doctype html><html><head><meta charset="utf-8"><title>]]..esc(title)..[[</title><style>body{line-height:1.6;margin:5%}h1{font-size:1.25em;border-bottom:1px solid #999;padding-bottom:.6em}p{margin:.55em 0}.note{font-size:.8em;opacity:.7}</style></head><body><h1>]]..esc(title)..[[ · 评论</h1><div class="note">实验版：优先显示晋江本章公开评论内容；后续版本会继续增强“点段落数字直接弹段评”。</div>]]..table.concat(rows,'\n')..[[</body></html>]]
end

function H.paragraph_comments(title, paragraph_id, paragraph_text, data)
    data=data or {}
    local root=data.data or data
    local list=root.commentList or root.commentlist or root.list or {}
    local total=root.commentTotal or root.commenttotal or #list
    local rows={}
    if type(list)=="table" then
        for _,c in ipairs(list) do
            local author=c.commentAuthor or c.commentauthor or c.author or "匿名"
            local body=c.commentBody or c.commentbody or c.body or ""
            local date=c.commentDate or c.commentdate or c.date or ""
            local agree=c.agreenum or c.agreeNum or c.agree or 0
            local mark=c.commentMark or c.commentmark
            local head=esc(author)
            if mark and tostring(mark)~="" and tostring(mark)~="nil" then head=head.." · "..esc(mark).."分" end
            if date and tostring(date)~="" then head=head.." · "..esc(date) end
            local replies=c.replyAll or c.reply or {}
            local rep={}
            if type(replies)=="table" then
                for _,r in ipairs(replies) do
                    local ra=r.replyAuthor or r.commentauthor or ""
                    local rb=r.replyBody or r.commentbody or ""
                    if tostring(rb)~="" then rep[#rep+1]='<div class="reply"><b>'..esc(ra)..'</b>：'..esc(rb)..'</div>' end
                end
            end
            rows[#rows+1]='<article><div class="meta">'..head..'　♡ '..esc(agree)..'</div><div class="body">'..esc(body)..'</div>'..table.concat(rep,'')..'</article>'
        end
    end
    if #rows==0 then rows[1]='<p class="empty">这一段暂时没有返回段评，或者晋江当前没有开放该段评论。</p>' end
    return [[<!doctype html><html><head><meta charset="utf-8"><title>]]..esc(title)..[[ · 段评</title><style>
body{line-height:1.58;margin:5%}h1{font-size:1.2em;margin-bottom:.35em}.quote{border-left:3px solid #888;padding:.5em .8em;margin:.7em 0 1.2em;opacity:.78}article{border-top:1px solid #aaa;padding:1em 0}.meta{font-size:.78em;opacity:.72;margin-bottom:.5em}.body{font-size:1em}.reply{margin:.7em 0 0 1em;padding:.55em .7em;border-left:2px solid #aaa;font-size:.9em}.empty{opacity:.68}.count{font-size:.82em;opacity:.65}
</style></head><body><h1>]]..esc(title)..[[ · 第 ]]..esc(paragraph_id)..[[ 段</h1><div class="quote">]]..esc(paragraph_text or "")..[[</div><div class="count">共 ]]..esc(total)..[[ 条段评</div>]]..table.concat(rows,'\n')..[[</body></html>]]
end


function H.book_shell(meta)
    meta=meta or {}
    local title=meta.book or "晋江小说"
    local author=meta.author or ""
    local current=meta.chapter_title or ""
    local pct=tonumber(meta.percent or 0) or 0
    local cover=meta.cover or ""
    local cover_html=cover ~= "" and ('<img class="cover" src="'..esc(cover)..'" alt="封面">') or ('<div class="cover placeholder"><div>'..esc(title)..'</div></div>')
    return [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">]]..
        '<meta name="author" content="'..esc(author)..'">'..
        '<meta name="jjwxc-book-shell" content="1">'..
        '<meta name="jjwxc-novel-id" content="'..esc(meta.novel_id or "")..'">'..
        '<meta name="jjwxc-book" content="'..esc(title)..'">'..
        '<meta name="jjwxc-author" content="'..esc(author)..'">'..
        [[<title>]]..esc(title)..[[</title><style>
body{margin:7%;line-height:1.55;text-align:center}.wrap{max-width:34em;margin:0 auto}.cover{width:46%;max-height:58vh;object-fit:contain;border:1px solid #999;margin:1em auto}.placeholder{height:18em;display:flex;align-items:center;justify-content:center;padding:1em;font-size:1.2em}h1{font-size:1.55em;margin:.9em 0 .3em}.author{opacity:.7}.current{margin-top:1.6em;border-top:1px solid #aaa;padding-top:1em}.bar{height:.45em;border:1px solid #777;margin:.7em 0}.fill{height:100%;background:#555}.hint{font-size:.78em;opacity:.65;margin-top:1.8em}
</style></head><body><div class="wrap">]]..cover_html..'<h1>'..esc(title)..'</h1>'..
        (author ~= "" and ('<div class="author">'..esc(author)..'</div>') or "")..
        '<div class="current">继续阅读：'..esc(current ~= "" and current or "上次章节")..'</div>'..
        '<div class="bar"><div class="fill" style="width:'..string.format('%.1f', math.max(0, math.min(100, pct)))..'%"></div></div>'..
        '<div>'..string.format('%.0f%%', math.max(0, math.min(100, pct)))..'</div>'..
        '<div class="hint">这是晋江小说入口。打开后会自动回到上次阅读章节；章节缓存不会再作为独立书籍出现在 Simple UI 首页。</div></div></body></html>'
end

return H
