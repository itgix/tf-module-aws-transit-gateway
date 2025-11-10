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

// refactored for ITGix Landing Zone to allow 2 route tables to be created one for inspection and one for the common (the rest of the routing)
output "tgw_inspection_route_table_id" {
  description = "Transit Gateway route table ID for inspection traffic"
  value       = try(aws_ec2_transit_gateway_route_table.this[0].id, "")
}

output "tgw_common_route_table_id" {
  description = "Transit Gateway route table ID for common traffic"
  value       = try(aws_ec2_transit_gateway_route_table.this[1].id, "")
}

################################################################################
# Routes
################################################################################

output "tgw_inspection_routes" {
  description = "Transit Gateway inspection routes"
  value = {
    to_vpcs           = try([for r in aws_ec2_transit_gateway_route.inspection_to_vpcs : r.id], [])
    default_to_egress = try(aws_ec2_transit_gateway_route.inspection_default_to_egress[0].id, null)
  }
}

output "tgw_common_routes" {
  description = "Transit Gateway common routes"
  value = {
    default_to_inspection = try(aws_ec2_transit_gateway_route.common_default_to_inspection[0].id, null)
  }
}

################################################################################
# Route Table Associations
################################################################################

output "tgw_inspection_association_id" {
  description = "TGW route table association ID for the inspection attachment"
  value       = try(aws_ec2_transit_gateway_route_table_association.inspection_association[0].id, null)
}

################################################################################
# Route Table Propagations
################################################################################

output "tgw_route_table_propagation_ids" {
  description = "List of Transit Gateway route table propagation IDs"
  value       = [for p in aws_ec2_transit_gateway_route_table_propagation.this : p.id]
}

