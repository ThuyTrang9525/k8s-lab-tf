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

Truy cập `alb_dns_name` trên trình duyệt là xong. Đợi ~3 phút để EC2 bootstrap xong.

```bash
# Dọn dẹp toàn bộ
terraform destroy -auto-approve
```

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
│                   (port 80 public)                  │
└──────────────────────┬──────────────────────────────┘
                       │ forward :30080
                       ▼
┌─────────────────────────────────────────────────────┐
│                  EC2 t3.small                       │
│              (Security Group: 22, 30080)            │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │           kind cluster (Docker)               │  │
│  │                                               │  │
│  │   ┌─────────────────────────────────────┐     │  │
│  │   │  Service NodePort :30080            │     │  │
│  │   └──────────────┬──────────────────────┘     │  │
│  │                  │                            │  │
│  │   ┌─────────────────────────────────────┐     │  │
│  │   │  Deployment: nginx:alpine x2 pods   │     │  │
│  │   │  HTML served from ConfigMap         │     │  │
│  │   └─────────────────────────────────────┘     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Request flow:**
```
Browser → ALB :80 → EC2 :30080 → docker-proxy → kind → NodePort → nginx Pod → HTML
```

---

## Cách wire providers

Project dùng 4 providers phối hợp để đạt được 1-click automation:

```hcl
terraform {
  required_providers {
    aws       = { source = "hashicorp/aws",       version = "~> 5.0" }
    tls       = { source = "hashicorp/tls",       version = "~> 4.0" }
    local     = { source = "hashicorp/local",     version = "~> 2.5" }
    cloudinit = { source = "hashicorp/cloudinit", version = "~> 2.3" }
  }
}
```

### `tls` provider — sinh SSH key tự động

Thay vì yêu cầu người dùng tạo key thủ công, `tls` provider generate RSA key pair ngay trong Terraform:

```hcl
resource "tls_private_key" "minikube_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
```

Public key được đẩy lên AWS, private key được chuyển sang `local` provider.

### `local` provider — ghi file `.pem` xuống máy

```hcl
resource "local_file" "private_key" {
  content         = tls_private_key.minikube_key.private_key_pem
  filename        = "${path.module}/minikube-key.pem"
  file_permission = "0600"
}
```

Người dùng có ngay file `minikube-key.pem` để SSH vào EC2 mà không cần làm gì thêm.

### `cloudinit` provider — render bootstrap script

`setup.sh` cần nhúng nội dung của `k8s-app.yaml` vào bên trong. `cloudinit` xử lý việc render template và encode đúng format cho EC2 `user_data`:

```hcl
data "cloudinit_config" "minikube_setup" {
  part {
    content_type = "text/x-shellscript"
    content = templatefile("templates/setup.sh", {
      k8s_app_manifest = file("templates/k8s-app.yaml")
    })
  }
}
```

### `aws` provider — tạo toàn bộ hạ tầng

Nhận output từ 3 provider trên để hoàn thiện:
- `aws_key_pair` ← public key từ `tls`
- `aws_instance.user_data` ← rendered script từ `cloudinit`
- File `.pem` đã có sẵn ← từ `local`

### Dependency chain

```
tls_private_key
    ├──► aws_key_pair ──────────────► aws_instance
    └──► local_file (minikube-key.pem)

templatefile(setup.sh + k8s-app.yaml)
    └──► cloudinit_config ──────────► aws_instance.user_data
```

---

## Tại sao dùng kind thay Minikube

`t3.small` chỉ có 2GB RAM. Minikube cần VM layer bổ sung nên thường xuyên OOM. kind chạy thẳng trên Docker container, nhẹ hơn đáng kể và có `extraPortMappings` để expose NodePort ra host mà không cần socat thủ công.


---

## Các thành phần chính và cơ chế hoạt động

### EC2 Instance (`ec2.tf`)

Là "máy chủ" duy nhất trong hệ thống. Chạy Ubuntu 22.04, type `t3.small` (2GB RAM).  
Toàn bộ logic bootstrap được nhúng vào `user_data` — EC2 tự cài đặt và cấu hình mọi thứ khi khởi động lần đầu, không cần SSH vào làm tay.

### kind Cluster (`templates/setup.sh`)

kind (Kubernetes IN Docker) chạy một node k8s cluster bên trong một Docker container trên EC2.  
Khác với Minikube, kind không cần VM layer nên nhẹ hơn và phù hợp với instance RAM thấp.

`extraPortMappings` trong kind config làm cầu nối trực tiếp:
```
EC2 host port 30080  ──►  kind container port 30080  ──►  NodePort Service
```
Không cần socat hay bất kỳ proxy thủ công nào.

### Kubernetes App (`templates/k8s-app.yaml`)

3 object K8s phối hợp với nhau:

| Object | Vai trò |
|---|---|
| `ConfigMap` | Chứa nội dung HTML trang web, inject vào pod qua volume mount |
| `Deployment` | Chạy 2 replica nginx:alpine, mount HTML từ ConfigMap |
| `Service` (NodePort) | Expose app ra port 30080, là điểm nhận traffic từ ALB |

HTML được lưu trong ConfigMap thay vì build Docker image riêng — đơn giản, không cần registry, thay đổi nội dung chỉ cần `kubectl apply` lại.

### Application Load Balancer (`alb.tf`)

ALB đứng trước EC2, là entry point duy nhất từ internet.

- **Listener**: lắng nghe port 80 HTTP
- **Target Group**: trỏ vào EC2 port 30080, health check `GET /` expect 200
- **Security**: chỉ EC2 SG mới nhận traffic từ ALB SG trên port 30080 — EC2 không expose thẳng ra internet

### Security Groups (`security-groups.tf`)

Hai lớp bảo vệ:

```
Internet → ALB SG (chỉ port 80)
ALB SG  → EC2 SG (chỉ port 30080 từ ALB SG + port 22 SSH)
```

EC2 không thể bị truy cập trực tiếp trên port 30080 từ internet — chỉ đi qua ALB.

### Key Pair (`keypair.tf`)

`tls` provider generate RSA 4096-bit key ngay trong Terraform state.  
`local` provider ghi private key ra file `minikube-key.pem` — người dùng có thể SSH vào debug mà không cần tạo key thủ công trước.

> Lưu ý: `minikube-key.pem` chứa private key, không commit lên git (đã có trong `.gitignore`).
