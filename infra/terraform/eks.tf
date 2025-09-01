############################################
# eks.tf (inline auto-discovery, HCL chuẩn)
############################################

# --- Auto-discovery VPC & Subnets ---
data "aws_vpc" "target" {
  default = true
}

data "aws_subnets" "private_tagged" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.target.id]
  }
  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

data "aws_subnets" "public_tagged" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.target.id]
  }
  filter {
    name   = "tag:kubernetes.io/role/elb"
    values = ["1"]
  }
}

data "aws_subnets" "all_in_vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.target.id]
  }
}

locals {
  want_n = 2

  private_take_n = min(local.want_n, length(data.aws_subnets.private_tagged.ids))
  public_take_n  = min(local.want_n, length(data.aws_subnets.public_tagged.ids))
  all_take_n     = min(local.want_n, length(data.aws_subnets.all_in_vpc.ids))

  candidate_private = slice(data.aws_subnets.private_tagged.ids, 0, local.private_take_n)
  candidate_public  = slice(data.aws_subnets.public_tagged.ids, 0, local.public_take_n)
  candidate_all     = slice(data.aws_subnets.all_in_vpc.ids, 0, local.all_take_n)

  pick_private = length(local.candidate_private) == local.want_n ? local.candidate_private : []
  pick_public  = length(local.candidate_public) == local.want_n ? local.candidate_public : []
  pick_all     = length(local.candidate_all) == local.want_n ? local.candidate_all : []

  # ưu tiên: 2 private -> 2 public -> 2 bất kỳ
  effective_subnet_ids = length(local.pick_private) > 0 ? local.pick_private : (
    length(local.pick_public) > 0 ? local.pick_public : local.pick_all
  )
}

# Guard: buộc phải có đúng 2 subnet
resource "null_resource" "assert_two_subnets" {
  triggers = {
    chosen = join(",", local.effective_subnet_ids)
  }
  lifecycle {
    precondition {
      condition     = length(local.effective_subnet_ids) == 2
      error_message = "Cần tối thiểu 2 subnet (khác AZ càng tốt). Hãy tag hoặc tạo thêm subnet."
    }
  }
}

# --- EKS ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id     = data.aws_vpc.target.id
  subnet_ids = local.effective_subnet_ids

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      desired_size   = 2
      min_size       = 2
      max_size       = 5
    }
  }

  enable_irsa = true
}
