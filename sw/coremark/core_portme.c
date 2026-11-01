/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
/* Porting : Timing functions
        How to capture time and convert to seconds must be ported to whatever is
   supported by the platform. e.g. Read value from on board RTC, read value from
   cpu clock cycles performance counter etc. Sample implementation for standard
   time.h and windows.h definitions included.
*/
CORETIMETYPE
barebones_clock(void)
{
    /* 读 mcycle（CSR 0xB00）：CPU 周期计数器，csr.v 里每拍 +1。
       CoreMark 用它量总周期数。 */
    ee_u32 cyc;
    __asm__ volatile("csrr %0, mcycle" : "=r"(cyc));
    return cyc;
}
/* Define : TIMER_RES_DIVIDER
        Divider to trade off timer resolution and total time that can be
   measured.

        Use lower values to increase resolution, but make sure that overflow
   does not occur. If there are issues with the return value overflowing,
   increase this value.
        */
/* CPU clock：必须填【这块镜像实际跑的主频】，否则打印出来的分数是错的。
     · 仿真 / 81 MHz 目标：-DCLOCKS_PER_SEC=81000000
     · 板子：-DCLOCKS_PER_SEC=94500000（pll_945m，27 × 7/2 = 94.5 MHz）
     · 27 MHz 晶振直通（USE_PLL=0）：-DCLOCKS_PER_SEC=27000000
   ⚠ 换 PLL 频率时这里必须跟着改，否则板上打出来的分数仍是旧频率的。
   mcycle 数的是周期数，与频率无关，所以同一份程序在不同频率下
   "每轮周期数"一样，分数按主频等比放大。
   与频率无关的那个指标请看 core_main.c 里另打的 CoreMark/MHz 那一行。 */
#ifndef CLOCKS_PER_SEC
#define CLOCKS_PER_SEC             94500000
#endif
#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
/* 加了 #ifndef 之后可以用 -DTIMER_RES_DIVIDER=... 覆盖。
   正常综合/上板都用 1（计时器就是 CPU 周期计数器，1 拍 = 1 tick）。
   仿真里用它把"至少跑 10 秒"那道检查放过去 —— 否则 2 轮迭代只有 0.01 秒，
   CoreMark 会判定结果无效、跳过 "Correct operation validated" 那一段
   （我们新增的分数行也在那一段里，就验证不到了）。 */
#ifndef TIMER_RES_DIVIDER
#define TIMER_RES_DIVIDER          1
#endif
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC           (CLOCKS_PER_SEC / TIMER_RES_DIVIDER)

/** Define Host specific (POSIX), or target specific global time variables. */
static CORETIMETYPE start_time_val, stop_time_val;

/* Function : start_time
        This function will be called right before starting the timed portion of
   the benchmark.

        Implementation may be capturing a system timer (as implemented in the
   example code) or zeroing some system parameters - e.g. setting the cpu clocks
   cycles to 0.
*/
void
start_time(void)
{
    GETMYTIME(&start_time_val);
}
/* Function : stop_time
        This function will be called right after ending the timed portion of the
   benchmark.

        Implementation may be capturing a system timer (as implemented in the
   example code) or other system parameters - e.g. reading the current value of
   cpu cycles counter.
*/
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
}
/* Function : get_time
        Return an abstract "ticks" number that signifies time on the system.

        Actual value returned may be cpu cycles, milliseconds or any other
   value, as long as it can be converted to seconds by <time_in_secs>. This
   methodology is taken to accommodate any hardware or simulated platform. The
   sample implementation returns millisecs by default, and the resolution is
   controlled by <TIMER_RES_DIVIDER>
*/
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
/* Function : time_in_secs
        Convert the value returned by get_time to seconds.

        The <secs_ret> type is used to accommodate systems with no support for
   floating point. Default implementation implemented by the EE_TICKS_PER_SEC
   macro above.
*/
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

/* Function : coremark_score_x100
        算出 CoreMark 分数 ×100（带两位小数的定点值），例如 198.59 返回 19859。

        【为什么需要它】
          CoreMark 官方那行 `CoreMark 1.0 : <分数>` 在 core_main.c 里被包在
          #if HAS_FLOAT 里面，而本移植 HAS_FLOAT=0，所以那一行【永远不会打印】
          （串口输出到 "Correct operation validated." 就结束了）。
          比赛报告要用分数，只能自己算。这个函数就是给 core_main.c 用的。

        【为什么不能直接用 time_in_secs() 的结果去除】
          它做的是整数秒截断：例如 407868959 周期 ÷ 27000000 = 15.1 秒
          → 截断成 15 秒，于是 3000 ÷ 15 = 200，比真实值 【虚高】。
          正确公式：  分数 = iterations × CLOCKS_PER_SEC ÷ total_ticks

        【为什么放在 .c 而不是 core_main.c】
          CLOCKS_PER_SEC 只定义在本文件里，头文件看不到它。

        【溢出保护 —— 故意不用 64 位】
          分子分母先同除 1000（量纲不变，精度足够）：
            num = iterations × (27000000/1000) = 3000 × 27000 = 8.1e7
            den = total_ticks / 1000
          num 远小于 2^32（上限 4.29e9，要溢出需要 iterations > 158000，
          而自动标定把轮数限制在 10~100 秒内，很安全）；
          中间量 (num % den) × 100 也只有 1e8 量级。
          这样就避免了 64 位除法 —— 本工程用 -nostdlib 编译，
          链接 __udivdi3 有风险。

        【参考值（同一份 mcycle 计数，两种频率下的分数关系）】
          本设计在仿真里实测 3000 轮 ≈ 1019672397 周期（67.5 MHz 下的记录）。
          换到 27 MHz 后，同样的周期数对应约 37.8 秒，分数约为
              3000 ÷ 1019672397 × 27000000 ≈ 79.4 分
          ⚠ 这只是"同一周期数在两种频率下的换算"，不是上板实测值。
            真实分数必须在板上跑出来，并且 __must__ 与 CLOCKS_PER_SEC 一致。

        【为什么用 CLOCKS_PER_SEC 而不是 EE_TICKS_PER_SEC】
          本平台计时器就是 CPU 周期计数器（barebones_clock 读 mcycle），
          TIMER_RES_DIVIDER=1，两者相等。
          用 CLOCKS_PER_SEC 语义更明确：它就是 CPU 主频。
*/
ee_u32
coremark_score_x100(CORE_TICKS total_time, ee_u32 iterations)
{
    ee_u32 num, den, whole, frac;

    if (total_time == 0)
        return 0;

    num = iterations * (ee_u32)(CLOCKS_PER_SEC / 1000);
    den = (ee_u32)(total_time / 1000);
    if (den == 0)
        den = 1;                    /* total_time 不足 1000 周期时的兜底 */

    whole = num / den;
    frac  = ((num % den) * 100u) / den;
    return whole * 100u + frac;
}

ee_u32 default_num_contexts = 1;

/* Function : portable_init
        Target specific initialization code
        Test for some common mistakes.
*/
void
portable_init(core_portable *p, int *argc, char *argv[])
{
    /* 本平台 UART（uart_tx.v）无需初始化，写数据寄存器即发送；
       这里只保留 CoreMark 自带的数据类型自检。 */
    (void)argc; // prevent unused warning
    (void)argv; // prevent unused warning

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf(
            "ERROR! Please define ee_ptr_int to a type that holds a "
            "pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}
/* Function : portable_fini
        Target specific final code
*/
void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
