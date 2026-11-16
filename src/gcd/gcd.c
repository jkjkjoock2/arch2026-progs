#include "gcd.h"

uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    /* gcd(x, 0) = gcd(0, x) = x, which also gives gcd(0, 0) = 0. */
    if (a == 0)
        return b;
    if (b == 0)
        return a;

    /* Factor out the powers of two common to both operands. */
    unsigned shift = 0;
    while (((a | b) & 1) == 0) {
        a >>= 1;
        b >>= 1;
        shift++;
    }

    /* A factor of two in only one operand is not common: drop it. */
    while ((a & 1) == 0)
        a >>= 1;

    /* Both odd: odd minus odd is even, so every subtraction is followed by
     * shifts that at least halve b. */
    do {
        while ((b & 1) == 0)
            b >>= 1;
        if (a > b) {
            uint32_t t = a;
            a = b;
            b = t;
        }
        b -= a;
    } while (b != 0);

    return a << shift;
}
