# FIS Infrastructure for EKS Hybrid Nodes Resilience Demo
#
# Creates:
#   1. Customer-managed Prefix List with the on-premises CIDRs
#   2. FIS IAM Role (with AWSFaultInjectionSimulatorNetworkAccess)
#   3. FIS Experiment Template using aws:network:disrupt-connectivity
#   4. CloudWatch Log Group
#
# HOW THE FAULT WORKS:
#   The aws:network:disrupt-connectivity action (scope=prefix-list) injects
#   temporary Network ACL rules on the TARGET SUBNETS that DENY all traffic
#   to/from the CIDRs in the prefix list (the on-premises networks).
#
#   Targeting the EKS cluster subnets blocks:
#     - EKS control plane ENIs → hybrid node kubelet   (node goes NotReady)
#     - Gateway Nodes → on-prem VXLAN                  (pod-to-pod cross-cluster fails)
#
#   This correctly simulates "the link between AWS and the datacenter is down"
#   affecting BOTH the control plane path and the data path.
#
#   NOTE: A blackhole applied on the Gateway Nodes only (previous design) would
#   NOT make the node NotReady, because the kubelet heartbeat path
#   (hybrid node → EKS API endpoint) does not traverse the Gateway Nodes.
#
# The fault auto-reverts after `fault_duration_seconds`. FIS restores the
# original network ACLs automatically (also on manual stop-experiment).
#
# Usage:
#   terraform init
#   terraform apply -var="cluster_name=llm-vmware-hybrid" -var="region=sa-east-1"

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "auto-delete" = "no"
      demo          = "hybrid-resilience-demo"
      owner         = "lopbruno"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region where the EKS cluster lives"
  type        = string
  default     = "sa-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster"
  type        = string
  default     = "llm-vmware-hybrid"
}

variable "onprem_node_cidr" {
  description = "On-premises node CIDR (RemoteNodeNetwork)"
  type        = string
  default     = "192.168.3.0/24"
}

variable "remote_pod_cidr" {
  description = "On-premises pod CIDR (RemotePodNetwork)"
  type        = string
  default     = "10.201.0.0/16"
}

variable "fault_duration_minutes" {
  description = "Duration of the network fault in minutes (FIS auto-reverts after this)"
  type        = number
  default     = 60
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Discover the EKS cluster subnets automatically
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  name       = "hybrid-resilience-demo"
  subnet_ids = data.aws_eks_cluster.this.vpc_config[0].subnet_ids
  tags = {
    Project       = "hybrid-resilience-demo"
    Environment   = "demo"
    ManagedBy     = "terraform"
    "auto-delete" = "no"
  }
}

# ─── Prefix List with On-Premises CIDRs ──────────────────────────────────────

resource "aws_ec2_managed_prefix_list" "onprem" {
  name           = "${local.name}-onprem-cidrs"
  address_family = "IPv4"
  max_entries    = 5

  entry {
    cidr        = var.onprem_node_cidr
    description = "On-premises node network (RemoteNodeNetwork)"
  }

  entry {
    cidr        = var.remote_pod_cidr
    description = "On-premises pod network (RemotePodNetwork)"
  }

  tags = local.tags
}

# ─── FIS IAM Role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "fis" {
  name = "${local.name}-fis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "fis.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })

  tags = local.tags
}

# AWS managed policy for FIS network actions (includes NACL manipulation)
resource "aws_iam_role_policy_attachment" "fis_network" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess"
}

resource "aws_iam_role_policy" "fis_logs" {
  name = "${local.name}-fis-logs"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${local.account_id}:log-group:/fis/*"
      }
    ]
  })
}

# ─── CloudWatch Log Group ────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/fis/${local.name}"
  retention_in_days = 7
  tags              = local.tags
}

# ─── FIS Experiment Template ─────────────────────────────────────────────────
# aws:network:disrupt-connectivity (scope=prefix-list) on the EKS cluster subnets.
# Denies all traffic to/from on-prem CIDRs = simulates AWS↔DC link failure.

resource "aws_fis_experiment_template" "network_disconnect" {
  description = "Block all traffic between AWS and on-premises CIDRs (simulates hybrid link failure)"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  target {
    name           = "cluster-subnets"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"

    resource_arns = [
      for subnet_id in local.subnet_ids :
      "arn:aws:ec2:${data.aws_region.current.region}:${local.account_id}:subnet/${subnet_id}"
    ]
  }

  action {
    name      = "disrupt-onprem-connectivity"
    action_id = "aws:network:disrupt-connectivity"

    parameter {
      key   = "duration"
      value = "PT${var.fault_duration_minutes}M"
    }

    parameter {
      key   = "scope"
      value = "prefix-list"
    }

    parameter {
      key   = "prefixListIdentifier"
      value = aws_ec2_managed_prefix_list.onprem.id
    }

    target {
      key   = "Subnets"
      value = "cluster-subnets"
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = local.tags
}

# ─── Outputs ─────────────────────────────────────────────────────────────────

output "fis_experiment_template_id" {
  description = "FIS experiment template ID. Use: aws fis start-experiment --experiment-template-id <id>"
  value       = aws_fis_experiment_template.network_disconnect.id
}

output "prefix_list_id" {
  description = "Managed prefix list with on-premises CIDRs"
  value       = aws_ec2_managed_prefix_list.onprem.id
}

output "target_subnets" {
  description = "EKS cluster subnets targeted by the experiment"
  value       = local.subnet_ids
}

output "fis_role_arn" {
  description = "IAM role ARN used by FIS"
  value       = aws_iam_role.fis.arn
}
