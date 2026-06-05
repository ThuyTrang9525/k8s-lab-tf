# -------------------------------------------------------------
# INPUT VARIABLES DECLARATION
# -------------------------------------------------------------

variable "aws_region" {
  description = "The AWS Region to deploy the infrastructure into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type to run Minikube"
  type        = string
  default     = "t3.micro"
}