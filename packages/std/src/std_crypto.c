#include "../../../src/runtime/cyna.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t words[8];
    uint8_t block[64];
    uint64_t length;
    size_t used;
} CynaSha256;

static const uint32_t round_constants[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t rotate_right(uint32_t value, unsigned count) {
    return (value >> count) | (value << (32u - count));
}

static uint32_t load_big_endian(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24u) | ((uint32_t)bytes[1] << 16u) |
           ((uint32_t)bytes[2] << 8u) | (uint32_t)bytes[3];
}

static void store_big_endian(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24u);
    bytes[1] = (uint8_t)(value >> 16u);
    bytes[2] = (uint8_t)(value >> 8u);
    bytes[3] = (uint8_t)value;
}

static void sha256_block(CynaSha256 *state, const uint8_t block[64]) {
    uint32_t schedule[64];
    for (size_t index = 0; index < 16; index++) {
        schedule[index] = load_big_endian(block + index * 4u);
    }
    for (size_t index = 16; index < 64; index++) {
        const uint32_t a = schedule[index - 15];
        const uint32_t b = schedule[index - 2];
        const uint32_t small_zero = rotate_right(a, 7) ^ rotate_right(a, 18) ^ (a >> 3u);
        const uint32_t small_one = rotate_right(b, 17) ^ rotate_right(b, 19) ^ (b >> 10u);
        schedule[index] = schedule[index - 16] + small_zero + schedule[index - 7] + small_one;
    }

    uint32_t a = state->words[0], b = state->words[1], c = state->words[2], d = state->words[3];
    uint32_t e = state->words[4], f = state->words[5], g = state->words[6], h = state->words[7];
    for (size_t index = 0; index < 64; index++) {
        const uint32_t big_one = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
        const uint32_t choose = (e & f) ^ (~e & g);
        const uint32_t first = h + big_one + choose + round_constants[index] + schedule[index];
        const uint32_t big_zero = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
        const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t second = big_zero + majority;
        h = g; g = f; f = e; e = d + first;
        d = c; c = b; b = a; a = first + second;
    }
    state->words[0] += a; state->words[1] += b;
    state->words[2] += c; state->words[3] += d;
    state->words[4] += e; state->words[5] += f;
    state->words[6] += g; state->words[7] += h;
}

static void sha256_init(CynaSha256 *state) {
    const uint32_t initial[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    };
    memcpy(state->words, initial, sizeof(initial));
    state->length = 0;
    state->used = 0;
}

static void sha256_update(CynaSha256 *state, const uint8_t *data, size_t length) {
    state->length += (uint64_t)length;
    while (length != 0) {
        size_t take = 64u - state->used;
        if (take > length) take = length;
        memcpy(state->block + state->used, data, take);
        state->used += take;
        data += take;
        length -= take;
        if (state->used == 64u) {
            sha256_block(state, state->block);
            state->used = 0;
        }
    }
}

static void sha256_final(CynaSha256 *state, uint8_t output[32]) {
    const uint64_t bit_length = state->length * 8u;
    state->block[state->used++] = 0x80u;
    if (state->used > 56u) {
        memset(state->block + state->used, 0, 64u - state->used);
        sha256_block(state, state->block);
        state->used = 0;
    }
    memset(state->block + state->used, 0, 56u - state->used);
    for (size_t index = 0; index < 8; index++) {
        state->block[56u + index] = (uint8_t)(bit_length >> (56u - 8u * index));
    }
    sha256_block(state, state->block);
    for (size_t index = 0; index < 8; index++) {
        store_big_endian(output + index * 4u, state->words[index]);
    }
}

void cyna_std_crypto_sha256_raw(CynaBytes data, CynaBytes output) {
    CynaSha256 state;
    if (data.len < 0 || output.len != 32 || output.ptr == NULL) return;
    sha256_init(&state);
    if (data.len != 0) sha256_update(&state, data.ptr, (size_t)data.len);
    sha256_final(&state, output.ptr);
}

void cyna_std_crypto_hmac_sha256_raw(CynaBytes key, CynaBytes data, CynaBytes output) {
    if (key.len < 0 || data.len < 0 || output.len != 32 || output.ptr == NULL) return;
    uint8_t key_block[64] = {0};
    uint8_t inner_digest[32];
    uint8_t pad[64];
    CynaSha256 state;

    if (key.len > 64) {
        sha256_init(&state);
        sha256_update(&state, key.ptr, (size_t)key.len);
        sha256_final(&state, key_block);
    } else if (key.len != 0) {
        memcpy(key_block, key.ptr, (size_t)key.len);
    }

    for (size_t index = 0; index < 64; index++) pad[index] = key_block[index] ^ 0x36u;
    sha256_init(&state);
    sha256_update(&state, pad, sizeof(pad));
    if (data.len != 0) sha256_update(&state, data.ptr, (size_t)data.len);
    sha256_final(&state, inner_digest);

    for (size_t index = 0; index < 64; index++) pad[index] = key_block[index] ^ 0x5cu;
    sha256_init(&state);
    sha256_update(&state, pad, sizeof(pad));
    sha256_update(&state, inner_digest, sizeof(inner_digest));
    sha256_final(&state, output.ptr);

    volatile uint8_t *clear_key = key_block;
    volatile uint8_t *clear_pad = pad;
    volatile uint8_t *clear_inner = inner_digest;
    volatile uint8_t *clear_state = (volatile uint8_t *)&state;
    for (size_t index = 0; index < sizeof(key_block); index++) clear_key[index] = 0;
    for (size_t index = 0; index < sizeof(pad); index++) clear_pad[index] = 0;
    for (size_t index = 0; index < sizeof(inner_digest); index++) clear_inner[index] = 0;
    for (size_t index = 0; index < sizeof(state); index++) clear_state[index] = 0;
}
