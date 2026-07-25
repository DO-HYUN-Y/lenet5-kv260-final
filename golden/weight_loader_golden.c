/* Independent C golden model for weight_loader (my_self.md sec.11.10).
 *
 * weight_loader is a passive BRAM-address-driven reader per window_gen.sv's
 * own header comment: "Weight Loader is a passive BRAM-address-driven
 * reader that just follows k_out -- no independent FSM on that side
 * (sec.11.10 addressing: addr = base_layer + pass*depth + k, base_layer/pass
 * added upstream)." This model does NOT re-derive k_out itself -- it reads
 * window_gen's own golden trace (wgen_golden_out.txt) and replays its
 * k_out/pair_valid[0]/depth_last[0] columns as the tap-address stream,
 * exactly like the real RTL will sit downstream of window_gen.
 *
 * Correctness of the dummy-flush cycle (window_gen emits pair_valid=1,
 * depth_last=1, k_out=0 when a whole band is row_zero-skipped) does NOT
 * need special-casing here: on that cycle win_q is all-zero, so downstream
 * data-gated MAC (sec.9.2) forces product=0 regardless of which weight
 * word gets fetched. weight_loader can blindly follow k_out every cycle.
 *
 * Bank/addressing model (sec.11.10, Conv mode only -- fc_mode reconfig is
 * out of scope until fc layers are built):
 *   8 independent column banks (bank index c = physical systolic column,
 *   i.e. one filter per column-group), each addressed identically:
 *     addr = BASE_LAYER + PASS_IDX * DEPTH + k        (DEPTH = K*K*C_IN)
 *   BRAM read has 1-cycle latency (registered output, matches real SDP
 *   BRAM behavior) -- this cycle's (addr,valid) is captured, and the
 *   fetched wgt_q/wgt_valid/wgt_depth_last appear on the NEXT cycle. This
 *   is why the output trace has exactly one more line than the input
 *   trace (final line flushes the last captured address).
 *
 * Weight memory contents are a fixed deterministic pattern (not random --
 * makes the RTL preload file and the expected fetch values both trivially
 * re-derivable by inspection): mem[c][a] = ((c*7 + a*3 + 11) % 256) - 128.
 *
 * Output line format (space-separated ints), one line per cycle, starting
 * the cycle after the first k_out/pair_valid input is presented, through
 * one extra drain cycle after the last input line:
 *   wgt_q[0..7] wgt_valid wgt_depth_last
 *
 * Stim dump (wload_stim_weights.txt), read by the RTL testbench to preload
 * the 8 banks via weight_loader's own write port:
 *   header line: NC MEM_DEPTH
 *   then NC rows, each row = MEM_DEPTH ints (bank-major, addr-minor).
 */
#include <stdio.h>
#include <stdlib.h>

#define K          5
#define C_IN       2
#define NG         4
#define NC         8
#define DEPTH      (K * K * C_IN)   /* 50 */
#define BASE_LAYER 37
#define PASS_IDX   1
#define MEM_DEPTH  200              /* covers 37 + 1*50 + 0..49 = 87..136 */

static int mem[NC][MEM_DEPTH];

static void build_mem(void) {
    for (int c = 0; c < NC; c++)
        for (int a = 0; a < MEM_DEPTH; a++)
            mem[c][a] = ((c * 7 + a * 3 + 11) % 256) - 128;
}

static void dump_mem(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen mem"); exit(1); }
    fprintf(f, "%d %d\n", NC, MEM_DEPTH);
    for (int c = 0; c < NC; c++) {
        for (int a = 0; a < MEM_DEPTH; a++)
            fprintf(f, "%d%s", mem[c][a], (a == MEM_DEPTH - 1) ? "\n" : " ");
    }
    fclose(f);
}

int main(void) {
    build_mem();
    dump_mem("wload_stim_weights.txt");

    FILE *fin = fopen("wgen_golden_out.txt", "r");
    if (!fin) { perror("fopen wgen_golden_out.txt"); return 1; }

    FILE *fout = fopen("wload_golden_out.txt", "w");
    if (!fout) { perror("fopen wload_golden_out.txt"); return 1; }

    int prev_valid = 0, prev_addr = 0, prev_dlast = 0;
    int win[2 * NG], pv[NG], lm[NG], dl[NG], k_out;
    int n_lines = 0;

    while (1) {
        int ok = 1;
        for (int i = 0; i < 2 * NG && ok; i++) ok = (fscanf(fin, "%d", &win[i]) == 1);
        for (int i = 0; i < NG && ok; i++)     ok = (fscanf(fin, "%d", &pv[i]) == 1);
        for (int i = 0; i < NG && ok; i++)     ok = (fscanf(fin, "%d", &lm[i]) == 1);
        for (int i = 0; i < NG && ok; i++)     ok = (fscanf(fin, "%d", &dl[i]) == 1);
        if (ok) ok = (fscanf(fin, "%d", &k_out) == 1);
        if (!ok) break;
        n_lines++;

        /* this cycle's output = registered fetch captured last cycle */
        if (prev_valid) {
            for (int c = 0; c < NC; c++) fprintf(fout, "%d ", mem[c][prev_addr]);
            fprintf(fout, "%d %d\n", 1, prev_dlast);
        } else {
            for (int c = 0; c < NC; c++) fprintf(fout, "%d ", 0);
            fprintf(fout, "%d %d\n", 0, 0);
        }

        /* capture this cycle's input for next cycle's registered output */
        prev_valid = pv[0];
        prev_addr  = BASE_LAYER + PASS_IDX * DEPTH + k_out;
        prev_dlast = dl[0];
    }
    fclose(fin);

    /* one extra drain cycle to flush the last captured address */
    if (prev_valid) {
        for (int c = 0; c < NC; c++) fprintf(fout, "%d ", mem[c][prev_addr]);
        fprintf(fout, "%d %d\n", 1, prev_dlast);
    } else {
        for (int c = 0; c < NC; c++) fprintf(fout, "%d ", 0);
        fprintf(fout, "%d %d\n", 0, 0);
    }

    fclose(fout);
    printf("weight_loader_golden: %d input lines, %d output lines\n", n_lines, n_lines + 1);
    return 0;
}
