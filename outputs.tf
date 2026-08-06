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

# Identical value to ec2_transit_gateway_id, but sourced from the attachment so that
# consumers creating VPC route table routes toward the TGW are ordered after the
# attachment is available. CreateRoute returns InvalidTransitGatewayID.NotFound while
# the VPC has no available attachment to the gateway.
output "vpc_attachment_transit_gateway_ids" {
  description = "Map of vpc_attachments key => transit gateway ID, dependent on the VPC attachment"
  value       = { for k, v in aws_ec2_transit_gateway_vpc_attachment.this : k => v.transit_gateway_id }
}

################################################################################
# Route Tables
################################################################################

output "tgw_inspection_route_table_id" {
  description = "Transit Gateway route table ID for inspection traffic"
  value = var.enable_environment_isolation ? (
    try(aws_ec2_transit_gateway_route_table.isolated_inspection[0].id, "")
  ) : try(aws_ec2_transit_gateway_route_table.this[0].id, "")
}

output "tgw_common_route_table_id" {
  description = "Transit Gateway route table ID for common traffic (non-isolated mode only)"
  value       = try(aws_ec2_transit_gateway_route_table.this[1].id, "")
}

output "tgw_isolated_spoke_route_table_ids" {
  description = "Map of spoke key to isolated route table ID (isolated mode only)"
  value       = { for k, v in aws_ec2_transit_gateway_route_table.isolated_spoke : k => v.id }
}

output "tgw_isolated_shared_infra_route_table_id" {
  description = "Transit Gateway route table ID for shared infrastructure (isolated mode only)"
  value       = try(aws_ec2_transit_gateway_route_table.isolated_shared_infra[0].id, "")
}

################################################################################
# Routes
################################################################################

output "tgw_inspection_routes" {
  description = "Transit Gateway inspection routes"
  value = var.enable_environment_isolation ? {
    to_vpcs           = try([for r in aws_ec2_transit_gateway_route.isolated_inspection_to_vpcs : r.id], [])
    default_to_egress = try(aws_ec2_transit_gateway_route.isolated_inspection_default_to_egress[0].id, null)
    } : {
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
  value = var.enable_environment_isolation ? (
    try(aws_ec2_transit_gateway_route_table_association.isolated_inspection_association[0].id, null)
  ) : try(aws_ec2_transit_gateway_route_table_association.inspection_association[0].id, null)
}

################################################################################
# Route Table Propagations
################################################################################

output "tgw_route_table_propagation_ids" {
  description = "List of Transit Gateway route table propagation IDs"
  value = var.enable_environment_isolation ? (
    [for p in aws_ec2_transit_gateway_route_table_propagation.isolated_to_inspection : p.id]
  ) : [for p in aws_ec2_transit_gateway_route_table_propagation.this : p.id]
}
