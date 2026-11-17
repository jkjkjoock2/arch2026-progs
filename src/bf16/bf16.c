#include "bf16.h"

#define BF16_SIGN 0x8000u
#define BF16_INF 0x7F80u
#define BF16_NAN 0x7FC0u
#define BF16_BIAS 127

/* Round to nearest even: add half of the discarded part (0x7FFF) plus the
 * lowest kept bit, then drop the low 16 bits. Inf and NaN keep their top half.
 */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0xFFu) == 0xFFu)
        return (uint16_t) (f32bits >> 16);
    f32bits += ((f32bits >> 16) & 1u) + 0x7FFFu;
    return (uint16_t) (f32bits >> 16);
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint16_t sign = (a ^ b) & BF16_SIGN;
    uint32_t exp_a = (a >> 7) & 0xFFu, exp_b = (b >> 7) & 0xFFu;
    uint32_t mant_a = a & 0x7Fu, mant_b = b & 0x7Fu;

    /* a is examined first, then b. */
    if (exp_a == 0xFFu) {
        if (mant_a)
            return a;
        if (exp_b == 0 && mant_b == 0)
            return BF16_NAN;
        return sign | BF16_INF;
    }
    if (exp_b == 0xFFu) {
        if (mant_b)
            return b;
        if (exp_a == 0 && mant_a == 0)
            return BF16_NAN;
        return sign | BF16_INF;
    }
    if ((exp_a == 0 && mant_a == 0) || (exp_b == 0 && mant_b == 0))
        return sign;

    /* Normalize denormals: shift the leading one up to bit 7. */
    int exp_adjust = 0;
    if (exp_a == 0) {
        while (!(mant_a & 0x80u)) {
            mant_a <<= 1;
            exp_adjust--;
        }
        exp_a = 1;
    } else {
        mant_a |= 0x80u;
    }
    if (exp_b == 0) {
        while (!(mant_b & 0x80u)) {
            mant_b <<= 1;
            exp_adjust--;
        }
        exp_b = 1;
    } else {
        mant_b |= 0x80u;
    }

    /* 8-bit by 8-bit product: bit 14 or bit 15 is the leading one. */
    uint32_t mant = mant_a * mant_b;
    int exp = (int) exp_a + (int) exp_b - BF16_BIAS + exp_adjust;
    if (mant & 0x8000u) {
        mant >>= 8;
        exp++;
    } else {
        mant >>= 7;
    }

    if (exp >= 0xFF)
        return sign | BF16_INF;
    if (exp <= 0) {
        /* Denormal result: the oracle shifts the 7 fraction bits, without
         * the hidden one, right by (1 - exp); below -6 nothing is left. */
        if (exp < -6)
            return sign;
        return (uint16_t) (sign | ((mant & 0x7Fu) >> (1 - exp)));
    }
    return (uint16_t) (sign | ((uint32_t) exp << 7) | (mant & 0x7Fu));
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t exp = (a >> 7) & 0xFFu;
    uint32_t mant = a & 0x7Fu;

    if (exp == 0xFFu) {
        if (mant)
            return a; /* NaN */
        if (a & BF16_SIGN)
            return BF16_NAN; /* -Inf */
        return a;            /* +Inf */
    }
    if ((a & BF16_SIGN) && (exp || mant))
        return BF16_NAN; /* negative nonzero */
    if (exp == 0)
        return 0; /* zeros and denormals */

    uint32_t m = mant | 0x80u;
    int e = (int) exp - BF16_BIAS;
    int new_exp;
    if (e & 1) {
        m <<= 1;
        new_exp = ((e - 1) >> 1) + BF16_BIAS;
    } else {
        new_exp = (e >> 1) + BF16_BIAS;
    }

    /* Largest mid in [90, 256] with mid^2 / 128 <= m. */
    uint32_t low = 90, high = 256, result = 128;
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        uint32_t sq = (mid * mid) >> 7;
        if (sq <= m) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    if (result >= 256u) {
        result >>= 1;
        new_exp++;
    } else {
        while (!(result & 0x80u)) {
            result <<= 1;
            new_exp--;
        }
    }
    if (new_exp >= 0xFF)
        return BF16_INF;
    if (new_exp <= 0)
        return 0;
    return (uint16_t) (((uint32_t) new_exp << 7) | (result & 0x7Fu));
}
