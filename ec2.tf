# -------------------------------------------------------------
# EC2 INSTANCE CONFIGURATION AND BOOTSTRAP SCRIPT
# -------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = [
      "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    ]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  user_data = templatefile(
    "${path.module}/templates/setup.sh",
    {
      k8s_app_manifest_b64 = base64encode(file("${path.module}/templates/k8s-app.yaml"))
    }
  )
}

resource "aws_instance" "minikube_node" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  subnet_id = data.aws_subnets.default.ids[0]

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  key_name = aws_key_pair.deployer.key_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = local.user_data

  user_data_replace_on_change = true

  tags = {
    Name = "minikube-ec2-instance"
  }
}