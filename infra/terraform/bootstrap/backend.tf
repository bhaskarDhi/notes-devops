terraform {
  backend "s3" {
    bucket       = "notes-devops-tfstate-725072160791"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
