# -------------------------
# Open source K8s lab deployment
# for CNCF CKA/D labs
# Ubuntu 22.04
# Tom Dean
# Last updated 12/31/2023
# -------------------------

# ========================
# Set AWS Terraform Provider
# ========================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ========================
# Configure the AWS Provider
# Set Region in the aws_region
# variable in Cluster Variables
# ========================

provider "aws" {
  region = var.aws_region
}

# ========================
# AMI Finder - Latest Ubuntu 22.04
# ========================

data "aws_ami" "ubuntu_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["*ubuntu*22*04*server*"]
  }

  owners = ["099720109477"]
}

# -------------------------
# Cluster Variables
# Change these values here!!
# -------------------------

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "owner" {
  type    = string
  default = "USER"
}

variable "control_plane_count" {
  type    = number
  default = 1
}

variable "control_plane_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

# -------------------------
# Course wide VPC variables
# -------------------------

variable "subnet_range" {
  type    = string
  default = "10.0.0.0/24"
}

variable "route_destination_cidr_block" {
  type    = string
  default = "0.0.0.0/0"
}

variable "class_name" {
  type    = string
  default = "cka"
}

# -------------------------
# Keypair Resources: cluster_key
# This is the keypair for the student to use for labs
# -------------------------

resource "tls_private_key" "cluster_key" {
  algorithm = "ED25519"
  ecdsa_curve = "P256"
}

resource "aws_key_pair" "cluster_key" {
  key_name_prefix = "cluster_key_"
  public_key      = tls_private_key.cluster_key.public_key_openssh
}

# -------------------------
# Generate a random string for cluster name
# No two clusters shall be named the same!
# -------------------------

resource "random_pet" "pet" {
  length    = 2
  separator = "-"
}

locals {
  cluster_name = random_pet.pet.id
}

# -------------------------
# Pull AWS Account ID for future use
# We might need this
# -------------------------

data "aws_caller_identity" "current" {}

# -------------------------
# IAM Polices/Roles/Instance Profiles
# All Host(s)
# kubeadm-labs-role
# -------------------------
# Create instance-assume-role-policy
# We will need this to create the IAM Roles
# -------------------------

data "aws_iam_policy_document" "instance-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# -------------------------
# Create kubeadm-control-plane-roles
# Control Plane Policy
# -------------------------

resource "aws_iam_role" "kubeadm-control-plane-role" {
  name                 = "kubeadm-control-plane-role"
  assume_role_policy   = data.aws_iam_policy_document.instance-assume-role-policy.json
  inline_policy {
    name = "kubeadm-control-plane-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = [
            "ec2:*",
            "elasticloadbalancing:*",
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:GetRepositoryPolicy",
            "ecr:DescribeRepositories",
            "ecr:ListImages",
            "ecr:BatchGetImage"
            ]
          Resource = "*"
        }
      ]
    })
  }
}

# -------------------------
# Create kubeadm-worker-roles
# Worker Node Policy
# -------------------------

resource "aws_iam_role" "kubeadm-worker-role" {
  name                 = "kubeadm-worker-role"
  assume_role_policy   = data.aws_iam_policy_document.instance-assume-role-policy.json
  inline_policy {
    name = "kubeadm-worker-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = [
            "ec2:Describe*",
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:GetRepositoryPolicy",
            "ecr:DescribeRepositories",
            "ecr:ListImages",
            "ecr:BatchGetImage"
            ]
          Resource = "*"
        }
      ]
    })
  }
}


# -------------------------
# IAM Instance Profile
# This is where we attach our kubeadm-control-plane-role
# and kubeadm-worker-role Roles to our
# kubeadm-control-plane-role-instance-profile and
# kubeadm-worker-role-instance-profile Instance Profiles
# These Instance Profiles are consumed by the EC2 Instances (Control Plane/Worker)
# -------------------------

resource "aws_iam_instance_profile" "kubeadm-control-plane-role-instance-profile" {
  name = "kubeadm-control-plane-role-instance-profile"
  role = aws_iam_role.kubeadm-control-plane-role.name
}
resource "aws_iam_instance_profile" "kubeadm-worker-role-instance-profile" {
  name = "kubeadm-worker-role-instance-profile"
  role = aws_iam_role.kubeadm-worker-role.name
}

# -------------------------
# VPC
# -------------------------

resource "aws_vpc" "course_vpc" {
  cidr_block = var.subnet_range

  tags = {
    Name = "${var.class_name}-vpc-${local.cluster_name}",
    KubernetesCluster = local.cluster_name
  }
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# -------------------------
# Subnet + Routes
# -------------------------

resource "aws_subnet" "course_subnet" {
  vpc_id     = aws_vpc.course_vpc.id
  cidr_block = var.subnet_range

  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${var.class_name}-${local.cluster_name}-subnet",
    "kubernetes.io/cluster"                       = local.cluster_name,
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "KubernetesCluster"                           = local.cluster_name
  }
}

resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.course_vpc.id
}

resource "aws_route_table" "course_public_rt" {
  vpc_id = aws_vpc.course_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default.id
  }

  lifecycle {
    ignore_changes = [route, tags]
  }

  tags = {
    "Name"                                        = "${var.class_name}-${local.cluster_name}-routetable",
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "kubernetes.io/cluster"                       = "${local.cluster_name}",
    "KubernetesCluster"                           = local.cluster_name
  }
}

resource "aws_route_table_association" "course_public_rta" {
  subnet_id      = aws_subnet.course_subnet.id
  route_table_id = aws_route_table.course_public_rt.id
}

# -------------------------
# Security Groups
# -------------------------

resource "aws_security_group" "common" {
  name        = "${var.class_name}-${local.cluster_name}-common-firewall"
  description = "Allow common ports (e.g. 22/tcp)"
  vpc_id      = aws_vpc.course_vpc.id

  ingress {
    description = "All Ingress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All Egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "kubernetes.io/cluster"                       = local.cluster_name,
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "KubernetesCluster"                           = local.cluster_name
  }
}

resource "aws_security_group" "cluster_ssh" {
  name        = "${var.class_name}-${local.cluster_name}-ssh"
  description = "Allow inbound SSH."
  vpc_id      = aws_vpc.course_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name                = "${var.class_name}-${local.cluster_name}-sg-ssh",
    "KubernetesCluster" = local.cluster_name
  }
}

resource "aws_security_group" "elb_control_plane" {
  name        = "${var.class_name}-${local.cluster_name}-cp"
  description = "Allow traffic to control plane"
  vpc_id      = aws_vpc.course_vpc.id

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                = "${var.class_name}-${local.cluster_name}-cp",
    "KubernetesCluster" = local.cluster_name
  }
}

# -------------------------
# Control Plane Instance
# Yes just one, this is a lab!
# -------------------------

resource "aws_instance" "control_plane" {
  count         = var.control_plane_count
  ami           = data.aws_ami.ubuntu_ami.id
  instance_type = var.control_plane_instance_type
  subnet_id     = aws_subnet.course_subnet.id
  key_name      = aws_key_pair.cluster_key.key_name
  vpc_security_group_ids = [
    aws_security_group.common.id,
    aws_security_group.cluster_ssh.id,
    aws_security_group.elb_control_plane.id
  ]
  iam_instance_profile = aws_iam_instance_profile.kubeadm-control-plane-role-instance-profile.name

  associate_public_ip_address = true
  root_block_device {
    volume_size           = 80
    volume_type           = "gp2"
    delete_on_termination = true
  }

  tags = {
    Class                                         = var.class_name,
    Name                                          = "${var.class_name}-${local.cluster_name}-control-plane",
    Cluster                                       = local.cluster_name,
    "KubernetesCluster"                           = local.cluster_name,
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "kubernetes.io/cluster"                       = "${local.cluster_name}",
    "kubeadm/nodeRoles"                            = "control_plane",
    ci-key-username                               = "ubuntu"
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  user_data = <<EOF
#!/usr/bin/bash
sudo apt-get update && sudo apt-get upgrade -y
echo "${tls_private_key.cluster_key.private_key_openssh}" > /home/ubuntu/cluster_key.priv
echo "${tls_private_key.cluster_key.private_key_pem}" > /home/ubuntu/cluster_key.pem
echo "${tls_private_key.cluster_key.public_key_pem}" > /home/ubuntu/cluster_key.pub
chmod 600 /home/ubuntu/cluster_key.*
chown ubuntu:ubuntu /home/ubuntu/cluster_key.*
EOF
}

# -------------------------
# Worker Instances
# Two, by default
# -------------------------

resource "aws_instance" "worker" {
  count         = var.worker_count
  ami           = data.aws_ami.ubuntu_ami.id
  instance_type = var.worker_instance_type
  subnet_id     = aws_subnet.course_subnet.id
  key_name      = aws_key_pair.cluster_key.key_name
  vpc_security_group_ids = [
    aws_security_group.common.id,
    aws_security_group.cluster_ssh.id
  ]
  iam_instance_profile        = aws_iam_instance_profile.kubeadm-worker-role-instance-profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 160
    volume_type           = "gp2"
    delete_on_termination = true
  }

  tags = {
    Class                                         = var.class_name,
    Name                                          = "${var.class_name}-${local.cluster_name}-worker-${count.index}",
    Cluster                                       = local.cluster_name,
    "KubernetesCluster"                           = local.cluster_name,
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "kubernetes.io/cluster"                       = "${local.cluster_name}",
    "kubeadm/nodeRoles"                            = "worker_node",
    ci-key-username                               = "ubuntu"
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  user_data = <<EOF
#!/usr/bin/bash
sudo apt-get update && sudo apt-get upgrade -y
echo "${tls_private_key.cluster_key.private_key_openssh}" > /home/ubuntu/cluster_key.priv
echo "${tls_private_key.cluster_key.private_key_pem}" > /home/ubuntu/cluster_key.pem
echo "${tls_private_key.cluster_key.public_key_pem}" > /home/ubuntu/cluster_key.pub
chmod 600 /home/ubuntu/cluster_key.*
chown ubuntu:ubuntu /home/ubuntu/cluster_key.*
EOF
}

# -------------------------
# Outputs
# -------------------------

output "cluster_name" {
  value = local.cluster_name
}

output "cluster_key_name" {
  value = "${trimspace(aws_key_pair.cluster_key.key_name)}"
}

output "cluster_private_key_openssh" {
  value = tls_private_key.cluster_key.private_key_openssh
  sensitive = false
}

output "control_plane_public_ip" {
  value = aws_instance.control_plane[0].public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane[0].private_ip
}

output "worker_0_public_ip" {
  value = aws_instance.worker[0].public_ip
}

output "worker_0_private_ip" {
  value = aws_instance.worker[0].private_ip
}

output "worker_1_public_ip" {
  value = aws_instance.worker[1].public_ip
}

output "worker_1_private_ip" {
  value = aws_instance.worker[1].private_ip
}

# -------------------------
# Create Configuration Text File
# -------------------------

resource "local_file" "cluster_configuration" {
  filename = "${local.cluster_name}-configuration.txt"
  content = templatefile(
    abspath("${path.root}/configuration.tpl"),
    {
      cluster_name              = local.cluster_name,
      cluster_key_name          = "${trimspace(aws_key_pair.cluster_key.key_name)}",
      cluster_private_key_openssh = tls_private_key.cluster_key.private_key_openssh
      control_plane_public_ips  = aws_instance.control_plane[0].public_ip,
      control_plane_private_ips = aws_instance.control_plane[0].private_ip,
      worker_0_public_ip        = aws_instance.worker[0].public_ip,
      worker_0_private_ip       = aws_instance.worker[0].private_ip,
      worker_1_public_ip        = aws_instance.worker[1].public_ip,
      worker_1_private_ip       = aws_instance.worker[1].private_ip
    }
  )
}

# -------------------------
# Create SSH Key Files
# -------------------------

resource "local_file" "ssh_key_private" {
  filename        = "./cluster_key.priv"
  content         = tls_private_key.cluster_key.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "ssh_key_public" {
  filename        = "./cluster_key.pub"
  content         = tls_private_key.cluster_key.public_key_openssh
  file_permission = "0600"
}
