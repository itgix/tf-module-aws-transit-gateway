locals {
  # 1) Special attachment keys
  inspection_keys = [for k, v in var.vpc_attachments : k if try(v.inspection, false)]
  egress_keys     = [for k, v in var.vpc_attachments : k if try(v.egress, false)]

  inspection_key = length(local.inspection_keys) > 0 ? local.inspection_keys[0] : null
  egress_key     = length(local.egress_keys) > 0 ? local.egress_keys[0] : null

  # 2) Inspection route table attachments: all VPCs except the inspection VPC itself
  inspection_route_attachments = {
    for k, v in var.vpc_attachments :
    k => v if k != local.inspection_key && try(v.tgw_destination_cidr, null) != null
  }

  # 3) TGW default route table tags
  tgw_default_route_table_tags_merged = merge(
    var.tags,
    { Name = var.name },
    var.tgw_default_route_table_tags,
  )

  # 4) Flattened route table destination CIDRs
  vpc_route_table_destination_cidr = flatten([
    for k, v in var.vpc_attachments : [
      for rtb_id in try(v.vpc_route_table_ids, []) : {
        rtb_id = rtb_id
        cidr   = v.tgw_destination_cidr
        tgw_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : v.tgw_id
      }
    ]
  ])
}

################################################################################
# Transit Gateway
################################################################################

resource "aws_ec2_transit_gateway" "this" {
  count = var.create_tgw ? 1 : 0

  region = var.region

  description                        = coalesce(var.description, var.name)
  amazon_side_asn                    = var.amazon_side_asn
  default_route_table_association    = var.enable_default_route_table_association ? "enable" : "disable"
  default_route_table_propagation    = var.enable_default_route_table_propagation ? "enable" : "disable"
  auto_accept_shared_attachments     = var.enable_auto_accept_shared_attachments ? "enable" : "disable"
  multicast_support                  = var.enable_multicast_support ? "enable" : "disable"
  vpn_ecmp_support                   = var.enable_vpn_ecmp_support ? "enable" : "disable"
  dns_support                        = var.enable_dns_support ? "enable" : "disable"
  transit_gateway_cidr_blocks        = var.transit_gateway_cidr_blocks
  security_group_referencing_support = var.enable_sg_referencing_support ? "enable" : "disable"

  dynamic "timeouts" {
    for_each = var.timeouts == null ? [] : [var.timeouts]
    content {
      create = timeouts.value.create
      update = timeouts.value.update
      delete = timeouts.value.delete
    }
  }

  tags = merge(
    var.tags,
    { Name = var.name },
    var.tgw_tags,
  )
}

resource "aws_ec2_tag" "this" {
  for_each = { for k, v in local.tgw_default_route_table_tags_merged : k => v if var.create_tgw && var.enable_default_route_table_association }

  region = var.region

  resource_id = aws_ec2_transit_gateway.this[0].association_default_route_table_id
  key         = each.key
  value       = each.value
}

################################################################################
# VPC Attachment
################################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = var.vpc_attachments

  region = var.region

  transit_gateway_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : each.value.tgw_id
  vpc_id             = each.value.vpc_id
  subnet_ids         = each.value.subnet_ids

  dns_support                                     = try(each.value.dns_support, true) ? "enable" : "disable"
  ipv6_support                                    = try(each.value.ipv6_support, false) ? "enable" : "disable"
  appliance_mode_support                          = try(each.value.appliance_mode_support, false) ? "enable" : "disable"
  security_group_referencing_support              = try(each.value.security_group_referencing_support, false) ? "enable" : "disable"
  transit_gateway_default_route_table_association = try(each.value.transit_gateway_default_route_table_association, true)
  transit_gateway_default_route_table_propagation = try(each.value.transit_gateway_default_route_table_propagation, true)

  tags = merge(
    var.tags,
    // extended with option to add custom names on each attachment
    { Name = try(each.value.vpc_attachment_name, var.name) },
    var.tgw_vpc_attachment_tags,
    try(each.value.tags, {}),
  )

  depends_on = [aws_ram_resource_share_accepter.this]
}

################################################################################
# Route Table / Routes
################################################################################

// customized approach for the ITGix Landign Zone where we create 2 route tables
// one for the common traffic from application VPCs to inspection VPC
// one for the inspection traffic from inspection VPC to Egress VPC and also with routes to all other VPCs to route back all traffic responses
resource "aws_ec2_transit_gateway_route_table" "this" {
  count = var.create_tgw && var.create_tgw_routes ? 2 : 0

  region = var.region

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    // separate names for the 2 route tables
    { Name = "${var.name}-${element(["inspection", "common"], count.index)}" },
    var.tgw_route_table_tags,
  )
}

// custom for the ITGix Landing Zone to allow creation of separate routes, one for inspection and one for common traffic
// 1) one route per other VPC (dest = that VPC's tgw_destination_cidr)
resource "aws_ec2_transit_gateway_route" "inspection_to_vpcs" {
  // add the destination CIDR of each VPC except the inspection VPC (because it will be in the other route table that is specific for inspection traffic)
  for_each = var.create_tgw_routes ? local.inspection_route_attachments : {}

  region = var.region

  destination_cidr_block = each.value.tgw_destination_cidr
  blackhole              = try(each.value.blackhole, false) ? true : null

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id

  # ensure attachment exists before creating route
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// custom for the ITGix Landing Zone to allow creation of separate routes, one for inspection and one for common traffic
// 2) default route in inspection table pointing to egress VPC attachment
resource "aws_ec2_transit_gateway_route" "inspection_default_to_egress" {
  count = (var.create_tgw_routes && local.egress_key != null) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.egress_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// custom for the ITGix Landing Zone to allow creation of separate routes, one for inspection and one for common traffic
// 3) default route in common table pointing to inspection VPC
resource "aws_ec2_transit_gateway_route" "common_default_to_inspection" {
  count = (var.create_tgw_routes && local.inspection_key != null) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[1].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "this" {
  for_each = { for x in local.vpc_route_table_destination_cidr : x.rtb_id => {
    cidr   = x.cidr,
    tgw_id = x.tgw_id
  } }

  region = var.region

  route_table_id              = each.key
  destination_cidr_block      = try(each.value.ipv6_support, false) ? null : each.value["cidr"]
  destination_ipv6_cidr_block = try(each.value.ipv6_support, false) ? each.value["cidr"] : null
  transit_gateway_id          = each.value["tgw_id"]

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection_association" {
  # associate the inspection attachment with the inspection table
  count = (var.create_tgw && var.create_tgw_routes && local.inspection_key != null) ? 1 : 0

  region = var.region

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = {
    for k, v in var.vpc_attachments : k => v if var.create_tgw && var.create_tgw_routes && try(v.transit_gateway_default_route_table_propagation, true) != true
  }

  region = var.region

  # Create association if it was not set already by aws_ec2_transit_gateway_vpc_attachment resource
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = var.create_tgw ? aws_ec2_transit_gateway_route_table.this[0].id : try(each.value.transit_gateway_route_table_id, var.transit_gateway_route_table_id)
}

################################################################################
# Resource Access Manager
################################################################################

locals {
  ram_name = coalesce(var.ram_name, var.name)
}

resource "aws_ram_resource_share" "this" {
  count = var.create_tgw && var.share_tgw ? 1 : 0

  region = var.region

  name                      = local.ram_name
  allow_external_principals = var.ram_allow_external_principals

  tags = merge(
    var.tags,
    { Name = local.ram_name },
    var.ram_tags,
  )
}

resource "aws_ram_resource_association" "this" {
  count = var.create_tgw && var.share_tgw ? 1 : 0

  region = var.region

  resource_arn       = aws_ec2_transit_gateway.this[0].arn
  resource_share_arn = aws_ram_resource_share.this[0].id
}

resource "aws_ram_principal_association" "this" {
  count = var.create_tgw && var.share_tgw ? length(var.ram_principals) : 0

  region = var.region

  principal          = var.ram_principals[count.index]
  resource_share_arn = aws_ram_resource_share.this[0].arn
}

resource "aws_ram_resource_share_accepter" "this" {
  count = !var.create_tgw && var.share_tgw ? 1 : 0

  region = var.region

  share_arn = var.ram_resource_share_arn
}
