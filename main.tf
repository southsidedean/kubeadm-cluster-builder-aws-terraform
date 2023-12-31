# -------------------------
# Open source K8s lab deployment for CNCF labs
# Ubuntu 22.04
# Tom Dean
# Last updated 12/30/2023
# -------------------------

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

#variable "control_plane_key" {
#  type    = string
#  default = "cluster_key"
#}

variable "worker_count" {
  type    = number
  default = 2
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

#variable "worker_key" {
#  type    = string
#  default = "cluster_key"
#}

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
  default = "CKA/D"
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

output "cluster_key_name" {
  value = "${trimspace(aws_key_pair.cluster_key.key_name)}"
}

output "cluster_key_pem" {
  value = "${trimspace(aws_key_pair.cluster_key.public_key_pem)}"
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
# We'll need this!!
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
# Create kubeadm-labs-role
# Very liberal, with guardrails set by the permissions_boundary
# -------------------------

resource "aws_iam_role" "kubeadm-labs-role" {
  name                 = "kubeadm-labs-role"
  assume_role_policy   = data.aws_iam_policy_document.instance-assume-role-policy.json
#  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/BoundaryForAdministratorAccess"
  inline_policy {
    name = "kubeadm-admin-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = ""
          Effect   = "Allow"
          Action   = ["*"]
          Resource = "*"
        }
      ]
    })
  }
}

# -------------------------
# IAM Instance Profile
# This is where we attach our kubeadm-labs-role Role to our kubeadm-labs-role-instance-profile Instance Profile
# The kubeadm-labs-role-instance-profile Instance Profile is consumed by the EC2 Instances (Control Plane/Worker)
# -------------------------

resource "aws_iam_instance_profile" "kubeadm-labs-role-instance-profile" {
  name = "kubeadm-labs-role-instance-profile"
  role = aws_iam_role.kubeadm-labs-role.name
}

# -------------------------
# VPC
# -------------------------

resource "aws_vpc" "course_vpc" {
  cidr_block = var.subnet_range

  tags = {
    Name = "${var.class_name}-vpc-${local.cluster_name}"
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
    Name                                          = "${var.class_name}-${local.cluster_name}-subnet"
    "kubernetes.io/cluster"                       = local.cluster_name
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
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
    "Name" : "${var.class_name}-${local.cluster_name}-routetable",
    "kubernetes.io/cluster/${local.cluster_name}" : "owned",
    "kubernetes.io/cluster" : "${local.cluster_name}"
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
    "kubernetes.io/cluster"                       = local.cluster_name
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
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
    Name = "${var.class_name}-${local.cluster_name}-sg-ssh"
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
    Name = "${var.class_name}-${local.cluster_name}-cp"
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
  iam_instance_profile = aws_iam_instance_profile.kubeadm-labs-role-instance-profile.name

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
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "kubernetes.io/cluster"                       = "${local.cluster_name}",
    "kubeadm/nodeRoles"                            = "control_plane",
    ci-key-username                               = "ec2-user"
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  user_data = <<EOF
#!/usr/bin/bash
echo "${tls_private_key.cluster_key.private_key_pem}" > /home/ec2-user/cluster_key.pem
echo "${tls_private_key.cluster_key.public_key_pem}" > /home/ec2-user/cluster_key.pub
chmod 600 /home/ec2-user/cluster_key.pem
chown ec2-user:ec2-user /home/ec2-user/cluster_key.*
EOF
}

# -------------------------
# Worker Instances
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
  iam_instance_profile        = aws_iam_instance_profile.kubeadm-labs-role-instance-profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 160
    volume_type           = "gp2"
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/xvda"
    volume_size           = 500
    volume_type           = "gp2"
    delete_on_termination = true
  }

  tags = {
    Class                                         = var.class_name,
    Name                                          = "${var.class_name}-${local.cluster_name}-worker-${count.index}",
    Cluster                                       = local.cluster_name,
    "kubernetes.io/cluster/${local.cluster_name}" = "owned",
    "kubernetes.io/cluster"                       = "${local.cluster_name}",
    "kubeadm/nodeRoles"                            = "worker_node",
    ci-key-username                               = "ec2-user"
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  user_data = <<EOF
#!/usr/bin/bash
echo "${tls_private_key.cluster_key.private_key_pem}" > /home/ec2-user/cluster_key.pem
echo "${tls_private_key.cluster_key.public_key_pem}" > /home/ec2-user/cluster_key.pub
chmod 600 /home/ec2-user/cluster_key.pem
chown ec2-user:ec2-user /home/ec2-user/cluster_key.*
sudo mkdir -p /mnt/disks/data-vol-01
sudo mkfs.ext4 /dev/nvme1n1
echo '/dev/nvme1n1 /mnt/disks/data-vol-01 ext4 defaults 0 2' | sudo tee -a /etc/fstab > /dev/null
sudo mount -a
EOF
}
