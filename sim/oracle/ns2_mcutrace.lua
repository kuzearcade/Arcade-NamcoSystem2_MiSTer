-- The I/O MCU's own traces, from power-on (docs/PLAN.md M2, D2), for the
-- MCU harness (sim/rtl/mcu):
--   <MP_OUT>/mcu_bus.txt  every access in the MCU's space, in order:
--                         "R|W addr data" (opcode fetches included)
--   <MP_OUT>/mcu_pc.txt   MAME's instruction trace (the debugger's `trace`)
--   <MP_OUT>/mcu_irq.txt  "F access_index pc" for each interrupt vector read
-- for MP_FRAMES frames (the boot script presses Start as the captures do).
-- MP_TRACE=pc takes the instruction trace alone (run with -debug -debugger
-- none); otherwise the bus and interrupt traces alone, without the debugger,
-- whose disassembler reads memory through the taps. MAME is deterministic,
-- so the two runs execute the same.
-- Guarded against a re-run (SS-7); taps kept in _G (MS1-10).
if _G.ns2_mcu_loaded then return end
_G.ns2_mcu_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT    = os.getenv("MP_OUT") or "."
local FRAMES = tonumber(os.getenv("MP_FRAMES") or "300")
local mcu
for tag, d in pairs(manager.machine.devices) do
  if tag:match("c65mcu:mcu$") or tag:match("c68mcu:mcu$") then mcu = d end
end
local sp = mcu.spaces["program"]
local PC = os.getenv("MP_TRACE") == "pc"
local bus = not PC and io.open(OUT .. "/mcu_bus.txt", "w")
local irqf = not PC and io.open(OUT .. "/mcu_irq.txt", "w")
local n, F, done = 0, 0, false
local vectors = { [0x1ff8] = true, [0x1fea] = true, [0x1ffc] = true, [0xfff8] = true, [0xfffa] = true, [0xfffc] = true }
if not PC then
_G.ns2_mcu_r = sp:install_read_tap(0, 0xffff, "mcur", function(o, d)
  if done then return end
  if vectors[o] then irqf:write(string.format("%d %d %04x\n", F, n, mcu.state["PC"].value)) end
  bus:write(string.format("R %04x %02x\n", o, d & 0xff)); n = n + 1
end)
_G.ns2_mcu_w = sp:install_write_tap(0, 0xffff, "mcuw", function(o, d)
  if done then return end
  bus:write(string.format("W %04x %02x\n", o, d & 0xff)); n = n + 1
end)
end
local dbg = manager.machine.debugger
if PC then dbg:command("trace " .. OUT .. "/mcu_pc.txt," .. mcu.tag .. ",noloop") end   -- noloop: every instruction, loops not collapsed
_G.ns2_mcu_f = emu.add_machine_frame_notifier(function()
  F = F + 1
  if F >= FRAMES and not done then
    done = true
    if PC then dbg:command("trace off," .. mcu.tag) else bus:close(); irqf:close() end
    manager.machine:exit()
  end
end)
