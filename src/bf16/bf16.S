# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.

    .text

# ---------------------------------------------------------------------------
# bf16_from_f32: Inf/NaN keep the top half; otherwise round to nearest even
# by adding 0x7FFF + bit 16, then keep the top half.
# ---------------------------------------------------------------------------
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    srli    t0, a0, 23
    andi    t0, t0, 0xFF            # exponent field
    li      t1, 0xFF
    beq     t0, t1, .Lf32_top       # Inf or NaN: top 16 bits unchanged
    srli    t1, a0, 16
    andi    t1, t1, 1               # bit 16 (lowest kept bit)
    add     a0, a0, t1
    lui     t1, 0x8
    addi    t1, t1, -1              # 0x7FFF
    add     a0, a0, t1
.Lf32_top:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# ---------------------------------------------------------------------------
# bf16_mul
#   t0 = sign, t1 = exp_a, t2 = exp_b, t3 = mant_a, t4 = mant_b,
#   t5 = 0xFF then exp_adjust, t6 = scratch then product
# ---------------------------------------------------------------------------
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     t0, a0, a1
    lui     t6, 0x8                 # 0x8000
    and     t0, t0, t6              # sign = (a ^ b) & 0x8000
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # exp_a
    srli    t2, a1, 7
    andi    t2, t2, 0xFF            # exp_b
    andi    t3, a0, 0x7F            # mant_a
    andi    t4, a1, 0x7F            # mant_b
    li      t5, 0xFF

    # a first: NaN a -> a; Inf * 0 -> NaN; Inf * anything -> signed Inf
    bne     t1, t5, .Lmul_chk_b
    bnez    t3, .Lmul_ret_a
    or      t6, t2, t4
    beqz    t6, .Lmul_ret_nan
    j       .Lmul_ret_inf
.Lmul_chk_b:
    bne     t2, t5, .Lmul_finite
    bnez    t4, .Lmul_ret_b
    or      t6, t1, t3
    beqz    t6, .Lmul_ret_nan
    j       .Lmul_ret_inf

.Lmul_finite:
    or      t6, t1, t3
    beqz    t6, .Lmul_ret_sign      # a == 0
    or      t6, t2, t4
    beqz    t6, .Lmul_ret_sign      # b == 0

    # normalize denormals; t5 = exp_adjust
    li      t5, 0
    bnez    t1, .Lmul_a_norm
    li      t1, 1
.Lmul_a_den:
    andi    t6, t3, 0x80
    bnez    t6, .Lmul_b
    slli    t3, t3, 1
    addi    t5, t5, -1
    j       .Lmul_a_den
.Lmul_a_norm:
    ori     t3, t3, 0x80
.Lmul_b:
    bnez    t2, .Lmul_b_norm
    li      t2, 1
.Lmul_b_den:
    andi    t6, t4, 0x80
    bnez    t6, .Lmul_product
    slli    t4, t4, 1
    addi    t5, t5, -1
    j       .Lmul_b_den
.Lmul_b_norm:
    ori     t4, t4, 0x80

.Lmul_product:
    # exp = exp_a + exp_b - 127 + exp_adjust   (t1)
    add     t1, t1, t2
    add     t1, t1, t5
    addi    t1, t1, -127
    # mant = mant_a * mant_b by shift-and-add  (t6); t3 and t4 are consumed
    li      t6, 0
.Lmul_loop:
    andi    t2, t4, 1
    beqz    t2, .Lmul_skip
    add     t6, t6, t3
.Lmul_skip:
    slli    t3, t3, 1
    srli    t4, t4, 1
    bnez    t4, .Lmul_loop

    # renormalize: leading one at bit 15 or bit 14
    lui     t2, 0x8
    and     t2, t6, t2
    beqz    t2, .Lmul_shift7
    srli    t6, t6, 8
    addi    t1, t1, 1
    j       .Lmul_range
.Lmul_shift7:
    srli    t6, t6, 7
.Lmul_range:
    li      t2, 0xFF
    bge     t1, t2, .Lmul_ret_inf   # exp >= 0xFF
    bgtz    t1, .Lmul_normal        # exp > 0
    li      t2, -6
    blt     t1, t2, .Lmul_ret_sign  # exp < -6: zero
    andi    t6, t6, 0x7F            # denormal: fraction >> (1 - exp)
    li      t2, 1
    sub     t2, t2, t1
    srl     t6, t6, t2
    or      a0, t0, t6
    ret
.Lmul_normal:
    andi    t6, t6, 0x7F
    slli    t1, t1, 7
    or      a0, t0, t1
    or      a0, a0, t6
    ret

.Lmul_ret_b:
    mv      a0, a1
.Lmul_ret_a:
    ret
.Lmul_ret_nan:
    li      a0, 0x7FC0
    ret
.Lmul_ret_inf:
    li      a0, 0x7F80
    or      a0, a0, t0
    ret
.Lmul_ret_sign:
    mv      a0, t0
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# ---------------------------------------------------------------------------
# bf16_sqrt
#   t1 = exp then e then new_exp, t2 = mant then m, t3 = sign bit,
#   t4 = low, t5 = high, t6 = result, a1 = mid, a2..a5 = multiply scratch
# ---------------------------------------------------------------------------
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # exp
    andi    t2, a0, 0x7F            # mant
    lui     t3, 0x8
    and     t3, a0, t3              # sign bit
    li      t4, 0xFF
    bne     t1, t4, .Lsq_finite
    bnez    t2, .Lsq_ret_a          # NaN unchanged
    bnez    t3, .Lsq_ret_nan        # -Inf
    ret                             # +Inf unchanged
.Lsq_finite:
    beqz    t3, .Lsq_positive
    or      t4, t1, t2
    bnez    t4, .Lsq_ret_nan        # negative nonzero
.Lsq_positive:
    beqz    t1, .Lsq_ret_zero       # zeros and denormals

    ori     t2, t2, 0x80            # m = mant | 0x80
    addi    t1, t1, -127            # e = exp - 127
    andi    t4, t1, 1
    beqz    t4, .Lsq_even
    slli    t2, t2, 1               # odd e: m <<= 1
    addi    t1, t1, -1              #        e - 1
.Lsq_even:
    srai    t1, t1, 1               # e >> 1 (arithmetic)
    addi    t1, t1, 127             # new_exp

    # largest mid in [90, 256] with (mid * mid) >> 7 <= m
    li      t4, 90                  # low
    li      t5, 256                 # high
    li      t6, 128                 # result
.Lsq_loop:
    bltu    t5, t4, .Lsq_search_done    # while (low <= high)
    add     a1, t4, t5
    srli    a1, a1, 1               # mid
    mv      a3, a1
    mv      a4, a1
    li      a2, 0
.Lsq_mul:                           # a2 = mid * mid by shift-and-add
    andi    a5, a4, 1
    beqz    a5, .Lsq_mul_skip
    add     a2, a2, a3
.Lsq_mul_skip:
    slli    a3, a3, 1
    srli    a4, a4, 1
    bnez    a4, .Lsq_mul
    srli    a2, a2, 7               # sq
    bltu    t2, a2, .Lsq_high       # sq > m
    mv      t6, a1                  # result = mid
    addi    t4, a1, 1               # low = mid + 1
    j       .Lsq_loop
.Lsq_high:
    addi    t5, a1, -1              # high = mid - 1
    j       .Lsq_loop

.Lsq_search_done:
    li      t4, 256
    bltu    t6, t4, .Lsq_norm_up
    srli    t6, t6, 1               # result == 256
    addi    t1, t1, 1
    j       .Lsq_pack
.Lsq_norm_up:
    andi    t4, t6, 0x80
    bnez    t4, .Lsq_pack
    slli    t6, t6, 1
    addi    t1, t1, -1
    j       .Lsq_norm_up
.Lsq_pack:
    li      t4, 0xFF
    bge     t1, t4, .Lsq_ret_inf
    blez    t1, .Lsq_ret_zero
    andi    t6, t6, 0x7F
    slli    t1, t1, 7
    or      a0, t1, t6
.Lsq_ret_a:
    ret
.Lsq_ret_nan:
    li      a0, 0x7FC0
    ret
.Lsq_ret_inf:
    li      a0, 0x7F80
    ret
.Lsq_ret_zero:
    li      a0, 0
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
