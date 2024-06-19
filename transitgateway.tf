locals {
  tgw_routes = merge([
    for k, attachment in var.vpc_attachments : {
      for i, route in attachment.tgw_routes : "${k}-${i}" => {
        destination_cidr_block         = route.destination_cidr_block,
        transit_gateway_route_table_id = route.transit_gateway_route_table_id,
        transit_gateway_attachment_id  = route.transit_gateway_attachment_id
      }
    } if var.create_tgw && var.create_tgw_routes && try(attachment.tgw_routes, []) != []
  ]...)

  propagation_attachments = var.create_tgw && var.create_tgw_routes ? merge([
    for vpc_name, attachment in var.vpc_attachments : {
      for attachment_id in try(attachment.tgw_attachment_ids_for_propagation, []) : "${vpc_name}-${attachment_id}" => {
        tgw_attachment_id              = attachment_id
        transit_gateway_route_table_id = attachment.transit_gateway_route_table_id
      }
    }
  ]...) : {}

  tgw_default_route_table_tags_merged = merge(
    var.tags,
    { Name = var.name },
    var.tgw_default_route_table_tags,
  )

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

  description                     = coalesce(var.description, var.name)
  amazon_side_asn                 = var.amazon_side_asn
  default_route_table_association = var.enable_default_route_table_association ? "enable" : "disable"
  default_route_table_propagation = var.enable_default_route_table_propagation ? "enable" : "disable"
  auto_accept_shared_attachments  = var.enable_auto_accept_shared_attachments ? "enable" : "disable"
  multicast_support               = var.enable_multicast_support ? "enable" : "disable"
  vpn_ecmp_support                = var.enable_vpn_ecmp_support ? "enable" : "disable"
  dns_support                     = var.enable_dns_support ? "enable" : "disable"
  transit_gateway_cidr_blocks     = var.transit_gateway_cidr_blocks

  timeouts {
    create = try(var.timeouts.create, null)
    update = try(var.timeouts.update, null)
    delete = try(var.timeouts.delete, null)
  }

  tags = merge(
    var.tags,
    { Name = var.name },
    var.tgw_tags,
  )
}

################################################################################
# VPC Attachment
################################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each = var.vpc_attachments

  transit_gateway_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : each.value.tgw_id
  vpc_id             = each.value.vpc_id
  subnet_ids         = each.value.subnet_ids

  dns_support                                     = try(each.value.dns_support, true) ? "enable" : "disable"
  ipv6_support                                    = try(each.value.ipv6_support, false) ? "enable" : "disable"
  appliance_mode_support                          = try(each.value.appliance_mode_support, false) ? "enable" : "disable"
  transit_gateway_default_route_table_association = try(each.value.transit_gateway_default_route_table_association, true)
  transit_gateway_default_route_table_propagation = try(each.value.transit_gateway_default_route_table_propagation, true)

  tags = merge(
    var.tags,
    { Name = lookup(each.value, "tgw_attachment_name", var.name) },
    var.tgw_vpc_attachment_tags,
    try(each.value.tags, {}),
  )
}

################################################################################
# Route Table / Routes
################################################################################

resource "aws_ec2_transit_gateway_route_table" "this" {
  for_each = { for k, v in var.vpc_attachments : k => v if var.create_tgw && try(v.create_tgw_rtb, false) }

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    { Name = lookup(each.value, "tgw_rtb_name", var.tgw_rtb_name) },
    var.tgw_route_table_tags,
  )
}

resource "aws_ec2_transit_gateway_route" "this" {
  for_each = local.tgw_routes

  destination_cidr_block = each.value.destination_cidr_block
  blackhole              = try(each.value.blackhole, false)

  transit_gateway_route_table_id = each.value.transit_gateway_route_table_id
  transit_gateway_attachment_id  = each.value.transit_gateway_attachment_id
}

resource "aws_route" "this" {
  for_each = { for x in local.vpc_route_table_destination_cidr : x.rtb_id => {
    cidr   = x.cidr,
    tgw_id = x.tgw_id
    }
  }

  route_table_id              = each.key
  destination_cidr_block      = try(each.value.ipv6_support, false) ? null : each.value["cidr"]
  destination_ipv6_cidr_block = try(each.value.ipv6_support, false) ? each.value["cidr"] : null
  transit_gateway_id          = each.value["tgw_id"]
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  for_each = {
    for k, v in var.vpc_attachments : k => v if var.create_tgw && var.create_tgw_routes && try(v.transit_gateway_default_route_table_association, true) != true
  }
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = each.value.transit_gateway_route_table_id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = local.propagation_attachments

  transit_gateway_attachment_id  = each.value.tgw_attachment_id
  transit_gateway_route_table_id = each.value.transit_gateway_route_table_id
}
