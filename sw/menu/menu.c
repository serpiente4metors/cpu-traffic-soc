/* ============================================================
 * menu.c -- maxcpu serial menu
 *
 *   1) CoreMark
 *   2) Traffic sign image (ASCII hex frame over UART)
 *
 * UART: 115200 8N1, MMIO at 0x1000_0008 (TX) / 0x1000_000C (RX).
 *
 * Image frame (all ASCII):
 *
 *   IMG
 *   128 hex chars          (64 bytes, line 0)
 *   ...                    (48 lines total = 3072 bytes)
 *   128 hex chars          (64 bytes, line 47)
 *   CRC=ABCD               (16-bit sum of the 3072 bytes)
 *
 * The parser does not rely on line breaks: it skips spaces/tabs/CR/LF and
 * reads the fixed-size fields (3, then 48 x 128, then 8).  This is needed
 * because a web terminal may turn the newlines of a pasted frame into
 * spaces, which is exactly what the remote platform does.
 * ============================================================ */
#include <stdint.h>

#include "npu_layers.h"
#include "npu_infer.h"

#define MMIO_BASE       0x10000000u
#define UART_TX         0x08u
#define UART_RX         0x0Cu
#define RX_VALID_BIT    (1u << 8)
#define RX_TIMEOUT_CYC  1890000000u   /* 20 s at 94.5 MHz; fits uint32 */
#define START_PROMPT_CYC 661500000u   /* 7 s at 94.5 MHz: reprint start prompt */

#define IMG_BYTES       3072
#define IMG_LINES       48
#define IMG_LINE_BYTES  64
#define LINE_MAX        260

extern int coremark_main(void);

static uint8_t image[IMG_BYTES];
static char    line[LINE_MAX];

static inline void mmio_wr(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(MMIO_BASE + off) = v;
}

static inline uint32_t mmio_rd(uint32_t off)
{
    return *(volatile uint32_t *)(MMIO_BASE + off);
}

static void uart_putc(char c)
{
    while (mmio_rd(UART_TX) & 1u) {
        /* wait for uart_tx idle */
    }
    mmio_wr(UART_TX, (uint32_t)(uint8_t)c);
}

static void uart_puts(const char *s)
{
    while (*s) {
        uart_putc(*s++);
    }
}

static void uart_dec(uint32_t v)
{
    char buf[10];
    int n = 0;
    if (v == 0) {
        uart_putc('0');
        return;
    }
    while (v && n < (int)sizeof(buf)) {
        buf[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    while (n > 0) {
        uart_putc(buf[--n]);
    }
}

static inline uint32_t rd_cycle(void)
{
    uint32_t x;
    __asm__ volatile("csrr %0, mcycle" : "=r"(x));
    return x;
}

/* Blocking receive for the menu. */
static char uart_getc(void)
{
    for (;;) {
        uint32_t v = mmio_rd(UART_RX);
        if (v & RX_VALID_BIT) {
            return (char)(v & 0xFFu);
        }
    }
}

/* Non-blocking receive for the start prompt. */
static int uart_try_getc(char *out)
{
    uint32_t v = mmio_rd(UART_RX);
    if (v & RX_VALID_BIT) {
        *out = (char)(v & 0xFFu);
        return 0;
    }
    return -1;
}

/* Receive one byte with a timeout. Returns 0 on success, -1 on timeout. */
static int uart_getc_timeout(char *out)
{
    uint32_t start = rd_cycle();
    for (;;) {
        uint32_t v = mmio_rd(UART_RX);
        if (v & RX_VALID_BIT) {
            *out = (char)(v & 0xFFu);
            return 0;
        }
        if ((uint32_t)(rd_cycle() - start) > RX_TIMEOUT_CYC) {
            return -1;
        }
    }
}

/* Some web terminals wrap a paste in bracketed-paste markers:
 *
 *     ESC [ 2 0 0 ~   <pasted text>   ESC [ 2 0 1 ~
 *
 * The markers are not visible in the terminal's TX log, but the FPGA sees
 * them and would read ESC/[ as the first header characters.  Strip ANSI
 * CSI/OSC sequences while receiving the image frame.  Image data is ASCII
 * hex, so a real ESC byte never occurs inside a valid frame.
 */
static int ansi_state = 0;

static int uart_getc_filtered(char *out)
{
    for (;;) {
        char c;
        if (uart_getc_timeout(&c) != 0) {
            return -1;
        }
        switch (ansi_state) {
        case 0:
            if ((uint8_t)c == 0x1B) {
                ansi_state = 1;
            } else if ((uint8_t)c < 0x20 &&
                       c != '\t' && c != '\r' && c != '\n') {
                /* drop stray C0 controls (NUL, Ctrl-V, XON/XOFF, ...) */
            } else if ((uint8_t)c > 0x7E) {
                /* drop UTF-8 BOM / non-ASCII paste decoration */
            } else {
                *out = c;
                return 0;
            }
            break;
        case 1:                         /* after ESC */
            if (c == '[') {
                ansi_state = 2;
            } else if (c == ']') {
                ansi_state = 3;
            } else if ((uint8_t)c >= 0x20 && (uint8_t)c <= 0x2F) {
                ansi_state = 4;         /* charset designation, e.g. ESC ( B */
            } else {
                ansi_state = 0;         /* two-byte escape */
            }
            break;
        case 2:                         /* CSI: parameters until final */
            if ((uint8_t)c >= 0x40 && (uint8_t)c <= 0x7E) {
                ansi_state = 0;
            }
            break;
        case 3:                         /* OSC: until BEL or ESC \ */
            if ((uint8_t)c == 0x07) {
                ansi_state = 0;
            } else if ((uint8_t)c == 0x1B) {
                ansi_state = 5;
            }
            break;
        case 4:                         /* escape intermediate, then final */
            if ((uint8_t)c >= 0x30 && (uint8_t)c <= 0x7E) {
                ansi_state = 0;
            }
            break;
        default:                        /* OSC saw ESC: expect backslash */
            ansi_state = (c == '\\') ? 0 : 3;
            break;
        }
    }
}

static void uart_flush(void)
{
    while (mmio_rd(UART_RX) & RX_VALID_BIT) {
        (void)mmio_rd(UART_RX);
    }
}

/* Diagnostic: show the next 32 raw UART bytes, bypassing all filters.
 * Used to identify a terminal's invisible paste prefix. */
static void dump_uart(void)
{
    static const char hex[] = "0123456789abcdef";
    uart_puts("DUMP 32 bytes:\r\n");
    for (int i = 0; i < 32; i++) {
        char c;
        if (uart_getc_timeout(&c) != 0) {
            break;
        }
        uart_putc(hex[((uint8_t)c >> 4) & 0xFu]);
        uart_putc(hex[(uint8_t)c & 0xFu]);
        uart_putc(' ');
    }
    uart_puts("\r\n");
}

/* Read exactly `want` non-whitespace bytes.
 *
 * The web terminal on the remote platform may turn the newlines of a
 * pasted frame into spaces (or drop them), so the parser cannot rely on
 * line boundaries.  The protocol has fixed-size fields:
 *
 *     IMG                3 bytes
 *     48 x 128 hex       128 bytes each
 *     CRC=xxxx           8 bytes
 *
 * Spaces, tabs, CR and LF are all skipped as formatting.  This works
 * for both a normal line-oriented paste and a newline-collapsed paste.
 *
 * Returns 0 on success, -1 on overflow, -2 on timeout.
 */
static int read_exact(int want)
{
    int n = 0;
    for (;;) {
        char c;
        if (uart_getc_filtered(&c) != 0) {
            return -2;
        }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            continue;
        }
        if (n >= LINE_MAX - 1) {
            return -1;
        }
        line[n++] = c;
        if (n == want) {
            line[n] = '\0';
            return 0;
        }
    }
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a') + 10;
    if (c >= 'A' && c <= 'F') return (int)(c - 'A') + 10;
    return -1;
}

/* Parse exactly 64 bytes from one line. Returns 0 on success. */
static int parse_data_line(const uint8_t *src, int n, uint8_t *dst)
{
    int hi = -1;
    int bytes = 0;

    for (int i = 0; i < n; i++) {
        int v = hexval((char)src[i]);
        if (v < 0) {
            if (src[i] == ' ' || src[i] == '\t') {
                continue;
            }
            return -1;
        }
        if (hi < 0) {
            hi = v;
        } else {
            if (bytes >= IMG_LINE_BYTES) {
                return -1;
            }
            dst[bytes++] = (uint8_t)((hi << 4) | v);
            hi = -1;
        }
    }
    if (hi >= 0 || bytes != IMG_LINE_BYTES) {
        return -1;
    }
    return 0;
}

static int parse_crc_line(const uint8_t *src, int n, uint16_t *out)
{
    int i = 0;

    while (i < n && (src[i] == ' ' || src[i] == '\t')) i++;
    if (i + 4 > n) return -1;
    if (src[i] != 'C' || src[i + 1] != 'R' ||
        src[i + 2] != 'C' || src[i + 3] != '=') {
        return -1;
    }
    i += 4;
    while (i < n && (src[i] == ' ' || src[i] == '\t')) i++;

    int v0 = (i < n) ? hexval((char)src[i++]) : -1;
    int v1 = (i < n) ? hexval((char)src[i++]) : -1;
    int v2 = (i < n) ? hexval((char)src[i++]) : -1;
    int v3 = (i < n) ? hexval((char)src[i++]) : -1;
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) return -1;

    while (i < n) {
        if (src[i] != ' ' && src[i] != '\t') return -1;
        i++;
    }

    *out = (uint16_t)((v0 << 12) | (v1 << 8) | (v2 << 4) | v3);
    return 0;
}

static void uart_pct(uint16_t bp)
{
    uint32_t frac = (uint32_t)(bp % 100u);
    uart_dec((uint32_t)(bp / 100u));
    uart_putc('.');
    if (frac < 10u) {
        uart_putc('0');
    }
    uart_dec(frac);
    uart_putc('%');
}

static void print_result(const int32_t *scores, int pred)
{
    uint16_t pct[NPU_NUM_CLASSES];

    npu_softmax_pct(scores, pct);

    /* 只输出 top-1，避免 20 行概率在串口终端里互相覆盖。 */
    uart_puts("该张照片被识别为：");
    uart_puts(npu_class_cn(pred));
    uart_puts(" (");
    uart_puts(npu_class_name(pred));
    uart_puts(") ");
    uart_pct(pct[pred]);
    uart_puts("\r\n");
}

static int receive_image(void)
{
    int rc;
    uint16_t crc = 0;
    uint32_t sum = 0;

    ansi_state = 0;
    rc = read_exact(3);
    if (rc != 0) {
        uart_puts(rc == -2 ? "ERR TIMEOUT\r\n" : "ERR HEADER\r\n");
        return -1;
    }
    if (line[0] != 'I' || line[1] != 'M' || line[2] != 'G') {
        uart_puts("ERR HEADER\r\n");
        return -1;
    }

    for (int ln = 0; ln < IMG_LINES; ln++) {
        rc = read_exact(IMG_LINE_BYTES * 2);
        if (rc != 0) {
            uart_puts(rc == -2 ? "ERR TIMEOUT\r\n" : "ERR LINE\r\n");
            return -1;
        }
        if (parse_data_line((const uint8_t *)line,
                            IMG_LINE_BYTES * 2,
                            &image[ln * IMG_LINE_BYTES]) != 0) {
            uart_puts("ERR LINE\r\n");
            return -1;
        }
        if (((ln + 1) % 8) == 0) {
            uart_puts("OK ");
            uart_dec((uint32_t)(ln + 1));
            uart_puts("/48\r\n");
        }
    }

    rc = read_exact(8);
    if (rc != 0) {
        uart_puts(rc == -2 ? "ERR TIMEOUT\r\n" : "ERR CRC FORMAT\r\n");
        return -1;
    }
    if (parse_crc_line((const uint8_t *)line, 8, &crc) != 0) {
        uart_puts("ERR CRC FORMAT\r\n");
        return -1;
    }

    for (int i = 0; i < IMG_BYTES; i++) {
        sum += image[i];
    }
    if ((uint16_t)sum != crc) {
        uart_puts("ERR CRC\r\n");
        return -1;
    }

    uint32_t cycles = 0;
    int32_t scores[NPU_NUM_CLASSES];
    int pred = npu_infer(image, &cycles, scores);
    if (pred < 0) {
        uart_puts("ERR NPU\r\n");
        return -1;
    }

    print_result(scores, pred);
    uart_puts("DONE\r\n");
    return 0;
}

static void print_start(void)
{
    uart_puts("\r\n输入 start 开始\r\n> ");
}

static void wait_start(void)
{
    char w[5];
    int n = 0;
    uint32_t last_prompt = rd_cycle();

    for (;;) {
        char c;
        if (uart_try_getc(&c) != 0) {
            /* 还没输入 start 时，每 7 秒滚屏提示一次。 */
            if ((uint32_t)(rd_cycle() - last_prompt) > START_PROMPT_CYC) {
                print_start();
                last_prompt = rd_cycle();
            }
            continue;
        }

        last_prompt = rd_cycle();
        if (c == '\r' || c == '\n' || c == ' ' || c == '\t') {
            n = 0;
            continue;
        }
        if (c >= 'A' && c <= 'Z') {
            c = (char)(c + ('a' - 'A'));
        }
        if (n < 5) {
            w[n++] = c;
        }
        if (n == 5) {
            if (w[0] == 's' && w[1] == 't' && w[2] == 'a' &&
                w[3] == 'r' && w[4] == 't') {
                return;
            }
            n = 0;
            print_start();
            last_prompt = rd_cycle();
        }
    }
}

static void print_menu(void)
{
    uart_puts("\r\n1) CoreMark\r\n");
    uart_puts("2) 图像识别\r\n");
    uart_puts("> ");
}

int main(void)
{
    uart_puts("\r\nmaxcpu boot fw=20261030-1050 cn+top1\r\n");

    for (;;) {
        print_start();
        wait_start();
        print_menu();

        for (;;) {
            char c = uart_getc();
            if (c == '\r' || c == '\n' || c == ' ' || c == '\t') {
                continue;
            }

            uart_puts("\r\n");

            if (c == '1') {
                uart_puts("running CoreMark...\r\n");
                (void)coremark_main();
                uart_flush();
                print_menu();
            } else if (c == '2') {
                uart_puts("READY\r\n");
                (void)receive_image();
                uart_flush();
                print_menu();
            } else if (c == '3') {
                dump_uart();
                print_menu();
            } else {
                uart_puts("?\r\n");
                print_menu();
            }
        }
    }
}