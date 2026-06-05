# -------------------------------------------------------------
# TERRAFORM CONFIGURATION AND PROVIDERS DECLARATION
# -------------------------------------------------------------

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws       = { source = "hashicorp/aws",       version = "~> 5.0" }
    tls       = { source = "hashicorp/tls",       version = "~> 4.0" }
    cloudinit = { source = "hashicorp/cloudinit", version = "~> 2.3" }
    local     = { source = "hashicorp/local",     version = "~> 2.5" }
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------
# DEFAULT VPC DATA SOURCES
# -------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}