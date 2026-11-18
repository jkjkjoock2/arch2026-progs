# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# Same algorithm as rubik.c (meet in the middle): a depth-first search to
# depth 5 from the input, each node looked up by binary search in the sorted
# table of the states within 5 moves of solved (rubik_tables.S); states at
# distance 11 come from a second table that gives their first move. The
# search is iterative: one 16-byte cube per level on the stack frame.
#
# A state is packed into 32 bits: p[0..5] in 3 bits each, then o[0..6] in
# 2 bits each. No multiply or divide anywhere.

    .equ    NEAR_DEPTH, 5
    .equ    NEAR_COUNT, 12224
    .equ    FAR_COUNT, 2644
    .equ    MAX_MOVES, 11

# Stack frame (288 bytes)
    .equ    FRAME, 288
    .equ    ITER, 56                # uint8 iter[6]: next move to try per level
    .equ    PATH, 64                # uint8 path[5]: moves applied so far
    .equ    BEST, 72                # uint8 best[5]: path of the best hit
    .equ    MOVES, 80               # uint8 moves[12]: the solution
    .equ    CUBES, 96               # 12 cube slots of 16 bytes: p[7] at +0, o[7] at +7

# Callee-saved registers in use:
#   s0 = out, s1 = cap, s2 = n (moves so far), s3 = depth / slot index
#   s4 = best_len, s5 = best_depth, s6 = best_key
#   s7 = rubik_near_key, s8 = rubik_near_aux, s9 = mod3
#   s10 = rubik_move_src, s11 = rubik_move_twist

    .section .rodata
    .align  2
face_of:
    .byte   0, 0, 0, 1, 1, 1, 2, 2, 2
mod3:
    .byte   0, 1, 2, 0, 1
move_name:
    .ascii  "R\0\0R2\0R'\0B\0\0B2\0B'\0D\0\0D2\0D'\0"

    .text

# ---------------------------------------------------------------------------
# One cubie of turn_pack: dst[i] takes cubie and twist from src[i].
#   t1 = source row, t2 = twist row, a0 = src cube, a1 = dst cube
#   t3 = packed permutation so far, t4 = packed orientation so far
# ---------------------------------------------------------------------------
    .macro  TPSTEP i
    lbu     t6, \i(t1)              # src[i]
    add     t0, a0, t6
    lbu     a3, 0(t0)               # p[src[i]]
    lbu     a4, 7(t0)               # o[src[i]]
    lbu     t6, \i(t2)              # twist[i]
    add     a4, a4, t6
    add     a4, a4, s9
    lbu     a4, 0(a4)               # mod3[o + twist]
    sb      a3, \i(a1)
    sb      a4, 7+\i(a1)
    slli    t3, t3, 3
    or      t3, t3, a3
    slli    t4, t4, 2
    or      t4, t4, a4
    .endm

# Record a hit of the near table for the node at depth s3 with key a0.
# Clobbers a0-a4, t0-t5.
    .macro  CHECK_NODE
    mv      a2, a0                  # key (bsearch_near keeps a2)
    jal     bsearch_near
    bltz    a0, 1f
    add     t0, s8, a0
    lbu     t0, 0(t0)               # aux = depth << 4 | back move
    srli    t1, t0, 4
    add     t1, t1, s3              # total = depth here + table depth
    bge     t1, s4, 1f              # not better
    mv      s4, t1
    mv      s5, s3
    mv      s6, a2
    lw      t2, PATH(sp)            # best[0..4] = path[0..4]
    sw      t2, BEST(sp)
    lw      t2, PATH+4(sp)
    sw      t2, BEST+4(sp)
1:
    .endm

    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -FRAME
    sw      ra, 0(sp)
    sw      s0, 4(sp)
    sw      s1, 8(sp)
    sw      s2, 12(sp)
    sw      s3, 16(sp)
    sw      s4, 20(sp)
    sw      s5, 24(sp)
    sw      s6, 28(sp)
    sw      s7, 32(sp)
    sw      s8, 36(sp)
    sw      s9, 40(sp)
    sw      s10, 44(sp)
    sw      s11, 48(sp)
    mv      s0, a1
    mv      s1, a2

    # ---- parse: seven cubies '1'..'7', no repeats ----
    addi    t5, sp, CUBES           # cube slot 0
    li      t0, 0                   # seen bit mask
    li      t1, 0                   # i
    li      t6, 7
.Lparse_p:
    add     t2, a0, t1
    lbu     t2, 0(t2)
    addi    t2, t2, -49             # - '1'
    bgeu    t2, t6, .Linvalid       # outside 0..6 (a NUL wraps to a big value)
    li      t3, 1
    sll     t3, t3, t2
    and     t4, t0, t3
    bnez    t4, .Linvalid           # repeated cubie
    or      t0, t0, t3
    add     t4, t5, t1
    sb      t2, 0(t4)               # p[i]
    addi    t1, t1, 1
    bne     t1, t6, .Lparse_p

    # ---- parse: seven orientations '1'..'3', sum a multiple of 3 ----
    li      t0, 0                   # orientation sum
    li      t1, 0
    li      t6, 3
.Lparse_o:
    addi    t2, a0, 7
    add     t2, t2, t1
    lbu     t2, 0(t2)
    addi    t2, t2, -49
    bgeu    t2, t6, .Linvalid       # outside 0..2
    add     t0, t0, t2
    add     t4, t5, t1
    sb      t2, 7(t4)               # o[i]
    addi    t1, t1, 1
    li      t3, 7
    bne     t1, t3, .Lparse_o
    lbu     t2, 14(a0)
    bnez    t2, .Linvalid           # exactly 14 characters
.Lmod3:
    bltu    t0, t6, .Lmod3_done     # sum < 3
    addi    t0, t0, -3
    j       .Lmod3
.Lmod3_done:
    bnez    t0, .Linvalid

    # ---- constants for the search ----
    la      s7, rubik_near_key
    la      s8, rubik_near_aux
    la      s9, mod3
    la      s10, rubik_move_src
    la      s11, rubik_move_twist
    li      a5, 6112 * 4            # the three large steps of bsearch_near
    li      a6, 3056 * 4
    li      a7, 1528 * 4
    li      s2, 0                   # n = 0

    # ---- key of the input; distance 11 takes one table move first ----
    mv      a0, t5
    jal     pack
    mv      a2, a0
    la      a0, rubik_far_key
    li      a1, FAR_COUNT
    jal     bsearch
    mv      a3, a2                  # key, in case of a miss
    bltz    a0, .Lsearch
    la      t0, rubik_far_move
    add     t0, t0, a0
    lbu     a2, 0(t0)               # first move
    sb      a2, MOVES(sp)
    li      s2, 1
    addi    a0, sp, CUBES
    addi    a1, a0, 16
    jal     turn_pack               # slot 0 -> slot 1
    mv      a3, a0
    lw      t0, CUBES+16(sp)        # slot 1 -> slot 0
    lw      t1, CUBES+20(sp)
    lw      t2, CUBES+24(sp)
    lw      t3, CUBES+28(sp)
    sw      t0, CUBES(sp)
    sw      t1, CUBES+4(sp)
    sw      t2, CUBES+8(sp)
    sw      t3, CUBES+12(sp)

    # ---- iterative depth-first search to depth 5 ----
.Lsearch:
    li      s3, 0                   # depth
    li      s4, MAX_MOVES + 1       # best_len
    li      s5, 0
    li      s6, 0
    sb      zero, ITER(sp)          # iter[0] = 0
    mv      a0, a3
    CHECK_NODE                      # the root itself
.Ldfs:
    add     t0, sp, s3
    lbu     t1, ITER(t0)            # m = iter[depth]
    li      t2, 9
    beq     t1, t2, .Lpop           # all nine moves tried
    addi    t3, t1, 1
    sb      t3, ITER(t0)            # iter[depth] = m + 1
    beqz    s3, .Lturn
    lbu     t4, PATH-1(t0)          # the move that produced this level
    la      t5, face_of
    add     t6, t5, t1
    lbu     t6, 0(t6)
    add     t5, t5, t4
    lbu     t5, 0(t5)
    beq     t5, t6, .Ldfs           # same face twice: skip
.Lturn:
    sb      t1, PATH(t0)            # path[depth] = m
    slli    a0, s3, 4
    addi    a0, a0, CUBES
    add     a0, a0, sp              # cube[depth]
    addi    a1, a0, 16              # cube[depth + 1]
    mv      a2, t1
    jal     turn_pack
    addi    s3, s3, 1
    CHECK_NODE
    li      t0, NEAR_DEPTH
    bne     s3, t0, .Ldescend
    addi    s3, s3, -1              # a leaf: stay on the parent
    j       .Ldfs
.Ldescend:
    add     t0, sp, s3
    sb      zero, ITER(t0)          # iter[depth] = 0
    j       .Ldfs
.Lpop:
    beqz    s3, .Lfound
    addi    s3, s3, -1
    j       .Ldfs

.Lfound:
    li      t0, MAX_MOVES
    bgt     s4, t0, .Linvalid       # cannot happen for a valid state

    # ---- replay the best prefix: slot i -> slot i + 1 ----
    li      s3, 0
.Lreplay:
    beq     s3, s5, .Lwalk
    add     t0, sp, s3
    lbu     a2, BEST(t0)
    add     t1, sp, s2
    sb      a2, MOVES(t1)           # moves[n++] = best[i]
    addi    s2, s2, 1
    slli    a0, s3, 4
    addi    a0, a0, CUBES
    add     a0, a0, sp
    addi    a1, a0, 16
    jal     turn_pack
    addi    s3, s3, 1
    j       .Lreplay

    # ---- walk the near table from the hit (key s6) back to solved ----
.Lwalk:
    mv      a2, s6
    jal     bsearch_near
    bltz    a0, .Lemit              # cannot happen
    add     t0, s8, a0
    lbu     t0, 0(t0)               # aux
    srli    t1, t0, 4
    beqz    t1, .Lemit              # depth 0: solved
    andi    a2, t0, 15              # move toward solved
    add     t1, sp, s2
    sb      a2, MOVES(t1)           # moves[n++] = move
    addi    s2, s2, 1
    slli    a0, s3, 4
    addi    a0, a0, CUBES
    add     a0, a0, sp
    addi    a1, a0, 16
    jal     turn_pack
    mv      s6, a0
    addi    s3, s3, 1
    j       .Lwalk

    # ---- text length: names, single spaces, NUL ----
.Lemit:
    la      t2, move_name
    li      t0, 1                   # the NUL
    li      t1, 0
.Llen:
    beq     t1, s2, .Llen_done
    add     t3, sp, t1
    lbu     t3, MOVES(t3)
    slli    t4, t3, 1
    add     t4, t4, t3              # m * 3
    add     t4, t4, t2
    lbu     t4, 1(t4)               # second character, 0 for R, B, D
    snez    t4, t4
    add     t0, t0, t4
    addi    t0, t0, 1
    beqz    t1, 1f
    addi    t0, t0, 1               # separating space
1:
    addi    t1, t1, 1
    j       .Llen
.Llen_done:
    bgeu    s1, t0, .Lwrite         # cap >= len + 1
    beqz    s1, .Lret_m2
    sb      zero, 0(s0)
.Lret_m2:
    li      a0, -2
    j       .Lreturn

.Lwrite:
    mv      t0, s0                  # write position
    li      t1, 0
.Lw:
    beq     t1, s2, .Lw_done
    beqz    t1, 1f
    li      t5, 32                  # ' '
    sb      t5, 0(t0)
    addi    t0, t0, 1
1:
    add     t3, sp, t1
    lbu     t3, MOVES(t3)
    slli    t4, t3, 1
    add     t4, t4, t3
    add     t4, t4, t2              # &move_name[m]
    lbu     t5, 0(t4)
    sb      t5, 0(t0)
    addi    t0, t0, 1
    lbu     t5, 1(t4)
    beqz    t5, 2f
    sb      t5, 0(t0)
    addi    t0, t0, 1
2:
    addi    t1, t1, 1
    j       .Lw
.Lw_done:
    sb      zero, 0(t0)
    mv      a0, s2
    j       .Lreturn

.Linvalid:
    li      a0, -1
.Lreturn:
    lw      ra, 0(sp)
    lw      s0, 4(sp)
    lw      s1, 8(sp)
    lw      s2, 12(sp)
    lw      s3, 16(sp)
    lw      s4, 20(sp)
    lw      s5, 24(sp)
    lw      s6, 28(sp)
    lw      s7, 32(sp)
    lw      s8, 36(sp)
    lw      s9, 40(sp)
    lw      s10, 44(sp)
    lw      s11, 48(sp)
    addi    sp, sp, FRAME
    ret

# ---------------------------------------------------------------------------
# turn_pack: a1 = turn(a0, move a2); returns the packed key of a1 in a0.
# Clobbers t0-t6, a3, a4. Uses s9, s10, s11.
# ---------------------------------------------------------------------------
turn_pack:
    slli    t0, a2, 3               # rows are 8 bytes
    add     t1, s10, t0             # source row
    add     t2, s11, t0             # twist row
    li      t3, 0
    li      t4, 0
    TPSTEP  0
    TPSTEP  1
    TPSTEP  2
    TPSTEP  3
    TPSTEP  4
    TPSTEP  5
    TPSTEP  6
    srli    t3, t3, 3               # drop p[6]: it is implied
    slli    t3, t3, 14
    or      a0, t3, t4
    ret

# ---------------------------------------------------------------------------
# pack: a0 = packed key of the cube at a0. Clobbers t0-t4.
# ---------------------------------------------------------------------------
pack:
    mv      t0, a0
    addi    t1, a0, 7
    li      t3, 0
    li      t4, 0
.Lpk:
    lbu     t2, 0(t0)
    slli    t3, t3, 3
    or      t3, t3, t2
    lbu     t2, 7(t0)
    slli    t4, t4, 2
    or      t4, t4, t2
    addi    t0, t0, 1
    bne     t0, t1, .Lpk
    srli    t3, t3, 3
    slli    t3, t3, 14
    or      a0, t3, t4
    ret

# ---------------------------------------------------------------------------
# bsearch: index of key a2 in the sorted uint32 table a0 of a1 entries, or
# -1. Keeps a2, a3; clobbers t0-t5. Branch-light: halve the range 14 times,
# then compare once.
# ---------------------------------------------------------------------------
bsearch:
    mv      t0, a0                  # base
    mv      t1, a1                  # n
    li      t5, 1
.Lbs:
    srli    t2, t1, 1               # half
    slli    t3, t2, 2
    add     t3, t3, t0              # &base[half]
    lw      t4, 0(t3)
    bltu    a2, t4, 1f              # key < base[half]: keep the lower part
    mv      t0, t3                  # else base += half
1:
    sub     t1, t1, t2              # n -= half
    bltu    t5, t1, .Lbs            # while n > 1
    lw      t4, 0(t0)
    bne     t4, a2, .Lbs_miss
    sub     a0, t0, a0
    srli    a0, a0, 2               # index
    ret
.Lbs_miss:
    li      a0, -1
    ret

# ---------------------------------------------------------------------------
# bsearch_near: bsearch over rubik_near_key (s7, NEAR_COUNT entries), unrolled.
# The count is fixed, so the halves are too: 6112, 3056, 1528, 764, 382, 191,
# 95, 48, 24, 12, 6, 3, 1, 1. Each step compares the entry one half above the
# base and moves the base up when the key is not below it. a5, a6, a7 hold the
# three byte offsets that do not fit an immediate. Keeps a2, a3; clobbers t0,
# t3, t4.
# ---------------------------------------------------------------------------
    .macro  BSTEP_R reg
    add     t3, t0, \reg
    lw      t4, 0(t3)
    bltu    a2, t4, 1f
    mv      t0, t3
1:
    .endm

    .macro  BSTEP_I off
    lw      t4, \off(t0)
    bltu    a2, t4, 1f
    addi    t0, t0, \off
1:
    .endm

bsearch_near:
    mv      t0, s7
    BSTEP_R a5                      # 6112
    BSTEP_R a6                      # 3056
    BSTEP_R a7                      # 1528
    addi    t3, t0, 764 * 2         # 764: 3056 bytes, two immediates
    lw      t4, 764 * 2(t3)
    bltu    a2, t4, 1f
    addi    t0, t3, 764 * 2
1:
    BSTEP_I 382 * 4
    BSTEP_I 191 * 4
    BSTEP_I 95 * 4
    BSTEP_I 48 * 4
    BSTEP_I 24 * 4
    BSTEP_I 12 * 4
    BSTEP_I 6 * 4
    BSTEP_I 3 * 4
    BSTEP_I 1 * 4
    BSTEP_I 1 * 4
    lw      t4, 0(t0)
    bne     t4, a2, .Lbn_miss
    sub     a0, t0, s7
    srli    a0, a0, 2               # index
    ret
.Lbn_miss:
    li      a0, -1
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm
