# Changelog

## 0.2.1 (unreleased)

The Terraform is safer and current. The Kubernetes steps in the README are still the 2023 ones; 0.3.0 updates them.

### Upgrading from 0.2.0

Run `terraform destroy` on any nodes built with 0.2.0 before you pull this release. Then run `terraform init -upgrade` for the new providers, and `terraform apply`.

### Fixes

- Only the public IP address you run Terraform from can reach the nodes, and only on SSH and the Kubernetes API. Before, every port on every node was open to the internet. The nodes can still reach each other on any port. Set `admin_cidrs` to allow other addresses.
- The cluster's SSH private key is no longer copied onto the nodes through user data, where anything on a node could read it from the instance metadata service.
- The nodes no longer get IAM roles. The control plane's role allowed every EC2 action, and kubeadm without a cloud provider doesn't use them. Their fixed names also stopped a second cluster from being built in the same account.
- The instance metadata service needs a session token (IMDSv2), and pods on the pod network can't reach it. Disks are encrypted gp3 volumes instead of gp2.
- The Ubuntu image lookup matches only Canonical's Ubuntu Server images for amd64. The old filter also matched the arm64 images, which don't run on the t3 instance types the lab uses.
- The outputs and the configuration file list every worker, so `worker_count` works with any number. The configuration file no longer includes the private key; Terraform saves it to `cluster_key.priv`.
- The README says to `cd terraform` before running Terraform.

### New

- AWS provider 6, and every provider the lab uses is pinned.
- The README's prerequisites cover setting up your workstation on Linux (Ubuntu, Rocky Linux, RHEL, AlmaLinux) or macOS: Terraform from HashiCorp's packages, the AWS CLI version 2, and signing in to AWS. Tested on Ubuntu 26.04, Rocky Linux 10.2, and macOS 26.
- An `ubuntu_version` variable for the node image.
- Terraform checks `worker_count` (a whole number, 1 or more) and `admin_cidrs` (IPv4 CIDR blocks) before building anything.
- Tests for the Terraform (`terraform test`, in `terraform/tests`) that need no AWS account. They check who can reach the nodes, the node settings, the Ubuntu image lookup, and that the outputs work with one worker or five.
- The lab is MIT licensed.
- Checks on every pull request: Terraform formatting, validation, and tests, TFLint, a Trivy scan, Markdown lint, spelling, and the workflows themselves. A weekly check reports when the Kubernetes, Calico, or Ubuntu versions the lab uses fall behind.

### Removed

- The `control_plane_count` variable. The lab always builds one control plane node, and the rest of the code assumed one.

## 0.2.0 (2023-12-31)

The lab as published in December 2023: Terraform that builds one control plane node and two worker nodes on EC2 in their own VPC, and a README that walks through building a Kubernetes 1.26 cluster with kubeadm. Tagged in 2026 as a snapshot from before the refresh.
