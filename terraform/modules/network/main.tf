###############################################################################
# modules/network — a 3-AZ, private-data VPC with VPC endpoints.
#
# BOILERPLATE TEMPLATE (CTO package): instantiable + validate-clean, NOT applied
# to AWS. Account IDs / real CIDRs are supplied per environment.
#
# Design anchors:
#   - 3 AZs, one per Raft node (prime directive #3).
#   - Private-only DATA subnets; DB never on a public subnet/LB (prime directive #4).
#   - VPC endpoints keep traffic private + cut NAT cost (HLD §5.3).
#   - Residency guard: region must be in-geo (ADR-0007).
###############################################################################

locals {
  # Defence-in-depth residency guard at plan time. The SCP + CI gate are the
  # primary controls; this fails fast in the module too.
  region_in_geo = contains(var.allowed_regions, var.region)

  common_tags = merge(var.tags, {
    "platform"            = "arcadedb-kb"
    "geo"                 = var.geo
    "env"                 = var.env
    "module"              = "network"
    "managed-by"          = "opentofu"
    "data-classification" = "tenant-data"
    "residency-boundary"  = var.geo
  })

  # one-NAT-per-AZ unless single_nat_gateway is set
  nat_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.azs)) : 0

  create_public = length(var.public_subnet_cidrs) > 0
}

# Fail the plan if the region is out of jurisdiction (residency, ADR-0007).
resource "terraform_data" "residency_guard" {
  lifecycle {
    precondition {
      condition     = local.region_in_geo
      error_message = "RESIDENCY VIOLATION: region ${var.region} is not in the ${var.geo} allow-list ${jsonencode(var.allowed_regions)}."
    }
  }
}

###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.name}-vpc" })
}

###############################################################################
# Subnets — private (data), intra (no egress), public (NAT/LB only)
###############################################################################
resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # No public IPs on data subnets — prime directive #4.
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                              = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    tier                              = "private-data"
  })
}

resource "aws_subnet" "intra" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.intra_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name}-intra-${var.azs[count.index]}"
    tier = "intra-no-egress"
  })
}

resource "aws_subnet" "public" {
  count                   = local.create_public ? length(var.azs) : 0
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false # explicit; ALBs/NLBs assign as needed

  tags = merge(local.common_tags, {
    Name                     = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
    tier                     = "public-lb-nat-only"
  })
}

###############################################################################
# Internet + NAT gateways
###############################################################################
resource "aws_internet_gateway" "this" {
  count  = local.create_public ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name}-igw" })
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  # Place NAT in public subnets; index 0 when single, else per-AZ.
  subnet_id  = local.create_public ? aws_subnet.public[count.index].id : null
  tags       = merge(local.common_tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route tables
###############################################################################
# Public route table → IGW
resource "aws_route_table" "public" {
  count  = local.create_public ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route" "public_internet" {
  count                  = local.create_public ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count          = local.create_public ? length(var.azs) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Private route tables → NAT (one per AZ for HA, or all → single NAT)
resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name}-rt-private-${var.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? length(var.azs) : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Intra route table — no default route (no NAT/IGW). Endpoints only.
resource "aws_route_table" "intra" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name}-rt-intra" })
}

resource "aws_route_table_association" "intra" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra.id
}

###############################################################################
# Security group for interface endpoints (443 from within the VPC only)
###############################################################################
resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from within the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All egress (endpoint responses)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# VPC endpoints — gateway (S3, DynamoDB) + interface (everything else)
###############################################################################
resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_s3_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.intra.id],
  )
  tags = merge(local.common_tags, { Name = "${var.name}-vpce-s3" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  count             = var.enable_dynamodb_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.intra.id],
  )
  tags = merge(local.common_tags, { Name = "${var.name}-vpce-dynamodb" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(var.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.intra[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.name}-vpce-${replace(each.value, ".", "-")}" })
}

###############################################################################
# VPC Flow Logs → CloudWatch (audit layer 1, HLD §7.1). Encryption + retention
# are set on the log group; KMS key arn is supplied by the caller.
###############################################################################
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = 365
  kms_key_id        = var.flow_logs_kms_key_arn
  tags              = local.common_tags
}

resource "aws_flow_log" "this" {
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = var.flow_logs_role_arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id
  tags                 = merge(local.common_tags, { Name = "${var.name}-flow-logs" })
}
