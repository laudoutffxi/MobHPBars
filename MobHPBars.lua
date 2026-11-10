--[[
    MobHPBars - HP bars over monsters for FFXI (Ashita v4)

    - Framed health bar + name over every nearby monster
    - Debuffs shown as small status icons under the bar
    - Your current target's plate is drawn larger, highlighted and on top

    Commands (/np or /mobhpbars):
      /np                 show help
      /np debug           toggle a calibration dot at your own feet
      /np axis            cycle world-axis mode (use with /np debug until the dot sits on you)
      /np height <n>      base height above the mob (yalms, default 2.5)
      /np auto            toggle automatic height by mob size (default on)
      /np sizefactor <n>  how strongly mob size raises the plate (default 1.5)
      /np mobheight <n>   fix the height for every mob with your target's name
      /np mobheight       clear that override (back to automatic)
      /np export          save your heights to shared_heights.txt (for your other characters)
      /np import          load heights from shared_heights.txt (replaces your mob list)
      /np import merge    load them but keep any mob heights you already have
      /np perrow <n>      debuff icons per row before wrapping (default 6)
      /np glow <n>        how far the soft target glow spreads in px (default 10, 0 = off)
      /np arrow           toggle the arrow above your target's plate
      /np pulse           toggle the target glow's gentle pulse
      /np distance <n>    max distance to show plates (default 30)
      /np scale <n>       target plate scale (default 1.1)
      /np width <n>       base bar width in px (default 100)
      /np icons <n>       base debuff icon size in px (default 14)
      /np round <n>       HP bar corner radius in px (default 2, 0 = square)
      /np hp              toggle HP % text on the bars
      /np claim           toggle claim colours (off = green bar)
      /np elite <name>    toggle a mob name as elite (gold border)
      /np boss <name>     toggle a mob name as NM/boss (ornate frame, red bar)
      /np frames          toggle image frames (assets/frame_*.png) vs shape style
      /np size <n>        image frame height in px (default 34)
      /np players         toggle plates over players (you, party, others)
      /np gamenames       toggle hiding the game's own monster names
      /np status          print diagnostics (camera, entity counts, errors)
      /np clear           clear all tracked debuffs
]]

addon.name    = 'MobHPBars'
addon.author  = 'Laudout'
addon.version = '3.1'
addon.desc    = 'HP bars over monsters with debuff icons, target glow and arrow.'
addon.link    = ''

require('common')
local chat     = require('chat')
local imgui    = require('imgui')
local settings = require('settings')
local d3d8     = require('d3d8')
local ffi      = require('ffi')
local bit      = require('bit')

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------
local defaults = T{
    max_distance   = 30,
    plate_width    = 100,   -- HP bar width in px (the frame is built around it)
    plate_height   = 8,     -- HP bar height for the shape-drawn fallback style
    frame_height   = 34,    -- height in px of the image frame (assets/frame_*.png)
    use_frames     = true,
    hide_game_names = true, -- hide the game's own monster names (no plugin needed)
    show_players   = false, -- also draw plates over players (you, party, others)  -- false = draw plates with shapes instead of the image frames
    bar_rounding   = 2,     -- HP bar corner radius in px (square-rounded ends)
    target_scale   = 1.1,
    boss_scale     = 1.25,  -- extra size for NM / boss plates
    elite_levels   = 5,     -- mobs this many levels above you count as elite (needs /check)
    elite_names    = T{},   -- names always shown as elite  (/np elite <name>)
    auto_height    = true,  -- raise/lower each plate using the mob's hitbox size from the server
    size_factor    = 1.5,   -- yalms of extra height per yalm of hitbox size above 1.0
    mob_heights    = T{},   -- per-name height overrides in yalms (/np mobheight <n> on a target)
    glow_px      = 10,    -- px the soft target glow spreads out from the frame
    show_arrow     = true,  -- bobbing arrow above your target's plate
    glow_pulse     = true,  -- gently pulse the target glow
    boss_names     = T{},   -- names always shown as NM/boss (/np boss <name>)
    claim_colours  = false, -- false = classic green bar, true = red/yellow/grey by claim
    icon_size      = 14,
    max_icons      = 5,     -- (old setting, no longer used)
    debuffs_per_row = 6,    -- debuff icons per row; more wrap onto another row and the plate moves up
    head_offset    = 2.5,   -- yalms above the mob's feet where the plate's bottom edge sits
    axis_mode      = 1,
    show_hp_text   = true,
    debug          = false,
}

local config = settings.load(defaults)

settings.register('settings', 'np_settings_update', function (s)
    if s ~= nil then config = s end
end)

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)))
end

----------------------------------------------------------------------------------------------------
-- Colours (ImU32, ABGR)
----------------------------------------------------------------------------------------------------
local function rgba(r, g, b, a)
    local v = bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r)
    if v < 0 then v = v + 4294967296 end
    return v
end

local COL = {
    border      = rgba(0, 0, 0, 230),
    bg          = rgba(25, 25, 25, 200),
    hostile     = rgba(204, 26, 26, 255),     -- claimed by you / party (red)
    neutral     = rgba(230, 200, 30, 255),    -- unclaimed (yellow)
    tapped      = rgba(128, 128, 128, 255),   -- claimed by someone else (grey)
    gloss       = rgba(255, 255, 255, 45),
    shade       = rgba(0, 0, 0, 60),
    target_glow = rgba(255, 255, 255, 255),
    target_out  = rgba(255, 210, 60, 160),
    text        = rgba(255, 255, 255, 255),
    text_target = rgba(255, 230, 120, 255),
    shadow      = rgba(0, 0, 0, 220),
    icon_border = rgba(0, 0, 0, 255),
    debug_dot   = rgba(0, 255, 120, 255),

    -- Blue panel style
    panel_bg     = rgba(10, 20, 45, 191),     -- dark navy, 25% transparent
    panel_edge   = rgba(85, 135, 205, 255),   -- thin metallic blue
    panel_shine  = rgba(170, 210, 255, 70),   -- inner highlight line for the metal look
    target_line  = rgba(0, 235, 255, 255),    -- bright cyan target outline
    target_glow  = rgba(0, 220, 255, 45),     -- soft cyan glow
    elite_edge   = rgba(220, 180, 75, 255),   -- gold border
    elite_gem    = rgba(255, 210, 90, 255),
    boss_outer   = rgba(120, 22, 22, 255),    -- dark red outer frame
    boss_edge    = rgba(215, 170, 70, 255),   -- gold inner frame
    boss_gem     = rgba(230, 40, 40, 255),
    bar_frame    = rgba(0, 0, 0, 255),
    bar_bg       = rgba(8, 20, 12, 230),
    bar_green    = rgba(46, 196, 46, 255),
    bar_red      = rgba(205, 35, 35, 255),
    lvl_bg       = rgba(8, 14, 30, 245),
    lvl_ring     = rgba(80, 150, 230, 255),
    lvl_text     = rgba(255, 255, 255, 255),
}

-- Mob levels learned from /check results (FFXI doesn't send mob level otherwise)
local levels = {}   -- levels[server_id] = level
local hitbox = {}   -- hitbox[server_id] = hitbox size in yalms (from 0x00E byte 0x25, size x10)
local nm_flag = {}  -- nm_flag[server_id] = true when /check says 'impossible to gauge'

----------------------------------------------------------------------------------------------------
-- Status icon textures (pulled from the game's own icon resources)
----------------------------------------------------------------------------------------------------
local icon_cache = {}

local function get_status_icon(status_id)
    local cached = icon_cache[status_id]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local ok, result = pcall(function ()
        local icon = AshitaCore:GetResourceManager():GetStatusIconByIndex(status_id)
        if icon == nil then return nil end

        local dev = d3d8.get_device()
        local ptr = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(dev, icon.Bitmap, icon.ImageSize,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED,
            ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000, nil, nil, ptr)
        if hr ~= ffi.C.S_OK then return nil end

        local tex = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]))
        return { tex = tex, id = tonumber(ffi.cast('uint32_t', tex)) }
    end)

    if not ok or result == nil then
        icon_cache[status_id] = false
        return nil
    end
    icon_cache[status_id] = result
    return result
end

----------------------------------------------------------------------------------------------------
-- Frame textures (assets/frame_normal.png, frame_elite.png, frame_boss.png)
----------------------------------------------------------------------------------------------------
-- Measurements of the source art (1888 x 365 px) - every slot is placed from these.
local FRAME = {
    w = 1888, h = 365,
    cap_l = 214,                 -- left end cap (pointed ornament) is never stretched
    cap_r = 1674,                -- right end cap starts here, also never stretched
    body_y1 = 68, body_y2 = 307, -- top / bottom of the straight frame body (the end points stick out past it)
    body_inset = 42,             -- how far the body's sides sit in from the tips of the end points
    name_x1 = 150, name_x2 = 1738, name_y1 = 104, name_y2 = 171,
    bar_x1  = 65,  bar_x2  = 1823, bar_y1  = 203, bar_y2  = 283,
}

local frame_tex = {}

local function load_asset(file)
    if frame_tex[file] ~= nil then return frame_tex[file] or nil end
    local ok, result = pcall(function ()
        local path = string.format('%s/assets/%s.png', addon.path, file)
        local ptr  = ffi.new('IDirect3DTexture8*[1]')
        local hr   = ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), path, ptr)
        if hr ~= ffi.C.S_OK then return nil end
        local t = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]))
        return { tex = t, id = tonumber(ffi.cast('uint32_t', t)) }
    end)
    frame_tex[file] = (ok and result) or false
    return frame_tex[file] or nil
end

local function load_frame(name) return load_asset('frame_' .. name) end

----------------------------------------------------------------------------------------------------
-- Debuff tracking (built from action / message packets the client receives)
----------------------------------------------------------------------------------------------------
local debuffs = {}   -- debuffs[server_id] = { [status_id] = { applied = t, expires = t } }

-- Action messages that mean "target gained <status>" (status id is the action param)
local APPLY_MESSAGES = T{ 82, 127, 141, 203, 236, 237, 242, 268, 270, 271, 277, 278, 279, 280 }
-- Additional-effect messages that apply a status (status id is the add-effect param)
local ADD_EFFECT_APPLY = T{ 160, 164, 166 }
-- 0x029 messages meaning a status wore off / was removed (status id is param 1)
local WEAR_MESSAGES = T{ 64, 83, 204, 206, 321, 322, 341, 342, 343, 344, 350, 351, 378, 531 }
-- 0x029 messages meaning the target died
local DEATH_MESSAGES = T{ 6, 20, 97, 113, 406, 605, 646 }

-- Statuses that make a mob unable to move: if it moves, they are gone.
local MOVE_BREAKS = { [2] = true, [19] = true, [7] = true, [10] = true, [11] = true, [28] = true }
-- Statuses that make a mob unable to act: if it attacks or uses an ability, they are gone.
local ACTION_BREAKS = { [2] = true, [19] = true, [7] = true, [10] = true, [28] = true }
-- 0x028 categories where the actor is doing something itself
local ACTOR_CATEGORIES = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true,
                           [7] = true, [8] = true, [11] = true, [12] = true, [14] = true }

-- Mobs that you or a party member have hit with anything (melee, ranged, magic, abilities)
local engaged = {}   -- engaged[server_id] = time of your/party's last attack on it

local function is_party_member(id)
    local party = AshitaCore:GetMemoryManager():GetParty()
    for n = 0, 17 do
        if party:GetMemberIsActive(n) == 1 and party:GetMemberServerId(n) == id then return true end
    end
    return false
end

local ATTACK_CATEGORIES = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [14] = true, [15] = true }

-- Damage spells that also leave a debuff (their action message only reports the damage)
local SPELL_STATUS = {
    [23] = 134, [24] = 134, [25] = 134, [26] = 134, [27] = 134,      -- Dia I-V
    [33] = 134, [34] = 134, [35] = 134,                              -- Diaga I-III
    [230] = 135, [231] = 135, [232] = 135, [233] = 135, [234] = 135, -- Bio I-V
}
local DAMAGE_MESSAGES = { [2] = true, [252] = true, [264] = true }  -- magic damage, magic burst, AoE damage

local function add_debuff(target_id, status_id)
    if status_id == nil or status_id <= 0 or status_id >= 1024 then return end
    debuffs[target_id] = debuffs[target_id] or {}
    debuffs[target_id][status_id] = { applied = os.clock(), t = os.time() }
end

local function remove_debuff(target_id, status_id)
    local list = debuffs[target_id]
    if list == nil then return end
    list[status_id] = nil
    if next(list) == nil then debuffs[target_id] = nil end
end

local function parse_action(data_raw)
    local pos = 40
    local function bits(n)
        local v = ashita.bits.unpack_be(data_raw, 0, pos, n)
        pos = pos + n
        return v
    end

    local act = { targets = {} }
    act.actor    = bits(32)
    local tcount = bits(6)
    bits(4)
    act.category = bits(4)
    act.param    = bits(32)
    act.recast   = bits(32)

    for _ = 1, tcount do
        local tgt = { id = bits(32), actions = {} }
        local acount = bits(4)
        for _ = 1, acount do
            local a = {}
            a.reaction  = bits(5)
            a.animation = bits(12)
            a.effect    = bits(7)
            a.knockback = bits(3)
            a.param     = bits(17)
            a.message   = bits(10)
            bits(31)
            if bits(1) == 1 then
                a.add_anim    = bits(10)
                a.add_param   = bits(17)
                a.add_message = bits(10)
            end
            if bits(1) == 1 then
                bits(10); bits(14); bits(10)
            end
            tgt.actions[#tgt.actions + 1] = a
        end
        act.targets[#act.targets + 1] = tgt
    end
    return act
end

-- 0x00E entity update: Flags1 is the uint32 at 0x20 (bit 0 = monster), Flags3 the uint32 at 0x28.
-- Flags3 bit 29 (byte 0x2B, value 0x20) tells the client not to draw that entity's name.
local NAME_HIDE_BYTE, NAME_HIDE_BIT = 0x2B, 0x20

local function hide_name_in_packet(e)
    local data = e.data_modified
    if #data <= NAME_HIDE_BYTE then return end
    local monster = bit.band(data:byte(0x20 + 1), 0x01) ~= 0
    if not monster then return end
    local b = data:byte(NAME_HIDE_BYTE + 1)
    if bit.band(b, NAME_HIDE_BIT) ~= 0 then return end
    e.data_modified = data:sub(1, NAME_HIDE_BYTE) .. string.char(bit.bor(b, NAME_HIDE_BIT)) .. data:sub(NAME_HIDE_BYTE + 2)
end

ashita.events.register('packet_in', 'np_packet_in', function (e)
    if e.id == 0x00E then
        if #e.data > 0x25 then
            local sid = struct.unpack('I', e.data, 0x04 + 1)
            local hb  = e.data:byte(0x25 + 1)
            if hb > 0 then hitbox[sid] = hb / 10 end
            if bit.band(e.data:byte(0x0A + 1), 0x20) ~= 0 then debuffs[sid] = nil; engaged[sid] = nil end   -- despawned
        end
        if config.hide_game_names then pcall(hide_name_in_packet, e) end
    elseif e.id == 0x028 then
        local ok, act = pcall(parse_action, e.data_raw)
        if not ok or act == nil then return end
        -- A mob that acts can't be asleep / stunned / petrified / terrored any more
        if ACTOR_CATEGORIES[act.category] and debuffs[act.actor] ~= nil then
            for st in pairs(ACTION_BREAKS) do remove_debuff(act.actor, st) end
        end
        if ATTACK_CATEGORIES[act.category] and is_party_member(act.actor) then
            for _, tgt in ipairs(act.targets) do
                if not is_party_member(tgt.id) then engaged[tgt.id] = os.time() end
            end
        end
        for _, tgt in ipairs(act.targets) do
            for _, a in ipairs(tgt.actions) do
                if APPLY_MESSAGES:contains(a.message) then
                    add_debuff(tgt.id, a.param)
                elseif act.category == 4 and SPELL_STATUS[act.param] and DAMAGE_MESSAGES[a.message] then
                    local st = SPELL_STATUS[act.param]
                    -- Dia and Bio overwrite each other
                    remove_debuff(tgt.id, st == 134 and 135 or 134)
                    add_debuff(tgt.id, st)
                end
                if a.add_message ~= nil and ADD_EFFECT_APPLY:contains(a.add_message) then
                    add_debuff(tgt.id, a.add_param)
                end
            end
        end
    elseif e.id == 0x029 then
        local target_id = struct.unpack('I', e.data, 0x08 + 1)
        local param1    = struct.unpack('I', e.data, 0x0C + 1)
        local message   = bit.band(struct.unpack('H', e.data, 0x18 + 1), 0x7FFF)
        if WEAR_MESSAGES:contains(message) then
            remove_debuff(target_id, param1)
        elseif DEATH_MESSAGES:contains(message) then
            debuffs[target_id] = nil
            levels[target_id] = nil
            engaged[target_id] = nil
        elseif message >= 170 and message <= 178 and param1 > 0 and param1 < 200 then
            levels[target_id] = param1   -- /check result: param1 is the mob's level
        elseif message == 249 then
            nm_flag[target_id] = true    -- "impossible to gauge" = notorious monster
        end
    elseif e.id == 0x00A then
        debuffs = {}   -- zoned
        levels = {}
        nm_flag = {}
        engaged = {}
        hitbox = {}
    end
end)

----------------------------------------------------------------------------------------------------
-- World -> screen projection
----------------------------------------------------------------------------------------------------
local view, proj = nil, nil

local function matrix_to_table(m)
    return {
        m._11, m._12, m._13, m._14,
        m._21, m._22, m._23, m._24,
        m._31, m._32, m._33, m._34,
        m._41, m._42, m._43, m._44,
    }
end

local function read_matrix(dev, state)
    -- Form 1: hr, matrix = dev:GetTransform(state)
    local ok, a, b = pcall(function () return dev:GetTransform(state) end)
    if ok then
        local m = (type(a) == 'number') and b or a
        if m ~= nil then
            local ok2, t = pcall(matrix_to_table, m)
            if ok2 then return t end
        end
    end
    -- Form 2: dev:GetTransform(state, out_matrix)
    local out = ffi.new('D3DMATRIX[1]')
    ok = pcall(function () dev:GetTransform(state, out) end)
    if ok then
        local ok2, t = pcall(matrix_to_table, out[0])
        if ok2 then return t end
    end
    return nil
end

-- Converts game coords + height offset into a D3D world vector, by axis mode.
local function to_world(x, y, z, offset)
    local mode = config.axis_mode
    if mode == 1 then return x, z - offset, y
    elseif mode == 2 then return x, z + offset, y
    elseif mode == 3 then return x, y - offset, z
    else return x, y + offset, z end
end

local function world_to_screen(wx, wy, wz, sw, sh)
    if view == nil or proj == nil then return nil end
    local v, p = view, proj

    local vx = wx * v[1] + wy * v[5] + wz * v[9]  + v[13]
    local vy = wx * v[2] + wy * v[6] + wz * v[10] + v[14]
    local vz = wx * v[3] + wy * v[7] + wz * v[11] + v[15]
    local vw = wx * v[4] + wy * v[8] + wz * v[12] + v[16]

    local cx = vx * p[1] + vy * p[5] + vz * p[9]  + vw * p[13]
    local cy = vx * p[2] + vy * p[6] + vz * p[10] + vw * p[14]
    local cw = vx * p[4] + vy * p[8] + vz * p[12] + vw * p[16]

    if cw < 0.1 then return nil end   -- behind the camera

    local sx = (cx / cw * 0.5 + 0.5) * sw
    local sy = (1.0 - (cy / cw * 0.5 + 0.5)) * sh
    return sx, sy
end

local function screen_size()
    local ok, io = pcall(imgui.GetIO)
    if ok and io ~= nil and io.DisplaySize ~= nil then
        local ds = io.DisplaySize
        local w = ds.x or ds[1]
        local h = ds.y or ds[2]
        if w and h and w > 0 and h > 0 then return w, h end
    end
    local cfg = AshitaCore:GetConfigurationManager()
    return cfg:GetFloat('boot', 'ffxi.registry', '0001', 1024),
           cfg:GetFloat('boot', 'ffxi.registry', '0002', 768)
end

----------------------------------------------------------------------------------------------------
-- Drawing helpers
----------------------------------------------------------------------------------------------------
local function text_size(text)
    local w, h = imgui.CalcTextSize(text)
    if type(w) == 'table' then return w[1] or w.x, w[2] or w.y end
    return w, h
end

local function shadow_text(dl, x, y, col, text)
    dl:AddText({ x + 1, y + 1 }, COL.shadow, text)
    dl:AddText({ x, y }, col, text)
end

local function sorted_debuffs(server_id)
    local list = debuffs[server_id]
    if list == nil then return nil end
    local out = {}
    for status_id, d in pairs(list) do
        out[#out + 1] = { id = status_id, applied = d.applied }
    end
    if #out == 0 then debuffs[server_id] = nil; return nil end
    table.sort(out, function (a, b) return a.applied < b.applied end)
    return out
end

local function diamond(dl, x, y, r, col)
    dl:AddQuadFilled({ x, y - r }, { x + r, y }, { x, y + r }, { x - r, y }, col)
end

-- Number of debuff rows a mob currently needs (at least 1, so the first debuff never moves the plate)
local function debuff_rows(server_id)
    local list = debuffs[server_id]
    if list == nil then return 1 end
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    return math.max(1, math.ceil(n / math.max(1, config.debuffs_per_row or 6)))
end

-- Draws every debuff icon centred on cx, wrapping onto extra rows when there are many.
local function draw_debuff_icons(dl, list, cx, top, size, gap)
    local per_row = math.max(1, config.debuffs_per_row or 6)
    local n, row = #list, 0
    local i = 1
    while i <= n do
        local count = math.min(per_row, n - i + 1)
        local ix = cx - (count * size + (count - 1) * gap) / 2
        local iy = top + row * (size + gap + 1)
        for k = i, i + count - 1 do
            local icon = get_status_icon(list[k].id)
            if icon ~= nil then
                dl:AddRectFilled({ ix - 1, iy - 1 }, { ix + size + 1, iy + size + 1 }, COL.icon_border, 0)
                dl:AddImage(icon.id, { ix, iy }, { ix + size, iy + size })
            end
            ix = ix + size + gap
        end
        i = i + count
        row = row + 1
    end
end

-- Soft blue glow around a rectangle: stacked rounded rects fading outwards, no hard edge.
local function soft_glow(dl, x1, y1, x2, y2, rounding, red)
    local size = config.glow_px or 6
    if size <= 0 then return end
    local strength = 1.0
    if config.glow_pulse then strength = 0.7 + 0.3 * (0.5 + 0.5 * math.sin(os.clock() * 3.0)) end
    local steps = math.max(3, math.floor(size))
    for n = steps, 1, -1 do
        local g = size * n / steps
        local a = math.floor(70 * strength * (1 - (n - 1) / steps))
        local col = red and rgba(255, 45, 45, a) or rgba(40, 170, 255, a)
        dl:AddRectFilled({ x1 - g, y1 - g }, { x2 + g, y2 + g }, col, rounding + g)
    end
end

-- Bobbing arrow pointing down at the target's plate. (x, y) is the tip's resting position.
local function target_arrow(dl, x, y, s, red)
    if not config.show_arrow then return end
    local bob = 2.5 * math.sin(os.clock() * 4.0)
    local w, h = 7 * s, 9 * s
    local ty = y - 3 + bob                       -- tip
    local by = ty - h                            -- top edge
    dl:AddTriangleFilled({ x - w - 2, by - 2 }, { x + w + 2, by - 2 }, { x, ty + 3 }, rgba(0, 0, 0, 230))
    dl:AddTriangleFilled({ x - w, by }, { x + w, by }, { x, ty }, red and rgba(240, 50, 50, 255) or rgba(60, 190, 255, 255))
    dl:AddTriangleFilled({ x - w * 0.55, by + 1.5 }, { x + w * 0.55, by + 1.5 }, { x, by + h * 0.55 }, red and rgba(255, 180, 180, 200) or rgba(190, 235, 255, 200))
end

local function draw_plate_shapes(dl, sx, sy, p)
    local s = 1.0
    if p.rank == 'boss' then s = s * config.boss_scale end
    if p.is_target then s = s * config.target_scale end

    local bw  = config.plate_width * s
    local bh  = config.plate_height * s
    local pad = 4 * s

    imgui.SetWindowFontScale((p.rank == 'boss' and 0.95 or 0.85) * s)
    local tw, th = text_size(p.name)

    local panel_w = pad + bw + pad
    local panel_h = pad + th + 2 * s + bh + pad
    local icon_row = debuff_rows(p.server_id) * (config.icon_size * s + 3) + 1   -- plate rises a row at a time
    local px2, py2 = sx + bw / 2 + pad, sy - 3 - icon_row   -- bottom-anchored above the mob
    local px1, py1 = px2 - panel_w, py2 - panel_h
    local pr  = 3 * s                           -- slightly rounded corners
    local midx = (px1 + px2) / 2

    -- Target: soft blue glow
    if p.is_target then
        soft_glow(dl, px1, py1, px2, py2, pr, p.engaged)
        target_arrow(dl, (px1 + px2) / 2, py1 - (p.rank == 'normal' and 3 or 9 * s), s, p.engaged)
    elseif p.engaged then
        soft_glow(dl, px1, py1, px2, py2, pr, true)     -- engaged mobs keep their red glow
    end

    -- Frame
    if p.rank == 'boss' then
        dl:AddRectFilled({ px1 - 3, py1 - 3 }, { px2 + 3, py2 + 3 }, COL.boss_outer, pr + 3)
        dl:AddRectFilled({ px1 - 1.5, py1 - 1.5 }, { px2 + 1.5, py2 + 1.5 }, COL.boss_edge, pr + 1.5)
    else
        local edge = (p.rank == 'elite') and COL.elite_edge or COL.panel_edge
        dl:AddRectFilled({ px1 - 1, py1 - 1 }, { px2 + 1, py2 + 1 }, edge, pr + 1)
    end
    dl:AddRectFilled({ px1, py1 }, { px2, py2 }, COL.panel_bg, pr)
    dl:AddLine({ px1 + pr, py1 + 1 }, { px2 - pr, py1 + 1 }, COL.panel_shine, 1)

    -- Boss ornaments: small gold corner points + red gem on top (kept small)
    if p.rank == 'boss' then
        local o = 5 * s
        dl:AddTriangleFilled({ px1 - 3, py1 - 3 }, { px1 - 3 - o, py1 - 3 }, { px1 - 3, py1 - 3 - o }, COL.boss_edge)
        dl:AddTriangleFilled({ px2 + 3, py1 - 3 }, { px2 + 3 + o, py1 - 3 }, { px2 + 3, py1 - 3 - o }, COL.boss_edge)
        dl:AddTriangleFilled({ px1 - 3, py2 + 3 }, { px1 - 3 - o, py2 + 3 }, { px1 - 3, py2 + 3 + o }, COL.boss_edge)
        dl:AddTriangleFilled({ px2 + 3, py2 + 3 }, { px2 + 3 + o, py2 + 3 }, { px2 + 3, py2 + 3 + o }, COL.boss_edge)
        diamond(dl, midx, py1 - 3, 5 * s, COL.boss_edge)
        diamond(dl, midx, py1 - 3, 3 * s, COL.boss_gem)
    elseif p.rank == 'elite' then
        diamond(dl, midx, py1 - 1, 4 * s, COL.bar_frame)
        diamond(dl, midx, py1 - 1, 3 * s, COL.elite_gem)
    end

    -- Name (centre aligned, white, subtle shadow)
    local bx1 = sx - bw / 2
    local bx2 = bx1 + bw
    local ny  = py1 + pad - 1
    shadow_text(dl, bx1 + (bw - tw) / 2, ny, COL.text, p.name)

    -- HP bar (slim, slight gloss)
    local by1 = ny + th + 2 * s
    local by2 = by1 + bh
    local r   = math.min(config.bar_rounding * s, bh / 2)
    dl:AddRectFilled({ bx1 - 1, by1 - 1 }, { bx2 + 1, by2 + 1 }, COL.bar_frame, r + 1)
    dl:AddRectFilled({ bx1, by1 }, { bx2, by2 }, COL.bar_bg, r)

    local fill_w = bw * math.max(0, math.min(1, p.hpp / 100))
    if fill_w > 0 then
        local col
        if config.claim_colours then col = p.color
        elseif p.rank == 'boss' then col = COL.bar_red
        else col = COL.bar_green end
        local fr = math.min(r, fill_w / 2)
        dl:AddRectFilled({ bx1, by1 }, { bx1 + fill_w, by2 }, col, fr)
        if fill_w > 2 then
            dl:AddRectFilled({ bx1 + 1, by1 + 1 }, { bx1 + fill_w - 1, by1 + bh * 0.4 }, COL.gloss, math.min(fr, 1))
        end
    end

    if config.show_hp_text and bh >= 6 then
        imgui.SetWindowFontScale(0.7 * s)
        local hp = string.format('%d%%', p.hpp)
        local hw, hh = text_size(hp)
        shadow_text(dl, bx1 + (bw - hw) / 2, by1 + (bh - hh) / 2, COL.text, hp)
    end

    imgui.SetWindowFontScale(1.0)

    -- Debuff icons underneath (max 5)
    local list = sorted_debuffs(p.server_id)
    if list ~= nil then
        local size  = config.icon_size * s
        local gap   = 2
        draw_debuff_icons(dl, list, (bx1 + bx2) / 2, py2 + (p.rank == 'boss' and 6 or 4), size, gap)
    end
end

-- Draws one slice of the frame texture: source x range [sx1, sx2] to screen x range [dx1, dx2]
local function frame_slice(dl, id, sx1, sx2, dx1, dx2, y1, y2)
    if dx2 <= dx1 then return end
    dl:AddImage(id, { dx1, y1 }, { dx2, y2 }, { sx1 / FRAME.w, 0 }, { sx2 / FRAME.w, 1 })
end

local function draw_plate_framed(dl, sx, sy, p, tex)
    local s = 1.0
    if p.rank == 'boss' then s = s * config.boss_scale end
    if p.is_target then s = s * config.target_scale end

    -- Layout: H = frame height, k = screen px per source px for the caps,
    -- M = stretched middle so the HP bar slot comes out at plate_width.
    -- frame_height is the height of the straight body; the pointed ends reach a little past it
    local k  = (config.frame_height * s) / (FRAME.body_y2 - FRAME.body_y1)
    local H  = FRAME.h * k
    local bw = config.plate_width * s
    local M  = math.max(10, bw - (FRAME.bar_x2 - FRAME.cap_r) * k - (FRAME.cap_l - FRAME.bar_x1) * k)
    local W  = FRAME.cap_l * k + M + (FRAME.w - FRAME.cap_r) * k
    -- Anchor: the centre of the name slot sits exactly on the point above the mob,
    -- so the plate is centred where the game draws the mob's name.
    local name_l  = FRAME.name_x1 * k                                         -- name slot left (in left cap)
    local name_r  = FRAME.cap_l * k + M + (FRAME.name_x2 - FRAME.cap_r) * k   -- name slot right (in right cap)
    local name_cx = (name_l + name_r) / 2
    local x0 = sx - name_cx
    -- Bottom-anchored: the frame and its debuff row sit fully above the point over the mob
    local icon_row = debuff_rows(p.server_id) * (config.icon_size * s + 3)       -- plate rises a row at a time
    local y0 = sy - 3 - icon_row - FRAME.body_y2 * k
    local y1 = y0 + H

    -- source x -> screen x (3-slice mapping)
    local function mx(x)
        if x <= FRAME.cap_l then return x0 + x * k end
        if x >= FRAME.cap_r then return x0 + FRAME.cap_l * k + M + (x - FRAME.cap_r) * k end
        return x0 + FRAME.cap_l * k + (x - FRAME.cap_l) / (FRAME.cap_r - FRAME.cap_l) * M
    end
    local function my(y) return y0 + y * k end

    local fx1, fy1 = mx(FRAME.body_inset), my(FRAME.body_y1)              -- body of the frame (for glow)
    local fx2, fy2 = mx(FRAME.w - FRAME.body_inset), my(FRAME.body_y2)

    -- Target: soft blue glow around the frame
    if p.is_target then
        soft_glow(dl, fx1, fy1 + 1, fx2, fy2 - 1, 5 * s, p.engaged)
        target_arrow(dl, (mx(FRAME.name_x1) + mx(FRAME.name_x2)) / 2, fy1 - (p.rank == 'normal' and 3 or 9 * s), s, p.engaged)
    elseif p.engaged then
        soft_glow(dl, fx1, fy1 + 1, fx2, fy2 - 1, 5 * s, true)   -- engaged mobs keep their red glow
    end

    -- Frame art
    -- joins are snapped to whole pixels so no hairline gap can show between the three slices
    local jl = math.floor(mx(FRAME.cap_l) + 0.5)
    local jr = math.floor(mx(FRAME.cap_r) + 0.5)
    frame_slice(dl, tex.id, 0, FRAME.cap_l, x0, jl, y0, y1)
    frame_slice(dl, tex.id, FRAME.cap_l, FRAME.cap_r, jl, jr, y0, y1)
    frame_slice(dl, tex.id, FRAME.cap_r, FRAME.w, jr, x0 + W, y0, y1)

    -- Boss: red gem on top; elite: gold gem
    if p.rank == 'boss' then
        local gx = (mx(FRAME.name_x1) + mx(FRAME.name_x2)) / 2
        diamond(dl, gx, fy1, 5 * s, COL.boss_edge)
        diamond(dl, gx, fy1, 3 * s, COL.boss_gem)
    elseif p.rank == 'elite' then
        local gx = (mx(FRAME.name_x1) + mx(FRAME.name_x2)) / 2
        diamond(dl, gx, fy1, 4 * s, COL.bar_frame)
        diamond(dl, gx, fy1, 3 * s, COL.elite_gem)
    end

    -- Name, centred in the top slot (shrunk to fit if long)
    local nx1, nx2 = mx(FRAME.name_x1) + 3, mx(FRAME.name_x2) - 3
    local ny1, ny2 = my(FRAME.name_y1), my(FRAME.name_y2)
    local fs = 0.8 * s
    imgui.SetWindowFontScale(fs)
    local tw, th = text_size(p.name)
    if tw > (nx2 - nx1) then
        fs = fs * (nx2 - nx1) / tw
        imgui.SetWindowFontScale(fs)
        tw, th = text_size(p.name)
    end
    shadow_text(dl, (nx1 + nx2 - tw) / 2, (ny1 + ny2 - th) / 2, COL.text, p.name)

    -- HP bar in the bottom slot
    local bx1, bx2 = mx(FRAME.bar_x1) + 1, mx(FRAME.bar_x2) - 1
    local by1, by2 = my(FRAME.bar_y1) + 1, my(FRAME.bar_y2) - 1
    local r = math.min(config.bar_rounding * s, (by2 - by1) / 2)
    local fill_w = (bx2 - bx1) * math.max(0, math.min(1, p.hpp / 100))
    if fill_w > 0 then
        local col
        if config.claim_colours then col = p.color
        elseif p.rank == 'boss' then col = COL.bar_red
        else col = COL.bar_green end
        local fr = math.min(r, fill_w / 2)
        dl:AddRectFilled({ bx1, by1 }, { bx1 + fill_w, by2 }, col, fr)
        if fill_w > 2 then
            dl:AddRectFilled({ bx1 + 1, by1 + 1 }, { bx1 + fill_w - 1, by1 + (by2 - by1) * 0.4 }, COL.gloss, math.min(fr, 1))
        end
    end
    if config.show_hp_text and (by2 - by1) >= 6 then
        imgui.SetWindowFontScale(0.7 * s)
        local hp = string.format('%d%%', p.hpp)
        local hw, hh = text_size(hp)
        shadow_text(dl, (bx1 + bx2 - hw) / 2, (by1 + by2 - hh) / 2, COL.text, hp)
    end

    imgui.SetWindowFontScale(1.0)

    -- Debuff icons underneath, centred on the bar
    local list = sorted_debuffs(p.server_id)
    if list ~= nil then
        local size  = config.icon_size * s
        local gap   = 2
        draw_debuff_icons(dl, list, (bx1 + bx2) / 2, fy2 + 3, size, gap)
    end
end

local function draw_plate(dl, sx, sy, p)
    if config.use_frames then
        local name = (p.rank == 'boss' and 'boss') or (p.rank == 'elite' and 'elite') or 'normal'
        local tex = load_frame(name) or load_frame('normal')
        if tex ~= nil then return draw_plate_framed(dl, sx, sy, p, tex) end
    end
    return draw_plate_shapes(dl, sx, sy, p)
end

-- Elite / NM classification
local function name_in(list, name)
    if list == nil then return false end
    local n = name:lower()
    for _, v in pairs(list) do
        if type(v) == 'string' and v:lower() == n then return true end
    end
    return false
end

local function get_rank(server_id, name, level, my_level)
    if nm_flag[server_id] or name_in(config.boss_names, name) then return 'boss' end
    if name_in(config.elite_names, name) then return 'elite' end
    if level ~= nil and my_level > 0 and level >= my_level + config.elite_levels then return 'elite' end
    return 'normal'
end

----------------------------------------------------------------------------------------------------
-- Main render
----------------------------------------------------------------------------------------------------
local function party_ids()
    local ids = {}
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local sid = party:GetMemberServerId(i)
            if sid ~= 0 then ids[bit.band(sid, 0xFFFF)] = true end
        end
    end
    return ids
end

local OVERLAY_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoInputs, ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBringToFrontOnFocus)

-- Height of the plate above a mob's feet, in yalms
local function name_key(name) return (name or ''):lower() end

local function plate_height(sid, name)
    local over = config.mob_heights and config.mob_heights[name_key(name)]
    if over ~= nil then return over end
    local h = config.head_offset
    if config.auto_height then
        local hb = hitbox[sid]
        if hb ~= nil then
            h = h + math.max(-1.0, math.min(12, (hb - 1.0) * config.size_factor))
        end
    end
    return h
end

-- A mob that moves can't be bound / asleep / stunned / petrified / terrored any more
-- The client keeps gliding a mob into place for a moment after a bind/sleep lands, so we wait
-- MOVE_GRACE seconds before taking its "held" position, then need a clear move to drop the icon.
local MOVE_GRACE  = 3
local MOVE_LIMIT2 = 2.0 * 2.0

local function check_movement(ent, i)
    local sid  = ent:GetServerId(i)
    local list = debuffs[sid]
    if list == nil then return end
    local x, y = ent:GetLocalPositionX(i), ent:GetLocalPositionY(i)
    local z    = ent:GetLocalPositionZ(i)
    for st, d in pairs(list) do
        if MOVE_BREAKS[st] then
            if d.pos == nil then
                if os.time() - (d.t or 0) >= MOVE_GRACE then d.pos = { x, y, z } end
            else
                local dx, dy, dz = x - d.pos[1], y - d.pos[2], z - d.pos[3]
                if dx * dx + dy * dy + dz * dz > MOVE_LIMIT2 then remove_debuff(sid, st) end
            end
        end
    end
end

-- Diagnostics for /np status
local diag = { frames = 0, view_ok = false, proj_ok = false, err = nil, warned = false,
               ents = 0, mobs = 0, visible = 0, in_range = 0, projected = 0, sw = 0, sh = 0 }

local function render()
    local player = GetPlayerEntity()
    if player == nil then return end

    local dev = d3d8.get_device()
    if dev == nil then return end
    view = read_matrix(dev, 2)   -- D3DTS_VIEW
    proj = read_matrix(dev, 3)   -- D3DTS_PROJECTION
    diag.frames  = diag.frames + 1
    diag.view_ok = view ~= nil
    diag.proj_ok = proj ~= nil
    if view == nil or proj == nil then
        if not diag.warned and diag.frames > 300 then
            diag.warned = true
            msg('Could not read the game camera, so plates cannot be placed. Type /np status and send the output.')
        end
        return
    end

    local sw, sh = screen_size()
    diag.sw, diag.sh = sw, sh
    local mm     = AshitaCore:GetMemoryManager()
    local ent    = mm:GetEntity()
    local tgt    = mm:GetTarget()
    local tidx   = tgt:GetTargetIndex(tgt:GetIsSubTargetActive())
    local party  = party_ids()
    local maxd2  = config.max_distance * config.max_distance
    local my_lvl = mm:GetPlayer():GetMainJobLevel() or 0

    -- Levels of party members, by entity index (for player plates)
    local pt_lvl = {}
    if config.show_players then
        local pm = mm:GetParty()
        for n = 0, 17 do
            if pm:GetMemberIsActive(n) == 1 then
                local ti = pm:GetMemberTargetIndex(n)
                if ti and ti > 0 then pt_lvl[ti] = pm:GetMemberMainJobLevel(n) end
            end
        end
    end

    diag.ents, diag.mobs, diag.visible, diag.in_range, diag.projected = 0, 0, 0, 0, 0

    -- Collect visible monsters (and players, if enabled)
    local plates = {}
    for i = 1, 0x8FF do
        if ent:GetRawEntity(i) ~= nil then
            diag.ents = diag.ents + 1
            local flags   = ent:GetRenderFlags0(i)
            local visible = bit.band(flags, 0x200) == 0x200 and bit.band(flags, 0x4000) == 0
            local spawn   = ent:GetSpawnFlags(i)
            local is_mob  = bit.band(spawn, 0x10) ~= 0
            local is_pc   = config.show_players and bit.band(spawn, 0x01) ~= 0 and not is_mob
            local hpp     = ent:GetHPPercent(i)
            local status  = ent:GetStatus(i)
            local dist2   = ent:GetDistance(i)
            local is_tgt  = (i == tidx)

            if is_mob then
                diag.mobs = diag.mobs + 1
                check_movement(ent, i)
            end
            if (is_mob or is_pc) and visible then diag.visible = diag.visible + 1 end

            if visible and (is_mob or is_pc) and status ~= 2 and status ~= 3 and hpp > 0
                and (dist2 <= maxd2 or is_tgt) then
                diag.in_range = diag.in_range + 1
                local wx, wy, wz = to_world(ent:GetLocalPositionX(i), ent:GetLocalPositionY(i),
                    ent:GetLocalPositionZ(i), plate_height(ent:GetServerId(i), ent:GetName(i)))
                local sx, sy = world_to_screen(wx, wy, wz, sw, sh)
                if sx ~= nil and sx > -150 and sx < sw + 150 and sy > -100 and sy < sh + 100 then
                    diag.projected = diag.projected + 1
                    local sid  = ent:GetServerId(i)
                    local name = ent:GetName(i) or '???'
                    local p
                    if is_pc then
                        p = { level = pt_lvl[i], rank = 'normal', color = COL.bar_green }
                    else
                        local claim = bit.band(ent:GetClaimStatus(i), 0xFFFF)
                        local color
                        if claim == 0 then color = COL.neutral
                        elseif party[claim] then color = COL.hostile
                        else color = COL.tapped end
                        local lvl = levels[sid]
                        -- mob reset (unclaimed, full HP, not fighting) a while after the last hit: forget it
                        if engaged[sid] and claim == 0 and hpp >= 100 and status ~= 1
                            and os.time() - engaged[sid] > 8 then engaged[sid] = nil end
                        p = { level = lvl, rank = get_rank(sid, name, lvl, my_lvl), color = color,
                              engaged = (party[claim] == true) or (engaged[sid] ~= nil) }
                    end
                    p.sx, p.sy, p.dist2, p.hpp = sx, sy, dist2, hpp
                    p.name, p.server_id, p.is_target = name, sid, is_tgt
                    p.idx = i
                    plates[#plates + 1] = p
                end
            end
        end
    end

    if #plates == 0 and not config.debug then return end

    -- Far plates first, near on top, current target always last (on top of everything)
    table.sort(plates, function (a, b)
        if a.is_target ~= b.is_target then return b.is_target end
        return a.dist2 > b.dist2
    end)

    imgui.SetNextWindowPos({ 0, 0 })
    imgui.SetNextWindowSize({ sw, sh })
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    if imgui.Begin('mobhpbars_overlay', true, OVERLAY_FLAGS) then
        local dl = imgui.GetWindowDrawList()

        for _, p in ipairs(plates) do
            draw_plate(dl, p.sx, p.sy, p)
        end

        -- Calibration: a dot at your own feet
        if config.debug then
            local pidx = mm:GetParty():GetMemberTargetIndex(0)
            local wx, wy, wz = to_world(ent:GetLocalPositionX(pidx), ent:GetLocalPositionY(pidx),
                ent:GetLocalPositionZ(pidx), 0)
            local sx, sy = world_to_screen(wx, wy, wz, sw, sh)
            if sx ~= nil then
                dl:AddCircleFilled({ sx, sy }, 6, COL.debug_dot)
                shadow_text(dl, sx + 10, sy - 7, COL.debug_dot,
                    string.format('axis mode %d (dot should be at your feet)', config.axis_mode))
            end
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end

ashita.events.register('d3d_present', 'np_present', function ()
    local ok, err = pcall(render)
    if not ok then
        if diag.err == nil then msg('Render error: ' .. tostring(err)) end
        diag.err = tostring(err)
    end
end)


-- Export / import of mob heights so several characters can share them.
-- File: <addon folder>/shared_heights.txt  (plain text, one entry per line)
--   @height=2.5          base height        @sizefactor=1.5     size factor
--   @auto=1              auto height on/off
--   skimmer=4.5          per-mob override (lower-case mob name = yalms)
local SHARE_FILE = 'shared_heights.txt'

local function share_path() return string.format('%s/%s', addon.path, SHARE_FILE) end

local function export_heights()
    local f, err = io.open(share_path(), 'w')
    if f == nil then msg('Export failed: ' .. tostring(err)); return end
    f:write('# MobHPBars shared mob heights - made with /np export, load with /np import\n')
    f:write(string.format('@height=%s\n', tostring(config.head_offset)))
    f:write(string.format('@sizefactor=%s\n', tostring(config.size_factor)))
    f:write(string.format('@auto=%d\n', config.auto_height and 1 or 0))
    local names, count = {}, 0
    for name in pairs(config.mob_heights or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        f:write(string.format('%s=%s\n', name, tostring(config.mob_heights[name])))
        count = count + 1
    end
    f:close()
    msg(string.format('Exported base height and %d mob heights to %s', count, SHARE_FILE))
end

local function import_heights(merge)
    local f = io.open(share_path(), 'r')
    if f == nil then msg('No ' .. SHARE_FILE .. ' found - run /np export on your other character first.'); return end
    if not merge then config.mob_heights = T{} end
    config.mob_heights = config.mob_heights or T{}
    local count = 0
    for line in f:lines() do
        line = line:gsub('\r', '')
        local key, val = line:match('^%s*([^#=][^=]-)%s*=%s*(.-)%s*$')
        if key ~= nil then
            local n = tonumber(val)
            if key == '@height' and n then config.head_offset = n
            elseif key == '@sizefactor' and n then config.size_factor = n
            elseif key == '@auto' and n then config.auto_height = (n ~= 0)
            elseif key:sub(1, 1) ~= '@' and n then
                config.mob_heights[key:lower()] = n
                count = count + 1
            end
        end
    end
    f:close()
    settings.save()
    msg(string.format('Imported base height %.1f and %d mob heights%s', config.head_offset, count,
        merge and ' (merged with your own)' or ''))
end

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------
local function help()
    msg('/np debug - calibration dot at your feet')
    msg('/np axis - cycle axis mode (1-4) until the dot sits on you')
    msg('/np height <n> | distance <n> | scale <n> | width <n> | icons <n> | round <n>')
    msg('/np hp - toggle HP%   /np claim - toggle claim colours   /np clear - clear debuffs')
    msg('/np elite <name> | /np boss <name> - toggle a mob name as elite / NM')
    msg('/np frames - toggle image frames   /np size <n> - frame height (default 34)')
    msg('/np players - toggle plates on players   /np status - diagnostics')
    msg('/np export - share heights   /np import [merge] - load shared heights')
    msg('/np glow <n> - target glow size (0 = off)   /np pulse - glow pulse   /np arrow - target arrow')
    msg('/np mobheight <n> - fix height for target\'s mob name   /np auto - size-based height   /np sizefactor <n>')
    msg('/np gamenames - toggle hiding the game\'s own monster names')
end

ashita.events.register('command', 'np_command', function (e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd ~= '/np' and cmd ~= '/mobhpbars' then return end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or nil
    local num = tonumber(args[3])

    if sub == nil then
        help()
    elseif sub == 'debug' then
        config.debug = not config.debug
        msg('Debug ' .. (config.debug and 'on' or 'off'))
    elseif sub == 'axis' then
        config.axis_mode = (config.axis_mode % 4) + 1
        msg('Axis mode ' .. config.axis_mode)
    elseif sub == 'perrow' and num then
        config.debuffs_per_row = math.max(1, math.floor(num)); msg('Debuffs per row ' .. config.debuffs_per_row)
    elseif sub == 'glow' and num then
        config.glow_px = num; msg('Target glow size ' .. num)
    elseif sub == 'arrow' then
        config.show_arrow = not config.show_arrow
        msg('Target arrow ' .. (config.show_arrow and 'on' or 'off'))
    elseif sub == 'pulse' then
        config.glow_pulse = not config.glow_pulse
        msg('Target glow pulse ' .. (config.glow_pulse and 'on' or 'off'))
    elseif sub == 'export' then
        export_heights(); return
    elseif sub == 'import' then
        import_heights(args[3] ~= nil and args[3]:lower() == 'merge'); return
    elseif sub == 'mobheight' then
        local mm  = AshitaCore:GetMemoryManager()
        local tg  = mm:GetTarget()
        local idx = tg:GetTargetIndex(tg:GetIsSubTargetActive())
        local name = idx and idx > 0 and mm:GetEntity():GetName(idx) or nil
        if name == nil or name == '' then msg('Target a mob first.'); return end
        config.mob_heights = config.mob_heights or T{}
        if num then
            config.mob_heights[name_key(name)] = num
            msg(string.format('%s plates now sit at %.1f yalms', name, num))
        else
            config.mob_heights[name_key(name)] = nil
            msg(name .. ' height override cleared (back to automatic)')
        end
    elseif sub == 'auto' then
        config.auto_height = not config.auto_height
        msg('Automatic height by mob size ' .. (config.auto_height and 'on' or 'off'))
    elseif sub == 'sizefactor' and num then
        config.size_factor = num; msg('Size factor ' .. num)
    elseif sub == 'height' and num then
        config.head_offset = num; msg('Height offset ' .. num)
    elseif sub == 'distance' and num then
        config.max_distance = num; msg('Max distance ' .. num)
    elseif sub == 'scale' and num then
        config.target_scale = num; msg('Target scale ' .. num)
    elseif sub == 'width' and num then
        config.plate_width = num; msg('Plate width ' .. num)
    elseif sub == 'round' and num then
        config.bar_rounding = num; msg('Bar rounding ' .. num)
    elseif sub == 'icons' and num then
        config.icon_size = num; msg('Icon size ' .. num)
    elseif (sub == 'elite' or sub == 'boss') and args[3] then
        local name = table.concat(args, ' ', 3)
        local key  = sub == 'elite' and 'elite_names' or 'boss_names'
        config[key] = config[key] or T{}
        local found = nil
        for k, v in pairs(config[key]) do
            if type(v) == 'string' and v:lower() == name:lower() then found = k end
        end
        if found then
            table.remove(config[key], found); msg(name .. ' removed from ' .. sub .. ' list')
        else
            table.insert(config[key], name); msg(name .. ' added to ' .. sub .. ' list')
        end
    elseif sub == 'status' then
        msg(string.format('Camera: view %s, projection %s  |  screen %dx%d  |  frames %d',
            diag.view_ok and 'OK' or 'FAILED', diag.proj_ok and 'OK' or 'FAILED', diag.sw, diag.sh, diag.frames))
        msg(string.format('Entities %d, monsters %d, visible %d, in range %d, on screen %d',
            diag.ents, diag.mobs, diag.visible, diag.in_range, diag.projected))
        msg(string.format('Axis mode %d, height %.1f, distance %d, players %s, frames %s',
            config.axis_mode, config.head_offset, config.max_distance,
            config.show_players and 'on' or 'off', config.use_frames and 'on' or 'off'))
        do
            local mm  = AshitaCore:GetMemoryManager()
            local tg  = mm:GetTarget()
            local idx = tg:GetTargetIndex(tg:GetIsSubTargetActive())
            if idx and idx > 0 then
                local e2  = mm:GetEntity()
                local sid = e2:GetServerId(idx)
                local nm  = e2:GetName(idx)
                local hb  = hitbox[sid]
                msg(string.format('Target %s: hitbox %s, plate height %.1f yalms%s', tostring(nm),
                    hb and string.format('%.1f', hb) or 'unknown', plate_height(sid, nm),
                    (config.mob_heights and config.mob_heights[name_key(nm)]) and ' (manual)' or ''))
            end
        end
        local t = load_frame('normal')
        msg('Frame image: ' .. (t and 'loaded' or ('not found at ' .. addon.path .. '/assets/frame_normal.png')))
        if diag.err then msg('Last error: ' .. diag.err) end
        return
    elseif sub == 'gamenames' then
        config.hide_game_names = not config.hide_game_names
        msg('Game monster names ' .. (config.hide_game_names and 'hidden' or 'shown')
            .. ' (applies as monsters update; zone to refresh all at once)')
    elseif sub == 'players' then
        config.show_players = not config.show_players
        msg('Player plates ' .. (config.show_players and 'on' or 'off'))
    elseif sub == 'frames' then
        config.use_frames = not config.use_frames
        msg('Image frames ' .. (config.use_frames and 'on' or 'off (shape style)'))
    elseif sub == 'size' and num then
        config.frame_height = num; msg('Frame height ' .. num)
    elseif sub == 'claim' then
        config.claim_colours = not config.claim_colours
        msg('Claim colours ' .. (config.claim_colours and 'on' or 'off (classic green)'))
    elseif sub == 'hp' then
        config.show_hp_text = not config.show_hp_text
        msg('HP% text ' .. (config.show_hp_text and 'on' or 'off'))
    elseif sub == 'clear' then
        debuffs = {}; msg('Debuffs cleared')
    else
        help()
        return
    end
    settings.save()
end)

ashita.events.register('unload', 'np_unload', function ()
    icon_cache = {}
    frame_tex = {}
    settings.save()
end)
