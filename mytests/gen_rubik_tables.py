#!/usr/bin/env python3
"""Generate the lookup tables of src/rubik (meet-in-the-middle solver).

Run from the repository root:

    python3 mytests/gen_rubik_tables.py

It writes src/rubik/rubik_tables.inc (included by rubik.c) and
src/rubik/rubik_tables.S (the same tables as global symbols for rubik.S; the
assembler runs without the C preprocessor, so the assembly cannot share the
.inc file).

The cube model is the one of tests/trubik.c (sysprog21/minirubik solver.c):
seven cubies, each destination i takes the cubie and the twist of
source[face][i]. The nine moves are R R2 R' B B2 B' D D2 D'.

A state is packed into 32 bits: p[0..5] in 3 bits each (p[6] is implied),
then o[0..6] in 2 bits each.

Tables:
  move_src[9][7], move_twist[9][7]  composed quarter turns for the 9 moves
  near_key[]  sorted packed states within 5 moves of solved (12,224)
  near_aux[]  depth << 4 | move that brings the state one step nearer
  far_key[]   sorted packed states at distance 11 (2,644)
  far_move[]  move that brings the state to distance 10
"""

import sys
from collections import deque

CUBIES = 7
NEAR_DEPTH = 5
MAX_DIST = 11

SOURCE = [
    [1, 4, 2, 0, 3, 5, 6],
    [0, 1, 2, 4, 5, 6, 3],
    [0, 2, 5, 3, 1, 4, 6],
]
TWIST = [
    [1, 2, 0, 2, 1, 0, 0],
    [0, 0, 0, 1, 2, 1, 2],
    [0, 0, 0, 0, 0, 0, 0],
]
NAMES = ["R", "R2", "R'", "B", "B2", "B'", "D", "D2", "D'"]


def quarter(p, o, face):
    src, tw = SOURCE[face], TWIST[face]
    np_ = [p[src[i]] for i in range(CUBIES)]
    no = [(o[src[i]] + tw[i]) % 3 for i in range(CUBIES)]
    return np_, no


def compose_moves():
    """move_src[m], move_twist[m]: apply move m to the identity cube."""
    msrc, mtw = [], []
    for m in range(9):
        p, o = list(range(CUBIES)), [0] * CUBIES
        for _ in range(m % 3 + 1):
            p, o = quarter(p, o, m // 3)
        msrc.append(p)
        mtw.append(o)
    return msrc, mtw


MSRC, MTW = compose_moves()
INV = [2, 1, 0, 5, 4, 3, 8, 7, 6]


def apply(p, o, m):
    src, tw = MSRC[m], MTW[m]
    return ([p[src[i]] for i in range(CUBIES)],
            [(o[src[i]] + tw[i]) % 3 for i in range(CUBIES)])


def pack(p, o):
    code = 0
    for i in range(6):
        code = (code << 3) | p[i]
    for i in range(CUBIES):
        code = (code << 2) | o[i]
    return code


# ---------------------------------------------------------------------------
# Full BFS over all 3,674,160 states, on a dense index so that it is fast:
# the permutation and the orientation move independently.
# ---------------------------------------------------------------------------

def perm_index(p):
    idx = 0
    for i in range(CUBIES):
        r = sum(1 for j in range(i + 1, CUBIES) if p[j] < p[i])
        idx = idx * (CUBIES - i) + r
    return idx


def perm_from_index(idx):
    digits = []
    for i in range(CUBIES):
        digits.append(idx % (i + 1))
        idx //= i + 1
    digits.reverse()
    avail = list(range(CUBIES))
    return [avail.pop(d) for d in digits]


def orient_index(o):
    idx = 0
    for i in range(6):
        idx = idx * 3 + o[i]
    return idx


def orient_from_index(idx):
    o = []
    for _ in range(6):
        o.append(idx % 3)
        idx //= 3
    o.reverse()
    o.append((-sum(o)) % 3)
    return o


NPERM, NORIENT = 5040, 729


def build_move_tables():
    pm = [[0] * NPERM for _ in range(9)]
    om = [[0] * NORIENT for _ in range(9)]
    for pi in range(NPERM):
        p = perm_from_index(pi)
        for m in range(9):
            pm[m][pi] = perm_index(apply(p, [0] * CUBIES, m)[0])
    for oi in range(NORIENT):
        o = orient_from_index(oi)
        for m in range(9):
            om[m][oi] = orient_index(apply(list(range(CUBIES)), o, m)[1])
    return pm, om


def bfs():
    pm, om = build_move_tables()
    total = NPERM * NORIENT
    dist = bytearray([255]) * total
    via = bytearray([15]) * total  # move that reached the state from its parent
    start = 0  # solved: identity permutation, all orientations 0
    dist[start] = 0
    frontier = [start]
    d = 0
    while frontier:
        nxt = []
        for s in frontier:
            pi, oi = divmod(s, NORIENT)
            for m in range(9):
                t = pm[m][pi] * NORIENT + om[m][oi]
                if dist[t] == 255:
                    dist[t] = d + 1
                    via[t] = m
                    nxt.append(t)
        frontier = nxt
        d += 1
    return dist, via


def state_of(idx):
    pi, oi = divmod(idx, NORIENT)
    return perm_from_index(pi), orient_from_index(oi)


def fmt_rows(values, per_line, fmt):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append("    " + ", ".join(fmt % v for v in values[i:i + per_line]) + ",")
    return "\n".join(lines)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "src/rubik/rubik_tables.inc"
    dist, via = bfs()
    hist = [0] * (MAX_DIST + 1)
    for d in dist:
        hist[d] += 1
    print("distance histogram:", hist, file=sys.stderr)
    assert sum(hist) == NPERM * NORIENT

    near, far = [], []
    for idx in range(NPERM * NORIENT):
        d = dist[idx]
        if d <= NEAR_DEPTH:
            p, o = state_of(idx)
            back = 15 if d == 0 else INV[via[idx]]
            near.append((pack(p, o), (d << 4) | back))
        elif d == MAX_DIST:
            p, o = state_of(idx)
            far.append((pack(p, o), INV[via[idx]]))
    near.sort()
    far.sort()
    assert len(set(k for k, _ in near)) == len(near)
    assert len(set(k for k, _ in far)) == len(far)

    # The assembler runs without the C preprocessor, so the assembly gets its
    # own file: a .S of global read-only data next to rubik.S.
    asm_out = out[: -len(".inc")] + ".S" if out.endswith(".inc") else out + ".S"
    with open(asm_out, "w", newline="\n") as f:
        w = f.write
        w("# Generated by mytests/gen_rubik_tables.py. Do not edit.\n")
        w("# Lookup tables of rubik_solve_asm; the layout is the one of\n")
        w("# rubik_tables.inc. RUBIK_NEAR_DEPTH = %d.\n\n" % NEAR_DEPTH)
        w("    .equ    RUBIK_NEAR_DEPTH, %d\n" % NEAR_DEPTH)
        w("    .equ    RUBIK_NEAR_COUNT, %d\n" % len(near))
        w("    .equ    RUBIK_FAR_COUNT, %d\n\n" % len(far))
        w("    .section .rodata\n")
        w("    .align  2\n")
        w("    .globl  rubik_move_src\n")
        w("rubik_move_src:\n")
        for m in range(9):
            w("    .byte   " + ", ".join(str(v) for v in MSRC[m]) + ", 0\n")
        w("    .globl  rubik_move_twist\n")
        w("rubik_move_twist:\n")
        for m in range(9):
            w("    .byte   " + ", ".join(str(v) for v in MTW[m]) + ", 0\n")
        w("    .align  2\n")
        w("    .globl  rubik_near_key\n")
        w("rubik_near_key:\n")
        for i in range(0, len(near), 4):
            w("    .word   " + ", ".join("0x%08x" % k for k, _ in near[i:i + 4]) + "\n")
        w("    .globl  rubik_near_aux\n")
        w("rubik_near_aux:\n")
        for i in range(0, len(near), 8):
            w("    .byte   " + ", ".join("0x%02x" % a for _, a in near[i:i + 8]) + "\n")
        w("    .align  2\n")
        w("    .globl  rubik_far_key\n")
        w("rubik_far_key:\n")
        for i in range(0, len(far), 4):
            w("    .word   " + ", ".join("0x%08x" % k for k, _ in far[i:i + 4]) + "\n")
        w("    .globl  rubik_far_move\n")
        w("rubik_far_move:\n")
        for i in range(0, len(far), 8):
            w("    .byte   " + ", ".join(str(a) for _, a in far[i:i + 8]) + "\n")

    with open(out, "w", newline="\n") as f:
        w = f.write
        w("/* Generated by mytests/gen_rubik_tables.py. Do not edit. */\n\n")
        w("#define RUBIK_NEAR_DEPTH %d\n" % NEAR_DEPTH)
        w("#define RUBIK_NEAR_COUNT %d\n" % len(near))
        w("#define RUBIK_FAR_COUNT %d\n\n" % len(far))
        w("static const uint8_t rubik_move_src[9][8] = {\n")
        for m in range(9):
            w("    {" + ", ".join(str(v) for v in MSRC[m]) + ", 0},\n")
        w("};\n")
        w("static const uint8_t rubik_move_twist[9][8] = {\n")
        for m in range(9):
            w("    {" + ", ".join(str(v) for v in MTW[m]) + ", 0},\n")
        w("};\n")
        w("static const uint32_t rubik_near_key[RUBIK_NEAR_COUNT] = {\n")
        w(fmt_rows([k for k, _ in near], 6, "0x%08x") + "\n};\n")
        w("static const uint8_t rubik_near_aux[RUBIK_NEAR_COUNT] = {\n")
        w(fmt_rows([a for _, a in near], 12, "0x%02x") + "\n};\n")
        w("static const uint32_t rubik_far_key[RUBIK_FAR_COUNT] = {\n")
        w(fmt_rows([k for k, _ in far], 6, "0x%08x") + "\n};\n")
        w("static const uint8_t rubik_far_move[RUBIK_FAR_COUNT] = {\n")
        w(fmt_rows([a for _, a in far], 12, "%d") + "\n};\n")
    print("wrote %s and %s: %d near, %d far" % (out, asm_out, len(near),
                                                len(far)), file=sys.stderr)

    if "--check" in sys.argv:
        check(dict(near), dict(far), dist)


# ---------------------------------------------------------------------------
# --check: a Python copy of the C solver, verified against the full BFS on
# the vectors of tests/rubikvec.h and on a random sample.
# ---------------------------------------------------------------------------

FACE = [0, 0, 0, 1, 1, 1, 2, 2, 2]


def solve(near, far, state):
    p = [ord(c) - ord("1") for c in state[:7]]
    o = [ord(c) - ord("1") for c in state[7:]]
    prefix = []
    aux = near.get(pack(p, o))
    best = None
    if pack(p, o) in far:
        m = far[pack(p, o)]
        prefix.append(m)
        p, o = apply(p, o, m)
    stack = []
    best = [99, None, None]

    def dfs(p, o, depth, last):
        k = pack(p, o)
        a = near.get(k)
        if a is not None:
            t = a >> 4
            if depth + t < best[0]:
                best[0] = depth + t
                best[1] = list(stack)
                best[2] = k
        if depth == NEAR_DEPTH:
            return
        for m in range(9):
            if last >= 0 and FACE[m] == FACE[last]:
                continue
            stack.append(m)
            np_, no = apply(p, o, m)
            dfs(np_, no, depth + 1, m)
            stack.pop()

    dfs(p, o, 0, -1)
    assert best[1] is not None
    moves = prefix + best[1]
    k = best[2]
    while True:
        a = near[k]
        if a >> 4 == 0:
            break
        m = a & 15
        moves.append(m)
        pp, oo = state_of_key(k)
        pp, oo = apply(pp, oo, m)
        k = pack(pp, oo)
    return moves


def state_of_key(k):
    o = [(k >> (2 * (6 - i))) & 3 for i in range(7)]
    p = [(k >> (14 + 3 * (5 - i))) & 7 for i in range(6)]
    p.append(21 - sum(p))
    return p, o


def check(near, far, dist):
    import random
    import re
    cases = []
    with open("tests/rubikvec.h") as f:
        for m in re.finditer(r'\{"(\d{14})", (\d+)\}', f.read()):
            cases.append((m.group(1), int(m.group(2))))
    random.seed(1)
    for _ in range(300):
        idx = random.randrange(NPERM * NORIENT)
        p, o = state_of(idx)
        s = "".join(chr(ord("1") + v) for v in p + o)
        cases.append((s, dist[idx]))
    for s, d in cases:
        moves = solve(near, far, s)
        p = [ord(c) - ord("1") for c in s[:7]]
        o = [ord(c) - ord("1") for c in s[7:]]
        for m in moves:
            p, o = apply(p, o, m)
        assert p == list(range(7)) and o == [0] * 7, (s, moves)
        assert len(moves) == d, (s, len(moves), d, [NAMES[m] for m in moves])
    print("check: %d states solved optimally" % len(cases), file=sys.stderr)


if __name__ == "__main__":
    main()
