/* skew_buf_golden.c -- independent per-cycle shift-register replica of
 * skew_buf.sv (my_self.md sec.11.6). Purpose is cycle-exact delay checking,
 * not just final value checking, so this reads one stim line per clock
 * cycle and emits one output line per clock cycle (1:1 with RTL capture),
 * instead of a FIFO/scoreboard value-only match.
 *
 * Sampling convention (must match tb_skew_buf.sv exactly):
 *   stim line T   = DUT inputs as sampled at posedge T (values driven by the
 *                   testbench at the preceding negedge, stable through the edge).
 *   output line T = DUT outputs as sampled at posedge T + 1ns (i.e. just after
 *                   that SAME edge's nonblocking updates land).
 * Because output(T) is read only 1ns after the very edge that stim(T) was
 * captured on, a g-stage register chain (g>=1) shows output(T) == stim(T-g+1),
 * not stim(T-g): the first stage's NBA update already lands within edge T
 * itself, so comparing "input at T" to "output right after T" already spans
 * one stage for free. g=0 (pure combinational passthrough) is unconditional
 * on en and always reflects the current row's raw input.
 *
 * stim line format (space-separated ints):
 *   en win_q[0..7] pair_valid_in[0..3] lane_mask_in[0..3] depth_last_in[0..3] weight_q[0..7]
 * output line format (space-separated ints), per group g=0..3:
 *   act_lo_out act_hi_out pair_valid lane_mask depth_last
 * followed by 8 weight_out values.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NG 4
#define NC 8
#define MAXLINE 512

typedef struct {
    int lo, hi, pv, lm, dl;
} pair_t;

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <stim.log> <out.log>\n", argv[0]);
        return 1;
    }
    FILE *fin = fopen(argv[1], "r");
    if (!fin) { perror("fopen stim"); return 1; }
    FILE *fout = fopen(argv[2], "w");
    if (!fout) { perror("fopen out"); return 1; }

    /* group g shift chain: g stages, each holding {lo,hi,pv,lm,dl} */
    pair_t g_chain[NG][NG];   /* g_chain[g][0..g-1], stage 0 = nearest input */
    /* column c shift chain: c stages, each holding weight byte */
    int w_chain[NC][NC];      /* w_chain[c][0..c-1] */

    memset(g_chain, 0, sizeof(g_chain));
    memset(w_chain, 0, sizeof(w_chain));

    char line[MAXLINE];
    while (fgets(line, sizeof(line), fin)) {
        if (line[0] == '\n' || line[0] == '#') continue;

        int en;
        int win_q[2 * NG];
        int pv_in[NG], lm_in[NG], dl_in[NG];
        int wq[NC];

        char *tok = strtok(line, " \t\n");
        en = atoi(tok);
        for (int i = 0; i < 2 * NG; i++) { tok = strtok(NULL, " \t\n"); win_q[i] = atoi(tok); }
        for (int i = 0; i < NG; i++) { tok = strtok(NULL, " \t\n"); pv_in[i] = atoi(tok); }
        for (int i = 0; i < NG; i++) { tok = strtok(NULL, " \t\n"); lm_in[i] = atoi(tok); }
        for (int i = 0; i < NG; i++) { tok = strtok(NULL, " \t\n"); dl_in[i] = atoi(tok); }
        for (int i = 0; i < NC; i++) { tok = strtok(NULL, " \t\n"); wq[i] = atoi(tok); }

        /* apply this cycle's (possibly gated) register update FIRST, then
         * read the chain state -- matches sampling output 1ns after the
         * same edge that consumed this row's stim (see file header). */
        if (en) {
            for (int g = 1; g < NG; g++) {
                for (int i = g - 1; i >= 1; i--) g_chain[g][i] = g_chain[g][i - 1];
                g_chain[g][0].lo = win_q[2 * g];
                g_chain[g][0].hi = win_q[2 * g + 1];
                g_chain[g][0].pv = pv_in[g];
                g_chain[g][0].lm = lm_in[g];
                g_chain[g][0].dl = dl_in[g];
            }
            for (int c = 1; c < NC; c++) {
                for (int i = c - 1; i >= 1; i--) w_chain[c][i] = w_chain[c][i - 1];
                w_chain[c][0] = wq[c];
            }
        }

        pair_t g_out[NG];
        int w_out[NC];

        for (int g = 0; g < NG; g++) {
            if (g == 0) {
                /* pure combinational tap: unconditional on en, tracks the
                 * raw port value live */
                g_out[g].lo = win_q[0];
                g_out[g].hi = win_q[1];
                g_out[g].pv = pv_in[0];
                g_out[g].lm = lm_in[0];
                g_out[g].dl = dl_in[0];
            } else {
                g_out[g] = g_chain[g][g - 1];
            }
        }
        for (int c = 0; c < NC; c++) {
            if (c == 0) {
                w_out[c] = wq[0];
            } else {
                w_out[c] = w_chain[c][c - 1];
            }
        }

        for (int g = 0; g < NG; g++) {
            fprintf(fout, "%d %d %d %d %d ",
                    g_out[g].lo, g_out[g].hi, g_out[g].pv, g_out[g].lm, g_out[g].dl);
        }
        for (int c = 0; c < NC; c++) {
            fprintf(fout, "%d%s", w_out[c], (c == NC - 1) ? "\n" : " ");
        }
    }

    fclose(fin);
    fclose(fout);
    return 0;
}
