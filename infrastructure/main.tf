provider "aws" {
  region = "us-west-2"  # Change to your preferred region
}

# Variables
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "harness-gitops-cluster"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# VPC Configuration
resource "aws_vpc" "eks_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# Get available AZs
data "aws_availability_zones" "available" {}

# Create two subnets in different AZs (EKS requirement)
resource "aws_subnet" "subnet_az1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name                                           = "${var.cluster_name}-subnet-az1"
    "kubernetes.io/cluster/${var.cluster_name}"    = "shared"
    "kubernetes.io/role/elb"                       = "1"
  }
}

resource "aws_subnet" "subnet_az2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                                           = "${var.cluster_name}-subnet-az2"
    "kubernetes.io/cluster/${var.cluster_name}"    = "shared"
    "kubernetes.io/role/elb"                       = "1"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# Route Table
resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.cluster_name}-route-table"
  }
}

# Route Table Associations
resource "aws_route_table_association" "subnet_az1_association" {
  subnet_id      = aws_subnet.subnet_az1.id
  route_table_id = aws_route_table.route_table.id
}

resource "aws_route_table_association" "subnet_az2_association" {
  subnet_id      = aws_subnet.subnet_az2.id
  route_table_id = aws_route_table.route_table.id
}

# Security Groups
resource "aws_security_group" "eks_cluster_sg" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.eks_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_security_group" "eks_nodes_sg" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.eks_vpc.id

  # Outbound HTTPS for Harness connections
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow outbound HTTPS to Harness, GitHub, and Docker Hub"
  }

  # Allow SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Consider restricting to your IP range
    description = "Allow SSH access"
  }

  # Allow all internal communication within the security group
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    self            = true
    description     = "Allow all internal communication"
  }

  # Allow communication from the EKS cluster security group
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.eks_cluster_sg.id]
    description     = "Allow communication from EKS cluster security group"
  }

  # General egress rule
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.cluster_name}-nodes-sg"
  }
}

# IAM Roles for EKS
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_node_role" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_container_registry_read" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

# EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.28"  # Specify your desired Kubernetes version

  vpc_config {
    subnet_ids             = [aws_subnet.subnet_az1.id, aws_subnet.subnet_az2.id]
    security_group_ids     = [aws_security_group.eks_cluster_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# EKS Node Group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.subnet_az1.id, aws_subnet.subnet_az2.id]
  instance_types  = ["t3.medium"]  # 2 vCPUs, 4GB memory
  disk_size       = 50             # 50GB disk as required

  scaling_config {
    desired_size = 2               # 2 nodes as required
    min_size     = 2
    max_size     = 3               # Allow for one additional node if needed
  }

  # Remote access configuration removed as we don't have a valid key pair
  # and AWS doesn't allow an empty SSH key when remote_access is specified

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_container_registry_read,
  ]

  tags = {
    Name = "${var.cluster_name}-node-group"
  }
}

# Outputs
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}

output "eks_cluster_id" {
  value = aws_eks_cluster.eks_cluster.id
}

output "eks_cluster_certificate_authority" {
  value = aws_eks_cluster.eks_cluster.certificate_authority[0].data
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region us-west-2 --name ${aws_eks_cluster.eks_cluster.name}"
}

# Note: The Kubernetes service account needs to be created after connecting to the cluster
# Run these commands after the EKS cluster is provisioned:
# 
# kubectl create serviceaccount harness-gitops-agent
# kubectl create clusterrolebinding harness-gitops-agent-binding \
#   --clusterrole=cluster-admin \
#   --serviceaccount=default:harness-gitops-agent