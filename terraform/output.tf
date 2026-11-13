output "public_ip" {
  description = "Elastic IP of the server. GitHub variable DEPLOY_HOST."
  value       = aws_eip.web.public_ip
}

output "app_url" {
  description = "Public URL of the app. GitHub variable APP_URL."
  value       = "http://${aws_eip.web.public_ip}"
}

output "ssh_command" {
  description = "Log in to the server."
  value       = "ssh -i ~/.ssh/nginx-cicd-deploy ec2-user@${aws_eip.web.public_ip}"
}
