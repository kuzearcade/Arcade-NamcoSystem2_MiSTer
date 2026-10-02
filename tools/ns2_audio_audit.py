#!/usr/bin/env python3
"""The board's audio against MAME's, per set (NS2-26).

    tools/ns2_audio_audit.py BOARD.wav MAME_DIR [--name SET] [--json OUT]

BOARD.wav: the MiSTer's HDMI audio, 48 kHz stereo, from the core's load.
MAME_DIR: mix.wav, ym.wav and c140.wav from MAME 0.289 with the local
NS2_SND_ISO patch (tools/mame-patches): the stock mix and each chip alone at
its own gain, from a cold boot (sim/oracle/ns2_boot.lua). mix = ym + c140 to
1 LSB, so the board's band powers are fitted as gy^2 * YM + gc^2 * C140:
gy and gc are the board's YM2151 and C140 levels against MAME's (1.0 =
equal; the chips' gains in MAME differ by machine config).

The timelines differ (the download, the EEPROM warning's Start), so MAME's
recording is cut into 10 s windows, each aligned on its own by the
correlation of the band-energy envelopes; windows that do not match (the
attract has diverged, or one side is silent) are left out of the fit.

Reported per set: the alignment, gy and gc with the fit's residual, the
level difference, "missing" stretches (MAME has 10 dB more energy than the
fit predicts from the board, per chip), and "extra" narrow-band tones in the
board's long-term spectrum (a screech) against the fitted prediction.
"""
import argparse, json, sys, wave
import numpy as np

SR = 48000
HOP = 960            # 20 ms
NFFT = 2048
NB = 48              # log bands, 40 Hz .. 20 kHz
EDGES = np.geomspace(40, 20000, NB + 1)
WIN_S = 10.0


def load(path):
    w = wave.open(path, 'rb')
    assert w.getframerate() == SR, (path, w.getframerate())
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels()).astype(np.float64)
    return x if x.shape[1] == 2 else np.repeat(x, 2, axis=1)


def stft_power(x):
    """|STFT|^2 of a mono signal, frames of NFFT every HOP."""
    n = (len(x) - NFFT) // HOP + 1
    if n <= 0:
        return np.zeros((0, NFFT // 2 + 1))
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    seg = x[idx] * np.hanning(NFFT)[None, :]
    return np.abs(np.fft.rfft(seg, axis=1)) ** 2


FREQS = np.fft.rfftfreq(NFFT, 1 / SR)
BAND_OF = np.digitize(FREQS, EDGES) - 1


def bands(p):
    out = np.zeros((p.shape[0], NB))
    for b in range(NB):
        m = BAND_OF == b
        if m.any():
            out[:, b] = p[:, m].sum(axis=1)
    return out


def env(bp):
    return np.log10(bp.sum(axis=1) + 1e6)


def best_lag(e_m, e_b, lo, hi):
    """board frame = MAME frame + lag; the lag in [lo, hi] frames with the
    best normalised correlation of the envelopes."""
    best = (-2.0, 0)
    a = e_m - e_m.mean()
    na = np.linalg.norm(a) + 1e-9
    for lag in range(lo, hi + 1):
        s = lag
        if s < 0 or s + len(e_m) > len(e_b):
            continue
        b = e_b[s:s + len(e_m)]
        b = b - b.mean()
        c = float(np.dot(a, b) / (na * (np.linalg.norm(b) + 1e-9)))
        if c > best[0]:
            best = (c, lag)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('board')
    ap.add_argument('mame_dir')
    ap.add_argument('--name', default='')
    ap.add_argument('--json')
    ap.add_argument('--min-corr', type=float, default=0.6)
    a = ap.parse_args()

    bd = load(a.board)
    mx = load(a.mame_dir + '/mix.wav')
    ym = load(a.mame_dir + '/ym.wav')
    cc = load(a.mame_dir + '/c140.wav')
    n = min(len(mx), len(ym), len(cc))
    mx, ym, cc = mx[:n], ym[:n], cc[:n]
    mono = lambda x: x.mean(axis=1)
    P_b, P_m, P_y, P_c = (stft_power(mono(x)) for x in (bd, mx, ym, cc))
    B_b, B_m, B_y, B_c = (bands(p) for p in (P_b, P_m, P_y, P_c))
    e_b, e_m = env(B_b), env(B_m)

    res = {'set': a.name, 'board_s': len(bd) / SR, 'mame_s': n / SR}
    # MAME's sound: the frames with real energy (the warning is silent)
    active_m = e_m > np.log10(1e6) + 1.0
    if active_m.sum() < 100:
        res['error'] = 'MAME silent'
        print(json.dumps(res)); return
    # windows of MAME, each aligned
    W = int(WIN_S * SR / HOP)
    wins = []
    for s0 in range(0, len(e_m) - W + 1, W // 2):
        if active_m[s0:s0 + W].mean() < 0.3:
            continue
        c, lag = best_lag(e_m[s0:s0 + W], e_b, s0 - int(5 * SR / HOP), s0 + int(45 * SR / HOP))
        wins.append((s0, lag - s0, c))
    good = [w for w in wins if w[2] >= a.min_corr]
    res['windows'] = len(wins)
    res['windows_matched'] = len(good)
    if not good:
        res['error'] = 'no window matched'
        res['corr_max'] = max((w[2] for w in wins), default=None)
        print(json.dumps(res)); return
    offs = [w[1] for w in good]
    res['offset_s'] = float(np.median(offs) * HOP / SR)
    res['offset_spread_s'] = float((max(offs) - min(offs)) * HOP / SR)
    res['corr_mean'] = float(np.mean([w[2] for w in good]))

    # stack the aligned frames of the matched windows (each MAME frame once)
    used = {}
    for s0, off, c in good:
        for t in range(s0, s0 + W):
            if t not in used and 0 <= t + off < len(B_b):
                used[t] = t + off
    tm = np.array(sorted(used))
    tb = np.array([used[t] for t in tm])
    Bb, By, Bc, Bm = B_b[tb], B_y[tm], B_c[tm], B_m[tm]

    # gy^2, gc^2 >= 0 by least squares on the band powers (log-weighted: each
    # (frame, band) cell counts by its share, via a sqrt of the power)
    w = 1.0 / np.sqrt(Bm + Bb + 1e4)
    X1, X2, Y = (By * w).ravel(), (Bc * w).ravel(), (Bb * w).ravel()
    # non-negative least squares in two unknowns: both, or one chip alone
    # (a chip MAME leaves silent here is not fitted: its gain is None)
    cands = []
    A = np.array([[X1 @ X1, X1 @ X2], [X1 @ X2, X2 @ X2]])
    r = np.array([X1 @ Y, X2 @ Y])
    if abs(np.linalg.det(A)) > 1e-12 * (A[0, 0] * A[1, 1] + 1e-30):
        s = np.linalg.solve(A, r)
        if s[0] >= 0 and s[1] >= 0:
            cands.append((s[0], s[1]))
    if X1 @ X1 > 0:
        cands.append((max(0.0, (X1 @ Y) / (X1 @ X1)), 0.0))
    if X2 @ X2 > 0:
        cands.append((0.0, max(0.0, (X2 @ Y) / (X2 @ X2))))
    ka, kc = min(cands, key=lambda k: float(np.sum((Y - k[0] * X1 - k[1] * X2) ** 2))) if cands else (0.0, 0.0)
    silent = {'ym': not (X1 @ X1 > 0), 'c140': not (X2 @ X2 > 0)}
    res['ym_gain'] = None if silent['ym'] else float(np.sqrt(ka))
    res['c140_gain'] = None if silent['c140'] else float(np.sqrt(kc))
    pred = ka * By + kc * Bc
    # the fit's quality: the log-band error where either side has energy
    sig = (pred + Bb) > 1e8
    err = np.abs(np.log10(Bb[sig] + 1e6) - np.log10(pred[sig] + 1e6))
    res['fit_err_db'] = float(10 * np.median(err))
    # each chip alone: the frames where MAME's other chip has under 3% of the
    # energy, the board's energy against MAME's (below 9 kHz: the C140's
    # images above its 10.7 kHz Nyquist are reported apart)
    lo = EDGES[1:] < 9000
    ey, ec, eb = By[:, lo].sum(axis=1), Bc[:, lo].sum(axis=1), Bb[:, lo].sum(axis=1)
    for nm, ex, eo in (('ym', ey, ec), ('c140', ec, ey)):
        m = (ex > 0.97 * (ex + eo)) & (ex > np.percentile(ex[ex > 0], 25) if (ex > 0).any() else False)
        res[nm + '_solo_frames'] = int(np.sum(m))
        res[nm + '_solo_gain'] = float(np.sqrt(eb[m].sum() / ex[m].sum())) if m.sum() >= 25 else None
    # the chips' shares of MAME's energy here
    res['mame_ym_share'] = float(By.sum() / (By.sum() + Bc.sum() + 1e-9))
    # level: total energy, board against MAME's mix, in dB
    res['level_db'] = float(10 * np.log10((Bb.sum() + 1e-9) / (Bm.sum() + 1e-9)))

    # missing: frames where MAME's chip alone (at the fitted gain) has 10 dB
    # more than the board, the chip clearly present
    tot_b = Bb.sum(axis=1)
    miss = {}
    for nm, Bx, k in (('ym', By, ka), ('c140', Bc, kc)):
        e = Bx.sum(axis=1) * max(k, 1e-3)
        loud = e > np.percentile(e[e > 0], 50) if (e > 0).any() else np.zeros(len(e), bool)
        m = loud & (e > 10 * tot_b)
        miss[nm] = {'frames': int(m.sum()), 'of': int(loud.sum()),
                    'times_s': [round(float(tm[i] * HOP / SR), 2) for i in np.flatnonzero(m)[:40:4]]}
    res['missing'] = miss

    # extra: narrow-band tones in the board's long-term spectrum (fine FFT
    # bins) that the fitted MAME prediction does not have
    Pb = P_b[tb].mean(axis=0)
    Pp = (ka * P_y[tm] + kc * P_c[tm]).mean(axis=0)
    ratio = 10 * np.log10((Pb + 1e3) / (Pp + 1e3))
    level = 10 * np.log10(Pb + 1e3) - 10 * np.log10(Pb.max() + 1e3)
    cand = np.flatnonzero((ratio > 12) & (level > -50) & (FREQS > 2000))
    extra = []
    for i in cand:
        if ratio[i] >= ratio[max(0, i - 2):i + 3].max():
            extra.append((round(float(FREQS[i]), 0), round(float(ratio[i]), 1), round(float(level[i]), 1)))
    extra.sort(key=lambda t: -t[1])
    res['extra_tones'] = extra[:8]
    # the high band's energy against the prediction (above 6 kHz)
    hi = FREQS > 6000
    res['hf_excess_db'] = float(10 * np.log10((Pb[hi].sum() + 1e3) / (Pp[hi].sum() + 1e3)))
    # stereo: the left/right RMS balance, board against MAME's mix
    seg_b = bd[tb[0] * HOP: (tb[-1] + 1) * HOP]
    seg_m = mx[tm[0] * HOP: (tm[-1] + 1) * HOP]
    bal = lambda x: 20 * np.log10((np.sqrt((x[:, 0] ** 2).mean()) + 1) / (np.sqrt((x[:, 1] ** 2).mean()) + 1))
    res['lr_db_board'] = float(bal(seg_b))
    res['lr_db_mame'] = float(bal(seg_m))
    res['peak_board'] = int(np.abs(bd).max())
    res['peak_mame'] = int(np.abs(mx).max())
    if a.json:
        json.dump(res, open(a.json, 'w'), indent=1)
    print(json.dumps(res))


if __name__ == '__main__':
    main()
