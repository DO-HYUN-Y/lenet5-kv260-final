/* Independent C golden model for packed_pe.sv (my_self.md sec.2, WP487 method A).
 * Reads stim_log.txt (dumped by tb_packed_pe.sv, one line per issued MAC cycle:
 *   act_lo act_hi weight depth_last lane_mask
 * ), replays the WP487 DSP48E2 packing trick bit-exactly (preadd/shift/split,
 * P[17] carry correction) independently from the SV reference model in the
 * testbench, accumulates per tile, and on depth_last emits one result line to
 * golden_out.txt:
 *   acc_lo acc_hi mask
 * in issue order. Compare against rtl_out.txt (dumped from DUT acc_valid
 * events) with `diff` — order-matched, same format as the SV scoreboard.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define SHIFT_G 18

int main(int argc, char **argv) {
    const char *in_path  = (argc > 1) ? argv[1] : "stim_log.txt";
    const char *out_path = (argc > 2) ? argv[2] : "golden_out.txt";

    FILE *fin = fopen(in_path, "r");
    if (!fin) { perror(in_path); return 1; }
    FILE *fout = fopen(out_path, "w");
    if (!fout) { perror(out_path); return 1; }

    int64_t acc_lo = 0, acc_hi = 0;
    long line = 0;
    int results = 0;

    int act_lo, act_hi, weight, depth_last, lane_mask;
    while (fscanf(fin, "%d %d %d %d %d", &act_lo, &act_hi, &weight, &depth_last, &lane_mask) == 5) {
        line++;

        /* WP487 method A: AD = (act_hi << G) + act_lo (preadder), P = AD * weight
         * (single DSP multiply), then split back into two independent signed
         * products with the P[17] carry-correction on the hi slice. */
        int64_t AD = ((int64_t)act_hi << SHIFT_G) + (int64_t)act_lo;
        int64_t P  = AD * (int64_t)weight;

        uint64_t Pu = (uint64_t)P & 0xFFFFFFFFFULL; /* P[35:0] */
        int32_t p17 = (int32_t)((Pu >> 17) & 0x1);

        /* prod_lo = sign_extend(P[17:0]) */
        int32_t prod_lo_raw = (int32_t)(Pu & 0x3FFFF); /* 18 bits */
        int32_t prod_lo = (prod_lo_raw << 14) >> 14;    /* sign-extend from bit17 */

        /* prod_hi = sign_extend(P[35:18]) + P[17] */
        int32_t prod_hi_raw = (int32_t)((Pu >> 18) & 0x3FFFF); /* 18 bits */
        int32_t prod_hi = ((prod_hi_raw << 14) >> 14) + p17;

        acc_lo += prod_lo;
        acc_hi += prod_hi;

        if (depth_last) {
            fprintf(fout, "%lld %lld %d\n", (long long)acc_lo, (long long)acc_hi, lane_mask);
            results++;
            acc_lo = 0;
            acc_hi = 0;
        }
    }

    fclose(fin);
    fclose(fout);
    fprintf(stderr, "golden: %d stim lines, %d results -> %s\n", (int)line, results, out_path);
    return 0;
}
