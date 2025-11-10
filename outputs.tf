################################################################################
# Transit Gateway
################################################################################

output "ec2_transit_gateway_id" {
  description = "EC2 Transit Gateway ID"
  value       = try(aws_ec2_transit_gateway.this[0].id, "")
}

output "ec2_transit_gateway_arn" {
  description = "EC2 Transit Gateway ARN"
  value       = try(aws_ec2_transit_gateway.this[0].arn, "")
}

################################################################################
# Route Tables
################################################################################

output "tgw_inspection_route_table_id" {
  description = "Transit Gateway Route Table ID for inspection traffic"
  value       = try(aws_ec2_transit_gateway_route_table.inspection.id, "")
}

output "tgw_common_route_table_id" {
  description = "Transit Gateway Route Table ID for common traffic"
  value       = try(aws_ec2_transit_gateway_route_table.common.id, "")
}

################################################################################
# Routes
################################################################################

output "tgw_route_ids" {
  description = "Transit Gateway route IDs for inspection and common route tables"
  value = concat(
    try([for r in aws_ec2_transit_gateway_route.inspection : r.id], []),
    try([for r in aws_ec2_transit_gateway_route.common : r.id], [])
  )
}

################################################################################
# Route Table Associations
################################################################################

output "tgw_route_table_association_ids" {
  description = "List of all Transit Gateway route table association IDs"
  value = concat(
    try([for r in aws_ec2_transit_gateway_route_table_association.inspection : r.id], []),
    try([for r in aws_ec2_transit_gateway_route_table_association.common : r.id], [])
  )
}

output "tgw_route_table_associations" {
  description = "Map of Transit Gateway route table associations by route table type"
  value = {
    inspection = try(aws_ec2_transit_gateway_route_table_association.inspection, {})
    common     = try(aws_ec2_transit_gateway_route_table_association.common, {})
  }
}

################################################################################
# Route Table Propagations
################################################################################

output "tgw_route_table_propagation_ids" {
  description = "List of all Transit Gateway route table propagation IDs"
  value = concat(
    try([for r in aws_ec2_transit_gateway_route_table_propagation.inspection : r.id], []),
    try([for r in aws_ec2_transit_gateway_route_table_propagation.common : r.id], [])
  )
}

output "tgw_route_table_propagations" {
  description = "Map of Transit Gateway route table propagations by route table type"
  value = {
    inspection = try(aws_ec2_transit_gateway_route_table_propagation.inspection, {})
    common     = try(aws_ec2_transit_gateway_route_table_propagation.common, {})
  }
}

