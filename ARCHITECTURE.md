# Architecture — Terraform K8s Challenge

## Khi bạn chạy `terraform apply`

---

### STEP 1 — Terraform đọc code và lập kế hoạch

Terraform phân tích tất cả file `.tf`, xây dựng dependency graph và quyết định thứ tự tạo resource. Không có gì trên AWS được tạo ở bước này.

```
Terraform reads:
  provider.tf → biết dùng AWS + TLS + Local
  variables.tf → region = us-east-1, instance = t3.small
  *.tf → build dependency graph
```

---

### STEP 2 — Tạo SSH key (tls + local provider)

Không cần AWS. Hai provider này chạy local trên máy bạn.

```
[tls provider]
  tls_private_key → generate RSA 4096-bit keypair trong memory

[local provider]                    [aws provider]
  local_file                          aws_key_pair
  → ghi minikube-key.pem              → upload public key lên AWS
    ra thư mục project                  (cần: public_key_openssh từ bước trên)
```

Sau bước này bạn đã có file `minikube-key.pem` để SSH.

---

### STEP 3 — Tạo Security Groups (chạy song song)

Cần biết VPC id trước, nên Terraform query VPC default trước tiên.

```
data.aws_vpc.default       → lấy VPC id
data.aws_subnets.default   → lấy danh sách subnet ids
         │
         ▼ (cả hai xong thì chạy song song)
         │
   ┌─────┴──────────────────────┐
   │                            │
aws_security_group.alb_sg    aws_security_group.ec2_sg
→ cho phép port 80             → CHỜ alb_sg tạo xong
  từ internet                  → cho phép port 22 từ internet
                               → cho phép port 30080 từ alb_sg id
```

---

### STEP 4 — Tạo ALB và EC2 (chạy song song)

Hai nhóm này không phụ thuộc nhau nên Terraform tạo cùng lúc.

```
   ┌──────────────────────────────────────────────────┐
   │                                                  │
   ▼                                                  ▼
[ALB group]                                    [EC2 group]
aws_lb                                         aws_instance
→ cần: alb_sg id, subnet ids                  → cần: ami id, ec2_sg id,
→ tạo Load Balancer trên AWS                          key_pair name,
                                                      user_data script
aws_lb_target_group
→ cần: vpc id                                  EC2 tạo xong → Terraform
→ port 30080, health check GET /               báo "apply complete"
                                               nhưng EC2 vẫn đang boot!
aws_lb_listener
→ cần: alb arn + target_group arn
→ port 80 → forward → target group
```

---

### STEP 5 — Terraform kết nối EC2 vào ALB

```
aws_lb_target_group_attachment
→ cần: target_group arn (từ step 4) + instance id (từ step 4)
→ đăng ký EC2 vào target group
→ ALB bắt đầu health check EC2:30080 ngay lập tức
```

**Terraform apply kết thúc ở đây.** In ra outputs: ALB URL, EC2 IP, SSH command.

---

### STEP 6 — EC2 tự bootstrap (Terraform không còn kiểm soát)

EC2 vừa boot, `user_data` script (`setup.sh`) tự chạy trong nền. Mất ~3-4 phút.

```
[~T+5s]   Script bắt đầu, log ra /var/log/user_data_setup.log

[~T+40s]  apt-get install
          docker.io, conntrack, socat, curl, jq
          └── CHỜ: apt lock giải phóng + packages download xong

[~T+60s]  systemctl start docker
          └── CHỜ: Docker daemon khởi động xong

[~T+75s]  Download kubectl (~57MB) + kind (~6MB)

[~T+80s]  kind create cluster --wait 120s
          └── CHỜ: pull image kindest/node:v1.30.0 (~700MB)
          └── CHỜ: container start + API server healthy
          └── kind báo "Ready after 18s" (sau khi image pull xong)

[~T+180s] python3 decode base64 → ghi /root/k8s-app.yaml

[~T+181s] kubectl apply -f k8s-app.yaml
          → Deployment (2x nginx:alpine pods)
          → ConfigMap (HTML content)
          → Service (NodePort 30080)

[~T+200s] kubectl rollout status
          └── CHỜ: 2 pods ở trạng thái Running
          └── nginx:alpine pull ~8MB → pods ready sau ~20s

[~T+210s] Copy kubeconfig → /home/ubuntu/.kube/config
          Port 30080 bắt đầu listen ✓
```

---

### STEP 7 — ALB health check pass

ALB đã health check từ step 5 nhưng liên tục fail vì EC2 chưa ready. Đến khi step 6 xong:

```
[~T+220s] Health check GET http://EC2:30080/ → 200 OK  ← lần 1
[~T+240s] Health check GET http://EC2:30080/ → 200 OK  ← lần 2
[~T+260s] Health check GET http://EC2:30080/ → 200 OK  ← lần 3 ✓

Target status: initial → unhealthy → healthy
ALB bắt đầu forward traffic thật
```

---

### STEP 8 — Request từ người dùng

App đã live. Mỗi request đi theo path:

```
Browser
  → ALB :80
  → ALB listener → forward → target group
  → EC2 :30080 (qua Security Group, chỉ cho phép từ ALB SG)
  → docker-proxy (kind extraPortMappings host:30080 → container:30080)
  → kind control-plane container
  → kube-proxy → Service NodePort :30080
  → nginx Pod :80
  → HTML từ ConfigMap (volume mount tại /usr/share/nginx/html)
  → HTTP 200 OK → Browser render trang
```

---

## Timeline tổng

```
0:00  terraform apply bắt đầu
0:30  SSH key + Security Groups xong
1:00  ALB + EC2 tạo xong trên AWS  ← Terraform báo "Apply complete"
1:00  EC2 bắt đầu boot, setup.sh chạy
1:00  ALB health check bắt đầu (fail liên tục)
3:30  kind cluster ready, app deployed, port 30080 listen
4:00  ALB health check pass 3 lần liên tiếp
4:20  ✅ App accessible tại ALB URL
```

---

## Providers và vai trò

| Provider | Chạy ở đâu | Làm gì |
|---|---|---|
| `tls` | Local machine | Generate RSA keypair |
| `local` | Local machine | Ghi file `.pem` |
| `aws` | AWS API | Tạo toàn bộ hạ tầng cloud |

---

## Tại sao không dùng cloudinit provider

`cloudinit` provider tạo multipart MIME payload. Cloud-init trên một số EC2 AMI fail khi ghi script ra disk với format này (`util.write_file` error). Raw bash script qua `templatefile()` trực tiếp vào `user_data` đơn giản và đáng tin cậy hơn.

## Tại sao dùng kind thay Minikube

`t3.small` có 2GB RAM. Minikube cần VM layer, thường xuyên OOM và API server timeout. kind chạy thẳng trên Docker container, boot trong ~18s sau khi image pull xong, có `extraPortMappings` built-in không cần socat.

## Tại sao base64 encode k8s manifest

`k8s-app.yaml` chứa HTML với ký tự `{` `}` — Terraform `templatefile()` sẽ interpret chúng là template variables và lỗi. Base64 encode trước khi nhúng vào script, Python3 decode trong EC2 tránh hoàn toàn vấn đề này.
