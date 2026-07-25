/* Independent C golden model for window_gen (my_self.md sec.11.1-11.9).
 *
 * window_gen is the single master sequencer: it owns the 5-slot FF line
 * buffer, the kr/kc/ch tap counters, row_zero skip logic (sec.9.1), and
 * drives skew_buf's input side (win_q[0:7], pair_valid/lane_mask/depth_last
 * per group) directly -- Weight Loader is a passive BRAM reader that just
 * follows whatever tap index k this module emits, so k_out is modeled here
 * too (as the weight tap linear address window_gen would drive).
 *
 * Test shape is deliberately NOT full Conv1 scale (32x32->28x28) -- it is a
 * small synthetic shape chosen to exercise every skip-count from 0 to 5
 * (fully-zero band) in one run, plus lane_mask boundary AND input-overrun
 * zero-forcing simultaneously in the last tile of each row:
 *   C_IN=2, K=5, FMAP_W=FMAP_H=13, OUT_W=OUT_H=9 (2 tiles/row, tile1 base=8
 *   leaves only output col 8 valid out of 8 lanes, and kc+r reaches col 19
 *   which overruns FMAP_W=13).
 * Rows 3..7 (5 consecutive rows, both channels) are forced to all-zero so
 * band b=3 (window rows 3-7) hits the fully-skipped-tile edge case; bands
 * 0,1,2 and 4,5,6,7 each get a different partial skip count (1..4); band 8
 * gets skip count 0. This is a deliberate hand-picked image, not random.
 *
 * Degenerate all-zero-tile handling (derived from packed_pe.sv acc logic):
 * acc_valid only ever fires when pair_valid reaches tag_pipe[3] with
 * depth_last set. If every kr row of a tile is skipped, window_gen must
 * still emit exactly ONE dummy cycle (pair_valid=1, depth_last=1, act=0)
 * per tile so the accumulator flushes an explicit zero result instead of
 * silently never firing acc_valid for that spatial position. Weight tap
 * value on that dummy cycle is irrelevant (act=0 forces product=0 no
 * matter what weight_in is), so k_out=0 is used.
 *
 * Cycle budget is architected explicitly (not left as "however long RTL
 * happens to take"), so the RTL FSM must match this exactly for the line
 * diff to pass:
 *   PREFILL:        5*C_IN*FMAP_W idle cycles (1 pixel/cycle load of the
 *                    first 5 rows into slots 0..4)
 *   PREFILL_DRAIN:  1 idle cycle (row_zero OR-reduce settle margin)
 *   COMPUTE:        per tile: dummy 1-cycle flush if fully skipped, else
 *                    5*C_IN cycles per surviving (non-skipped) kr
 *   PREFETCH:       up to two future rows load in parallel with COMPUTE into
 *                    a K+2-bank FF ring, so even the deliberate zero-row
 *                    burst emits no idle source cycles for this shape
 * repeated COMPUTE with one setup cycle per band, no slide bubble.
 *
 * Output line format (space-separated ints), one line per simulated cycle
 * from the cycle after start through the cycle window_gen's own last valid
 * COMPUTE cycle (inclusive), matching tb_skew_buf.sv's per-cycle log style:
 *   win_q[0..7] pair_valid[0..3] lane_mask[0..3] depth_last[0..3] k_out
 *
 * Image dump (wgen_stim_img.txt), read by the RTL testbench to preload its
 * BRAM/memory model:
 *   header line: C_IN FMAP_W FMAP_H OUT_W OUT_H
 *   then FMAP_H rows, each row = C_IN*FMAP_W ints (ch-major, col-minor).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define K       5
#define NG      4
#define TILE    (2 * NG)   /* 8 output columns per tile */

#define C_IN    2
#define FMAP_W  13
#define FMAP_H  13
#define OUT_W   9
#define OUT_H   9

static int img[FMAP_H][C_IN][FMAP_W];

/* 5-slot FF line buffer + per-slot row_zero flag */
static int line_buf[5][C_IN][FMAP_W];
static int row_zero_by_slot[5];

static FILE *fout;

static void build_image(void) {
    unsigned int seed = 12345u;
    for (int r = 0; r < FMAP_H; r++) {
        int force_zero = (r >= 3 && r <= 7);
        for (int ch = 0; ch < C_IN; ch++) {
            for (int c = 0; c < FMAP_W; c++) {
                if (force_zero) {
                    img[r][ch][c] = 0;
                } else {
                    seed = seed * 1103515245u + 12345u;
                    img[r][ch][c] = (int)((seed >> 16) % 41) - 20; /* [-20,20] */
                }
            }
        }
    }
}

static void dump_image(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen img"); exit(1); }
    fprintf(f, "%d %d %d %d %d\n", C_IN, FMAP_W, FMAP_H, OUT_W, OUT_H);
    for (int r = 0; r < FMAP_H; r++) {
        for (int ch = 0; ch < C_IN; ch++) {
            for (int c = 0; c < FMAP_W; c++) {
                fprintf(f, "%d%s", img[r][ch][c],
                        (ch == C_IN - 1 && c == FMAP_W - 1) ? "\n" : " ");
            }
        }
    }
    fclose(f);
}

static void emit_cycle(const int win[2 * NG], const int pv[NG],
                        const int lm[NG], const int dl[NG], int k_out) {
    for (int i = 0; i < 2 * NG; i++) fprintf(fout, "%d ", win[i]);
    for (int i = 0; i < NG; i++)     fprintf(fout, "%d ", pv[i]);
    for (int i = 0; i < NG; i++)     fprintf(fout, "%d ", lm[i]);
    for (int i = 0; i < NG; i++)     fprintf(fout, "%d ", dl[i]);
    fprintf(fout, "%d\n", k_out);
}

static void emit_idle(void) {
    int win[2 * NG] = {0};
    int pv[NG] = {0}, lm[NG] = {0}, dl[NG] = {0};
    emit_cycle(win, pv, lm, dl, 0);
}

/* load one image row into line_buf[slot], recompute that slot's row_zero,
 * emitting one idle cycle per pixel (1 pixel/cycle load rate) */
static void load_row_into_slot(int img_row, int slot, int emit_load_cycles) {
    int any_nonzero = 0;
    for (int ch = 0; ch < C_IN; ch++) {
        for (int c = 0; c < FMAP_W; c++) {
            int v = img[img_row][ch][c];
            line_buf[slot][ch][c] = v;
            if (v != 0) any_nonzero = 1;
            if (emit_load_cycles) emit_idle();
        }
    }
    row_zero_by_slot[slot] = !any_nonzero;
}

int main(void) {
    fout = fopen("wgen_golden_out.txt", "w");
    if (!fout) { perror("fopen out"); return 1; }

    build_image();
    dump_image("wgen_stim_img.txt");

    int lb_base = 0;

    /* PREFILL: rows 0..4 -> slots 0..4 (lb_base=0, so slot==kr directly) */
    for (int r = 0; r < K; r++) load_row_into_slot(r, r, 1);
    emit_idle(); /* PREFILL_DRAIN */

    int num_tiles = (OUT_W + TILE - 1) / TILE;

    for (int b = 0; b < OUT_H; b++) {
        /* which kr survive row_zero skip this band, in ascending order */
        int active_kr[K], n_active = 0;
        for (int kr = 0; kr < K; kr++) {
            int slot = (lb_base + kr) % 5;
            if (!row_zero_by_slot[slot]) active_kr[n_active++] = kr;
        }
        int active_kr_last = (n_active > 0) ? active_kr[n_active - 1] : -1;

        for (int tx = 0; tx < num_tiles; tx++) {
            int tile_base_col = tx * TILE;
            int lm[NG];
            for (int g = 0; g < NG; g++) {
                int lo_valid = (tile_base_col + 2 * g)     < OUT_W;
                int hi_valid = (tile_base_col + 2 * g + 1) < OUT_W;
                lm[g] = (hi_valid << 1) | lo_valid;
            }

            if (n_active == 0) {
                /* degenerate all-zero-tile: one dummy flush cycle */
                int win[2 * NG] = {0};
                int pv[NG], dl[NG];
                for (int g = 0; g < NG; g++) { pv[g] = 1; dl[g] = 1; }
                emit_cycle(win, pv, lm, dl, 0);
                continue;
            }

            for (int ai = 0; ai < n_active; ai++) {
                int kr = active_kr[ai];
                int slot = (lb_base + kr) % 5;
                for (int kc = 0; kc < K; kc++) {
                    for (int ch = 0; ch < C_IN; ch++) {
                        int k = (kr * K + kc) * C_IN + ch;
                        int win[2 * NG];
                        for (int r = 0; r < 2 * NG; r++) {
                            int col = tile_base_col + kc + r;
                            win[r] = (col >= FMAP_W) ? 0 : line_buf[slot][ch][col];
                        }
                        int pv[NG], dl[NG];
                        int is_last = (kr == active_kr_last && kc == K - 1 && ch == C_IN - 1);
                        for (int g = 0; g < NG; g++) { pv[g] = 1; dl[g] = is_last; }
                        emit_cycle(win, pv, lm, dl, k);
                    }
                }
            }
        }

        if (b < OUT_H - 1) {
            int new_row = b + K;
            int write_slot = lb_base;
            /* The sixth bank was filled during this band's COMPUTE cycles.
             * Updating the model here changes no source-visible cycle. */
            load_row_into_slot(new_row, write_slot, 0);
            lb_base = (lb_base + 1) % 5;
            emit_idle(); /* next band's active-kr setup cycle */
        }
    }

    fclose(fout);
    return 0;
}
