-- Oracle capture for Arcade-NamcoSystem2_MiSTer (MAME 0.289 with
-- tools/mame-patches/ns2-oracle.patch).
--
-- Every frame from MP_FROM to MP_FROM+MP_FRAMES-1 (every MP_EVERY-th), at
-- frame_done, writes
--   <MP_OUT>/sNNNNN.bin  the video state: the blocks of the board (MP_BOARD,
--                        below), in order, big-endian 16-bit words read through
--                        the master 68000's address space
--   <MP_OUT>/pNNNNN.raw  screen:pixels() (u32 0x00RRGGBB, 288 x 224)
-- and for the whole run
--   <MP_OUT>/regs.txt    every write to a video register (tilemap control, C116,
--                        gfx_ctrl, ROZ/C169/C355/road control) by either 68000:
--                        "F line addr data mask cpu" (cpu m = master, s = slave).
--                        MAME splits its picture at the POSIRQ line (partial
--                        update), so the model needs the registers per line.
--   <MP_OUT>/vram.txt    every write to the tilemap RAM and the sprite RAM (A,
--                        Final Lap, Metal Hawk) by either 68000, as regs.txt:
--                        MAME draws a band with the VRAM of that moment, so
--                        the model rebuilds it per band (NS2-5)
--   <MP_OUT>/blocks.txt  the block table of this board (name, address, words)
--   <MP_OUT>/frames.txt  "F frame_time_s"
--
-- MP_BOARD: std (standard ROZ + sprites), fl (Final Lap: sprites + C45),
-- mh (Metal Hawk), sg (Steel Gunner: C355), suz (Suzuka: C355 + C45),
-- lw (Lucky & Wild: C355 + C45 + C169). tools/ns2_capture.py picks it.
--
-- Lessons applied: taps are kept referenced in _G (MS1-10); callbacks run
-- under pcall and print their errors (MS1Z-4); guarded against a re-run
-- after a machine reset (SS-7); screen:pixels() returns (data, w, h) (MS1-9);
-- no screen:vpos() in this MAME, so the line comes from machine time (MS1Z-4).
if _G.ns2_cap_loaded then return end
_G.ns2_cap_loaded = true
if os.getenv("MP_PLAY") then dofile(os.getenv("MP_PLAY")) end

local OUT    = os.getenv("MP_OUT") or "."
local FROM   = tonumber(os.getenv("MP_FROM") or "0")
local FRAMES = tonumber(os.getenv("MP_FRAMES") or "600")
local EVERY  = tonumber(os.getenv("MP_EVERY") or "1")
local BOARD  = os.getenv("MP_BOARD") or "std"
local cpu    = manager.machine.devices[":maincpu"]
local mem    = cpu.spaces["program"]
local scr    = manager.machine.screens[":screen"]
local function guard(fn) return function(...) local ok, e = pcall(fn, ...); if not ok then print("tap error: " .. tostring(e)) end end end

-- {name, byte address, 16-bit words}
local common = {
  {"tmap",   0x400000, 0x8000},    -- C123 tilemap RAM (64 KB)
  {"tctl",   0x420000, 0x20},      -- C123 control
  {"pal",    0x440000, 0x8000},    -- C116: R/G/B byte planes and registers (low byte of each word)
  {"dpram",  0x460000, 0x800},     -- dual-port RAM (low byte)
}
local boards = {
  std = { {"spr", 0xc00000, 0x2000}, {"gfxctl", 0xc40000, 1}, {"roz", 0xc80000, 0x10000}, {"rozctl", 0xcc0000, 8} },
  fl  = { {"spr", 0x800000, 0x8000}, {"gfxctl", 0x840000, 1}, {"road", 0x880000, 0x10000} },
  mh  = { {"spr", 0xc00000, 0x2000}, {"c169", 0xc40000, 0x8000}, {"c169ctl", 0xd00000, 0x10}, {"gfxctl", 0xe00000, 1} },
  sg  = { {"c355", 0x800000, 0xa100} },
  suz = { {"c355", 0x800000, 0xa100}, {"c355pos", 0x900000, 4}, {"road", 0xa00000, 0x10000} },
  lw  = { {"c355", 0x800000, 0xa100}, {"c355pos", 0x900000, 4}, {"road", 0xa00000, 0x10000},
          {"c169", 0xc00000, 0x8000}, {"c169ctl", 0xd00000, 0x10} },
}
local blocks = {}
for _, b in ipairs(common) do blocks[#blocks + 1] = b end
for _, b in ipairs(boards[BOARD]) do blocks[#blocks + 1] = b end
local bt = io.open(OUT .. "/blocks.txt", "w")
for _, b in ipairs(blocks) do bt:write(string.format("%s %06x %d\n", b[1], b[2], b[3])) end
bt:close()

local function words(base, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.pack(">I2", mem:read_u16(base + 2 * i)) end
  return table.concat(t)
end

-- register writes with their line (frame_done is the start of vblank, line 224)
local F, t0 = 0, 0
local LINE = 384 / (49152000 / 8)
local regf = io.open(OUT .. "/regs.txt", "w")
local function line_now()
  local dt = manager.machine.time:as_double() - t0
  return (224 + math.floor(dt / LINE)) % 264
end
local regranges = { {0x420000, 0x42003f}, {0x443000, 0x44303f} }
for _, b in ipairs(boards[BOARD]) do
  if b[1] ~= "spr" and b[1] ~= "roz" and b[1] ~= "c169" and b[1] ~= "c355" and b[1] ~= "road" then
    regranges[#regranges + 1] = {b[2], b[2] + 2 * b[3] - 1}
  end
end
-- both 68000s share these devices: the slave does the per-line work in
-- several games (Burning Force's line scroll), so each is tapped on both
_G.ns2_cap_taps = {}
local slave = manager.machine.devices[":slave"].spaces["program"]
for i, r in ipairs(regranges) do
  for k, sp in ipairs({mem, slave}) do
    _G.ns2_cap_taps[#_G.ns2_cap_taps + 1] = sp:install_write_tap(r[1], r[2], "ns2reg" .. i .. "_" .. k, guard(function(off, data, mask)
      regf:write(string.format("%d %d %06x %04x %04x %s\n", F, line_now(), off, data, mask, k == 1 and "m" or "s"))
    end))
  end
end

-- VRAM writes: the tilemap RAM and the sprite RAM a band reads
local vramf = io.open(OUT .. "/vram.txt", "w")
local vranges = { {0x400000, 0x40ffff} }
for _, b in ipairs(boards[BOARD]) do
  if b[1] == "spr" then vranges[#vranges + 1] = {b[2], b[2] + 0x3fff} end
end
for i, r in ipairs(vranges) do
  for k, sp in ipairs({mem, slave}) do
    _G.ns2_cap_taps[#_G.ns2_cap_taps + 1] = sp:install_write_tap(r[1], r[2], "ns2vram" .. i .. "_" .. k, guard(function(off, data, mask)
      vramf:write(string.format("%d %d %06x %04x %04x %s\n", F, line_now(), off, data, mask, k == 1 and "m" or "s"))
    end))
  end
end

local ftxt = io.open(OUT .. "/frames.txt", "w")
_G.ns2_cap_sub = emu.add_machine_frame_notifier(guard(function()
  if F >= FROM and F < FROM + FRAMES and (F - FROM) % EVERY == 0 then
    local f = io.open(string.format("%s/s%05d.bin", OUT, F), "wb")
    for _, b in ipairs(blocks) do f:write(words(b[2], b[3])) end
    f:close()
    local px = scr:pixels()
    local p = io.open(string.format("%s/p%05d.raw", OUT, F), "wb"); p:write(px); p:close()
  end
  ftxt:write(string.format("%d %.9f\n", F, manager.machine.time:as_double())); ftxt:flush()
  regf:flush()
  vramf:flush()
  t0 = manager.machine.time:as_double()
  F = F + 1
  if F >= FROM + FRAMES then manager.machine:exit() end
end))
