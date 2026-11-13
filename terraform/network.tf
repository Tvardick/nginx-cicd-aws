data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "web" {
  name        = "nginx-cicd-web"
  description = "HTTP for users, SSH for deploys"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

#trivy:ignore:AVD-AWS-0107 GitHub runner IPs are not fixed, the risk is accepted in the README
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.web.id
  description       = "SSH from anywhere, key only"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

#trivy:ignore:AVD-AWS-0104 outbound traffic is required, there is no NAT or proxy in this setup
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "All outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
