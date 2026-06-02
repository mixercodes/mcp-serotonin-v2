-- agent.lua  (replaces bridge.lua)
-- File-based MCP agent for AI assistants.
-- IPC protocol:
--   Node writes  agent/cmd.lua     → Lua table literal, loadstring()ed here
--   Lua  writes  agent/result.json → JSON result, JSON.parse()d in Node
--   Lua  writes  agent/status.json → progress during async ops (dump etc.)
--
-- Commands: ping | eval | dump

local AGENT_DIR   = "agent"
local CMD_FILE    = AGENT_DIR .. "/cmd.lua"
local RESULT_FILE = AGENT_DIR .. "/result.json"
local STATUS_FILE = AGENT_DIR .. "/status.json"
local DUMP_DIR    = "dumps"

file.mkdir(AGENT_DIR)

-- ── JSON encoder ──────────────────────────────────────────────────────────
-- Only used for results; commands come in as Lua tables (no parser needed).

local function json(v, depth)
    depth = depth or 0
    if depth > 8 then return '"[deep]"' end
    local t = type(v)
    if t == "nil"     then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number"  then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.10g", v)
    end
    if t == "string" then
        v = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
              :gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. v .. '"'
    end
    if t == "table" then
        local is_arr = (#v > 0)
        local parts  = {}
        if is_arr then
            for i = 1, #v do parts[i] = json(v[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, val in pairs(v) do
                parts[#parts+1] = '"' .. tostring(k) .. '":' .. json(val, depth + 1)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    if t == "userdata" then
        -- Try Instance
        local ok, name, cn = pcall(function() return v.Name, v.ClassName end)
        if ok and name then
            return '{"__type":"Instance","Name":' .. json(name) .. ',"ClassName":' .. json(cn) .. "}"
        end
        -- Try Vector3
        local ok2, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
        if ok2 then
            return string.format('{"__type":"Vector3","X":%.4f,"Y":%.4f,"Z":%.4f}', x, y, z)
        end
        return '"[userdata]"'
    end
    return '"[' .. t .. ']"'
end

local function write_result(id, ok, value, err, elapsed)
    local val_str = ok and json(value) or "null"
    local err_str = err and ('"' .. tostring(err):gsub('"', '\\"') .. '"') or "null"
    local body = string.format(
        '{"id":%s,"ok":%s,"value":%s,"error":%s,"elapsed":%s}',
        json(id), ok and "true" or "false", val_str, err_str, json(elapsed or 0)
    )
    file.write(RESULT_FILE, body)
end

local function write_status(state, progress, output)
    local parts = {'"state":' .. json(state)}
    if progress then parts[#parts+1] = '"progress":' .. json(progress) end
    if output   then parts[#parts+1] = '"output":'   .. json(output)   end
    file.write(STATUS_FILE, "{" .. table.concat(parts, ",") .. "}")
end

-- ── Dump logic (same as dump_agent.lua, embedded here) ───────────────────

local TEE   = "\226\148\156\226\148\128"  -- ├─
local ELBOW = "\226\148\148\226\148\128"  -- └─
local PIPE  = "\226\148\130 "             -- │ (+ space)
local BLANK = "  "

local VALUE_CLASSES = {
    BoolValue=true, IntValue=true, NumberValue=true, StringValue=true,
    Vector3Value=true, Color3Value=true, ObjectValue=true,
}

local function fv3(v) return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
local function fnum(n)
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return string.format("%.2f", n)
end

local function fmt_val(child, ccn)
    local ok, v = pcall(function() return child.Value end)
    if not ok then return "?" end
    if ccn == "Vector3Value" then local ok2,s=pcall(fv3,v); return ok2 and s or "?" end
    if ccn == "Color3Value"  then
        local ok2,s=pcall(function() return string.format("rgb(%d,%d,%d)",
            math.floor(v.R*255),math.floor(v.G*255),math.floor(v.B*255)) end)
        return ok2 and s or "?"
    end
    if ccn == "ObjectValue" then
        if v == nil then return "nil" end
        local ok2,ref=pcall(function() return v.Name end)
        return ok2 and ("-> "..ref) or "-> ?"
    end
    if ccn == "NumberValue" then return fnum(v) end
    return tostring(v)
end

local function inline_props(inst)
    local r = {}
    local ok1,pos=pcall(function() return inst.Position end)
    if ok1 and pos then local ok2,s=pcall(fv3,pos); if ok2 then r[#r+1]="pos="..s end end
    local ok3,sz=pcall(function() return inst.Size end)
    if ok3 and sz then local ok4,s=pcall(fv3,sz); if ok4 then r[#r+1]="size="..s end end
    local ok5,hp=pcall(function() return inst.Health end)
    if ok5 and type(hp)=="number" then r[#r+1]="hp="..fnum(hp) end
    local ok6,pp=pcall(function() return inst.PrimaryPart end)
    if ok6 and pp then local ok7,ppn=pcall(function() return pp.Name end); if ok7 then r[#r+1]="primary="..ppn end end
    local ok8,attrs=pcall(function() return inst:GetAttributes() end)
    if ok8 and attrs then
        for k,v in pairs(attrs) do
            local t=type(v)
            local vs=(t=="boolean" or t=="string") and tostring(v) or (t=="number") and fnum(v) or tostring(v)
            r[#r+1]="@"..k.."="..vs
        end
    end
    if #r==0 then return "" end
    return "  {"..table.concat(r,"  ").."}"
end

local dump_lines, dump_count, dump_max_depth
local dump_ws_children, dump_idx, dump_total
local dump_start_t, dump_cmd_id, dump_output_path

local function do_dump_node(inst, prefix, is_last, depth)
    local ok,name,cn=pcall(function() return inst.Name, inst.ClassName end)
    if not ok then return end
    local conn=is_last and ELBOW or TEE
    local cpfx=prefix..(is_last and BLANK or PIPE)
    dump_count=dump_count+1
    dump_lines[#dump_lines+1]=prefix..conn.."["..cn.."] "..name..inline_props(inst)
    local ok2,children=pcall(function() return inst:GetChildren() end)
    if not ok2 or not children or #children==0 then return end
    if depth>=dump_max_depth then
        dump_lines[#dump_lines+1]=cpfx..ELBOW.."[..."..#children.." children, depth limit]"
        return
    end
    for i,child in ipairs(children) do
        local cname,ccn
        local ok3=pcall(function() cname=child.Name; ccn=child.ClassName end)
        if ok3 then
            local last=(i==#children)
            if VALUE_CLASSES[ccn] then
                local c=last and ELBOW or TEE
                dump_lines[#dump_lines+1]=cpfx..c.."["..ccn.."] "..cname.." = "..fmt_val(child,ccn)
            else
                do_dump_node(child,cpfx,last,depth+1)
            end
        end
    end
end

local function start_dump(cmd)
    dump_cmd_id     = cmd.id
    dump_max_depth  = cmd.payload.depth or 6
    dump_lines      = {}
    dump_count      = 0
    dump_idx        = 0
    dump_start_t    = utility.GetTickCount() / 1000

    local place_id = "unknown"
    pcall(function() place_id = tostring(game.PlaceId) end)
    local t = utility.GetSystemTime()
    local ds = string.format("%04d-%02d-%02d_%02d-%02d-%02d",
        t.year,t.month,t.day,t.hour,t.minute,t.second)
    file.mkdir(DUMP_DIR)
    dump_output_path = DUMP_DIR.."/place_"..place_id.."_"..ds..".txt"

    dump_ws_children = game.Workspace:GetChildren()
    dump_total       = #dump_ws_children

    dump_lines[#dump_lines+1] = "=== Workspace Dump ==="
    dump_lines[#dump_lines+1] = "PlaceId:   "..place_id
    dump_lines[#dump_lines+1] = "Date/Time: "..string.format("%04d-%02d-%02d %02d:%02d:%02d",
        t.year,t.month,t.day,t.hour,t.minute,t.second)
    dump_lines[#dump_lines+1] = "Max depth: "..dump_max_depth
    dump_lines[#dump_lines+1] = ""

    write_status("running", "0/"..dump_total)
end

-- ── Command dispatcher ────────────────────────────────────────────────────

local agent_busy = false

local function dispatch(cmd)
    local t0 = utility.GetTickCount()

    if cmd.type == "ping" then
        write_result(cmd.id, true, "pong", nil, utility.GetTickCount() - t0)

    elseif cmd.type == "eval" then
        local code = cmd.payload.code or "return nil"
        local fn, load_err = loadstring(code)
        if not fn then
            write_result(cmd.id, false, nil, load_err, utility.GetTickCount() - t0)
            return
        end
        local ok, val = pcall(fn)
        if ok then
            write_result(cmd.id, true, val, nil, utility.GetTickCount() - t0)
        else
            write_result(cmd.id, false, nil, tostring(val), utility.GetTickCount() - t0)
        end

    elseif cmd.type == "dump" then
        -- Async: starts the dump process, result written when chunks complete
        start_dump(cmd)
        -- Do NOT write result now — onUpdate will write it when done

    elseif cmd.type == "inspect_service" then
        local svc_name = cmd.payload.name or "Players"
        local svc
        local ok = pcall(function() svc = game.GetService(svc_name) end)
        if not ok or not svc then
            write_result(cmd.id, false, nil, "Service not found: "..svc_name, utility.GetTickCount()-t0)
            return
        end
        local name, cn
        local ok2 = pcall(function() name=svc.Name; cn=svc.ClassName end)
        if not ok2 then
            write_result(cmd.id, false, nil, "Cannot access service", utility.GetTickCount()-t0)
            return
        end
        local child_list = {}
        local ok3, children = pcall(function() return svc:GetChildren() end)
        if ok3 and children then
            for i, c in ipairs(children) do
                local ok4, cn2, ccn = pcall(function() return c.Name, c.ClassName end)
                if ok4 then child_list[#child_list+1] = "["..ccn.."] "..cn2 end
                if i >= 100 then child_list[#child_list+1] = "...truncated"; break end
            end
        end
        write_result(cmd.id, true, {Name=name,ClassName=cn,ChildCount=#child_list,Children=child_list}, nil, utility.GetTickCount()-t0)

    elseif cmd.type == "screen_info" then
        local sw, sh
        pcall(function() sw, sh = cheat.GetWindowSize() end)
        local cx, cy, cz
        pcall(function() local c=game.CameraPosition; cx,cy,cz=c.X,c.Y,c.Z end)
        local mx, my
        pcall(function() local m=utility.GetMousePos(); mx,my=m[1],m[2] end)
        write_result(cmd.id, true, {
            width=sw, height=sh,
            camera = cx and {x=cx,y=cy,z=cz} or nil,
            mouse  = mx and {x=mx,y=my}       or nil,
        }, nil, utility.GetTickCount()-t0)

    elseif cmd.type == "world_to_screen" then
        local px = cmd.payload.x or 0
        local py = cmd.payload.y or 0
        local pz = cmd.payload.z or 0
        local sx, sy, on
        local ok = pcall(function()
            sx, sy, on = utility.WorldToScreen(Vector3.new(px, py, pz))
        end)
        if ok then
            write_result(cmd.id, true, {x=sx, y=sy, on_screen=on}, nil, utility.GetTickCount()-t0)
        else
            write_result(cmd.id, false, nil, "WorldToScreen failed", utility.GetTickCount()-t0)
        end

    elseif cmd.type == "get_bones" then
        local target_name = cmd.payload.player_name
        local R6  = {"HumanoidRootPart","Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"}
        local R15 = {"HumanoidRootPart","Head","UpperTorso","LowerTorso",
                     "LeftUpperArm","LeftLowerArm","LeftHand",
                     "RightUpperArm","RightLowerArm","RightHand",
                     "LeftUpperLeg","LeftLowerLeg","LeftFoot",
                     "RightUpperLeg","RightLowerLeg","RightFoot"}
        -- Try entity first (remote players), then fall back to character parts (local player)
        local target_entity = nil
        local ok, eplayers = pcall(function() return entity.GetPlayers(false) end)
        if ok and eplayers then
            for _, p in ipairs(eplayers) do
                if p.Name == target_name then target_entity=p; break end
            end
        end
        local char = game.Workspace:FindFirstChild(target_name)
        if not target_entity and not char then
            write_result(cmd.id, false, nil, "Player not found: "..tostring(target_name), utility.GetTickCount()-t0)
            return
        end
        -- Detect rig type from character
        local bone_list = R6
        if char and char:FindFirstChild("UpperTorso") then bone_list = R15 end
        local bones = {}
        for _, bone in ipairs(bone_list) do
            local pos = nil
            if target_entity then
                local ok2, p = pcall(function() return target_entity:GetBonePosition(bone) end)
                if ok2 and p then pos = p end
            elseif char then
                local part = char:FindFirstChild(bone)
                if part then
                    local ok2, p = pcall(function() return part.Position end)
                    if ok2 and p then pos = p end
                end
            end
            -- Filter zero-position bones (bone doesn't exist in this rig)
            if pos and not (pos.X == 0 and pos.Y == 0 and pos.Z == 0) then
                bones[bone] = {x=pos.X, y=pos.Y, z=pos.Z}
            end
        end
        -- Screen projection for each bone (always include on_screen flag)
        for bone, pos in pairs(bones) do
            local ok3, sx, sy, on = pcall(function()
                return utility.WorldToScreen(Vector3.new(pos.x, pos.y, pos.z))
            end)
            if ok3 then bones[bone].sx=sx; bones[bone].sy=sy; bones[bone].on_screen=on end
        end
        write_result(cmd.id, true, bones, nil, utility.GetTickCount()-t0)

    elseif cmd.type == "find_by_class" then
        local class_name  = cmd.payload.class_name
        local root_path   = cmd.payload.root or "game.Workspace"
        local max_depth   = math.min(cmd.payload.depth or 4, 6)
        local MAX_RESULTS = 100
        local results = {}

        local function search(inst, depth)
            if depth > max_depth or #results >= MAX_RESULTS then return end
            local ok2, children = pcall(function() return inst:GetChildren() end)
            if not ok2 or not children then return end
            for _, child in ipairs(children) do
                if #results >= MAX_RESULTS then return end
                local cname, ccn
                local ok3 = pcall(function() cname=child.Name; ccn=child.ClassName end)
                if ok3 then
                    if ccn == class_name then
                        local entry = {Name=cname, ClassName=ccn}
                        -- Include parent name so identical-named instances are distinguishable
                        local ok_p, pname = pcall(function() return inst.Name end)
                        if ok_p then entry.Parent=pname end
                        local ok4, pos = pcall(function() return child.Position end)
                        if ok4 and pos then
                            local ok5, s = pcall(fv3, pos)
                            if ok5 then entry.pos=s end
                        end
                        results[#results+1] = entry
                    end
                    search(child, depth+1)
                end
            end
        end

        local fn = loadstring("return "..root_path)
        local ok, root = pcall(fn)
        if not ok or not root then
            write_result(cmd.id, false, nil, "Cannot resolve: "..root_path, utility.GetTickCount()-t0)
            return
        end
        search(root, 0)
        write_result(cmd.id, true, {count=#results, results=results}, nil, utility.GetTickCount()-t0)

    elseif cmd.type == "dump_subtree" then
        local root_path = cmd.payload.root or "game.Workspace"
        local max_depth = math.min(cmd.payload.depth or 4, 6)
        local MAX_INST  = 500
        local sub_lines = {}
        local sub_count = 0
        local truncated = false

        local function sub_dump(inst, prefix, is_last, depth)
            if sub_count >= MAX_INST then truncated=true; return end
            local ok, name, cn = pcall(function() return inst.Name, inst.ClassName end)
            if not ok then return end
            local conn = is_last and ELBOW or TEE
            local cpfx = prefix..(is_last and BLANK or PIPE)
            sub_count = sub_count+1
            sub_lines[#sub_lines+1] = prefix..conn.."["..cn.."] "..name..inline_props(inst)
            local ok2, children = pcall(function() return inst:GetChildren() end)
            if not ok2 or not children or #children==0 then return end
            if depth >= max_depth then
                sub_lines[#sub_lines+1] = cpfx..ELBOW.."[..."..#children.." children, depth limit]"
                return
            end
            for i, child in ipairs(children) do
                if sub_count >= MAX_INST then
                    sub_lines[#sub_lines+1] = cpfx..ELBOW.."[...truncated at "..MAX_INST.."]"
                    truncated=true; return
                end
                local cname, ccn
                local ok3=pcall(function() cname=child.Name; ccn=child.ClassName end)
                if ok3 then
                    local last=(i==#children)
                    if VALUE_CLASSES[ccn] then
                        local c=last and ELBOW or TEE
                        sub_lines[#sub_lines+1]=cpfx..c.."["..ccn.."] "..cname.." = "..fmt_val(child,ccn)
                    else
                        sub_dump(child,cpfx,last,depth+1)
                    end
                end
            end
        end

        local fn = loadstring("return "..root_path)
        local ok, root = pcall(fn)
        if not ok or not root then
            write_result(cmd.id, false, nil, "Cannot resolve: "..root_path, utility.GetTickCount()-t0)
            return
        end
        sub_dump(root, "", true, 0)
        write_result(cmd.id, true, {
            root=root_path, count=sub_count, truncated=truncated,
            tree=table.concat(sub_lines, "\n")
        }, nil, utility.GetTickCount()-t0)

    elseif cmd.type == "get_attributes" then
        local path = cmd.payload.path
        local fn, err = loadstring("return "..path)
        if not fn then
            write_result(cmd.id, false, nil, "bad path: "..tostring(err), utility.GetTickCount()-t0)
            return
        end
        local ok, inst = pcall(fn)
        if not ok or inst == nil then
            write_result(cmd.id, false, nil, "instance not found", utility.GetTickCount()-t0)
            return
        end
        local ok2, attrs = pcall(function() return inst:GetAttributes() end)
        if not ok2 then
            write_result(cmd.id, false, nil, "GetAttributes failed: "..tostring(attrs), utility.GetTickCount()-t0)
            return
        end
        local result = {}
        for _, attr in pairs(attrs) do
            result[#result+1] = {name=attr.Name, type=attr.TypeName, value=attr.Value}
        end
        write_result(cmd.id, true, result, nil, utility.GetTickCount()-t0)

    else
        write_result(cmd.id, false, nil, "unknown command: "..tostring(cmd.type),
            utility.GetTickCount() - t0)
    end
end

-- ── onUpdate: command polling + dump chunk processing ────────────────────

cheat.register("onUpdate", function()
    -- Process one dump chunk per tick
    if dump_ws_children then
        dump_idx = dump_idx + 1
        local child = dump_ws_children[dump_idx]

        if not child then
            -- Dump complete
            local elapsed = utility.GetTickCount()/1000 - dump_start_t
            dump_lines[#dump_lines+1] = ""
            dump_lines[#dump_lines+1] = "Total: "..dump_count.." instances"
            dump_lines[#dump_lines+1] = string.format("Time:  %.2fs", elapsed)
            file.write(dump_output_path, table.concat(dump_lines, "\n"))
            write_status("done", dump_total.."/"..dump_total, dump_output_path)
            write_result(dump_cmd_id, true, dump_output_path, nil, math.floor(elapsed * 1000))
            -- Clear dump state
            dump_ws_children = nil
            dump_lines       = nil
            agent_busy       = false
            return
        end

        local ok, cname = pcall(function() return child.Name end)
        if ok then
            -- Update status every 5 children to avoid excessive file writes
            if dump_idx % 5 == 0 then
                write_status("running", dump_idx.."/"..dump_total, cname)
            end
        end
        do_dump_node(child, "", dump_idx == dump_total, 1)
        return  -- skip command polling while dumping
    end

    -- Poll for new commands
    if agent_busy then return end
    local raw = file.read(CMD_FILE)
    if not raw then return end

    file.delete(CMD_FILE)
    agent_busy = true

    local fn = loadstring(raw)
    if not fn then
        agent_busy = false
        return
    end

    local ok, cmd = pcall(fn)
    if not ok or type(cmd) ~= "table" then
        agent_busy = false
        return
    end

    -- Async commands keep agent_busy=true until they finish
    local is_async = (cmd.type == "dump")
    dispatch(cmd)
    if not is_async then
        agent_busy = false
    end
end)

-- ── onPaint: one-line status HUD (bottom-right) ───────────────────────────

local FONT        = "SmallestPixel"
local COLOR_GRAY  = Color3.fromRGB(160, 160, 160)
local COLOR_YELL  = Color3.fromRGB(255, 220, 50)
local COLOR_GREEN = Color3.fromRGB(80, 255, 80)

cheat.register("onPaint", function()
    local sw, sh = cheat.GetWindowSize()
    local text, col

    if dump_ws_children then
        text = string.format("Agent: dumping %d/%d", dump_idx, dump_total)
        col  = COLOR_YELL
    elseif agent_busy then
        text = "Agent: busy"
        col  = COLOR_YELL
    else
        text = "Agent: idle"
        col  = COLOR_GRAY
    end

    local ok, tw = pcall(function() return draw.GetTextSize(text, FONT) end)
    local x = ok and tw and (sw - 10 - tw) or (sw - 150)
    draw.TextOutlined(text, x, sh - 20, col, FONT, 180)
end)

-- ── Shutdown ──────────────────────────────────────────────────────────────

cheat.register("shutdown", function()
    if dump_ws_children then
        dump_lines[#dump_lines+1] = ""
        dump_lines[#dump_lines+1] = "[incomplete -- shutdown after "..dump_count.." instances]"
        file.write(dump_output_path, table.concat(dump_lines, "\n"))
    end
    write_status("offline")
end)

-- ── Ready ─────────────────────────────────────────────────────────────────

write_status("idle")
