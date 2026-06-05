# Terraform K8s Challenge

Deploy một Kubernetes app lên AWS chỉ bằng một lệnh — EC2 + kind + ALB, fully automated.

---

## Lệnh chạy

```bash
# 1. Init providers
terraform init

# 2. Preview những gì sẽ tạo
terraform plan

# 3. Deploy toàn bộ hạ tầng (1-click)
terraform apply -auto-approve
```

Sau khi apply xong, Terraform in ra:

```
alb_dns_name = "http://<alb-dns>.us-east-1.elb.amazonaws.com"
ec2_public_ip = "x.x.x.x"
ssh_command   = "ssh -i minikube-key.pem ubuntu@x.x.x.x"
```

Truy cập `alb_dns_name` trên trình duyệt. Đợi ~4 phút để EC2 bootstrap và kind cluster khởi động xong.

```bash
# Dọn dẹp toàn bộ
terraform destroy -auto-approve
```

Destroy xong apply lại bình thường — tất cả resource names dùng `name_prefix` để tránh conflict.

---

## Sơ đồ kiến trúc

```
┌─────────────────────────────────────────────────────┐
│                      Internet                       │
└──────────────────────┬──────────────────────────────┘
                       │ HTTP :80
                       ▼
┌─────────────────────────────────────────────────────┐
│            AWS Application Load Balancer            │
│         Security Group: port 80 từ internet         │
└──────────────────────┬──────────────────────────────┘
                       │ forward :30080
                       ▼
┌─────────────────────────────────────────────────────┐
│                  EC2 t3.small                       │
│       Security Group: port 22 + 30080 từ ALB SG     │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │        kind cluster (Docker container)        │  │
│  │   extraPortMappings: host:30080→container:30080│  │
│  │                                               │  │
│  │   ┌─────────────────────────────────────┐     │  │
│  │   │  Service NodePort :30080            │     │  │
│  │   └──────────────┬──────────────────────┘     │  │
│  │                  │                            │  │
│  │   ┌─────────────────────────────────────┐     │  │
│  │   │  Deployment: nginx:alpine x2 pods   │     │  │
│  │   │  HTML từ ConfigMap (volume mount)   │     │  │
│  │   └─────────────────────────────────────┘     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

Request flow:
```
Browser → ALB :80 → EC2 :30080 → docker-proxy → kind → NodePort → nginx Pod → HTML
```

---

## Cách wire providers

Project dùng 3 providers phối hợp để đạt 1-click automation:

```hcl
terraform {
  required_providers {
    aws   = { source = "hashicorp/aws",   version = "~> 5.0" }
    tls   = { source = "hashicorp/tls",   version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}
```

### `tls` provider — sinh SSH key tự động

```hcl
resource "tls_private_key" "minikube_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
```

Không cần tạo key thủ công. Public key được đẩy lên AWS, private key chuyển sang `local` provider.

### `local` provider — ghi file `.pem` xuống máy

```hcl
resource "local_file" "private_key" {
  content         = tls_private_key.minikube_key.private_key_pem
  filename        = "${path.module}/minikube-key.pem"
  file_permission = "0600"
}
```

File `minikube-key.pem` có sẵn ngay sau `terraform apply`, dùng SSH vào EC2 luôn.

### `aws` provider — tạo toàn bộ hạ tầng

`user_data` được inject trực tiếp qua `templatefile()` — k8s manifest được base64 encode trước khi nhúng vào script để tránh lỗi ký tự đặc biệt:

```hcl
locals {
  user_data = templatefile("templates/setup.sh", {
    k8s_app_manifest_b64 = base64encode(file("templates/k8s-app.yaml"))
  })
}
```

Bên trong `setup.sh`, Python decode base64 ra file YAML sạch:

```bash
python3 - << 'PYEOF'
import base64
content = base64.b64decode("${k8s_app_manifest_b64}").decode("utf-8")
with open("/root/k8s-app.yaml", "w") as f:
    f.write(content)
PYEOF
```

### Dependency chain

```
tls_private_key
    ├──► aws_key_pair        ──► aws_instance
    └──► local_file (.pem)

templatefile(setup.sh)
    └── base64(k8s-app.yaml) ──► aws_instance.user_data
```

---

## Các thành phần chính và cơ chế hoạt động

### EC2 Instance (`ec2.tf`)

Chạy Ubuntu 22.04, type `t3.small` (2GB RAM). Toàn bộ logic bootstrap được nhúng vào `user_data` — EC2 tự cài đặt và cấu hình mọi thứ khi khởi động, không cần SSH vào làm tay.

### kind Cluster (`templates/setup.sh`)

kind (Kubernetes IN Docker) chạy một node k8s cluster bên trong Docker container trên EC2. Nhẹ hơn Minikube vì không có VM layer, phù hợp với instance RAM thấp.

`extraPortMappings` trong kind config làm cầu nối trực tiếp:
```
EC2 host :30080  ──►  kind container :30080  ──►  NodePort Service
```

### Kubernetes App (`templates/k8s-app.yaml`)

| Object | Vai trò |
|---|---|
| `ConfigMap` | Chứa HTML trang web, inject vào pod qua volume mount |
| `Deployment` | 2 replica nginx:alpine, mount HTML từ ConfigMap |
| `Service` NodePort | Expose app ra port 30080 |

### Application Load Balancer (`alb.tf`)

- Listener port 80 HTTP
- Target group trỏ EC2 port 30080, health check `GET /` expect 200
- Dùng `name_prefix` thay `name` để tránh conflict khi destroy/apply lại

### Security Groups (`security-groups.tf`)

```
Internet ──► ALB SG  (port 80 only)
ALB SG   ──► EC2 SG  (port 30080 from ALB SG + port 22 SSH)
```

EC2 không expose port 30080 thẳng ra internet — chỉ nhận traffic qua ALB.

### Key Pair (`keypair.tf`)

`tls` provider generate RSA 4096-bit key trong Terraform state. `local` provider ghi ra `minikube-key.pem` — SSH vào EC2 debug không cần chuẩn bị gì trước.

> `minikube-key.pem` chứa private key, không commit lên git (đã có trong `.gitignore`).

---

## Debug

```bash
# SSH vào EC2
ssh -i minikube-key.pem ubuntu@<ec2_public_ip>

# Xem bootstrap log
sudo tail -50 /var/log/user_data_setup.log

# Check port 30080
sudo ss -tulpn | grep 30080

# Test app trực tiếp
curl -s -o /dev/null -w "%{http_code}" http://localhost:30080

# Xem K8s resources
kubectl get all
```
