# FIS Infrastructure for EKS Hybrid Nodes Resilience Demo
#
# Creates:
#   1. Custom SSM Document - Network blackhole by CIDR (iptables-based)
#   2. FIS IAM Role
#   3. FIS Experiment Template
#   4. CloudWatch Log Group
#
# Why custom SSM Document?
#   AWS provides AWSFIS-Run-Network-Blackhole-Port (blocks by port),
#   but NOT a pre-built document for blocking by destination CIDR.
#   Our use case needs to block traffic to specific on-premises CIDRs.
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
  description = "On-premises node CIDR to block (simulates link failure)"
  type        = string
  default     = "192.168.3.0/24"
}

variable "remote_pod_cidr" {
  description = "Remote pod CIDR to block"
  type        = string
  default     = "10.201.0.0/16"
}

variable "fault_duration_seconds" {
  description = "Duration of the network fault in seconds"
  type        = number
  default     = 300 # 5 minutes
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  name       = "demo-stone"
  tags = {
    Project       = "hybrid-resilience-demo"
    Environment   = "demo"
    ManagedBy     = "terraform"
    "auto-delete" = "no"
  }
}

# ─── Custom SSM Document (Network Blackhole by CIDR) ──────────────────────────

resource "aws_ssm_document" "network_blackhole_cidr" {
  name            = "${local.name}-network-blackhole-cidr"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Blocks network traffic to specified CIDRs using iptables. Auto-reverts after duration."
    parameters = {
      DurationSeconds = {
        type        = "String"
        description = "Duration in seconds to maintain the blackhole"
        default     = tostring(var.fault_duration_seconds)
      }
      DestinationCIDRs = {
        type        = "String"
        description = "Comma-separated list of destination CIDRs to block"
        default     = "${var.onprem_node_cidr},${var.remote_pod_cidr}"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "InjectNetworkBlackhole"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "",
            "DURATION=\"{{ DurationSeconds }}\"",
            "CIDRS=\"{{ DestinationCIDRs }}\"",
            "CHAIN_NAME=\"FIS_BLACKHOLE\"",
            "",
            "echo \"[FIS] Starting network blackhole for $${DURATION}s targeting: $${CIDRS}\"",
            "",
            "# Create dedicated iptables chain for clean rollback",
            "iptables -N $${CHAIN_NAME} 2>/dev/null || iptables -F $${CHAIN_NAME}",
            "iptables -C FORWARD -j $${CHAIN_NAME} 2>/dev/null || iptables -I FORWARD 1 -j $${CHAIN_NAME}",
            "",
            "# Block each CIDR",
            "IFS=',' read -ra CIDR_ARRAY <<< \"$${CIDRS}\"",
            "for CIDR in \"$${CIDR_ARRAY[@]}\"; do",
            "  CIDR=$(echo $${CIDR} | tr -d ' ')",
            "  echo \"[FIS] Blocking traffic to $${CIDR}\"",
            "  iptables -A $${CHAIN_NAME} -d $${CIDR} -j DROP",
            "  iptables -A $${CHAIN_NAME} -s $${CIDR} -j DROP",
            "done",
            "",
            "echo \"[FIS] Blackhole active. Sleeping for $${DURATION}s...\"",
            "sleep $${DURATION}",
            "",
            "# Rollback: flush and remove chain",
            "echo \"[FIS] Duration elapsed. Removing blackhole rules...\"",
            "iptables -D FORWARD -j $${CHAIN_NAME} 2>/dev/null || true",
            "iptables -F $${CHAIN_NAME} 2>/dev/null || true",
            "iptables -X $${CHAIN_NAME} 2>/dev/null || true",
            "",
            "echo \"[FIS] Network blackhole removed. Traffic restored.\""
          ]
        }
      }
    ]
  })

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

resource "aws_iam_role_policy" "fis" {
  name = "${local.name}-fis-policy"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation",
          "ssm:CancelCommand"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${local.account_id}:log-group:/fis/*"
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

resource "aws_fis_experiment_template" "network_disconnect" {
  description = "Block network to on-prem CIDRs via iptables on Gateway Nodes (simulates AWS-side link failure)"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  target {
    name           = "gateway-nodes"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "hybrid-gateway-node"
      value = "true"
    }

    resource_tag {
      key   = "eks:cluster-name"
      value = var.cluster_name
    }
  }

  action {
    name      = "network-blackhole-to-onprem"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "duration"
      value = "PT${ceil(var.fault_duration_seconds / 60) + 2}M" # Action duration > script duration
    }

    parameter {
      key   = "documentArn"
      value = aws_ssm_document.network_blackhole_cidr.arn
    }

    parameter {
      key   = "documentParameters"
      value = jsonencode({
        DurationSeconds  = tostring(var.fault_duration_seconds)
        DestinationCIDRs = "${var.onprem_node_cidr},${var.remote_pod_cidr}"
      })
    }

    target {
      key   = "Instances"
      value = "gateway-nodes"
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

output "ssm_document_name" {
  description = "Custom SSM document name for network blackhole"
  value       = aws_ssm_document.network_blackhole_cidr.name
}

output "fis_role_arn" {
  description = "IAM role ARN used by FIS"
  value       = aws_iam_role.fis.arn
}
