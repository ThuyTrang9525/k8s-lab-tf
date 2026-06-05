#!/bin/bash

# -------------------------------------------------------------
# EC2 BOOTSTRAP SCRIPT - uses kind (lighter than minikube)
# -------------------------------------------------------------

exec > >(tee -i /var/log/user_data_setup.log) 2>&1

echo "=== Starting Initialization ==="
date

export HOME=/root
export KUBECONFIG=/root/.kube/config

# -------------------------------------------------------------
# INSTALL PACKAGES
# -------------------------------------------------------------

apt-get update -y

apt-get install -y \
  docker.io \
  conntrack \
  socat \
  curl \
  jq

systemctl start docker
systemctl enable docker

# -------------------------------------------------------------
# INSTALL KUBECTL
# -------------------------------------------------------------

echo "=== Installing kubectl ==="

curl -LO \
  "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# -------------------------------------------------------------
# INSTALL KIND
# -------------------------------------------------------------

echo "=== Installing kind ==="

curl -Lo /usr/local/bin/kind \
  https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64

chmod +x /usr/local/bin/kind

# -------------------------------------------------------------
# START KIND CLUSTER
# -------------------------------------------------------------

echo "=== Starting kind cluster ==="

cat << 'KINDCFG' > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    protocol: TCP
KINDCFG

kind create cluster \
  --name k8s-lab \
  --config /tmp/kind-config.yaml \
  --wait 120s

# -------------------------------------------------------------
# WRITE K8S MANIFEST
# -------------------------------------------------------------

echo "=== Writing Manifest ==="

cat << 'EOF' > /root/k8s-app.yaml
${k8s_app_manifest}
EOF

# -------------------------------------------------------------
# DEPLOY APP
# -------------------------------------------------------------

echo "=== Deploying Application ==="

kubectl apply -f /root/k8s-app.yaml

kubectl rollout status \
  deployment/hello-aws-deployment \
  --timeout=120s

# -------------------------------------------------------------
# COPY KUBECONFIG FOR ubuntu USER
# -------------------------------------------------------------

mkdir -p /home/ubuntu/.kube
cp /root/.kube/config /home/ubuntu/.kube/config
# Fix server address: kind dùng 127.0.0.1 nên ubuntu user dùng được luôn
chown -R ubuntu:ubuntu /home/ubuntu/.kube
echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc

echo "=== Deployment Completed Successfully ==="
date
