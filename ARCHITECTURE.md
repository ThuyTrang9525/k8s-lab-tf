# Architecture — Terraform K8s Challenge

## Providers

| Provider | Source | Vai trò |
|---|---|---|
| `aws` | hashicorp/aws ~> 5.0 | Tạo toàn bộ hạ tầng AWS |
| `tls` | hashicorp/tls ~> 4.0 | Generate RSA key pair tự động |
| `local` | hashicorp/local ~> 2.5 | Ghi file `.pem` xuống máy local |

> `cloudinit` provider đã bị loại bỏ — `user_data` được inject trực tiếp qua `templatefile()` để tránh lỗi cloud-init multipart handler.

---

## Workflow chi tiết — cái gì chạy trước, chờ cái gì

### Phase 1 — Terraform plan & resolve dependency graph

Trước khi tạo bất kỳ resource nào, Terraform phân tích dependency graph và quyết định thứ tự:

```
KHÔNG có dependency (chạy song song ngay):
  ├── tls_private_key
  ├── data.aws_ami.ubuntu
  ├── data.aws_vpc.default
  └── data.aws_subnets.default

CHỜ tls_private_key xong:
  ├── aws_key_pair            (cần public_key_openssh)
  └── local_file              (cần private_key_pem)

CHỜ data.aws_vpc xong:
  ├── aws_security_group.alb_sg
  └── aws_security_group.ec2_sg  ← CHỜ thêm alb_sg (cần SG id cho ingress rule)

CHỜ alb_sg + default_subnets xong:
  └── aws_lb

CHỜ aws_vpc xong:
  └── aws_lb_target_group

CHỜ aws_key_pair + ec2_sg + aws_ami + aws_subnets xong:
  └── aws_instance            ← đây là resource nặng nhất, Terraform submit rồi không chờ

CHỜ aws_lb xong:
  └── aws_lb_listener         (cần load_balancer_arn)

CHỜ aws_lb_target_group + aws_instance xong:
  ├── aws_lb_listener         (cần target_group_arn)
  └── aws_lb_target_group_attachment (cần cả target_group_arn + instance_id)
```

**Terraform apply kết thúc** khi tất cả resource trên đã được AWS xác nhận tạo xong. Lúc này EC2 đang boot, `setup.sh` chưa chắc đã chạy xong.

---

### Phase 2 — Bên trong EC2 (sau khi Terraform apply xong)

Đây là quá trình chạy hoàn toàn tự động bên trong EC2, Terraform không biết và không chờ:

```
[T+0s]   EC2 boot, cloud-init khởi động
[T+5s]   user_data script bắt đầu chạy
         → exec log ra /var/log/user_data_setup.log

[T+5s]   apt-get update
         → CHỜ: apt lock, network ready

[T+40s]  apt-get install docker.io kubectl curl jq socat conntrack
         → CHỜ: download packages xong

[T+60s]  systemctl start docker
         → CHỜ: Docker daemon ready

[T+65s]  curl download kubectl binary (~57MB)
         → CHỜ: download xong

[T+75s]  curl download kind binary (~6MB)
         → CHỜ: download xong

[T+80s]  kind create cluster --wait 120s
         → CHỜ: pull image kindest/node:v1.30.0 (~700MB, lần đầu mất 1-2 phút)
         → CHỜ: container start
         → CHỜ: API server healthy
         → kind tự báo "Ready after ~18s" (sau khi image đã pull xong)

[T+180s] python3 decode base64 → ghi /root/k8s-app.yaml

[T+181s] kubectl apply -f k8s-app.yaml
         → tạo ConfigMap, Deployment, Service
         → CHỜ: API server nhận request

[T+182s] kubectl rollout status --timeout=120s
         → CHỜ: 2 nginx pods ở trạng thái Running
         → nginx:alpine pull (~8MB, nhanh)
         → pods ready sau ~20-30s

[T+210s] copy kubeconfig → /home/ubuntu/.kube/config

[T+211s] === Deployment Completed Successfully ===
```

---

### Phase 3 — ALB health check (song song với Phase 2)

ALB bắt đầu health check ngay sau khi EC2 được register vào target group — không chờ Phase 2 xong:

```
[T+0s]   aws_lb_target_group_attachment tạo xong
         → EC2 được register, status: "initial"

[T+20s]  Health check lần 1: GET http://EC2:30080/
         → Nếu setup.sh chưa xong → connection refused → FAIL
         → Status vẫn: "initial" hoặc "unhealthy"

[T+40s]  Health check lần 2: FAIL (kind chưa xong)
[T+60s]  Health check lần 3: FAIL
...

[T+210s] setup.sh xong, port 30080 đang listen
[T+220s] Health check lần N: GET / → 200 OK → PASS (lần 1)
[T+240s] Health check: PASS (lần 2)
[T+260s] Health check: PASS (lần 3) ← cần 3 lần liên tiếp

[T+260s] Target status: "healthy"
         → ALB bắt đầu forward traffic
         → Truy cập ALB URL lúc này sẽ thấy app
```

**Tổng thời gian từ `terraform apply` đến khi app accessible: ~4-5 phút**

---

### Tóm tắt timeline

```
terraform apply ──────────────────────────────► [~2 phút] Terraform done
                                                     │
                        EC2 bootstrapping ───────────┤
                        apt + docker + kind ──────────┤
                        kubectl apply ────────────────┤ [~3.5 phút]
                                                     │
                        ALB health check loop ────────┤
                        3x pass ──────────────────────► [~4-5 phút] App live
```

---

## Tại sao không dùng cloudinit provider

`cloudinit` provider tạo multipart MIME payload. Cloud-init trên EC2 fail khi ghi script ra disk (`util.write_file`) với multipart format trong một số AMI version. Dùng raw bash script qua `templatefile()` trực tiếp vào `user_data` là cách đơn giản và đáng tin cậy hơn.

## Tại sao dùng kind thay Minikube

| | Minikube | kind |
|---|---|---|
| RAM tối thiểu | ~2GB (thường OOM trên t3.small) | ~1.2GB |
| Port mapping | Cần socat thủ công | `extraPortMappings` built-in |
| Boot time | 3-5 phút | ~30s |

## Tại sao base64 encode k8s manifest

`k8s-app.yaml` chứa HTML với ký tự `{`, `}` — Terraform templatefile sẽ interpret chúng là template variables và lỗi. Base64 encode trước khi nhúng vào script, Python decode trong EC2 là cách sạch nhất.

---

## File structure

```
.
├── provider.tf          # Providers (aws, tls, local) + data VPC/subnet
├── variables.tf         # Input variables: region, instance_type
├── keypair.tf           # TLS key gen + aws_key_pair + local .pem file
├── security-groups.tf   # SG cho ALB (80) và EC2 (22, 30080)
├── ec2.tf               # AMI lookup + EC2 + user_data via templatefile
├── alb.tf               # ALB + target group + listener + attachment
├── outputs.tf           # alb_dns_name, ec2_public_ip, ssh_command
└── templates/
    ├── setup.sh         # Bootstrap: install docker/kind/kubectl → deploy app
    └── k8s-app.yaml     # Deployment + ConfigMap + NodePort Service
```
