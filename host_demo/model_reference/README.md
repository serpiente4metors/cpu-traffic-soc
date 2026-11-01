# 模型资料备份

本目录只用于说明 `final soc` 中固化模型的来源，不参与现场串口演示。

- `best.pt`：训练后的 NpuNet checkpoint；
- `model.py`：NpuNet/ResNet8 网络定义；
- `npu_export.py`：BN 折叠、INT8 量化和 NPU 权重导出脚本；
- `npu_demo_image.h`：模型自带的 10 张已正确分类样例，其中前 6 类被提取为
  `../samples/demo_candidates/inputs/` 下的演示图片。

量化结果以 `../config/quant_report.json` 为准。最终 `final soc` 中的以下文件与本
备份对应：

- `sw/npu_demo/npu_layers.h`
- `sw/menu/npu_infer.c`
- `sw/npu/wgt_bank0.hex`
- `sw/npu/wgt_bank1.hex`
- `sw/npu/wgt_bank2.hex`
- `sw/npu/wgt_bank3.hex`

现场演示不需要安装 PyTorch，也不需要在 Python 中加载 `best.pt`。此目录中的
训练和导出脚本保留的是原始离线训练环境路径，仅用于资料溯源，不是最终演示入口。