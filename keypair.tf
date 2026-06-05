# -------------------------------------------------------------
# SSH KEY PAIR GENERATION FOR EC2
# -------------------------------------------------------------

resource "tls_private_key" "minikube_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = "minikube-key-pair"
  public_key = tls_private_key.minikube_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.minikube_key.private_key_pem
  filename        = "${path.module}/minikube-key.pem"
  file_permission = "0600"
}