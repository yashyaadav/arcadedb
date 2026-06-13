###############################################################################
# modules/network — outputs
###############################################################################

output "vpc_id" {
  description = "The VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "The VPC primary CIDR."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private DATA subnet IDs (nodes + DB pods), one per AZ."
  value       = aws_subnet.private[*].id
}

output "intra_subnet_ids" {
  description = "Intra (no-egress) subnet IDs, one per AZ."
  value       = aws_subnet.intra[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT/LB only), one per AZ (empty if disabled)."
  value       = aws_subnet.public[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs, one per AZ."
  value       = aws_route_table.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = aws_nat_gateway.this[*].id
}

output "endpoints_security_group_id" {
  description = "Security group ID protecting the interface VPC endpoints."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Map of service short-name => interface VPC endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "azs" {
  description = "The AZs this VPC spans (one per Raft node)."
  value       = var.azs
}
