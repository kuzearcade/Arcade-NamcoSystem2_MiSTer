-- Scripted play for oracle captures (MAME 0.289), after the boot script
-- (ns2_boot.lua, which it runs first): Coin 1 at frame MP_PLAY_FROM (default
-- 900), 1 Player Start 60 frames later, then P1 Button 1 pulsed every 8
-- frames, Button 2 every 97, Button 3 every 151, and a move pattern that
-- changes every 60 frames. Fields are found by name on every port, so the
-- one script drives every set (a set without a field simply skips it);
-- analog controls stay centred. The RTL harnesses reproduce it exactly
-- (F counts frame_done calls, 1 = first). Guarded against a re-run (SS-7).
if _G.ns2_play_loaded then return end
_G.ns2_play_loaded = true
dofile((os.getenv("MP_BOOT") or (debug.getinfo(1, "S").source:sub(2):match("(.*/)") .. "ns2_boot.lua")))
local F0 = tonumber(os.getenv("MP_PLAY_FROM") or "900")
local fields = {}
for _, p in pairs(manager.machine.ioport.ports) do
  for n, f in pairs(p.fields) do fields[n] = f end
end
local moves = { {}, {"P1 Right"}, {"P1 Right"}, {"P1 Left"}, {"P1 Right", "P1 Up"}, {"P1 Down"}, {"P1 Left", "P1 Down"} }
local held = {}
local function set(n, v) local f = fields[n]; if f then f:set_value(v) end end
local F = 0
_G.ns2_play_sub = emu.add_machine_frame_notifier(function()
  F = F + 1
  for n, _ in pairs(held) do set(n, 0) end
  held = {}
  local function press(n) set(n, 1); held[n] = true end
  if F >= F0 and F < F0 + 6 then press("Coin 1") end
  if F >= F0 + 60 and F < F0 + 66 then press("1 Player Start") end
  if F >= F0 + 120 then
    if (F % 8) < 4 then press("P1 Button 1") end
    if (F % 97) < 6 then press("P1 Button 2") end
    if (F % 151) < 6 then press("P1 Button 3") end
    for _, n in ipairs(moves[(F // 60) % #moves + 1]) do press(n) end
  end
end)
