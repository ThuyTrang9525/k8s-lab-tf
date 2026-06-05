#!/bin/bash

# -------------------------------------------------------------
# EC2 BOOTSTRAP SCRIPT
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

usermod -aG docker ubuntu

# -------------------------------------------------------------
# INSTALL KUBECTL
# -------------------------------------------------------------

echo "=== Installing kubectl ==="

curl -LO \
"https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

rm kubectl

# -------------------------------------------------------------
# INSTALL MINIKUBE
# -------------------------------------------------------------

echo "=== Installing Minikube ==="

curl -LO \
https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64

install minikube-linux-amd64 /usr/local/bin/minikube

rm minikube-linux-amd64

# -------------------------------------------------------------
# START MINIKUBE
# -------------------------------------------------------------

echo "=== Starting Minikube ==="

minikube start \
--driver=docker \
--force \
  --memory=768mb \
  --cpus=1

sleep 15

# -------------------------------------------------------------
# CREATE K8S MANIFEST
# -------------------------------------------------------------

echo "=== Writing Manifest ==="

cat << 'EOF' > /home/ubuntu/k8s-app.yaml
${k8s_app_manifest}
EOF

chown ubuntu:ubuntu /home/ubuntu/k8s-app.yaml

# -------------------------------------------------------------
# COPY KUBECONFIG
# -------------------------------------------------------------

mkdir -p /home/ubuntu/.kube

cp /root/.kube/config /home/ubuntu/.kube/config

cp -r /root/.minikube /home/ubuntu/.minikube

sed -i \
's|/root/.minikube|/home/ubuntu/.minikube|g' \
/home/ubuntu/.kube/config

chown -R ubuntu:ubuntu /home/ubuntu/.kube
chown -R ubuntu:ubuntu /home/ubuntu/.minikube

# -------------------------------------------------------------
# DEPLOY APP TO K8S
# -------------------------------------------------------------

echo "=== Deploying Application ==="

kubectl apply -f /home/ubuntu/k8s-app.yaml

kubectl rollout status \
deployment/hello-aws-deployment \
--timeout=120s

# -------------------------------------------------------------
# GET MINIKUBE IP
# -------------------------------------------------------------

MINIKUBE_IP=$(minikube ip)

echo "Minikube IP: $MINIKUBE_IP"

# -------------------------------------------------------------
# SOCAT FORWARD
# EC2:30080 -> MINIKUBE:30080
# -------------------------------------------------------------

cat << EOF > /etc/systemd/system/minikube-forward.service

[Unit]
Description=Minikube Port Forward Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:30080,fork,reuseaddr TCP:$MINIKUBE_IP:30080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

EOF

systemctl daemon-reload

systemctl enable minikube-forward.service

systemctl start minikube-forward.service

echo "=== Deployment Completed Successfully ==="

date