# 芯视交通 · maxcpu

面向边缘的交通标志识别 SoC —— **RV32IM 双发射 RISC-V 处理器 + INT8 卷积加速器**，
在紫光同创 Logos2（PG2L200H-6FBB676）上单芯片完成 CoreMark 基准与 20 类交通标志识别。

> 全国大学生嵌入式芯片与系统设计竞赛 2026 · 紫光同创赛道参赛作品

---

## 主要指标

| 项目 | 指标 |
|---|---|
| 器件 | Pango Logos2 **PG2L200H-6FBB676** |
| 系统主频 | **94.5 MHz**（27 MHz 晶振 × 3.5） |
| 时序 | WNS **+0.548 ns**，TNS 0，失败端点 0 / 35,141，All Constraints Met |
| 估算最高频率 | 99.66 MHz |
| CoreMark | **393.94** @ 94.5 MHz（约 **4.17 CoreMark/MHz**） |
| 资源占用 | LUT 14,315（12%）· FF 6,845（3%）· DRM 153（37%）· APM 108（15%） |
| 识别任务 | 20 类（禁令 / 指示 / 警告），输入 32×32×3 INT8 |
| 模型规模 | 26,564 参数，约 693 万次乘加 |
| 片上通信 | UART 115200 8N1，3072 B 图像 / 帧 |

---

## 系统架构

```
top_fpga                        板级顶层：PLL、上电复位、端口引出
├─ pll_94_5                     27 MHz → 94.5 MHz
└─ top                          处理器子系统
   ├─ icache                     8 KB 两路组相联指令 Cache
   ├─ bpu                        BTB(128) + BHT(256×2bit) + RAS(16)
   ├─ regfile                    32×32 寄存器堆，4 读 2 写
   ├─ alu ×2                     主 ALU + 第二槽影子 ALU
   ├─ mul_unit / div_unit        乘法器 / 迭代除法器
   ├─ csr                        Zicsr、异常与中断
   ├─ dual_port_mem              256 KB 主存（A 口取指 / B 口数据）
   ├─ uart_tx / uart_rx          115200 8N1
   ├─ npu_regs                   加速器 MMIO 寄存器
   └─ npu_core                   INT8 卷积加速器
      ├─ ucode_rom               微码：层序与控制字
      ├─ npu_addrgen             特征图 / 权重地址生成
      ├─ wgt_bank ×4             四个权重 bank
      ├─ mac_array               32 路乘加阵列
      └─ requant                 重量化与激活
```

### 处理器

- **RV32IM + Zicsr**，7 级流水线 `IF1 → IF2 → ID → E1 → E2 → M → WB`
- **顺序双发射**：slot1 走影子通路，配对判据只比较原始指令位（无 RAW / 无 WAW）
- 译码在 ID→E1 边界一次性锁存，E1 级内没有译码逻辑
- ALU 用一条 33 位减法链同时产生减法、有符号比较与无符号比较
- 乘法拆成 4 个 17×17 部分积，E1 算部分积、E2 拼装，全片只占 4 个乘加单元
- 8 KB 两路组相联指令 Cache + 动态分支预测，控制冒险与数据冒险均由旁路解决

### 卷积加速器

- 微码驱动的 INT8 卷积：层序与地址在综合期固化，运行期没有动态调度开销
- 32 路 MAC 阵列一拍算 32 个输出通道；权重分 4 个 bank，由微码切换
- 重量化：`acc32 × M16 >>> s`，加偏置后 ReLU 与饱和到 INT8
- CPU 通过 MMIO 写层描述符并置启动位，加速期间独占主存 B 口，取指不受影响
- 网络结构：5 层 3×3 卷积 + GAP + FC 32→20

---

## 目录结构

```
rtl/                     综合用 RTL（21 个 .v）
  core/  exec/  cache/  bpu/  soc/  periph/  npu/  fpga/
constraints/             时序与引脚约束 cpu_pll_94m5.fdc
sw/                      裸机固件
  crt0.S  link_c.ld      启动代码与链接脚本
  program.mem            已打包的 BRAM 固件镜像
  coremark/              CoreMark 移植
  menu/                  菜单与 NPU 推理
  npu_demo/npu_layers.h  层参数表
  npu/wgt_bank0..3.hex   量化后的权重
scripts/
  build_menu.py          生成菜单固件
  pds_run.bat            PDS 综合 / 布局布线 / 生成比特流
host_demo/               PC 端工具：选图、量化、打包 UART 帧并发送
pg200h/                  PDS 工程（PLL IP + 工程文件 + 比特流）
```

---

## 快速开始

**1. 烧录**：从 [Releases](../../releases) 下载 `top_fpga.sbit`，
通过紫光同创 PDS / 在线平台下载到 PG2L200H。

**2. 串口**：115200 8N1，接 RX/TX 后上电：

```
maxcpu boot fw=20261030-1050 cn+top1

输入 start 开始
> start

1) CoreMark
2) 图像识别
> 1
```

- 输入 `1`：跑标准 CoreMark 并输出完整报告
- 输入 `2`：等待 `READY` 后发送 6205 字节 ASCII 图像帧，返回类别与置信度

**3. 发送图片**：用 `host_demo/` 里的脚本把一张 32×32 图片量化、打包成帧并自动粘贴到串口终端。

---

## 从源码构建

**固件**（需要 RISC-V GCC）：

```bash
python scripts/build_menu.py --iters 4000 --out sw/program.mem
```

`program.mem` 会被 `dual_port_mem.v` 的 `$readmemh` 在综合期固化进 BRAM，
**改固件后必须重新综合并重新生成比特流**。

**硬件**（需要 Pango Design Suite 2022.2-SP6.4）：

```bash
scripts\pds_run.bat gen_bit_stream
```

> ⚠️ PDS 对工程路径有字符限制：路径里**不能出现圆括号**，
> 建议放在形如 `D:\work\maxcpu\` 的纯英文无括号目录下。

---

## 主机端工具 `host_demo`

- `run_python.bat` / `START_HERE.bat`：一键启动
- `console_demo.py`：选图 → 量化 → 生成帧 → 自动粘贴到串口终端
- `make_frame.py`：只生成帧文件
- `samples/`：示例图片与期望标签（含每张图的 CRC）

---

## 已知限制

- 比特流在 5 组种子中取最优结果，换器件或换版本后时序需重新收敛
- 加速器按固定层结构固化，换模型需重新生成 `npu_layers.h` 与权重文件
- 目前只支持单张 32×32 图片，未做整图检测与多目标跟踪

---

## 许可证

[MIT](LICENSE)

第三方组件的版权归各自作者所有：CoreMark（EEMBC）、Pango PLL IP（紫光同创）。
