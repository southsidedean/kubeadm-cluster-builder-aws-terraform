# -------------------------
# Open source K8s lab deployment
# for CNCF CKA/D labs
# Tom Dean
# Last updated 10/30/2026
# -------------------------

# ========================
# Terraform Providers
# ========================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ========================
# Configure the AWS Provider
# Set Region in the aws_region
# variable in Cluster Variables
# Every resource gets the Class and Cluster tags
# ========================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Class   = var.class_name
      Cluster = local.cluster_name
    }
  }
}

# -------------------------
# Cluster Variables
# Change these values here!!
# -------------------------

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "ubuntu_version" {
  type    = string
  default = "22.04"
}

variable "control_plane_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_count" {
  type    = number
  default = 2

  validation {
    condition     = var.worker_count >= 1 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count must be a whole number, 1 or more."
  }
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

# Where you can reach the nodes from (SSH and the Kubernetes API).
# Leave it empty to allow only the public IP address you run Terraform from.
variable "admin_cidrs" {
  type    = list(string)
  default = []

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":")])
    error_message = "admin_cidrs must be IPv4 CIDR blocks, such as 203.0.113.7/32."
  }
}

# -------------------------
# Course wide VPC variables
# -------------------------

variable "subnet_range" {
  type    = string
  default = "10.0.0.0/24"
}

variable "class_name" {
  type    = string
  default = "cka"
}

# ========================
# AMI Finder - Latest Ubuntu Server for amd64
# Published by Canonical
# ========================

data "aws_ami" "ubuntu_ami" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-${var.ubuntu_version}-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -------------------------
# Your public IP address, for the security group
# Used only when admin_cidrs is empty
# -------------------------

data "http" "my_ip" {
  count = length(var.admin_cidrs) > 0 ? 0 : 1
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidrs = length(var.admin_cidrs) > 0 ? var.admin_cidrs : ["${chomp(data.http.my_ip[0].response_body)}/32"]
}

# -------------------------
# Keypair Resources: cluster_key
# This is the keypair for the student to use for labs
# -------------------------

resource "tls_private_key" "cluster_key" {
  algorithm = "ED25519"
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
# VPC
# -------------------------

resource "aws_vpc" "course_vpc" {
  cidr_block           = var.subnet_range
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.class_name}-vpc-${local.cluster_name}"
  }
}

# -------------------------
# Subnet + Routes
# -------------------------

# The nodes have public IP addresses so you can SSH to them directly.
# The security group below limits who can reach them.
#trivy:ignore:AVD-AWS-0164
resource "aws_subnet" "course_subnet" {
  vpc_id                  = aws_vpc.course_vpc.id
  cidr_block              = var.subnet_range
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.class_name}-${local.cluster_name}-subnet"
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

  tags = {
    Name = "${var.class_name}-${local.cluster_name}-routetable"
  }
}

resource "aws_route_table_association" "course_public_rta" {
  subnet_id      = aws_subnet.course_subnet.id
  route_table_id = aws_route_table.course_public_rt.id
}

# -------------------------
# Security Group
# The nodes can reach each other on any port, you can reach them
# on SSH and the Kubernetes API, and nothing else gets in
# -------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.class_name}-${local.cluster_name}-nodes"
  description = "Cluster nodes"
  vpc_id      = aws_vpc.course_vpc.id

  tags = {
    Name = "${var.class_name}-${local.cluster_name}-nodes"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_nodes" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Any traffic between the nodes"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(local.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  description       = "SSH from you"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each          = toset(local.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  description       = "Kubernetes API from you"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

# The nodes download packages and container images from the internet.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  description       = "Any outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -------------------------
# Node settings shared by the control plane and the workers
# Update the packages, then reboot in case of a new kernel
# -------------------------

locals {
  user_data = <<-EOF
    #!/usr/bin/bash
    apt-get update && apt-get upgrade -y
    systemctl reboot
  EOF
}

# -------------------------
# Control Plane Instance
# Yes just one, this is a lab!
# -------------------------

resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.ubuntu_ami.id
  instance_type          = var.control_plane_instance_type
  subnet_id              = aws_subnet.course_subnet.id
  key_name               = aws_key_pair.cluster_key.key_name
  vpc_security_group_ids = [aws_security_group.nodes.id]
  user_data              = local.user_data

  # Instance metadata only with a session token, and not from inside pods
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 80
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.class_name}-${local.cluster_name}-control-plane"
    Role = "control-plane"
  }

  # Keep the nodes when a newer Ubuntu image comes out
  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

# -------------------------
# Worker Instances
# Two, by default
# -------------------------

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu_ami.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.course_subnet.id
  key_name               = aws_key_pair.cluster_key.key_name
  vpc_security_group_ids = [aws_security_group.nodes.id]
  user_data              = local.user_data

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 160
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.class_name}-${local.cluster_name}-worker-${count.index}"
    Role = "worker"
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

# -------------------------
# Outputs
# -------------------------

output "cluster_name" {
  value = local.cluster_name
}

output "cluster_key_name" {
  value = aws_key_pair.cluster_key.key_name
}

output "cluster_private_key_openssh" {
  value     = tls_private_key.cluster_key.private_key_openssh
  sensitive = true
}

locals {
  addresses = {
    for name, i in merge({ control_plane = aws_instance.control_plane }, { for n, w in aws_instance.worker : "worker_${n}" => w }) :
    name => {
      public_dns  = i.public_dns
      public_ip   = i.public_ip
      private_dns = i.private_dns
      private_ip  = i.private_ip
    }
  }
}

output "control_plane" {
  value = local.addresses["control_plane"]
}

output "workers" {
  value = [for n in range(var.worker_count) : local.addresses["worker_${n}"]]
}

output "admin_cidrs" {
  value = local.admin_cidrs
}

# -------------------------
# Create Configuration Text File
# -------------------------

resource "local_file" "cluster_configuration" {
  filename        = "${path.root}/${local.cluster_name}-configuration.txt"
  file_permission = "0644"
  content = templatefile("${path.root}/configuration.tpl", {
    cluster_name     = local.cluster_name
    cluster_key_name = aws_key_pair.cluster_key.key_name
    control_plane    = local.addresses["control_plane"]
    workers          = [for n in range(var.worker_count) : local.addresses["worker_${n}"]]
  })
}

# -------------------------
# Create SSH Key Files
# -------------------------

resource "local_sensitive_file" "ssh_key_private" {
  filename        = "${path.root}/cluster_key.priv"
  content         = tls_private_key.cluster_key.private_key_openssh
  file_permission = "0400"
}

resource "local_file" "ssh_key_public" {
  filename        = "${path.root}/cluster_key.pub"
  content         = tls_private_key.cluster_key.public_key_openssh
  file_permission = "0444"
}
