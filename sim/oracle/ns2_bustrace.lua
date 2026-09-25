-- A 68000's bus accesses from power-on (docs/PLAN.md M2), for the board
-- testbench (sim/rtl/ns2_frames): <MP_OUT>/<cpu>_bus.txt, one line per word
-- access in order: "R|W addr data mask frame". MP_CPU is maincpu (default),
-- slave, audiocpu or mcu (the C65's or C68's core); MP_MAX caps the
-- accesses; MP_WONLY=1 records writes only; MP_TIME=1 appends the machine
-- time in 49.152 MHz clocks. Also <MP_OUT>/ports.txt: the input
-- ports' values at the start (the testbench sets the same).
-- The boot script is run first when MP_PLAY names it. Guarded (SS-7);
-- taps kept in _G (MS1-10).
if _G.ns2_bus_loaded then return end
_G.ns2_bus_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT = os.getenv("MP_OUT") or "."
local CPU = os.getenv("MP_CPU") or "maincpu"
local MAX = tonumber(os.getenv("MP_MAX") or "2000000")
local WONLY = os.getenv("MP_WONLY") == "1"
local TIME = os.getenv("MP_TIME") == "1"
local function ts() return TIME and string.format(" %.0f", manager.machine.time:as_double() * 49152000) or "" end
local dev = manager.machine.devices[":" .. CPU]
if CPU == "mcu" then
  for tag, d in pairs(manager.machine.devices) do
    if tag:match("c65mcu:mcu$") or tag:match("c68mcu:mcu$") then dev = d end
  end
end
local sp = dev.spaces["program"]
local f = io.open(OUT .. "/" .. CPU .. "_bus.txt", "w")
local n, F, done = 0, 0, false
local function fin() if not done then done = true; f:close(); manager.machine:exit() end end
_G.ns2_bus_r = sp:install_read_tap(0, sp.address_mask, "busr", function(o, d, m)
  if done or WONLY then return end
  f:write(string.format("R %06x %04x %04x %d%s\n", o, d, m, F, ts())); n = n + 1
  if n >= MAX then fin() end
end)
_G.ns2_bus_w = sp:install_write_tap(0, sp.address_mask, "busw", function(o, d, m)
  if done then return end
  f:write(string.format("W %06x %04x %04x %d%s\n", o, d, m, F, ts())); n = n + 1
  if n >= MAX then fin() end
end)
local pf = io.open(OUT .. "/ports.txt", "w")
for tag, p in pairs(manager.machine.ioport.ports) do
  pf:write(string.format("%s %04x\n", tag, p:read()))
  -- the boot script's Start button (ns2_boot.lua): "start<port> mask" and its first frame
  for n, fl in pairs(p.fields) do
    if n == "1 Player Start" then pf:write(string.format("start%s %04x\nboot_start %04x\n", tag, fl.mask, tonumber(os.getenv("MP_BOOT_START") or "300"))) end
  end
end
pf:close()
_G.ns2_bus_f = emu.add_machine_frame_notifier(function() F = F + 1 end)
