# ── AWS Module: VPC + EKS Cluster with OIDC Provider ──────────────────────────
# Sets up networking (VPC, subnets, NAT) and an EKS cluster with OIDC enabled.
# The OIDC provider lets us wire Entra ID tokens to Kubernetes RBAC.
# Entra ID federation via IAM Identity Center requires manual console steps
# (see comment block at the bottom of this file).

locals {
  name_prefix     = "${var.project_name}-${var.environment}"
  vpc_cidr        = "10.20.0.0/16"
  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24"]
}

# ── VPC ────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${local.name_prefix}-igw" })

  # Must be destroyed after EKS cluster (and its LB cleanup provisioner) so
  # mapped public addresses from ELBs are gone before IGW detaches.
  depends_on = [aws_eks_cluster.main]
}

# ── Public Subnets (NAT gateway + load balancers) ─────────────────────────────

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${local.name_prefix}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  })

  # Destroyed after EKS cluster so the LB cleanup provisioner runs first,
  # releasing ENIs that Kubernetes ELBs attached to these public subnets.
  depends_on = [aws_eks_cluster.main]
}

# ── Private Subnets (EKS nodes live here) ─────────────────────────────────────

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${local.name_prefix}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# ── NAT Gateway (single, to reduce cost in lab) ───────────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${local.name_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${local.name_prefix}-nat" })

  # Destroyed after EKS cluster to ensure all ELB resources are released first.
  depends_on = [aws_internet_gateway.main, aws_eks_cluster.main]
}

# ── Route Tables ───────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${local.name_prefix}-public-rt" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${local.name_prefix}-private-rt" })

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ────────────────────────────────────────────────────────────

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name_prefix}-eks-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-eks-cluster-sg" })
}

resource "aws_security_group" "eks_nodes" {
  name        = "${local.name_prefix}-eks-nodes-sg"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow inter-node communication"
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
    description     = "Allow control plane to communicate with nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-eks-nodes-sg" })
}

# ── IAM: EKS Cluster Role ──────────────────────────────────────────────────────

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM: EKS Node Group Role ───────────────────────────────────────────────────

data "aws_iam_policy_document" "eks_nodes_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name               = "${local.name_prefix}-eks-nodes-role"
  assume_role_policy = data.aws_iam_policy_document.eks_nodes_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = "${local.name_prefix}-eks"
  version  = "1.30"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  # Delete ELBs that Kubernetes created outside Terraform before network teardown.
  # Without this, subnet/IGW deletion fails because ENIs from those ELBs remain attached.
  # var.* is forbidden in destroy provisioners; region is extracted from self.arn instead.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up EKS-managed load balancers..."
      REGION=$(echo "${self.arn}" | cut -d: -f4)
      for lb in $(aws elb describe-load-balancers --region $REGION --query "LoadBalancerDescriptions[?VPCId=='${self.vpc_config[0].vpc_id}'].LoadBalancerName" --output text 2>/dev/null); do
        aws elb delete-load-balancer --load-balancer-name $lb --region $REGION 2>/dev/null
      done
      echo "Waiting for ENIs to release..."
      sleep 60
    EOT
  }
}

# ── OIDC Provider (enables K8s RBAC tokens to be validated against Entra ID) ──

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# ── EKS Managed Node Group ────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

# ── MANUAL STEPS: Entra ID Federation via AWS IAM Identity Center ──────────────
# AWS IAM Identity Center (SSO) does not support full Terraform automation for
# external OIDC/SAML identity providers. After applying this Terraform:
#
# 1. AWS Console → IAM Identity Center → Settings → Identity source
# 2. Change identity source to "External identity provider"
# 3. Download the IAM Identity Center SAML metadata XML
# 4. Entra ID portal → Enterprise Applications → New application (non-gallery)
# 5. Upload the AWS SAML metadata and configure attribute mappings:
#    - NameID format: emailAddress → user.userprincipalname
#    - https://aws.amazon.com/SAML/Attributes/Role → mapped to AWS IAM roles
# 6. Assign Entra ID groups (Cloud-Admins, Cloud-Developers) to the application
# 7. Back in AWS, upload the Entra ID federation metadata XML
# 8. Create permission sets in IAM Identity Center for each Kubernetes role
#
# The OIDC provider created above (aws_iam_openid_connect_provider.eks) enables
# EKS to validate Kubernetes service account tokens — apply k8s/rbac.yaml after
# substituting the Entra ID group object IDs into the ClusterRoleBindings.
