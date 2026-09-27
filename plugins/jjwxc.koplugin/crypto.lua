-- Minimal pure-Lua DES/CBC/PKCS7 + Base64 used only to reproduce
-- JJWXC Android login request signing. No native crypto module required.
local C = {}

local IP = {
58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,
62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,
57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,
61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7}
local FP = {
40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,
38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,
36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,
34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25}
local E = {
32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,
12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,
24,25,26,27,28,29,28,29,30,31,32,1}
local P = {
16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,
2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25}
local PC1 = {
57,49,41,33,25,17,9,1,58,50,42,34,26,18,
10,2,59,51,43,35,27,19,11,3,60,52,44,36,
63,55,47,39,31,23,15,7,62,54,46,38,30,22,
14,6,61,53,45,37,29,21,13,5,28,20,12,4}
local PC2 = {
14,17,11,24,1,5,3,28,15,6,21,10,
23,19,12,4,26,8,16,7,27,20,13,2,
41,52,31,37,47,55,30,40,51,45,33,48,
44,49,39,56,34,53,46,42,50,36,29,32}
local SHIFTS = {1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1}
local S = {
{
14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,
0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,
15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13},
{
15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,
3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,
0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,
13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9},
{
10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,
13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,
1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12},
{
7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,
13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,
3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14},
{
2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,
14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,
11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3},
{
12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,
10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,
4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13},
{
4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,
13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,
6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12},
{
13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,
1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,
2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11}
}

local function bytes_to_bits(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        for j = 7, 0, -1 do
            out[#out+1] = math.floor(b / (2 ^ j)) % 2
        end
    end
    return out
end

local function bits_to_bytes(bits)
    local out = {}
    for i = 1, #bits, 8 do
        local b = 0
        for j = 0, 7 do b = b * 2 + (bits[i+j] or 0) end
        out[#out+1] = string.char(b)
    end
    return table.concat(out)
end

local function permute(bits, tbl)
    local out = {}
    for i = 1, #tbl do out[i] = bits[tbl[i]] end
    return out
end

local function xor_bits(a,b)
    local out = {}
    for i=1,#a do out[i] = (a[i] == b[i]) and 0 or 1 end
    return out
end

local function left_rotate(t, n)
    local out = {}
    local len = #t
    for i=1,len do out[i] = t[((i+n-1)%len)+1] end
    return out
end

local function make_subkeys(key8)
    local kb = bytes_to_bits(key8)
    local pc1 = permute(kb, PC1)
    local c,d = {},{}
    for i=1,28 do c[i]=pc1[i]; d[i]=pc1[i+28] end
    local keys = {}
    for r=1,16 do
        c = left_rotate(c, SHIFTS[r]); d = left_rotate(d, SHIFTS[r])
        local cd = {}
        for i=1,28 do cd[i]=c[i]; cd[i+28]=d[i] end
        keys[r] = permute(cd, PC2)
    end
    return keys
end

local function feistel(r, key)
    local x = xor_bits(permute(r,E), key)
    local s_out = {}
    for box=1,8 do
        local o=(box-1)*6
        local row = x[o+1]*2 + x[o+6]
        local col = x[o+2]*8 + x[o+3]*4 + x[o+4]*2 + x[o+5]
        local v = S[box][row*16 + col + 1]
        s_out[#s_out+1] = math.floor(v/8)%2
        s_out[#s_out+1] = math.floor(v/4)%2
        s_out[#s_out+1] = math.floor(v/2)%2
        s_out[#s_out+1] = v%2
    end
    return permute(s_out,P)
end

local function encrypt_block(block8, subkeys)
    local bits = permute(bytes_to_bits(block8), IP)
    local l,r = {},{}
    for i=1,32 do l[i]=bits[i]; r[i]=bits[i+32] end
    for round=1,16 do
        local old_r = r
        r = xor_bits(l, feistel(r,subkeys[round]))
        l = old_r
    end
    local pre = {}
    for i=1,32 do pre[i]=r[i]; pre[i+32]=l[i] end
    return bits_to_bytes(permute(pre,FP))
end

local function xor_bytes(a,b)
    local out={}
    for i=1,#a do
        local x,y=a:byte(i),b:byte(i)
        local v=0
        for bit=0,7 do
            local xb=x%2; local yb=y%2
            if xb~=yb then v=v+(2^bit) end
            x=math.floor(x/2); y=math.floor(y/2)
        end
        out[#out+1]=string.char(v)
    end
    return table.concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
    local out={}
    local i=1
    while i<=#s do
        local a=s:byte(i) or 0; local b=s:byte(i+1) or 0; local c=s:byte(i+2) or 0
        local n=a*65536+b*256+c
        local c1=math.floor(n/262144)%64
        local c2=math.floor(n/4096)%64
        local c3=math.floor(n/64)%64
        local c4=n%64
        out[#out+1]=B64:sub(c1+1,c1+1)
        out[#out+1]=B64:sub(c2+1,c2+1)
        out[#out+1]=(i+1<=#s) and B64:sub(c3+1,c3+1) or "="
        out[#out+1]=(i+2<=#s) and B64:sub(c4+1,c4+1) or "="
        i=i+3
    end
    return table.concat(out)
end

function C.des_cbc_pkcs7_base64(plain, key, iv)
    key = tostring(key or "")
    iv = tostring(iv or "")
    if #key < 8 then key = key .. string.rep("\0",8-#key) end
    if #iv < 8 then iv = iv .. string.rep("\0",8-#iv) end
    key=key:sub(1,8); iv=iv:sub(1,8)
    local pad=8-(#plain%8)
    plain=plain..string.rep(string.char(pad),pad)
    local keys=make_subkeys(key)
    local prev=iv
    local out={}
    for i=1,#plain,8 do
        local block=plain:sub(i,i+7)
        local enc=encrypt_block(xor_bytes(block,prev),keys)
        out[#out+1]=enc; prev=enc
    end
    return base64(table.concat(out))
end

local function base64_decode(data)
    data=tostring(data or ""):gsub("[^A-Za-z0-9%+/%=]","")
    local rev={}
    for i=1,#B64 do rev[B64:sub(i,i)]=i-1 end
    local out={}
    local i=1
    while i<=#data do
        local c1=rev[data:sub(i,i)] or 0
        local c2=rev[data:sub(i+1,i+1)] or 0
        local c3=data:sub(i+2,i+2); local c4=data:sub(i+3,i+3)
        local v3=(c3=="=") and 0 or (rev[c3] or 0)
        local v4=(c4=="=") and 0 or (rev[c4] or 0)
        local n=c1*262144+c2*4096+v3*64+v4
        out[#out+1]=string.char(math.floor(n/65536)%256)
        if c3~="=" and c3~='' then out[#out+1]=string.char(math.floor(n/256)%256) end
        if c4~="=" and c4~='' then out[#out+1]=string.char(n%256) end
        i=i+4
    end
    return table.concat(out)
end

local function decrypt_block(block8, subkeys)
    -- DES is a Feistel cipher: decryption is exactly the encryption round
    -- function with the 16 subkeys applied in reverse order.
    local bits=bytes_to_bits(block8)
    bits=permute(bits,IP)
    local l,r={},{}
    for i=1,32 do l[i]=bits[i]; r[i]=bits[i+32] end
    for round=16,1,-1 do
        local old_r = r
        r = xor_bits(l, feistel(r, subkeys[round]))
        l = old_r
    end
    local pre={}
    for i=1,32 do pre[i]=r[i]; pre[i+32]=l[i] end
    return bits_to_bytes(permute(pre,FP))
end

function C.des_cbc_pkcs7_base64_decrypt(cipher_b64,key,iv)
    key=tostring(key or ""); iv=tostring(iv or "")
    if #key<8 then key=key..string.rep("\0",8-#key) end
    if #iv<8 then iv=iv..string.rep("\0",8-#iv) end
    key=key:sub(1,8); iv=iv:sub(1,8)
    local cipher=base64_decode(cipher_b64)
    if #cipher==0 or #cipher%8~=0 then return nil,"invalid DES payload" end
    local keys=make_subkeys(key)
    local prev=iv; local out={}
    for i=1,#cipher,8 do
        local block=cipher:sub(i,i+7)
        local dec=decrypt_block(block,keys)
        out[#out+1]=xor_bytes(dec,prev)
        prev=block
    end
    local plain=table.concat(out)
    local pad=plain:byte(-1) or 0
    if pad>=1 and pad<=8 then plain=plain:sub(1,#plain-pad) end
    return plain
end

return C
