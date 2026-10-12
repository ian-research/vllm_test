#!/usr/bin/env bash
set -e

echo "=================================================="
echo " 1. 宿主机内核与 Containerd GPU 运行时初始化"
echo "=================================================="
modprobe br_netfilter
echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

dnf install -y nvidia-container-toolkit git jq
nvidia-ctk runtime configure --runtime=containerd --nvidia-set-as-default
systemctl restart containerd
systemctl restart kubelet

echo "=================================================="
echo " 2. 部署 Flannel CNI 与 NVIDIA Device Plugin"
echo "=================================================="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl -n kube-flannel patch daemonset kube-flannel-ds --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--iface=enp135s0"}
]'

kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.16.2/deployments/static/nvidia-device-plugin.yml

echo "=================================================="
echo " 3. 安装 Gateway API 与 llm-d 控制面"
echo "=================================================="
if [ ! -d "llm-d" ]; then
  git clone https://github.com/llm-d/llm-d.git
fi
cd llm-d && git checkout main
export REPO_ROOT=$(pwd)
source ${REPO_ROOT}/guides/env.sh
export GUIDE_NAME="quickstart"
export NAMESPACE=llm-d-quickstart

kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
kubectl apply -k "github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=main"

helm install ${GUIDE_NAME} \
  ${ROUTER_STANDALONE_CHART} \
  -f guides/recipes/router/base.values.yaml \
  -f guides/optimized-baseline/router/optimized-baseline.values.yaml \
  -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION} || true

echo "=================================================="
echo " 4. 部署 vLLM 后端服务 (Qwen2.5-7B-Instruct)"
echo "=================================================="
cat << 'EOF' > vllm-backend.yaml
apiVersion: v1
kind: Service
metadata:
  name: quickstart
  namespace: llm-d-quickstart
spec:
  clusterIP: None
  selector:
    app: vllm-worker
  ports:
  - port: 8000
    targetPort: 8000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-model-server
  namespace: llm-d-quickstart
spec:
  replicas: 4
  selector:
    matchLabels:
      app: vllm-worker
  template:
    metadata:
      labels:
        app: vllm-worker
        llm-d.ai/guide: quickstart
    spec:
      containers:
      - name: server
        image: vllm/vllm-openai:v0.6.3
        args:
        - "--model"
        - "Qwen/Qwen2.5-7B-Instruct"
        - "--served-model-name"
        - "Qwen/Qwen2.5-7B-Instruct"
        - "--enable-prefix-caching"
        - "--gpu-memory-utilization"
        - "0.95"
        - "--max-model-len"
        - "4096"
        - "--port"
        - "8000"
        ports:
        - containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: "1"
EOF

kubectl apply -f vllm-backend.yaml

echo "=================================================="
echo " 5. 配置 Inference 路由并修复 Selector 标签"
echo "=================================================="
cat << 'EOF' > routing-config.yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: quickstart
  namespace: llm-d-quickstart
spec:
  appProtocol: http
  endpointPickerRef:
    failureMode: FailOpen
    group: ""
    kind: Service
    name: quickstart-epp
    port:
      number: 9002
  selector:
    matchLabels:
      app: vllm-worker
  targetPorts:
  - number: 8000
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: qwen-7b-model
  namespace: llm-d-quickstart
spec:
  modelName: Qwen/Qwen2.5-7B-Instruct
  poolRef:
    group: inference.networking.k8s.io
    kind: InferencePool
    name: quickstart
EOF

kubectl apply -f routing-config.yaml

# 强制替换清除 Helm 部署遗留的冲突选择器标签
kubectl patch inferencepool quickstart -n llm-d-quickstart --type='json' \
  -p='[{"op": "replace", "path": "/spec/selector/matchLabels", "value": {"app": "vllm-worker"}}]'

# 重新启动 EPP 网关以更新内部节点缓存
kubectl rollout restart deployment/quickstart-epp -n llm-d-quickstart

echo "=================================================="
echo " 部署完成！等待 Pod 节点加载中..."
echo "=================================================="
echo "检查 Pod 命令: kubectl get pods -n llm-d-quickstart"
echo "验证推理测试命令:"
echo "--------------------------------------------------"
echo "export ROUTER_IP=\$(kubectl get svc quickstart-epp -n llm-d-quickstart -o jsonpath='{.spec.clusterIP}')"
echo "curl -i -X POST http://\${ROUTER_IP}/v1/completions \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"model\": \"Qwen/Qwen2.5-7B-Instruct\", \"prompt\": \"Explain Cloud Native architecture in one sentence.\", \"max_tokens\": 50}'"
echo "--------------------------------------------------"

```
