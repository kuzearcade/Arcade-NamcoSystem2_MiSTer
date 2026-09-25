-- A 68000's bus accesses from power-on (docs/PLAN.md M2), for the board
-- testbench (sim/rtl/ns2_frames): <MP_OUT>/<cpu>_bus.txt, one line per word
-- access in order: "R|W addr data mask frame". MP_CPU is maincpu (default)
-- or slave; MP_MAX caps the accesses. Also <MP_OUT>/ports.txt: the input
-- ports' values at the start (the testbench sets the same).
-- The boot script is run first when MP_PLAY names it. Guarded (SS-7);
-- taps kept in _G (MS1-10).
if _G.ns2_bus_loaded then return end
_G.ns2_bus_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT = os.getenv("MP_OUT") or "."
local CPU = os.getenv("MP_CPU") or "maincpu"
local MAX = tonumber(os.getenv("MP_MAX") or "2000000")
local sp = manager.machine.devices[":" .. CPU].spaces["program"]
local f = io.open(OUT .. "/" .. CPU .. "_bus.txt", "w")
local n, F, done = 0, 0, false
local function fin() if not done then done = true; f:close(); manager.machine:exit() end end
_G.ns2_bus_r = sp:install_read_tap(0, 0xffffff, "busr", function(o, d, m)
  if done then return end
  f:write(string.format("R %06x %04x %04x %d\n", o, d, m, F)); n = n + 1
  if n >= MAX then fin() end
end)
_G.ns2_bus_w = sp:install_write_tap(0, 0xffffff, "busw", function(o, d, m)
  if done then return end
  f:write(string.format("W %06x %04x %04x %d\n", o, d, m, F)); n = n + 1
  if n >= MAX then fin() end
end)
local pf = io.open(OUT .. "/ports.txt", "w")
for tag, p in pairs(manager.machine.ioport.ports) do pf:write(string.format("%s %04x\n", tag, p:read())) end
pf:close()
_G.ns2_bus_f = emu.add_machine_frame_notifier(function() F = F + 1 end)
