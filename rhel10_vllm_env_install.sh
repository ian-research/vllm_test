#!/bin/bash
set -e  # 出错立即停止

echo ">>> [1/7] 正在配置 RHEL 10 EPEL 仓库..."
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

echo ">>> [2/7] 正在安装 Python 3.12, wget"
sudo dnf install -y wget python3.12-pip python3.12-devel

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

# 1. 添加 NVIDIA 官方容器工具仓库 (在线源)
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo

# 2. 设置并锁定版本
export NVIDIA_CONTAINER_TOOLKIT_VERSION="1.18.2-1"

# 3. 安装指定版本的工具及其依赖
# 我们明确指定版本号，dnf 会自动处理 libnvidia-container1 等依赖
sudo dnf install -y \
    nvidia-container-toolkit-${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
    nvidia-container-toolkit-base-${NVIDIA_CONTAINER_TOOLKIT_VERSION}

# 4. 生成 RHEL 10 推荐的 CDI 规范文件 (核心步骤)
# RHEL 10 的 Podman 深度集成 CDI，这一步确保容器能正确识别 L40S
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# 验证 CDI 是否成功生成设备条目
if sudo nvidia-ctk cdi list | grep -q "nvidia.com/gpu=all"; then
    echo "CDI 配置成功：已识别到 GPU 设备。"
else
    echo "警告：CDI 配置未发现设备，请重启后重新生成。"
fi

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
