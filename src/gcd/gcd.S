# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    # Register use: a0 = a, a1 = b, a2 = shift, t0 = scratch.
    beqz    a0, .Lret_b         # if (a == 0) return b;
    beqz    a1, .Lret_a         # if (b == 0) return a;
    li      a2, 0               # shift = 0;

    or      t0, a0, a1          # if (((a | b) & 1) != 0) skip the loop
    andi    t0, t0, 1
    bnez    t0, .Lstrip_a
.Lcommon:                       # do {
    srli    a0, a0, 1           #   a >>= 1;
    srli    a1, a1, 1           #   b >>= 1;
    addi    a2, a2, 1           #   shift++;
    or      t0, a0, a1          # } while (((a | b) & 1) == 0);
    andi    t0, t0, 1
    beqz    t0, .Lcommon

.Lstrip_a:
    andi    t0, a0, 1           # if ((a & 1) != 0) skip the loop
    bnez    t0, .Lloop
.Lodd_a:                        # do {
    srli    a0, a0, 1           #   a >>= 1;
    andi    t0, a0, 1           # } while ((a & 1) == 0);
    beqz    t0, .Lodd_a

.Lloop:                         # do {
    andi    t0, a1, 1           #   if ((b & 1) != 0) skip the inner loop
    bnez    t0, .Lcmp
.Lstrip_b:                      #   do {
    srli    a1, a1, 1           #     b >>= 1;
    andi    t0, a1, 1           #   } while ((b & 1) == 0);
    beqz    t0, .Lstrip_b
.Lcmp:
    bgeu    a1, a0, .Lsub       #   if (a > b) {   written as: b >= a skips the swap
    mv      t0, a0              #     t = a;
    mv      a0, a1              #     a = b;
    mv      a1, t0              #     b = t; }
.Lsub:
    sub     a1, a1, a0          #   b -= a;
    bnez    a1, .Lloop          # } while (b != 0);

    sll     a0, a0, a2          # return a << shift;
    ret

.Lret_b:
    mv      a0, a1              # return value must be in a0
.Lret_a:
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
