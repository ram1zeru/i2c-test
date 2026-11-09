#!/usr/bin/env python3
"""Render waveform figures (like Fig. 1-4 of the paper) from the simulation VCDs.

Usage:  make waves        (or)   python3 scripts/plot_waves.py
Output: docs/fig*.png
Only needs matplotlib; contains a minimal VCD parser.
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
DOCS = os.path.join(ROOT, "docs")


def parse_vcd(path, wanted):
    """Return {full_name: [(t_ns, value_str), ...]} for the wanted signals."""
    ids, scope, data = {}, [], {}
    ts_scale = 1e-3  # timescale 1ps -> ns (iverilog default with `timescale 1ns/1ps)
    t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if in_defs:
                if tok[0] == "$timescale":
                    unit = " ".join(tok[1:]).replace("$end", "").strip() or next(f).strip()
                    ts_scale = {"1ps": 1e-3, "1ns": 1.0, "10ps": 1e-2, "100ps": 1e-1}.get(
                        unit.replace(" ", ""), 1e-3)
                elif tok[0] == "$scope":
                    scope.append(tok[2])
                elif tok[0] == "$upscope":
                    scope.pop()
                elif tok[0] == "$var":
                    name = ".".join(scope + [tok[4]])
                    if name in wanted:
                        ids.setdefault(tok[3], []).append(name)
                        data[name] = []
                elif tok[0] == "$enddefinitions":
                    in_defs = False
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:]) * ts_scale
            elif c in "01xzXZ":
                for n in ids.get(line[1:].strip(), []):
                    data[n].append((t, c.lower()))
            elif c == "b":
                val, code = tok[0][1:], tok[1]
                for n in ids.get(code, []):
                    data[n].append((t, val))
    return data


def value_at(series, t):
    v = None
    for ts, val in series:
        if ts > t:
            break
        v = val
    return v


def edges(series, frm, to):
    return [ts for (ts, v), (_, pv) in zip(series[1:], series[:-1]) if v == frm and pv == to]


def plot(ax_list, data, names, labels, t0, t1, bus=()):
    for ax, n, lab in zip(ax_list, names, labels):
        s = [(t, v) for t, v in data[n]]
        xs, ys, texts = [t0], [], []
        start_v = value_at(s, t0) or "x"
        pts = [(t0, start_v)] + [(t, v) for t, v in s if t0 < t < t1] + [(t1, None)]
        if n in bus:
            for (ta, va), (tb, _) in zip(pts[:-1], pts[1:]):
                ax.fill_between([ta, tb], 0.1, 0.9, color="#dbe7f3", edgecolor="#2b5d8a", lw=0.8)
                try:
                    txt = str(int(va, 2))
                except (TypeError, ValueError):
                    txt = str(va)
                if (tb - ta) > (t1 - t0) * 0.015:
                    ax.text((ta + tb) / 2, 0.5, txt, ha="center", va="center", fontsize=7)
        else:
            for (ta, va), (tb, _) in zip(pts[:-1], pts[1:]):
                y = {"1": 1.0, "0": 0.0}.get(va, 0.5)
                col = "#c0392b" if va in ("z", "x") else "#1f4e79"
                ax.plot([ta, tb], [y, y], color=col, lw=1.4)
                xs.append(tb)
            # vertical transitions
            for (ta, va), (tb, vb) in zip(pts[:-2], pts[1:-1]):
                ya = {"1": 1.0, "0": 0.0}.get(va, 0.5)
                yb = {"1": 1.0, "0": 0.0}.get(vb, 0.5)
                ax.plot([tb, tb], [ya, yb], color="#1f4e79", lw=1.0)
        ax.set_ylim(-0.2, 1.2)
        ax.set_yticks([])
        ax.set_ylabel(lab, rotation=0, ha="right", va="center", fontsize=9)
        for sp in ("top", "right", "left"):
            ax.spines[sp].set_visible(False)
    ax_list[-1].set_xlabel("time (µs)")
    for ax in ax_list:
        ax.set_xlim(t0, t1)
        ticks = ax.get_xticks()
        ax.set_xticks(ticks)
        ax.set_xticklabels([f"{x/1000:.1f}" for x in ticks], fontsize=7)
        ax.set_xlim(t0, t1)


def busy_windows(series):
    """(start, end) of every interval where a 1-bit signal is high."""
    out, t_up = [], None
    for t, v in series:
        if v == "1" and t_up is None:
            t_up = t
        elif v != "1" and t_up is not None:
            out.append((t_up, t))
            t_up = None
    return out


def main():
    os.makedirs(DOCS, exist_ok=True)

    # ------------------------------------------------------------------ I2C
    vcd = os.path.join(BUILD, "tb_i2c.vcd")
    if not os.path.exists(vcd):
        sys.exit("run `make test` first (build/tb_i2c.vcd not found)")
    names = ["tb_i2c.scl", "tb_i2c.sda", "tb_i2c.u_maestro.contador_32",
             "tb_i2c.ack_error", "tb_i2c.busy"]
    d = parse_vcd(vcd, set(names))
    wins = busy_windows(d["tb_i2c.busy"])
    titles = [
        ("fig3_i2c_write.png",   "I2C write 0x5A to address 0x1B (paper Fig. 3)"),
        ("fig_i2c_read.png",     "I2C read from address 0x1B -> 0xDE"),
        ("fig2_i2c_no_ack.png",  "I2C wrong address, no ACK -> STOP (paper Fig. 2)"),
        ("fig4_i2c_data_nack.png", "I2C data NACKed by slave -> STOP (paper Fig. 4)"),
    ]
    for (t0, t1), (fname, title) in zip(wins, titles):
        pad = (t1 - t0) * 0.04
        fig, axs = plt.subplots(4, 1, figsize=(12, 3.6), sharex=True,
                                gridspec_kw={"hspace": 0.15})
        plot(axs, d, names[:4], ["SCL", "SDA", "contador_32", "ack_error"],
             t0 - pad, t1 + pad, bus=("tb_i2c.u_maestro.contador_32",))
        fig.suptitle(title, fontsize=10)
        fig.savefig(os.path.join(DOCS, fname), dpi=130, bbox_inches="tight")
        plt.close(fig)
        print("wrote docs/" + fname)

    # ------------------------------------------------------------------ SPI
    vcd = os.path.join(BUILD, "tb_spi.vcd")
    names = ["tb_spi.CS", "tb_spi.CLK_3", "tb_spi.MOSI", "tb_spi.MISO"]
    d = parse_vcd(vcd, set(names))
    cs = d["tb_spi.CS"]
    lows = [(t, v) for t, v in cs]
    t0 = next(t for t, v in lows if v == "0")
    t1 = next(t for t, v in lows if v == "1" and t > t0)
    pad = (t1 - t0) * 0.08
    fig, axs = plt.subplots(4, 1, figsize=(12, 3.4), sharex=True, gridspec_kw={"hspace": 0.15})
    plot(axs, d, names, ["CS", "CLK_3", "MOSI", "MISO"], t0 - pad, t1 + pad)
    fig.suptitle("SPI mode 3 (CPOL=1, CPHA=1): master sends 0x5A, slave returns 0xDE (paper Fig. 1)",
                 fontsize=10)
    fig.savefig(os.path.join(DOCS, "fig1_spi_mode3.png"), dpi=130, bbox_inches="tight")
    plt.close(fig)
    print("wrote docs/fig1_spi_mode3.png")


def decode_i2c(sda, scl, t0, t1):
    """Return [(t_start, t_end, label)] for START/Sr/bytes/STOP inside [t0, t1]."""
    ev = sorted([(t, "sda", v) for t, v in sda] + [(t, "scl", v) for t, v in scl],
                key=lambda e: (e[0], e[1] == "sda"))
    s_v = c_v = "1"
    out, bits, t_byte, inframe, first = [], [], None, False, False
    for t, w, v in ev:
        if w == "sda":
            if c_v == "1" and t0 <= t <= t1:
                if s_v == "1" and v == "0":
                    out.append((t, t, "Sr" if inframe else "S"))
                    inframe, first, bits = True, True, []
                elif s_v == "0" and v == "1" and inframe:
                    out.append((t, t, "P"))
                    inframe = False
            s_v = v
        else:
            if c_v == "0" and v == "1" and inframe:
                if not bits:
                    t_byte = t
                bits.append(0 if s_v == "0" else 1)
                if len(bits) == 9:
                    byte = int("".join(map(str, bits[:8])), 2)
                    ack = "N" if bits[8] else "A"
                    lab = f"{byte:02X}"
                    if first:
                        lab = f"{byte >> 1:02X}+{'R' if byte & 1 else 'W'}"
                    out.append((t_byte, t, f"{lab} {ack}"))
                    bits, first = [], False
            c_v = v
    return out


def plot_i2c_full():
    vcd = os.path.join(BUILD, "tb_i2c_full.vcd")
    if not os.path.exists(vcd):
        return
    names = ["tb_i2c_full.scl", "tb_i2c_full.sda", "tb_i2c_full.u_slave_b.scl_oe",
             "tb_i2c_full.test_no"]
    d = parse_vcd(vcd, set(names))
    tn = d["tb_i2c_full.test_no"]

    def window(n):
        a = next(t for t, v in tn if int(v, 2) == n)
        b = next(t for t, v in tn if t > a)
        return a, b

    jobs = [
        (2, "fig5_i2c_read_repeated_start.png",
         "I2C doc 4 thanh ghi tu 0x1B: ghi so thanh ghi, Sr, doc, NACK byte cuoi"),
        (4, "fig6_i2c_clock_stretching.png",
         "I2C slave 0x50 keo dai clock (clock stretching) sau moi byte"),
    ]
    for n, fname, title in jobs:
        t0, t1 = window(n)
        dec = decode_i2c(d["tb_i2c_full.sda"], d["tb_i2c_full.scl"], t0, t1)
        if n == 4:                          # only the first transaction (write)
            p = next(i for i, x in enumerate(dec) if x[2] == "P")
            dec = dec[:p + 1]
        a = dec[0][0] - 15000
        b = dec[-1][1] + 15000
        lanes = names[:3] if n == 4 else names[:2]
        labels = ["SCL", "SDA", "slave giu SCL"][:len(lanes)]
        fig, axs = plt.subplots(len(lanes) + 1, 1, figsize=(13, 1.0 * (len(lanes) + 1) + 0.6),
                                sharex=True, gridspec_kw={"hspace": 0.15,
                                                          "height_ratios": [0.7] + [1] * len(lanes)})
        plot(axs[1:], d, lanes, labels, a, b)
        ax = axs[0]
        for ts, te, lab in dec:
            if ts == te:
                ax.axvline(ts, color="#c0392b", lw=0.8)
                ax.text(ts, 0.5, lab, ha="center", va="center", fontsize=8, color="#c0392b",
                        bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none"))
                for x in axs[1:]:
                    x.axvline(ts, color="#c0392b", lw=0.5, ls=":")
            else:
                col = "#d6eadf" if lab.endswith("A") else "#f6d5cf"
                ax.fill_between([ts, te], 0.15, 0.85, color=col, edgecolor="#5f5e5a", lw=0.5)
                ax.text((ts + te) / 2, 0.5, lab, ha="center", va="center", fontsize=8)
        ax.set_ylim(0, 1)
        ax.set_yticks([])
        ax.set_ylabel("giai ma", rotation=0, ha="right", va="center", fontsize=9)
        for sp in ("top", "right", "left", "bottom"):
            ax.spines[sp].set_visible(False)
        fig.suptitle(title, fontsize=10)
        fig.savefig(os.path.join(DOCS, fname), dpi=130, bbox_inches="tight")
        plt.close(fig)
        print("wrote docs/" + fname)


if __name__ == "__main__":
    main()
    plot_i2c_full()
