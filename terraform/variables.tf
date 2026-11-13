variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is enough for nginx without monitoring."
  type        = string
  default     = "t3.micro"
}

variable "compose_version" {
  description = "Docker Compose plugin release installed on the server."
  type        = string
  default     = "v5.7.1"
}

variable "ssh_public_key_path" {
  description = "Public half of the deploy SSH key. The private half goes to GitHub secrets."
  type        = string
  default     = "~/.ssh/nginx-cicd-deploy.pub"
}
