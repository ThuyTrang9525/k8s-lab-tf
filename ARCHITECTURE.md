# Terraform K8s Challenge — Architecture & Flow

## Providers đang dùng

| Provider | Source | Mục đích |
|---|---|---|
| `aws` | hashicorp/aws ~> 5.0 | Tạo toàn bộ hạ tầng AWS (EC2, ALB, SG, VPC...) |
| `tls` | hashicorp/tls ~> 4.0 | Generate RSA key pair cho SSH |
| `local` | hashicorp/local ~> 2.5 | Ghi file `.pem` xuống máy local |
| `cloudinit` | hashicorp/cloudinit ~> 2.3 | Render bootstrap script thành user_data cho EC2 |

> Đây chính là "wire thêm provider khác" theo yêu cầu — ngoài `aws`, còn có 3 provider phụ phối hợp để hoàn thành automation.

---

## Kiến trúc tổng quan

```
Internet
    │
    ▼
[ AWS ALB ] ← port 80
    │
    │ forward → port 30080
    ▼
[ EC2 t3.small ]
    │
    │ docker-proxy
    ▼
[ kind container ] ← k8s control-plane
    │
    │ NodePort 30080
    ▼
[ nginx Pod ] ← 2 replicas
    │
    └── HTML từ ConfigMap
```

---

## Khi người dùng chạy `terraform apply`

### Bước 1 — Terraform khởi tạo hạ tầng AWS (song song)

```
tls_private_key         → generate RSA 4096-bit key
local_file              → ghi minikube-key.pem ra thư mục local
aws_key_pair            → upload public key lên AWS
aws_security_group alb  → mở port 80 từ internet
aws_security_group ec2  → mở port 22 (SSH) + port 30080 từ ALB
aws_lb                  → tạo Application Load Balancer
aws_lb_target_group     → tạo target group port 30080, health check /
aws_lb_listener         → listener port 80 → forward tới target group
aws_instance            → tạo EC2 t3.small với user_data = setup.sh
aws_lb_target_group_attachment → đăng ký EC2 vào target group
```

### Bước 2 — EC2 boot lên, user_data (setup.sh) tự chạy

Đây là phần automation chạy **bên trong EC2**, không cần người dùng làm gì:

```
1. apt-get install docker, kubectl, socat, curl, jq
2. systemctl start docker
3. curl → download kubectl
4. curl → download kind v0.23.0
5. kind create cluster --config kind-config.yaml
   └── extraPortMappings: containerPort 30080 → hostPort 30080
6. kubectl apply -f k8s-app.yaml
   ├── Deployment: 2 replicas nginx:alpine
   ├── ConfigMap: chứa HTML trang web
   └── Service: NodePort 30080 → pod port 80
7. kubectl rollout status → đợi app sẵn sàng
```

### Bước 3 — Traffic flow khi người dùng truy cập

```
User browser
  → http://minikube-alb-xxx.us-east-1.elb.amazonaws.com (port 80)
  → ALB listener (port 80)
  → ALB target group (port 30080)
  → EC2 security group cho phép từ ALB SG
  → EC2 port 30080
  → docker-proxy (kind extraPortMappings)
  → kind k8s-lab container
  → kube-proxy
  → Service NodePort 30080
  → nginx Pod (port 80)
  → HTML từ ConfigMap
  → Response 200 OK
```

---

## Tại sao dùng kind thay Minikube?

| | Minikube | kind |
|---|---|---|
| Driver | Docker + VM layer | Docker container thuần |
| RAM tối thiểu | ~2GB | ~1.2GB |
| Phù hợp | Dev local có RAM nhiều | CI/CD, instance nhỏ |
| Port mapping | Cần socat thủ công | `extraPortMappings` built-in |

`t3.small` chỉ có 2GB RAM → kind là lựa chọn duy nhất khả thi.

---

## File structure

```
.
├── provider.tf          # Khai báo providers + data VPC/subnet mặc định
├── variables.tf         # Input variables (region, instance_type)
├── keypair.tf           # TLS key gen + AWS key pair + ghi .pem local
├── security-groups.tf   # SG cho ALB (port 80) và EC2 (port 22, 30080)
├── ec2.tf               # AMI lookup + EC2 instance + user_data render
├── alb.tf               # ALB + target group + listener + attachment
├── outputs.tf           # In ra ALB URL, EC2 IP, SSH command
└── templates/
    ├── setup.sh         # Bootstrap script chạy trong EC2
    └── k8s-app.yaml     # K8s manifest: Deployment + ConfigMap + Service
```

---

## Outputs sau khi apply

```
alb_dns_name = "http://<alb-dns>.us-east-1.elb.amazonaws.com"  ← truy cập app
ec2_public_ip = "x.x.x.x"
ssh_command   = "ssh -i minikube-key.pem ubuntu@x.x.x.x"
```
