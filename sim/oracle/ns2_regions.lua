-- Dump every ROM region MAME loaded for the running set into MP_OUT/<tag>.bin
-- (tags with ':' written as '_'), then exit. tools/ns2_regions.py compares
-- them with tools/ns2_romdata.py's rebuild (MS1-49: prove byte order against
-- MAME's memory, never assume it).
local out = os.getenv("MP_OUT") or "."
local function guard(fn) return function(...) local ok, e = pcall(fn, ...); if not ok then print("lua error: " .. tostring(e)) end end end
_G.ns2_regions_sub = emu.add_machine_frame_notifier(guard(function()
  for tag, r in pairs(manager.machine.memory.regions) do
    local t = {}
    for a = 0, r.size - 1 do t[#t + 1] = string.char(r:read_u8(a)) end
    local f = io.open(out .. "/" .. tag:gsub("^:", ""):gsub(":", "_") .. ".bin", "wb")
    f:write(table.concat(t)); f:close()
  end
  manager.machine:exit()
end))
