# 推荐演示图片

这些图片不是随机网上图片，而是从当前模型自带的 `npu_demo_image.h` 中提取的
**已正确分类测试样本**。已经验证：重新经过 `make_frame.py` 预处理后，得到的
3072 个 INT8 字节与原始模型输入逐字节一致。

## 推荐使用顺序

| 顺序 | 文件 | 类别 ID | 类别 | 完整帧 CRC |
|---:|---|---:|---|---|
| 1 | `inputs/04_pl40_32x32.png` | 4 | 限速40 | `5a55` |
| 2 | `inputs/05_pl50_32x32.png` | 6 | 限速50 | `8dea` |
| 3 | `inputs/06_pl80_32x32.png` | 8 | 限速80 | `abe2` |
| 4 | `inputs/01_pn_32x32.png` | 0 | 禁止停车 | `c213` |
| 5 | `inputs/02_pne_32x32.png` | 1 | 禁止驶入 | `9a7b` |
| 6 | `inputs/03_i5_32x32.png` | 2 | 靠右侧道路行驶 | `c724` |

限速类图案最直观，建议现场先用 `pl40`，成功后再展示 `pn` 和 `pne`。

## 文件说明

- `inputs/*_32x32.png`：实际用于上传给 Python 的图片；
- `previews/*_preview.png`：放大预览，仅用于展示；
- `contact_sheet.png`：六张图片总览；
- `expected_labels.csv`：文件名、类别 ID、中文名和 CRC。

不要在演示时用 `previews/` 中的放大图替代 `inputs/`，虽然通常也能识别，但
`inputs/` 已确认与模型原始输入完全一致。

## 重新生成

```powershell
# 先进入 host_demo 目录
.\run_python.bat .\scripts\extract_demo_candidates.py
```