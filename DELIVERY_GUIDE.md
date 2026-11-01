# final soc 最终交付说明

本文件用于说明最终交付目录的用途、演示入口和文件分工。核心 RTL、固件、约束、
PDS 工程和比特流保持原样；后来新增的主机端演示工具集中在 `host_demo/`。

## 最终演示入口

1. 在 FPGA 平台加载 `pg200h/generate_bitstream/top_fpga.sbit`。
2. 打开 115200 8N1 串口终端。
3. 依次输入 `start` 和 `2`，等待 `READY`。
4. 双击 `host_demo/START_HERE.bat`。
5. 选择 `host_demo/samples/demo_candidates/inputs/04_pl40_32x32.png`。
6. 控制台按 Enter，并在 5 秒内点击网页串口输入框。

## 顶层目录

```text
final soc/
  pg200h/         PDS 工程、PLL IP 和最终比特流
  constraints/    CPU 时钟、复位和引脚约束
  rtl/            CPU、UART、NPU、Cache 和 SoC RTL
  sw/             固件源码、CoreMark、NPU 层表和权重 Bank
  scripts/        固件构建与 PDS 构建脚本
  host_demo/      主机端演示工具、量化配置和推荐图片
  README.md       原有最终工程说明
  DELIVERY_GUIDE.md  本文件
```

## 核心交付文件

| 文件或目录 | 用途 |
|---|---|
| `pg200h/generate_bitstream/top_fpga.sbit` | 最终 FPGA 比特流，现场演示使用 |
| `pg200h/generate_bitstream/top_fpga.smsk` | Pango 比特流配套文件，与 sbit 保留在同一目录 |
| `pg200h/pg200h.pds` | Pango PDS 工程文件 |
| `pg200h/ipcore/pll_94/` | 94.5 MHz PLL IP 和模板文件 |
| `constraints/cpu_pll_94m5.fdc` | 27 MHz 输入时钟、94.5 MHz PLL 输出及板级管脚约束 |
| `rtl/` | 最终综合使用的 21 个 Verilog RTL 文件 |
| `rtl/fpga/top_fpga.v` | FPGA 顶层，连接 CPU、UART、LED 和板级端口 |
| `rtl/soc/top.v` | SoC 顶层，连接 CPU、存储、MMIO、UART 和 NPU |
| `rtl/npu/` | MAC 阵列、卷积控制、地址生成、重量化、权重 Bank 和微码 ROM |
| `sw/program.mem` | 最终 BRAM 固件镜像，必须与当前比特流配套 |
| `sw/menu/menu.c` | 串口菜单、UART 图像帧解析、CRC 检查和结果输出 |
| `sw/menu/npu_infer.c` | NPU 层驱动、GAP、全连接和 softmax 显示 |
| `sw/npu_demo/npu_layers.h` | 5 层网络描述符、量化参数、FC 权重和 20 类类别表 |
| `sw/npu/wgt_bank0.hex` 至 `wgt_bank3.hex` | 4 个 INT8 卷积权重 Bank，综合时写入 BRAM 初值 |
| `sw/coremark/` | CoreMark 测试源码 |
| `scripts/build_menu.py` | 编译 CoreMark、菜单和 NPU 驱动并生成固件镜像 |
| `scripts/pds_run.bat` | PDS 综合、布局布线和比特流构建脚本 |

## host_demo 文件逐个说明

### 一键演示入口

| 文件 | 用途 |
|---|---|
| `host_demo/START_HERE.bat` | 推荐入口；调用 Python 打开 Windows 文件选择窗口并执行完整演示流程 |
| `host_demo/console_demo.py` | 选择图片、生成 6205 字节串口帧、显示路径和 CRC、启动自动粘贴 |
| `host_demo/run_python.bat` | 查找本机可用 Python，跳过 Microsoft Store 假快捷方式 |
| `host_demo/requirements.txt` | 使用普通 Python 时需要安装 Pillow 的依赖清单 |
| `host_demo/README.md` | 主机端演示工具的完整使用说明和故障提示 |

### 备用入口

| 文件 | 用途 |
|---|---|
| `host_demo/make_frame.bat` | 把图片拖到该文件上，只生成 `output/frame.txt` 和分段文件 |
| `host_demo/auto_paste.bat` | 对已生成的 `output/frame_lines` 执行自动粘贴 |

### Python 脚本

| 文件 | 用途 |
|---|---|
| `host_demo/scripts/make_frame.py` | 执行 RGB 缩放、INT8 量化、HWC 排布、十六进制编码和 CRC 计算 |
| `host_demo/scripts/auto_paste.py` | 通过剪贴板和键盘事件依次粘贴 50 个分段，不直接占用 COM 口 |
| `host_demo/scripts/extract_demo_candidates.py` | 从 `npu_demo_image.h` 提取 6 张推荐图片，并校验 INT8 字节完全一致 |

### 配置

| 文件 | 用途 |
|---|---|
| `host_demo/config/quant_report.json` | 当前模型输入尺度、层量化参数和 INT8 精度报告 |

### 推荐演示图片

| 文件或目录 | 用途 |
|---|---|
| `host_demo/samples/demo_candidates/inputs/01_pn_32x32.png` | 禁止停车 |
| `host_demo/samples/demo_candidates/inputs/02_pne_32x32.png` | 禁止驶入 |
| `host_demo/samples/demo_candidates/inputs/03_i5_32x32.png` | 靠右侧道路行驶 |
| `host_demo/samples/demo_candidates/inputs/04_pl40_32x32.png` | 限速40，现场首选 |
| `host_demo/samples/demo_candidates/inputs/05_pl50_32x32.png` | 限速50 |
| `host_demo/samples/demo_candidates/inputs/06_pl80_32x32.png` | 限速80 |
| `host_demo/samples/demo_candidates/previews/` | 上述图片的放大预览，仅用于展示 |
| `host_demo/samples/demo_candidates/contact_sheet.png` | 6 张图片总览 |
| `host_demo/samples/demo_candidates/expected_labels.csv` | 文件名、类别 ID、中文名和帧 CRC 对照 |
| `host_demo/samples/demo_candidates/README.md` | 推荐顺序和图片兼容性说明 |

### 模型资料备份

| 文件 | 用途 |
|---|---|
| `host_demo/model_reference/best.pt` | 训练后的 NpuNet checkpoint，仅用于溯源 |
| `host_demo/model_reference/model.py` | NpuNet 和 ResNet8 网络定义 |
| `host_demo/model_reference/npu_export.py` | 原始 BN 折叠、INT8 量化和权重导出脚本，不用于现场演示 |
| `host_demo/model_reference/npu_demo_image.h` | 模型自带的 10 张正确分类样例，是推荐演示图片的源头 |
| `host_demo/model_reference/README.md` | 模型资料用途和边界说明 |

### 运行时输出

| 路径 | 用途 |
|---|---|
| `host_demo/output/README.txt` | 输出目录说明 |
| `host_demo/output/frame.txt` | 运行 `START_HERE.bat` 或 `make_frame.bat` 后生成，6205 字节完整串口帧 |
| `host_demo/output/frame_chunks/` | 运行时生成，每 8 行数据一个分段 |
| `host_demo/output/frame_lines/` | 运行时生成，一行一个文件，供自动粘贴使用 |

交付版本不预放旧的 `frame.txt`、`frame_chunks` 或 `frame_lines`，这样接收者能确认
识别结果对应的确实是本次选择的图片。

## 数据流

```text
选中图片
-> Python 双线性缩放到 32x32
-> 归一化并量化为 INT8 HWC
-> 3072 字节图像数据
-> 48 行十六进制文本和 CRC
-> 6205 字节 ASCII 串口帧
-> FPGA 固件解析并检查 CRC
-> NPU 执行 5 层卷积
-> CPU 执行 GAP、32 到 20 全连接和类别输出
-> 串口返回中文类别、置信度和 DONE
```

## 交付检查

- `pg200h/generate_bitstream` 中只保留最终 sbit 和配套 smsk。
- `sw/program.mem` 必须与最终 bitstream 配套，不要使用旧 soc 目录中的 109116 字节版本。
- `host_demo/output` 中不应保留旧测试结果。
- `host_demo` 中不应存在 `__pycache__` 或 `.pyc`。
- 交付前重新运行一次 `START_HERE.bat`，确认可以完成图片选择、帧生成和自动粘贴。
- `model_reference` 只用于资料溯源，现场演示只需要 Pillow，不需要 PyTorch。