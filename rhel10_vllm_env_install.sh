#!/bin/bash
set -e  # 出错立即停止

echo ">>> [1/7] 正在配置 RHEL 10 EPEL 仓库..."
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

echo ">>> [2/7] 正在安装 Python 3.12, wget 及 sox..."
sudo dnf install -y wget python3.12-pip python3.12-devel sox

echo ">>> [3/7] 正在配置 NVIDIA CUDA 13.1 本地仓库 (RHEL 10)..."
cd /tmp
wget -N https://developer.download.nvidia.com/compute/cuda/13.1.1/local_installers/cuda-repo-rhel10-13-1-local-13.1.1_590.48.01-1.x86_64.rpm
sudo rpm -i cuda-repo-rhel10-13-1-local-13.1.1_590.48.01-1.x86_64.rpm
sudo dnf clean all

echo ">>> [4/7] 正在安装编译环境及 CUDA Toolkit..."
# RHEL 10 必须有这些才能构建驱动内核模块
sudo dnf install -y kernel-devel-matched gcc make
sudo dnf -y install cuda-toolkit-13-1

echo ">>> [5/7] 正在安装 NVIDIA 驱动 (cuda-drivers)..."
sudo dnf -y install cuda-drivers

echo ">>> [6/7] 正在配置容器环境 (NVIDIA Container Toolkit)..."
sudo dnf install -y nvidia-container-toolkit
# 生成 RHEL 10 推荐的 CDI 规范文件
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

echo ">>> [7/7] 正在完成收尾工作..."
# 针对 L40S 建议禁用 GSP 固件以提高 RHEL 10 上的稳定性 (可选，已包含)
echo "options nvidia NVreg_EnableGpuFirmware=0" | sudo tee /etc/modprobe.d/nvidia.conf
sudo dracut -f

echo "----------------------------------------------------"
echo ">>> 安装成功！系统将在 5 秒后重启。"
echo ">>> 重启后请执行 'nvidia-smi' 和 'nvidia-ctk cdi list' 验证。"
echo "----------------------------------------------------"

sleep 5
sudo reboot
