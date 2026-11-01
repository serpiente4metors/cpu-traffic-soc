# final soc 主机端演示工具

本目录只包含主机侧图片预处理和串口发送工具，不替换 `final soc` 中已有的
RTL、固件、约束或比特流。模型推理发生在 FPGA 内，Python 不加载模型进行推理。

## 一键演示

1. 在线上 FPGA 平台加载：

   `../pg200h/generate_bitstream/top_fpga.sbit`

2. 打开串口终端，参数为 `115200 8N1`。
3. 在串口终端输入 `start` 并回车。
4. 输入 `2` 并回车，等待出现 `READY`。
5. 双击本目录的 `START_HERE.bat`。
6. 在 Windows 文件选择窗口中选择：

   `samples\demo_candidates\inputs\04_pl40_32x32.png`

7. Python 自动生成 6205 字节串口帧和 50 个粘贴分段。
8. 回到控制台按一次 Enter。
9. 在 5 秒内点击网页串口输入框，等待结果。

成功结果类似：

```text
该张照片被识别为：限速40 (pl40) 95.95%
DONE
```

## 命令行备用方式

生成串口帧：

```powershell
.\run_python.bat .\scripts\make_frame.py `
  .\samples\demo_candidates\inputs\04_pl40_32x32.png `
  --report .\config\quant_report.json `
  --out .\output\frame.txt
```

自动粘贴：

```powershell
.\run_python.bat .\scripts\auto_paste.py `
  --dir .\output\frame_lines --start-delay 5
```

只检查发送文件顺序，不实际按键：

```powershell
.\run_python.bat .\scripts\auto_paste.py `
  --dir .\output\frame_lines --dry-run
```

## 目录说明

```text
START_HERE.bat          一键入口：选择图片、生成帧、启动自动粘贴
make_frame.bat          备用入口：拖入图片，只生成串口帧
auto_paste.bat          备用入口：自动粘贴已经生成的 frame_lines
run_python.bat          自动寻找本机可用的 Python
console_demo.py         原生文件选择窗口和演示流程控制
requirements.txt        普通 Python 环境需要的 Pillow 依赖

scripts/
  make_frame.py         图片转换为 6205 字节 UART ASCII 帧
  auto_paste.py         依次发送 00_img.txt 到 49_crc.txt
  extract_demo_candidates.py 从模型自带样例重新提取推荐图片

config/
  quant_report.json     与 final soc 模型匹配的量化参数

samples/
  demo_candidates/
    inputs/             6 张推荐的 32x32 INT8 兼容图片
    previews/           放大预览图，仅用于展示
    contact_sheet.png   六张图片总览
    expected_labels.csv 文件名、类别、中文名和 CRC 对照
    README.md           演示图片选择说明

model_reference/
  best.pt               训练后的 NpuNet checkpoint
  model.py              NpuNet/ResNet8 网络定义
  npu_export.py         BN 折叠、INT8 量化与权重导出脚本
  npu_demo_image.h      6 张推荐图片的模型样例源头
  README.md             模型资料说明

output/
  README.txt            运行时输出目录说明
```

运行时会在 `output` 下生成 `frame.txt`、`frame_chunks` 和 `frame_lines`。
`output` 中不预放旧识别结果，避免把历史测试数据误当成当前图片结果。

## 预处理约定

```text
RGB
-> bilinear resize to 32x32
-> (pixel / 255 - 0.5) / 0.5
-> divide by input_scale
-> round and clamp to [-127, 127]
-> INT8 HWC, 3072 bytes
```

`config/quant_report.json` 中的输入尺度为：

```text
input_scale = 0.007874015748031496
```

`final soc` 中的 `npu_layers.h`、`npu_infer.c` 和四个权重 Bank 已与
`model_reference` 中的模型资料核对，内容一致。

## 当前机器说明

`run_python.bat` 会按以下顺序寻找解释器：

1. `host_demo\.venv\Scripts\python.exe`
2. 本机 Codex Python 运行时
3. 经过实际运行检测的 `py -3`
4. 经过实际运行检测的 `python`

Microsoft Store 的 `python` 快捷方式不会被当作有效解释器执行。
如需改用普通 Python，请安装 Pillow：

```powershell
python -m pip install -r requirements.txt
```

## 注意事项

- 输入必须是裁剪好的单个交通标志，不是整张街景。
- 最终 `final soc` 是 20 类分类模型，不输出检测框。
- Python 只负责生成图像帧和发送数据，模型推理在 FPGA 内完成。
- `model_reference` 只用于溯源，现场演示不需要 PyTorch。
- 自动粘贴需要浏览器拥有焦点；倒计时内必须点击串口输入框。