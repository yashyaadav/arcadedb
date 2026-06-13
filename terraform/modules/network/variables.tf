###############################################################################
# modules/network — input variables
#
# A 3-AZ VPC with PRIVATE-ONLY data subnets (no public DB exposure — prime
# directive #4), IPAM-friendly CIDR inputs, and interface/gateway VPC endpoints
# to keep traffic private and cut NAT cost (HLD §5.3).
###############################################################################

variable "name" {
  description = "Name prefix for all resources, e.g. \"kb-eu-prod\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.name))
    error_message = "name must be lowercase alphanumeric/hyphen, 3-41 chars, starting with a letter."
  }
}

variable "geo" {
  description = "Jurisdiction this VPC belongs to. Hard residency boundary (prime directive #1)."
  type        = string

  validation {
    condition     = contains(["eu", "us"], var.geo)
    error_message = "geo must be one of: eu, us."
  }
}

variable "env" {
  description = "Environment: dev | stage | prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "region" {
  description = "AWS region. MUST be in-geo (validated against allowed_regions)."
  type        = string
}

variable "allowed_regions" {
  description = "Allow-list of in-geo regions. Residency guard: var.region must be a member (ADR-0007)."
  type        = list(string)
  # Example EU: ["eu-central-1","eu-west-1"]; US: ["us-east-1","us-west-2"].
}

variable "vpc_cidr" {
  description = "Primary VPC CIDR (IPAM-allocated, non-overlapping across accounts)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "azs" {
  description = "Exactly three Availability Zones (one per Raft node — prime directive #3)."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3
    error_message = "Provide exactly 3 AZs (3-node quorum, one node per AZ)."
  }
}

variable "private_subnet_cidrs" {
  description = "Per-AZ CIDRs for the private DATA subnets (nodes + DB pods). Length must equal azs."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
}

variable "intra_subnet_cidrs" {
  description = "Per-AZ CIDRs for INTRA subnets (no route to NAT/IGW) — endpoints, control plane internals."
  type        = list(string)
  default     = ["10.0.48.0/22", "10.0.52.0/22", "10.0.56.0/22"]
}

variable "public_subnet_cidrs" {
  description = "Per-AZ CIDRs for PUBLIC subnets (NAT + internal/ingress LBs only; NEVER DB). Empty list = no public subnets."
  type        = list(string)
  default     = ["10.0.60.0/24", "10.0.61.0/24", "10.0.62.0/24"]
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) for private-subnet egress."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Cost lever: one shared NAT GW (true, fine for non-prod) vs one per AZ (false, prod HA)."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "AWS service short-names for INTERFACE VPC endpoints (private connectivity, less NAT)."
  type        = list(string)
  default = [
    "ecr.api", "ecr.dkr", "sts", "secretsmanager",
    "logs", "kms", "aps-workspaces", "elasticloadbalancing",
    "ec2", "autoscaling",
  ]
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway endpoint (backups/ECR layers stay off NAT)."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Create the DynamoDB gateway endpoint (tenant registry stays off NAT)."
  type        = bool
  default     = true
}

variable "flow_logs_kms_key_arn" {
  description = "KMS key ARN for the flow-logs CloudWatch group. Null = AWS-managed (override in prod)."
  type        = string
  default     = null
}

variable "flow_logs_role_arn" {
  description = "IAM role ARN allowing VPC Flow Logs to write to CloudWatch (created in the landing zone / env)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
