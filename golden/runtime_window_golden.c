/* runtime_window_golden.c -- C1/C3 runtime window reference. */

static void dims(int case_id, int *w, int *h, int *c, int *ow, int *oh) {
    if (case_id == 1) {
        *w = 32; *h = 32; *c = 1; *ow = 28; *oh = 28;
    } else {
        *w = 14; *h = 14; *c = 6; *ow = 10; *oh = 10;
    }
}

int runtime_row_zero(int case_id, int y) {
    if (case_id == 1) return y >= 4 && y <= 8;
    return y == 2 || y == 5 || y == 6;
}

static int pixel_at(int case_id, int y, int ch, int x) {
    int w, h, c, ow, oh;
    dims(case_id, &w, &h, &c, &ow, &oh);
    if (y < 0 || y >= h || ch < 0 || ch >= c || x < 0 || x >= w)
        return 0;
    if (runtime_row_zero(case_id, y)) return 0;
    return ((case_id + 3) * 17 + (y + 2) * 19 +
            (ch + 5) * 11 + (x + 7) * 3) % 31 - 15;
}

int runtime_pixel(int case_id, int index) {
    int w, h, c, ow, oh;
    int row_width;
    int y;
    int in_row;
    int ch;
    int x;
    dims(case_id, &w, &h, &c, &ow, &oh);
    row_width = c * w;
    y = index / row_width;
    in_row = index % row_width;
    ch = in_row / w;
    x = in_row % w;
    return pixel_at(case_id, y, ch, x);
}

static int band_all_zero(int case_id, int out_y) {
    int kr;
    for (kr = 0; kr < 5; ++kr)
        if (!runtime_row_zero(case_id, out_y + kr)) return 0;
    return 1;
}

int runtime_first_k(int case_id, int out_y) {
    int w, h, c, ow, oh;
    int kr;
    dims(case_id, &w, &h, &c, &ow, &oh);
    if (band_all_zero(case_id, out_y)) return 0;
    for (kr = 0; kr < 5; ++kr)
        if (!runtime_row_zero(case_id, out_y + kr))
            return kr * 5 * c;
    return 0;
}

int runtime_next_k(int case_id, int out_y, int current_k) {
    int w, h, c, ow, oh;
    int kr;
    int rem;
    int kc;
    int ch;
    dims(case_id, &w, &h, &c, &ow, &oh);
    if (band_all_zero(case_id, out_y)) return -1;
    kr = current_k / (5 * c);
    rem = current_k % (5 * c);
    kc = rem / c;
    ch = rem % c;
    if (ch + 1 < c) return current_k + 1;
    if (kc + 1 < 5) return current_k + 1;
    for (++kr; kr < 5; ++kr)
        if (!runtime_row_zero(case_id, out_y + kr))
            return kr * 5 * c;
    return -1;
}

int runtime_win(int case_id, int out_y, int tile_x, int k, int lane) {
    int w, h, c, ow, oh;
    int kr;
    int rem;
    int kc;
    int ch;
    dims(case_id, &w, &h, &c, &ow, &oh);
    if (band_all_zero(case_id, out_y)) return 0;
    kr = k / (5 * c);
    rem = k % (5 * c);
    kc = rem / c;
    ch = rem % c;
    return pixel_at(case_id, out_y + kr, ch, tile_x * 8 + kc + lane);
}
