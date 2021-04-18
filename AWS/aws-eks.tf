# Get current region
data "aws_region" "current" {}

# Create IAM roles for EKS
module "eks-iam-roles" {
  source = "./create_iam_roles"
}

# Create VPC with privte subnets only
module "eks-vpc" {
  source = "./create_vpc"

  cidr_block = "10.1.0.0/16"
}

# Update VPC wuth public subnets , NAT gateway and IGW
# Can be disabled //todo
module "aws-eks-make-public" {
  count = 1
  source = "./make_vpc_public"

  eks-vpc = module.eks-vpc.eks-vpc
  eks-private-route-table = module.eks-vpc.private-route-table
}

# Create EKS cluster, only private subnets are used for cluster creation
resource "aws_eks_cluster" "eks-private-cluster" {
  name     = var.cluster_name
  role_arn = module.eks-iam-roles.eks-cluster-role.arn

  vpc_config {
    subnet_ids = concat(module.eks-vpc.eks-internal-elb-subnets[*].id)
    endpoint_private_access = true
    endpoint_public_access = true
    public_access_cidrs = [
      "0.0.0.0/0"
    ]
  }
  
  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [ module.eks-iam-roles, module.eks-vpc ]

  provisioner "local-exec" {
    command = join(" ",["aws eks --region", data.aws_region.current.name, "update-kubeconfig --name", aws_eks_cluster.eks-private-cluster.name])
  }
}

# Enable security group for pods
resource "null_resource" "enable_security_groups_for_pods" {

  # Run this provisioner always
  triggers = {
    always_run = timestamp()
  }

  # Enable security groups for pods
  provisioner "local-exec" {
    command = <<EOL
      kubectl set env daemonset aws-node -n kube-system ENABLE_POD_ENI=true;\
      kubectl patch daemonset aws-node \
      -n kube-system \
      -p '{"spec": {"template": {"spec": {"initContainers": [{"env":[{"name":"DISABLE_TCP_EARLY_DEMUX","value":"true"}],"name":"aws-vpc-cni-init"}]}}}}'
       EOL
  }
  depends_on = [aws_eks_cluster.eks-private-cluster]
}

# Create Nodegroup. Nodes are created only in private subnets
resource "aws_eks_node_group" "eks-node-group-1" {
  cluster_name    = aws_eks_cluster.eks-private-cluster.name
  node_group_name = "eks-nodegroup-1"
  node_role_arn   = module.eks-iam-roles.eks-node-group-role.arn
  subnet_ids      = module.eks-vpc.eks-nodes-subnets[*].id
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 1
    max_size     = 4
    min_size     = 1
  }

  tags = {
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.eks-private-cluster.name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled" = "TRUE"
  }
  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [ module.eks-iam-roles  ]
}

# Enable IAM role for service accounts 
module "enable-irsa" {
  source = "./enable_iam_role_for_ser_account"

  eks-cluster = aws_eks_cluster.eks-private-cluster
}

# Enable cluster autoscalar 
module "enable-autoscalar" {
  source = "./enable_autoscalar"

  eks-oidc-provider = module.enable-irsa.eks-oidc-provider

  depends_on = [aws_eks_cluster.eks-private-cluster, module.enable-irsa]
}

# Enable container insights for monitoring and logging
module "enable-container-insights" {
  source = "./enable_containerinsights"
  cluster_name = var.cluster_name
  
  depends_on = [ aws_eks_cluster.eks-private-cluster  ]
}

# Enable IAM role for ALB
module "enable-alb" {
  source = "./enable_alb"

  eks-oidc-provider = module.enable-irsa.eks-oidc-provider
  depends_on = [ aws_eks_cluster.eks-private-cluster  ]
}

# Outputs Endpoint and OIDC provider url
output "eks-endpoint" {
  value = aws_eks_cluster.eks-private-cluster.endpoint
}

output "eks-oidc-provider-url" {
  value = aws_eks_cluster.eks-private-cluster.identity[0].oidc[0].issuer
}

output "autoscalar-iam-role-arn" {
  value = module.enable-autoscalar.autoscalar-iam-role-arn
}