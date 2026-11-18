# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

    .text

# ---------------------------------------------------------------------------
# op1: a + b using only &, ^, <<.  Loop until the carry word b is zero.
#   a0 = a, a1 = b, a2 = n (pointer), a3 = passes, t0 = a & b
# ---------------------------------------------------------------------------
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    li      a3, 0                   # passes = 0
    beqz    a1, .Lop1_done          # if (b == 0) skip the loop
.Lop1_loop:                         # do {
    and     t0, a0, a1              #   t0 = a & b
    xor     a0, a0, a1              #   a = a ^ b         (uses the old b)
    slli    a1, t0, 1               #   b = t0 << 1       (b is free now)
    addi    a3, a3, 1               #   passes++
    bnez    a1, .Lop1_loop          # } while (b != 0);
.Lop1_done:
    sw      a3, 0(a2)               # *n = passes
    ret                             # return a (already in a0)
    .size   op1_asm, .-op1_asm

# ---------------------------------------------------------------------------
# op2: a - b
# ---------------------------------------------------------------------------
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1              # return a - b
    ret
    .size   op2_asm, .-op2_asm

# ---------------------------------------------------------------------------
# op3: (a >> 1) + (b >> 1) + (a & b & 1)
# ---------------------------------------------------------------------------
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    srli    t0, a0, 1               # t0 = a >> 1
    srli    t1, a1, 1               # t1 = b >> 1
    and     t2, a0, a1              # t2 = a & b
    andi    t2, t2, 1               # t2 = a & b & 1
    add     a0, t0, t1              # a0 = (a >> 1) + (b >> 1)
    add     a0, a0, t2              # a0 += (a & b & 1)
    ret
    .size   op3_asm, .-op3_asm

# ---------------------------------------------------------------------------
# q_mul: Q11.20 product, 64-bit shift-and-add, round half up, >> 20.
#   a0 = a (= ua), a1 = b
#   t0 = hi, t1 = lo, t2 = loop counter, t3 = carry, t4 = scratch
# ---------------------------------------------------------------------------
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    li      t0, 0                   # hi = 0
    mv      t1, a1                  # lo = b
    li      t2, 32                  # i  = 32 (count down)
.Lqm_loop:
    andi    t3, t1, 1               # t3 = lo & 1   (also carry = 0 if bit clear)
    beqz    t3, .Lqm_shift          # if (lo & 1) {
    add     t0, t0, a0              #     hi += ua
    sltu    t3, t0, a0              #     carry = hi < ua   (unsigned overflow)
.Lqm_shift:                         # }
    srli    t1, t1, 1               # lo >>= 1
    slli    t4, t0, 31              # t4 = hi << 31
    or      t1, t1, t4              # lo = (lo >> 1) | (hi << 31)
    srli    t0, t0, 1               # hi >>= 1
    slli    t4, t3, 31              # t4 = carry << 31
    or      t0, t0, t4              # hi = (hi >> 1) | (carry << 31)
    addi    t2, t2, -1              # i--
    bnez    t2, .Lqm_loop           # 32 passes

    # unsigned product -> signed product (fix the high word only)
    bgez    a0, .Lqm_b_sign         # if (a < 0)
    sub     t0, t0, a1              #     hi -= b
.Lqm_b_sign:
    bgez    a1, .Lqm_round          # if (b < 0)
    sub     t0, t0, a0              #     hi -= ua
.Lqm_round:
    # add 2^19 (half a unit) to the 64-bit value hi:lo
    li      t4, 0x80000             # t4 = 1 << 19
    add     t3, t1, t4              # t3 = lo + 2^19
    sltu    t4, t3, t1              # t4 = carry out of lo (t3 < old lo)
    add     t0, t0, t4              # hi += carry
    # (hi:lo) >> 20, keep low 32 bits
    srli    t3, t3, 20              # lo >> 20
    slli    t0, t0, 12              # hi << (32 - 20)
    or      a0, t3, t0              # result
    ret
    .size   q_mul_asm, .-q_mul_asm
