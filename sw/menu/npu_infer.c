/* ============================================================
 * npu_infer.c -- NPU inference core for the menu firmware
 *
 * The NPU runs all 5 convolutions.  The CPU only:
 *   1. copies one 32x32x3 int8 image (HWC) to 0x2000_0000
 *   2. programs each layer through MMIO and waits for DONE/BUSY=0
 *   3. sums each of the 32 output channels (GAP), runs the integer
 *      FC 32->20, returns argmax and all 20 integer logits
 *
 * The menu layer turns those logits into a fixed-point softmax display.
 *
 * No image data is compiled in: the image always comes from UART.
 * ============================================================ */
#include <stdint.h>

#include "npu_layers.h"
#include "npu_infer.h"

#define MMIO_BASE   0x10000000u
#define NPU_WIN     0x20000000u
#define NPU_PIXELS  (32u * 32u * 3u)

static inline void mmio_wr(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(MMIO_BASE + off) = v;
}

static inline uint32_t mmio_rd(uint32_t off)
{
    return *(volatile uint32_t *)(MMIO_BASE + off);
}

/* ------------------------------------------------------------
 * One NPU layer. Returns elapsed cycles, or 0xFFFFFFFF on error.
 * ------------------------------------------------------------ */
static uint32_t npu_run_layer(const npu_layer_t *L)
{
    while (mmio_rd(0x14) & 1u) {
        /* still busy: never touch the window/descriptors now */
    }
    mmio_wr(0x14, 4u);                /* clear a stale ERROR from the previous tail */

    mmio_wr(0x1C, L->img_base);
    mmio_wr(0x20, L->wgt_base);
    mmio_wr(0x24, L->out_base);
    mmio_wr(0x38, L->img_w);
    mmio_wr(0x3C, L->img_h);
    mmio_wr(0x40, L->cin);
    mmio_wr(0x44, L->cout);
    mmio_wr(0x48, L->k);
    mmio_wr(0x4C, L->stride);
    mmio_wr(0x50, L->pad);
    mmio_wr(0x54, L->out_w);
    mmio_wr(0x58, L->out_h);
    mmio_wr(0x5C, L->shift);

    for (int i = 0; i < 16; i++) {
        uint32_t v = (uint32_t)L->m[2 * i] |
                     ((uint32_t)L->m[2 * i + 1] << 16);
        mmio_wr(0x60u + 4u * (uint32_t)i, v);
    }

    mmio_wr(0xA8, 0);                 /* bias lane pointer = 0 */
    for (int i = 0; i < 32; i++) {
        mmio_wr(0xA4, (uint32_t)L->bias[i]);
    }
    mmio_wr(0xAC, L->act ? 1u : 0u);

    mmio_wr(0x10, 1u);                /* START */

    uint32_t cycles;
    while (!(mmio_rd(0x14) & 2u)) {
        if (mmio_rd(0x14) & 4u) {
            mmio_wr(0x14, 4u);        /* W1C ERROR */
            return 0xFFFFFFFFu;
        }
    }
    /* Wait for BUSY to fall before any stack/window access: while the engine
       owns the B port, a CPU data access is dropped and sets STATUS.ERROR. */
    while (mmio_rd(0x14) & 1u) {
    }
    cycles = mmio_rd(0x28);
    mmio_wr(0x14, 2u);                /* W1C DONE */
    return cycles;
}

static void copy_image(const uint8_t *src)
{
    volatile uint8_t *dst = (volatile uint8_t *)NPU_WIN;
    for (uint32_t i = 0; i < NPU_PIXELS; i++) {
        dst[i] = src[i];
    }
}

int npu_infer(const uint8_t *img, uint32_t *total_cycles, int32_t *scores)
{
    copy_image(img);

    uint32_t total = 0;
    for (int i = 0; i < NPU_NUM_LAYERS; i++) {
        uint32_t c = npu_run_layer(&npu_layers[i]);
        if (c == 0xFFFFFFFFu) {
            return -1;
        }
        total += c;
    }
    *total_cycles = total;

    volatile int8_t *out = (volatile int8_t *)(NPU_WIN + NPU_FINAL_BASE);
    int32_t gap[NPU_FINAL_C];
    for (int c = 0; c < NPU_FINAL_C; c++) {
        gap[c] = 0;
    }
    for (int y = 0; y < NPU_FINAL_H; y++) {
        for (int x = 0; x < NPU_FINAL_W; x++) {
            for (int c = 0; c < NPU_FINAL_C; c++) {
                gap[c] += (int32_t)out[(y * NPU_FINAL_W + x) * NPU_FINAL_C + c];
            }
        }
    }

    int best = 0;
    int32_t best_score = -0x7FFFFFFF;
    for (int o = 0; o < NPU_NUM_CLASSES; o++) {
        int32_t s = npu_fc_bias[o];
        for (int c = 0; c < NPU_FINAL_C; c++) {
            s += gap[c] * (int32_t)npu_fc_w[o][c];
        }
        scores[o] = s;
        if (s > best_score) {
            best_score = s;
            best = o;
        }
    }
    return best;
}

const char *npu_class_name(int idx)
{
    if (idx < 0 || idx >= NPU_NUM_CLASSES) {
        return "?";
    }
    return npu_classes[idx];
}

/* Keep this table in exactly the same order as npu_classes[]. */
static const char *const npu_class_names_cn[NPU_NUM_CLASSES] = {
    "禁止停车",             /* pn  */
    "禁止驶入",             /* pne */
    "靠右侧道路行驶",       /* i5  */
    "禁止鸣喇叭",           /* p11 */
    "限速40",               /* pl40 */
    "其他禁止标志",         /* po  */
    "限速50",               /* pl50 */
    "其他指示标志",         /* io  */
    "限速80",               /* pl80 */
    "限速60",               /* pl60 */
    "禁止载货汽车驶入",     /* p26 */
    "机动车行驶",           /* i4  */
    "限速100",              /* pl100 */
    "限速30",               /* pl30 */
    "解除限速60",           /* il60 */
    "非机动车行驶",         /* i2  */
    "限速5",                /* pl5 */
    "注意行人",             /* w57 */
    "禁止掉头",             /* p5  */
    "禁止机动车驶入",       /* p10 */
};

const char *npu_class_cn(int idx)
{
    if (idx < 0 || idx >= NPU_NUM_CLASSES) {
        return "?";
    }
    return npu_class_names_cn[idx];
}

/* exp(x) in Q16 for x <= 0, with x in Q10 natural-log units.
 * Uses exp(x) = 2^(x*log2(e)) and a cubic for the fractional part.
 * Range is clamped to x >= -16, which is far below any useful class. */
static uint32_t exp_q16(int32_t x_q10)
{
    if (x_q10 < -16384) {
        return 1;
    }
    int32_t t = (x_q10 * 1477) >> 10;      /* Q10 * log2(e) */
    int32_t k = t >> 10;                   /* integer part, <= 0 */
    uint32_t f = (uint32_t)(t - (k << 10));/* fractional part, 0..1023 */
    uint32_t f2 = (f * f) >> 10;
    uint32_t f3 = (f2 * f) >> 10;
    uint32_t base = 65536u
                  + ((45426u * f) >> 10)
                  + ((15744u * f2) >> 10)
                  + ((3637u * f3) >> 10);
    if (k <= -16) {
        return 1;
    }
    return base >> (-k);
}

/* The integer FC scores are about 44x the natural-logit units used by
 * the training model (64 * final_scale * fc_scale).  Dividing by 44
 * therefore reproduces the float softmax closely enough for display. */
#define SCORE_Q10_DIV 44

void npu_softmax_pct(const int32_t *scores, uint16_t *out)
{
    int32_t mx = scores[0];
    for (int i = 1; i < NPU_NUM_CLASSES; i++) {
        if (scores[i] > mx) {
            mx = scores[i];
        }
    }

    uint32_t e[NPU_NUM_CLASSES];
    uint32_t sum = 0;
    for (int i = 0; i < NPU_NUM_CLASSES; i++) {
        int32_t d = scores[i] - mx;
        int32_t x = d / SCORE_Q10_DIV;
        if (x < -16384) {
            x = -16384;
        }
        e[i] = exp_q16(x);
        sum += e[i];
    }

    for (int i = 0; i < NPU_NUM_CLASSES; i++) {
        out[i] = (uint16_t)((e[i] * 10000u + sum / 2u) / sum);
    }
}