#ifndef NPU_INFER_H
#define NPU_INFER_H

#include <stdint.h>

/* Input: 32x32x3 int8, HWC, already quantized with the training scale.
 *
 * scores[] must have NPU_NUM_CLASSES entries.  It receives the raw
 * integer FC logits, which are also used for the softmax display. */
int npu_infer(const uint8_t *img, uint32_t *total_cycles, int32_t *scores);

/* Return the class name for a valid class id; "?" otherwise. */
const char *npu_class_name(int idx);

/* Human-readable Chinese name for a class id. */
const char *npu_class_cn(int idx);

/* Convert raw FC logits to per-class percentages (basis points, 0..10000).
 * out[] must have NPU_NUM_CLASSES entries. */
void npu_softmax_pct(const int32_t *scores, uint16_t *out);

#endif