#include "fixed.h"

/* The bitwise adder of Quiz 3: the carries are (a & b) << 1, the sum without
 * carries is a ^ b, and the loop repeats until no carry is left. The number
 * of passes is part of the result.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    int passes = 0;
    while (b) {
        uint32_t c = (a & b) << 1;
        a = a ^ b;
        b = c;
        passes++;
    }
    *n = passes;
    return a;
}

/* The budget asks for the plain subtraction, not the bitwise model. */
uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

/* floor((a + b) / 2) without overflow: halve each operand first, then put
 * back the unit lost when both were odd.
 */
uint32_t op3(uint32_t a, uint32_t b)
{
    return (a >> 1) + (b >> 1) + (a & b & 1);
}

/* Q11.20 product. RV32I has no multiply and the runtime has no __muldi3, so
 * the 64-bit product is formed by shift-and-add: the accumulator (hi:lo)
 * starts with b in lo, and each of the 32 passes adds a to hi when the bit
 * leaving lo is set, then shifts the 65-bit value (carry:hi:lo) right by one.
 * After 32 passes hi:lo is the unsigned product of the two bit patterns.
 *
 * The signed product differs from the unsigned one only in the high word:
 * a negative a contributes an extra b * 2^32, a negative b an extra a * 2^32,
 * so subtract those from hi. Then add 2^19 to the 64-bit value and shift it
 * right by 20, keeping the low 32 bits of the result.
 */
int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t ua = (uint32_t) a;
    uint32_t hi = 0, lo = (uint32_t) b;
    for (int i = 0; i < 32; i++) {
        uint32_t carry = 0;
        if (lo & 1) {
            hi += ua;
            carry = hi < ua;
        }
        lo = (lo >> 1) | (hi << 31);
        hi = (hi >> 1) | (carry << 31);
    }
    if (a < 0)
        hi -= (uint32_t) b;
    if (b < 0)
        hi -= ua;

    /* Adding 2^19 carries into hi exactly when lo is within 2^19 of 2^32. */
    hi += lo >= 0u - (1u << (Q - 1));
    lo += 1u << (Q - 1);
    return (int32_t) ((lo >> Q) | (hi << (32 - Q)));
}
