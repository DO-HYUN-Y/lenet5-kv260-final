/* dual_weight_golden.c -- deterministic byte reference for 64-bit banks. */
int dual_weight_golden(int address, int bank, int byte_lane) {
    return ((address + 3) * 13 + (bank + 1) * 17 +
            (byte_lane + 5) * 19) % 256 - 128;
}
