/* Independent C golden model for sa_packed_4x8.sv.
 *
 * packed_pe's own WP487-packed DSP math was already independently verified
 * bit-exact (packed_pe_golden.c, diff=0). sa_packed_4x8.sv only wires 32
 * copies of that already-proven PE together with a horizontal activation hop,
 * a vertical weight hop, and a parallel control-tag shift chain -- so this
 * model checks WIRING/SKEW correctness by re-deriving each PE's expected
 * black-box result (acc_lo = sum(act_lo*w), acc_hi = sum(act_hi*w) over one
 * tile) directly from row g's activation stream and col c's weight stream,
 * independent of when the RTL's hop chains actually deliver that value.
 *
 * Reads sa_stim_log.txt (one line per active cycle):
 *   tile lo0 hi0 lo1 hi1 lo2 hi2 lo3 hi3 w0 w1 w2 w3 w4 w5 w6 w7 depth_last mask0 mask1 mask2 mask3
 * Writes sa_golden_out.txt (one line per (tile,g,c), canonical g=0..3,c=0..7 order):
 *   tile g c acc_lo acc_hi mask
 */
#include <stdio.h>
#include <stdint.h>

#define NG 4
#define NC 8

int main(void) {
    FILE *in = fopen("sa_stim_log.txt", "r");
    FILE *out = fopen("sa_golden_out.txt", "w");
    if (!in || !out) {
        fprintf(stderr, "failed to open stim/golden files\n");
        return 1;
    }

    int32_t acc_lo[NG][NC] = {0};
    int32_t acc_hi[NG][NC] = {0};

    int tile;
    int lo[NG], hi[NG];
    int w[NC];
    int depth_last;
    int mask[NG];

    while (1) {
        if (fscanf(in, "%d", &tile) != 1) break;
        for (int g = 0; g < NG; g++)
            fscanf(in, "%d %d", &lo[g], &hi[g]);
        for (int c = 0; c < NC; c++)
            fscanf(in, "%d", &w[c]);
        fscanf(in, "%d", &depth_last);
        for (int g = 0; g < NG; g++)
            fscanf(in, "%d", &mask[g]);

        for (int g = 0; g < NG; g++) {
            for (int c = 0; c < NC; c++) {
                acc_lo[g][c] += (int32_t)lo[g] * (int32_t)w[c];
                acc_hi[g][c] += (int32_t)hi[g] * (int32_t)w[c];
            }
        }

        if (depth_last) {
            for (int g = 0; g < NG; g++) {
                for (int c = 0; c < NC; c++) {
                    fprintf(out, "%d %d %d %d %d %d\n",
                            tile, g, c, acc_lo[g][c], acc_hi[g][c], mask[g]);
                    acc_lo[g][c] = 0;
                    acc_hi[g][c] = 0;
                }
            }
        }
    }

    fclose(in);
    fclose(out);
    return 0;
}
