#!/bin/bash
set -e

echo "=== 1. 清理历史残留状态 ==="
kubeadm reset -f 2>/dev/null || true
rm -rf $HOME/.kube /etc/cni/net.d /etc/kubernetes/admin.conf

echo "=== 2. 禁用 Swap、Firewalld 与调整 SELinux ==="
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
systemctl stop firewalld && systemctl disable firewalld || true
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo "=== 3. 配置内核模块与网络参数 ==="
cat <<CONFIG | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
CONFIG

modprobe overlay
modprobe br_netfilter

cat <<CONFIG | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
CONFIG

sysctl --system

echo "=== 4. 安装基础网络依赖与 containerd 运行时 ==="
# 补充 conntrack-tools, socat 等 kubeadm 必须的网络组件
dnf install -y dnf-plugins-core iproute-tc conntrack-tools socat iptables
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y containerd.io

# 配置 containerd 使用 systemd cgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "=== 5. 添加 Kubernetes YUM 源并安装组件 ==="
K8S_VERSION="v1.31"
cat <<CONFIG | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
CONFIG

dnf install -y kubelet kubeadm kubectl
systemctl enable --now kubelet

echo "=== 6. 初始化单节点 K8s 集群 ==="
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket=unix:///run/containerd/containerd.sock

echo "=== 7. 配置 kubectl 访问权限 ==="
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "=== 8. 安装 Flannel 网络插件 ==="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "=== 9. 解除主节点污点 (允许单节点部署 Pod) ==="
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "=========================================="
echo " K8s 单节点集群安装完成！"
echo " 运行命令检查状态: kubectl get nodes"
echo "=========================================="
