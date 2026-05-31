-- agent.lua  (replaces bridge.lua)
-- File-based MCP agent for Claude Code.
-- No WebSocket, no crash risk. One command at a time via the filesystem.
--
-- IPC protocol:
--   Node writes  agent/cmd.lua     → Lua table literal, loadstring()ed here
--   Lua  writes  agent/result.json → JSON result, JSON.parse()d in Node
--   Lua  writes  agent/status.json → progress during async ops (dump etc.)
--
-- Commands: ping | eval | dump | inspect | players

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
