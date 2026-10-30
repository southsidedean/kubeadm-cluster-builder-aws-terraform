# Tests for main.tf with every provider mocked: no AWS account, no network, and
# no files written. Run from the terraform directory with "terraform test"
# (Terraform 1.7 or newer). CI runs them on every pull request.

mock_provider "aws" {
  override_data {
    target = data.aws_ami.ubuntu_ami
    values = {
      id = "ami-0123456789abcdef0"
    }
  }
}

mock_provider "http" {
  override_data {
    target = data.http.my_ip[0]
    values = {
      response_body = "203.0.113.7\n"
    }
  }
}

mock_provider "local" {}
mock_provider "random" {}
mock_provider "tls" {}

# -------------------------
# Who can reach the nodes
# -------------------------

run "defaults_allow_only_your_ip" {
  command = plan

  assert {
    condition     = local.admin_cidrs == tolist(["203.0.113.7/32"])
    error_message = "With admin_cidrs empty, only the address from checkip.amazonaws.com should be allowed."
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.ssh) == ["203.0.113.7/32"]
    error_message = "SSH should be open to your address only."
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.kube_api) == ["203.0.113.7/32"]
    error_message = "The Kubernetes API should be open to your address only."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.ssh["203.0.113.7/32"].from_port == 22 &&
      aws_vpc_security_group_ingress_rule.ssh["203.0.113.7/32"].to_port == 22 &&
      aws_vpc_security_group_ingress_rule.kube_api["203.0.113.7/32"].from_port == 6443 &&
      aws_vpc_security_group_ingress_rule.kube_api["203.0.113.7/32"].to_port == 6443
    )
    error_message = "The rules from your address should cover port 22 and port 6443 only."
  }
}

run "admin_cidrs_replace_your_ip" {
  command = plan

  variables {
    admin_cidrs = ["198.51.100.0/24", "192.0.2.10/32"]
  }

  assert {
    condition     = length(data.http.my_ip) == 0
    error_message = "Terraform shouldn't look up your address when admin_cidrs is set."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.ssh)) == toset(["198.51.100.0/24", "192.0.2.10/32"])
    error_message = "SSH should be open to each admin_cidrs block and nothing else."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.kube_api)) == toset(["198.51.100.0/24", "192.0.2.10/32"])
    error_message = "The Kubernetes API should be open to each admin_cidrs block and nothing else."
  }
}

run "nodes_reach_each_other" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nodes_from_nodes.ip_protocol == "-1"
    error_message = "The nodes should be able to reach each other on any port."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nodes_from_nodes.cidr_ipv4 == null
    error_message = "The rule between nodes should reference the security group, not an address range."
  }
}

run "admin_cidrs_must_be_ipv4_cidrs" {
  command = plan

  variables {
    admin_cidrs = ["203.0.113.7"]
  }

  expect_failures = [var.admin_cidrs]
}

# -------------------------
# The nodes
# -------------------------

run "nodes_are_locked_down" {
  command = plan

  assert {
    condition = alltrue([
      for i in concat([aws_instance.control_plane], aws_instance.worker) :
      i.metadata_options[0].http_tokens == "required" && i.metadata_options[0].http_put_response_hop_limit == 1
    ])
    error_message = "Every node should require IMDSv2 tokens with a hop limit of 1."
  }

  assert {
    condition = alltrue([
      for i in concat([aws_instance.control_plane], aws_instance.worker) :
      i.root_block_device[0].encrypted && i.root_block_device[0].volume_type == "gp3"
    ])
    error_message = "Every node's root disk should be an encrypted gp3 volume."
  }

  assert {
    condition     = !strcontains(local.user_data, "PRIVATE KEY")
    error_message = "The user data must not contain a private key."
  }
}

run "ami_is_canonical_ubuntu_amd64" {
  command = plan

  variables {
    ubuntu_version = "26.04"
  }

  assert {
    condition     = data.aws_ami.ubuntu_ami.owners == tolist(["099720109477"])
    error_message = "The image should come from Canonical's AWS account."
  }

  assert {
    condition = anytrue([
      for f in data.aws_ami.ubuntu_ami.filter :
      f.name == "name" && strcontains(one(f.values), "-26.04-amd64-server-")
    ])
    error_message = "The image name filter should follow ubuntu_version and match amd64 Server images only."
  }
}

# -------------------------
# Worker count, outputs, and the configuration file
# -------------------------

run "one_worker" {
  variables {
    worker_count = 1
  }

  assert {
    condition     = length(output.workers) == 1
    error_message = "The workers output should list one worker."
  }

  assert {
    condition     = strcontains(local_file.cluster_configuration.content, "[worker-0-networking]") && !strcontains(local_file.cluster_configuration.content, "[worker-1-networking]")
    error_message = "The configuration file should list exactly one worker."
  }
}

run "five_workers" {
  variables {
    worker_count = 5
  }

  assert {
    condition     = length(aws_instance.worker) == 5 && length(output.workers) == 5
    error_message = "worker_count = 5 should build and list five workers."
  }

  assert {
    condition     = strcontains(local_file.cluster_configuration.content, "[worker-4-networking]") && !strcontains(local_file.cluster_configuration.content, "[worker-5-networking]")
    error_message = "The configuration file should list workers 0 to 4."
  }

  assert {
    condition     = !strcontains(local_file.cluster_configuration.content, "PRIVATE KEY")
    error_message = "The configuration file must not contain the private key."
  }
}

run "worker_count_must_be_positive" {
  command = plan

  variables {
    worker_count = 0
  }

  expect_failures = [var.worker_count]
}
