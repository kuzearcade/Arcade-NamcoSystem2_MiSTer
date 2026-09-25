-- Q2 (docs/PLAN.md): which 1 KB pages of the work RAMs each 68000 touches.
-- MAME maps the master's at 0x100000-0x10ffff and the slave's at
-- 0x100000-0x13ffff; the board's sizes decide the M10K budget (Appendix F).
-- Runs MP_FRAMES frames (the boot script presses Start, as ns2_capture.lua
-- does), counting from frame MP_AFTER (after the boot's RAM test), then
-- writes <MP_OUT>/ramuse.txt: "cpu page(hex) reads writes".
if _G.ns2_ram_loaded then return end
_G.ns2_ram_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT    = os.getenv("MP_OUT") or "."
local FRAMES = tonumber(os.getenv("MP_FRAMES") or "3600")
local AFTER  = tonumber(os.getenv("MP_AFTER") or "0")
local F = 0
local function guard(fn) return function(...) local ok, e = pcall(fn, ...); if not ok then print("tap error: " .. tostring(e)) end end end

local use = { m = {}, s = {} }
_G.ns2_ram_taps = {}
local cpus = { { "m", ":maincpu", 0x10ffff }, { "s", ":slave", 0x13ffff } }
for _, c in ipairs(cpus) do
  local sp = manager.machine.devices[c[2]].spaces["program"]
  local u = use[c[1]]
  local function hit(kind) return guard(function(off)
    if F < AFTER then return end
    local p = (off - 0x100000) // 1024
    u[p] = u[p] or { 0, 0 }
    u[p][kind] = u[p][kind] + 1
  end) end
  _G.ns2_ram_taps[#_G.ns2_ram_taps + 1] = sp:install_read_tap(0x100000, c[3], "ns2ram_r" .. c[1], hit(1))
  _G.ns2_ram_taps[#_G.ns2_ram_taps + 1] = sp:install_write_tap(0x100000, c[3], "ns2ram_w" .. c[1], hit(2))
end

_G.ns2_ram_sub = emu.add_machine_frame_notifier(guard(function()
  F = F + 1
  if F >= FRAMES then
    local f = io.open(OUT .. "/ramuse.txt", "w")
    for _, c in ipairs(cpus) do
      local pages = {}
      for p in pairs(use[c[1]]) do pages[#pages + 1] = p end
      table.sort(pages)
      for _, p in ipairs(pages) do
        f:write(string.format("%s %03x %d %d\n", c[1], p, use[c[1]][p][1], use[c[1]][p][2]))
      end
    end
    f:close()
    manager.machine:exit()
  end
end))
