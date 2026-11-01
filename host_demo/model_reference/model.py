"""Traffic-sign classifiers.

- ResNet8: the 98.36% reference model (residual blocks, 64 channels).
- NpuNet:  deployment-friendly model for maxcpu S4: no residuals, at most 32
  channels, only 3x3 conv + BN + ReLU + GAP + FC.  Every conv layer maps 1:1
  to one NPU `START`, and the CPU only runs GAP/FC.
"""
import torch
from torch import nn
from torch.nn import functional as F


class ResNetBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int = 1):
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 3, padding=1, bias=True, stride=stride),
            nn.BatchNorm2d(out_channels),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=True),
            nn.BatchNorm2d(out_channels),
        )
        if in_channels == out_channels:
            self.residual = nn.Identity()
        else:
            self.residual = nn.Conv2d(in_channels, out_channels, 1, stride=stride)

    def forward(self, x):
        return F.relu(self.block(x) + self.residual(x))


class ResNet8(nn.Module):
    def __init__(self, num_classes: int = 20, dropout: float = 0.1):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, padding=1, bias=True),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),
        )
        self.first_stack = ResNetBlock(16, 16, stride=1)
        self.second_stack = ResNetBlock(16, 32, stride=2)
        self.third_stack = ResNetBlock(32, 64, stride=2)
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.dropout = nn.Dropout(dropout) if dropout > 0 else nn.Identity()
        self.fc = nn.Linear(64, num_classes)

    def forward(self, x):
        x = self.stem(x)
        x = self.first_stack(x)
        x = self.second_stack(x)
        x = self.third_stack(x)
        x = self.avgpool(x)
        x = torch.flatten(x, 1)
        x = self.dropout(x)
        return self.fc(x)


class NpuNet(nn.Module):
    """No-residual, <=32-channel CNN for the S4 NPU.

    Layer map (one NPU layer each):
        0: 3  -> 16, 3x3, stride 1, pad 1   32x32
        1: 16 -> 16, 3x3, stride 1, pad 1   32x32
        2: 16 -> 32, 3x3, stride 2, pad 1   16x16
        3: 32 -> 32, 3x3, stride 1, pad 1   16x16
        4: 32 -> 32, 3x3, stride 2, pad 1    8x8
        GAP -> FC 32 -> num_classes (CPU)

    `bias=False` on conv because the following BatchNorm has beta; BN folding
    still produces the per-output-channel bias the NPU needs.
    """

    def __init__(self, num_classes: int = 20, dropout: float = 0.1):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 16, 3, padding=1, bias=False),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),

            nn.Conv2d(16, 16, 3, padding=1, bias=False),
            nn.BatchNorm2d(16),
            nn.ReLU(inplace=True),

            nn.Conv2d(16, 32, 3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),

            nn.Conv2d(32, 32, 3, padding=1, bias=False),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),

            nn.Conv2d(32, 32, 3, stride=2, padding=1, bias=False),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
        )
        self.avgpool = nn.AdaptiveAvgPool2d((1, 1))
        self.dropout = nn.Dropout(dropout) if dropout > 0 else nn.Identity()
        self.fc = nn.Linear(32, num_classes)

    def forward(self, x):
        x = self.features(x)
        x = self.avgpool(x)
        x = torch.flatten(x, 1)
        x = self.dropout(x)
        return self.fc(x)


def build_model(arch: str, num_classes: int = 20, dropout: float = 0.1) -> nn.Module:
    arch = (arch or "resnet8").lower()
    if arch == "resnet8":
        return ResNet8(num_classes=num_classes, dropout=dropout)
    if arch == "npu":
        return NpuNet(num_classes=num_classes, dropout=dropout)
    raise ValueError(f"unknown arch: {arch}")