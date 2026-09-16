provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project   = "SD-lab02"
      ManagedBy = "Terraform"
      Owner     = "stephanie.borrego"
    }
  }
}
