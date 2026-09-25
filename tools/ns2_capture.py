#!/usr/bin/env python3
"""Run MAME's oracle capture (sim/oracle/ns2_capture.lua) for one or more sets.

    tools/ns2_capture.py SET[:tag] ... [--frames N] [--from F] [--every K] [--play SCRIPT]

Each run gets a fresh directory `sim/oracle/traces/<set>_<tag>/` (default tag
`attract`), so MAME starts from its all-ones EEPROM like the core does (the
EEPROM-warning boot is scripted by sim/oracle/ns2_boot.lua, or by the given
play script, which must include it). The board comes from the set's machine
config. Runs in parallel, one MAME per set.
"""
import argparse, os, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_romdata as R

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
BOARD = {  # machine config -> capture board
    'base': 'std', 'base2': 'std', 'base3': 'std', 'base_c68': 'std', 'assaultp': 'std',
    'finallap': 'fl', 'finallap_c68': 'fl', 'finalap2': 'fl', 'finalap3': 'fl', 'base_fl': 'fl',
    'metlhawk': 'mh', 'sgunner': 'sg', 'sgunner2': 'sg', 'suzuka8h': 'suz', 'luckywld': 'lw',
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sets', nargs='+')
    ap.add_argument('--frames', type=int, default=3600)
    ap.add_argument('--from', dest='frm', type=int, default=0)
    ap.add_argument('--every', type=int, default=1)
    ap.add_argument('--play', default=os.path.join(ROOT, 'sim/oracle/ns2_boot.lua'))
    a = ap.parse_args()
    gm = R.games()
    procs = []
    for spec in a.sets:
        name, _, tag = spec.partition(':')
        tag = tag or 'attract'
        out = os.path.join(ROOT, 'sim/oracle/traces', f'{name}_{tag}')
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        env = dict(os.environ, MP_OUT='.', MP_FROM=str(a.frm), MP_FRAMES=str(a.frames), MP_EVERY=str(a.every),
                   MP_BOARD=BOARD[gm[name]['config']], MP_PLAY=os.path.abspath(a.play))
        log = open(os.path.join(out, 'mame.log'), 'w')
        procs.append((name, out, subprocess.Popen(
            [os.path.expanduser('~/mame/mame'), name, '-rompath', os.path.join(ROOT, 'mame_roms'),
             '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
             '-autoboot_script', os.path.join(ROOT, 'sim/oracle/ns2_capture.lua')],
            cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT)))
    for name, out, p in procs:
        p.wait()
        n = len([f for f in os.listdir(out) if f.startswith('s') and f.endswith('.bin')])
        print(f'{name}: {n} states in {os.path.relpath(out, ROOT)} (rc {p.returncode})')


if __name__ == '__main__':
    main()
