locals {
  # 1) Special attachment keys
  inspection_keys = [for k, v in var.vpc_attachments : k if try(v.inspection, false)]
  egress_keys     = [for k, v in var.vpc_attachments : k if try(v.egress, false)]

  inspection_key = length(local.inspection_keys) > 0 ? local.inspection_keys[0] : null
  egress_key     = length(local.egress_keys) > 0 ? local.egress_keys[0] : null

  # 2) Spoke VPC keys (application VPCs subject to environment isolation)
  spoke_keys = [for k, v in var.vpc_attachments : k if try(v.spoke, false)]

  # 3) Non-spoke, non-inspection keys (egress, shared-services, etc.)
  shared_infra_keys = [for k, v in var.vpc_attachments : k if !try(v.inspection, false) && !try(v.spoke, false)]

  # 4) Inspection route table attachments: all VPCs except the inspection VPC itself
  inspection_route_attachments = {
    for k, v in var.vpc_attachments :
    k => v if try(v.inspection, false) != true && try(v.tgw_destination_cidr, null) != null
  }

  # 5) TGW default route table tags
  tgw_default_route_table_tags_merged = merge(
    var.tags,
    { Name = var.name },
    var.tgw_default_route_table_tags,
  )

  # 6) Flattened route table destination CIDRs (IPv4)
  vpc_route_table_destination_cidr = flatten([
    for k, v in var.vpc_attachments : [
      for rtb_id in try(v.vpc_route_table_ids, []) : {
        rtb_id = rtb_id
        cidr   = v.tgw_destination_cidr
        tgw_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : v.tgw_id
      } if try(v.tgw_destination_cidr, null) != null
    ]
  ])

  # 6b) Flattened route table destination CIDRs (IPv6) — mirror of (6)
  vpc_route_table_destination_ipv6_cidr = flatten([
    for k, v in var.vpc_attachments : [
      for rtb_id in try(v.vpc_route_table_ids, []) : {
        rtb_id = rtb_id
        cidr   = v.tgw_destination_ipv6_cidr
        tgw_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : v.tgw_id
      } if try(v.tgw_destination_ipv6_cidr, null) != null
    ]
  ])

  # 7) Environment isolation — map of spoke_key => env_label for pair matching
  spoke_env_labels = { for k, v in var.vpc_attachments : k => try(v.env_label, k) if try(v.spoke, false) }

  # 8) Build allowed connectivity map from pairs (bidirectional expansion)
  allowed_pairs_expanded = flatten([
    for pair in var.allowed_environment_pairs : [
      { from = split("-to-", pair)[0], to = split("-to-", pair)[1] },
      { from = split("-to-", pair)[1], to = split("-to-", pair)[0] },
    ]
  ])

  # 9) For each spoke, determine which other spokes it is allowed to reach
  spoke_allowed_targets = {
    for sk in local.spoke_keys : sk => [
      for other_sk in local.spoke_keys : other_sk
      if other_sk != sk && contains(
        [for p in local.allowed_pairs_expanded : "${p.from}-${p.to}"],
        "${local.spoke_env_labels[sk]}-${local.spoke_env_labels[other_sk]}"
      )
    ]
  }

  # 10) For each spoke, the other spokes it must be BLOCKED from reaching
  # (every other spoke that is NOT an allowed target). Used to create TGW
  # blackhole routes so isolation is enforced at the routing layer itself,
  # independent of the Network Firewall (works even when no firewall exists).
  spoke_blackhole_targets = {
    for sk in local.spoke_keys : sk => [
      for other_sk in local.spoke_keys : other_sk
      if other_sk != sk
      && !contains(local.spoke_allowed_targets[sk], other_sk)
      && try(var.vpc_attachments[other_sk].tgw_destination_cidr, null) != null
    ]
  }

  # 11) IPv6 equivalent of (10): same blocked-spoke logic, but only for spokes
  # that expose an IPv6 destination CIDR. Used to write IPv6 blackhole routes.
  spoke_blackhole_targets_ipv6 = {
    for sk in local.spoke_keys : sk => [
      for other_sk in local.spoke_keys : other_sk
      if other_sk != sk
      && !contains(local.spoke_allowed_targets[sk], other_sk)
      && try(var.vpc_attachments[other_sk].tgw_destination_ipv6_cidr, null) != null
    ]
  }
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
  transit_gateway_default_route_table_association = try(each.value.transit_gateway_default_route_table_association, var.enable_default_route_table_association)
  transit_gateway_default_route_table_propagation = try(each.value.transit_gateway_default_route_table_propagation, var.enable_default_route_table_propagation)

  tags = merge(
    var.tags,
    { Name = try(each.value.vpc_attachment_name, var.name) },
    var.tgw_vpc_attachment_tags,
    try(each.value.tags, {}),
  )

  depends_on = [aws_ram_resource_share_accepter.this]
}

################################################################################
# Route Table / Routes — Standard (non-isolated) mode
################################################################################

// When isolation is DISABLED: 2 route tables (inspection + common) — original behavior
resource "aws_ec2_transit_gateway_route_table" "this" {
  count = var.create_tgw && var.create_tgw_routes && !var.enable_environment_isolation ? 2 : 0

  region = var.region

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    { Name = "${var.name}-${element(["inspection-to-egress", "apps-and-shared-to-inspection"], count.index)}" },
    var.tgw_route_table_tags,
  )
}

// 1) Routes in inspection table to each VPC (return traffic)
resource "aws_ec2_transit_gateway_route" "inspection_to_vpcs" {
  for_each = var.create_tgw_routes && !var.enable_environment_isolation ? local.inspection_route_attachments : {}

  region = var.region

  destination_cidr_block = each.value.tgw_destination_cidr
  blackhole              = try(each.value.blackhole, false) ? true : null

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — return routes to each VPC's IPv6 CIDR
resource "aws_ec2_transit_gateway_route" "inspection_to_vpcs_ipv6" {
  for_each = var.create_tgw_routes && !var.enable_environment_isolation && var.ipv6_support ? {
    for k, v in local.inspection_route_attachments : k => v
    if try(v.tgw_destination_ipv6_cidr, null) != null
  } : {}

  region = var.region

  destination_cidr_block = each.value.tgw_destination_ipv6_cidr
  blackhole              = try(each.value.blackhole, false) ? true : null

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// 2) Default route in inspection table → egress VPC
resource "aws_ec2_transit_gateway_route" "inspection_default_to_egress" {
  count = (var.create_tgw_routes && !var.enable_environment_isolation && local.egress_key != null) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.egress_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but ipv6
resource "aws_ec2_transit_gateway_route" "inspection_default_to_egress_ipv6" {
  count = (var.create_tgw_routes && !var.enable_environment_isolation && local.egress_key != null && var.ipv6_support) ? 1 : 0

  region = var.region

  destination_cidr_block         = "::/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.egress_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// 3) Default route in common table → inspection VPC
resource "aws_ec2_transit_gateway_route" "common_default_to_inspection" {
  count = (var.create_tgw_routes && !var.enable_environment_isolation && local.inspection_key != null) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[1].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6
resource "aws_ec2_transit_gateway_route" "common_default_to_inspection_ipv6" {
  count = (var.create_tgw_routes && !var.enable_environment_isolation && local.inspection_key != null && var.ipv6_support) ? 1 : 0

  region = var.region

  destination_cidr_block         = "::/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[1].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// Associate inspection VPC with inspection table
resource "aws_ec2_transit_gateway_route_table_association" "inspection_association" {
  count = (var.create_tgw && var.create_tgw_routes && !var.enable_environment_isolation && local.inspection_key != null) ? 1 : 0

  region = var.region

  replace_existing_association   = var.replace_existing_association
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
}

// Associate all non-inspection VPCs with common table
resource "aws_ec2_transit_gateway_route_table_association" "common_association" {
  for_each = !var.enable_environment_isolation ? toset([
    for k, v in var.vpc_attachments :
    k if try(v.inspection, false) != true
  ]) : toset([])



  region = var.region

  replace_existing_association   = var.replace_existing_association
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[1].id
}

// Propagate all non-inspection VPCs into inspection route table
resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = !var.enable_environment_isolation ? toset([
    for k, v in var.vpc_attachments :
    k if try(v.inspection, false) != true
  ]) : toset([])

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this[0].id
}

################################################################################
# Route Table / Routes — Isolated mode (per-spoke route tables)
################################################################################

// Inspection route table (isolated mode)
resource "aws_ec2_transit_gateway_route_table" "isolated_inspection" {
  count = var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation ? 1 : 0

  region = var.region

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    { Name = "${var.name}-inspection-to-egress" },
    var.tgw_route_table_tags,
  )
}

// One route table per spoke VPC (dev, stage, prod)
resource "aws_ec2_transit_gateway_route_table" "isolated_spoke" {
  for_each = var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation ? {
    for k in local.spoke_keys : k => k
  } : {}

  region = var.region

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    { Name = "${var.name}-${local.spoke_env_labels[each.key]}-to-inspection" },
    var.tgw_route_table_tags,
  )
}

// Shared-infra route table (for egress, shared-services VPCs)
resource "aws_ec2_transit_gateway_route_table" "isolated_shared_infra" {
  count = var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation && length(local.shared_infra_keys) > 0 ? 1 : 0

  region = var.region

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id

  tags = merge(
    var.tags,
    { Name = "${var.name}-shared-to-inspection" },
    var.tgw_route_table_tags,
  )
}

################################################################################
# Isolated mode — Inspection route table routes
################################################################################

// Routes in inspection RT to each VPC (for return traffic)
resource "aws_ec2_transit_gateway_route" "isolated_inspection_to_vpcs" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation ? local.inspection_route_attachments : {}

  region = var.region

  destination_cidr_block = each.value.tgw_destination_cidr
  blackhole              = try(each.value.blackhole, false) ? true : null

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — return routes to each VPC's IPv6 CIDR
resource "aws_ec2_transit_gateway_route" "isolated_inspection_to_vpcs_ipv6" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && var.ipv6_support ? {
    for k, v in local.inspection_route_attachments : k => v
    if try(v.tgw_destination_ipv6_cidr, null) != null
  } : {}

  region = var.region

  destination_cidr_block = each.value.tgw_destination_ipv6_cidr
  blackhole              = try(each.value.blackhole, false) ? true : null

  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// Default route in inspection table → egress VPC
resource "aws_ec2_transit_gateway_route" "isolated_inspection_default_to_egress" {
  count = (var.create_tgw_routes && var.enable_environment_isolation && local.egress_key != null) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.egress_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# same but for ipv6
resource "aws_ec2_transit_gateway_route" "isolated_inspection_default_to_egress_ipv6" {
  count = (var.create_tgw_routes && var.enable_environment_isolation && local.egress_key != null && var.ipv6_support) ? 1 : 0

  region = var.region

  destination_cidr_block         = "::/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.egress_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

################################################################################
# Isolated mode — Per-spoke route table routes
################################################################################

// Default route in each spoke RT → inspection VPC (for egress/internet traffic)
resource "aws_ec2_transit_gateway_route" "isolated_spoke_default_to_inspection" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && local.inspection_key != null ? {
    for k in local.spoke_keys : k => k
  } : {}

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.key].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# same but for ipv6
resource "aws_ec2_transit_gateway_route" "isolated_spoke_default_to_inspection_ipv6" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && local.inspection_key != null && var.ipv6_support ? {
    for k in local.spoke_keys : k => k
  } : {}

  region = var.region

  destination_cidr_block         = "::/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.key].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// Routes from each spoke to shared-infra VPCs (shared-services, egress CIDRs)
resource "aws_ec2_transit_gateway_route" "isolated_spoke_to_shared_infra" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for ik in local.shared_infra_keys : {
          key      = "${sk}-to-${ik}"
          spoke    = sk
          target   = ik
          dst_cidr = try(var.vpc_attachments[ik].tgw_destination_cidr, null)
        } if try(var.vpc_attachments[ik].tgw_destination_cidr, null) != null
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.value.target].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — routes from each spoke to shared-infra VPCs' IPv6 CIDRs
resource "aws_ec2_transit_gateway_route" "isolated_spoke_to_shared_infra_ipv6" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && var.ipv6_support ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for ik in local.shared_infra_keys : {
          key      = "${sk}-to-${ik}"
          spoke    = sk
          target   = ik
          dst_cidr = try(var.vpc_attachments[ik].tgw_destination_ipv6_cidr, null)
        } if try(var.vpc_attachments[ik].tgw_destination_ipv6_cidr, null) != null
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.value.target].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
// Blackhole routes between non-allowed spoke pairs.
// Enforces environment isolation at the TGW routing layer itself, so it works
// even when there is no Network Firewall (e.g. cost-sensitive customers).
// A more-specific blackhole route to another spoke's CIDR takes precedence over
// the 0.0.0.0/0 default, dropping the traffic at the Transit Gateway.
resource "aws_ec2_transit_gateway_route" "isolated_spoke_blackhole" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for target_sk in local.spoke_blackhole_targets[sk] : {
          key      = "${sk}-to-${target_sk}"
          spoke    = sk
          dst_cidr = var.vpc_attachments[target_sk].tgw_destination_cidr
        }
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  blackhole                      = true
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — blackhole another spoke's IPv6 CIDR
resource "aws_ec2_transit_gateway_route" "isolated_spoke_blackhole_ipv6" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && var.ipv6_support ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for target_sk in local.spoke_blackhole_targets_ipv6[sk] : {
          key      = "${sk}-to-${target_sk}"
          spoke    = sk
          dst_cidr = var.vpc_attachments[target_sk].tgw_destination_ipv6_cidr
        }
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  blackhole                      = true
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

// Selective override: routes between allowed spoke pairs
resource "aws_ec2_transit_gateway_route" "isolated_spoke_allowed_pairs" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for target_sk in local.spoke_allowed_targets[sk] : {
          key      = "${sk}-to-${target_sk}"
          spoke    = sk
          target   = target_sk
          dst_cidr = try(var.vpc_attachments[target_sk].tgw_destination_cidr, null)
        } if try(var.vpc_attachments[target_sk].tgw_destination_cidr, null) != null
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.value.target].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — direct routes between allowed spoke pairs (IPv6 CIDRs)
resource "aws_ec2_transit_gateway_route" "isolated_spoke_allowed_pairs_ipv6" {
  for_each = var.create_tgw_routes && var.enable_environment_isolation && var.ipv6_support ? {
    for pair in flatten([
      for sk in local.spoke_keys : [
        for target_sk in local.spoke_allowed_targets[sk] : {
          key      = "${sk}-to-${target_sk}"
          spoke    = sk
          target   = target_sk
          dst_cidr = try(var.vpc_attachments[target_sk].tgw_destination_ipv6_cidr, null)
        } if try(var.vpc_attachments[target_sk].tgw_destination_ipv6_cidr, null) != null
      ]
    ]) : pair.key => pair
  } : {}

  region = var.region

  destination_cidr_block         = each.value.dst_cidr
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.value.spoke].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.value.target].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

################################################################################
# Isolated mode — Shared-infra route table routes
################################################################################

// Default route in shared-infra RT → inspection VPC
resource "aws_ec2_transit_gateway_route" "isolated_shared_infra_default_to_inspection" {
  count = (var.create_tgw_routes && var.enable_environment_isolation && local.inspection_key != null && length(local.shared_infra_keys) > 0) ? 1 : 0

  region = var.region

  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_shared_infra[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# same but for ipv6
resource "aws_ec2_transit_gateway_route" "isolated_shared_infra_default_to_inspection_ipv6" {
  count = (var.create_tgw_routes && var.enable_environment_isolation && local.inspection_key != null && length(local.shared_infra_keys) > 0 && var.ipv6_support) ? 1 : 0

  region = var.region

  destination_cidr_block         = "::/0"
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_shared_infra[0].id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

################################################################################
# Isolated mode — Route table associations
################################################################################

// Associate inspection VPC with its route table
resource "aws_ec2_transit_gateway_route_table_association" "isolated_inspection_association" {
  count = (var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation && local.inspection_key != null) ? 1 : 0

  region = var.region

  replace_existing_association   = var.replace_existing_association
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[local.inspection_key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
}

// Associate each spoke VPC with its own route table
resource "aws_ec2_transit_gateway_route_table_association" "isolated_spoke_association" {
  for_each = var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation ? {
    for k in local.spoke_keys : k => k
  } : {}

  region = var.region

  replace_existing_association   = var.replace_existing_association
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_spoke[each.key].id
}

// Associate shared-infra VPCs with the shared-infra route table
resource "aws_ec2_transit_gateway_route_table_association" "isolated_shared_infra_association" {
  for_each = var.create_tgw && var.create_tgw_routes && var.enable_environment_isolation ? {
    for k in local.shared_infra_keys : k => k
  } : {}

  region = var.region

  replace_existing_association   = var.replace_existing_association
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_shared_infra[0].id
}

################################################################################
# Isolated mode — Route table propagations
################################################################################

// Propagate all non-inspection VPCs into the inspection route table (for return traffic)
resource "aws_ec2_transit_gateway_route_table_propagation" "isolated_to_inspection" {
  for_each = var.enable_environment_isolation ? toset([
    for k, v in var.vpc_attachments :
    k if try(v.inspection, false) != true
  ]) : toset([])

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_inspection[0].id
}

################################################################################
# VPC Route Table routes (both modes)
################################################################################

resource "aws_route" "this" {
  for_each = { for x in local.vpc_route_table_destination_cidr : x.rtb_id => {
    cidr   = x.cidr,
    tgw_id = x.tgw_id
  } }

  region = var.region

  route_table_id         = each.key
  destination_cidr_block = each.value["cidr"]
  transit_gateway_id     = each.value["tgw_id"]

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# the same but IPv6 — pushes the VPC's IPv6 CIDR into the target route tables
resource "aws_route" "this_ipv6" {
  for_each = var.ipv6_support ? { for x in local.vpc_route_table_destination_ipv6_cidr : x.rtb_id => {
    cidr   = x.cidr,
    tgw_id = x.tgw_id
  } } : {}

  region = var.region

  route_table_id              = each.key
  destination_ipv6_cidr_block = each.value["cidr"]
  transit_gateway_id          = each.value["tgw_id"]

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
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
