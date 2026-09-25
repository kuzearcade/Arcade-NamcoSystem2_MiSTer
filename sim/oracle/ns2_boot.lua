-- Deterministic cold boot for the oracle (and the same schedule in the RTL
-- harnesses): the capture always starts from MAME's all-ones EEPROM (a clean
-- nvram/ directory), and several games stop on an EEPROM warning ("35 WARNING
-- 00180040 EXIT = 1P START") until Start is pressed. P1 Start is pressed for
-- frames MP_BOOT_START .. +5 (default 300). Guarded against a re-run (SS-7).
if _G.ns2_boot_loaded then return end
_G.ns2_boot_loaded = true
local S0 = tonumber(os.getenv("MP_BOOT_START") or "300")
local field
for _, p in pairs(manager.machine.ioport.ports) do
  for n, f in pairs(p.fields) do if n == "1 Player Start" then field = f end end
end
local F = 0
_G.ns2_boot_sub = emu.add_machine_frame_notifier(function()
  F = F + 1
  if field then field:set_value((F >= S0 and F < S0 + 6) and 1 or 0) end
end)
