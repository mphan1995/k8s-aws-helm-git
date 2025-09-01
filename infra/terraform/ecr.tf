resource "aws_ecr_repository" "flask_app" {
  name                 = "flask-app"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
output "ecr_url" { value = aws_ecr_repository.flask_app.repository_url }
