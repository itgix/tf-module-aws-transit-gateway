The Terraform module is used by the ITGix AWS Landing Zone - https://itgix.com/itgix-landing-zone/

# AWS Transit Gateway Terraform Module

This module creates an AWS Transit Gateway with VPC attachments, route tables, routes, and
optional RAM sharing for multi-account architectures. It supports two topologies:

- **Flat mode** (default) — a single common route table for all spoke VPCs plus an inspection
  route table. All spokes can route to each other; isolation depends on the network firewall.
- **Isolated mode** (`enable_environment_isolation = true`) — a dedicated route table per
  application spoke (dev, stage, prod) with **blackhole routes** to the other environments'
  CIDRs, plus a shared-infrastructure route table for egress and shared-services. Isolation is
  enforced at the Transit Gateway itself, so it works **with or without a Network Firewall**.
  Selective exceptions are supported via `allowed_environment_pairs`.

Part of the [ITGix AWS Landing Zone](https://itgix.com/itgix-landing-zone/).

## Resources Created

- EC2 Transit Gateway
- VPC attachments
- Route tables:
  - Flat mode: inspection + common
  - Isolated mode: inspection + one per spoke + shared-infra
- Transit Gateway routes:
  - Spoke → inspection defaults (`0.0.0.0/0`)
  - Inspection → egress default + return routes to every VPC
  - Spoke → shared-infra routes
  - **Blackhole** routes between non-allowed spoke pairs (isolated mode)
  - Direct routes for allowed spoke pairs (isolated mode)
- Route table associations and propagations
- *(Optional)* RAM resource share for cross-account access

## Environment Isolation (Isolated Mode)

When `enable_environment_isolation = true`, each application spoke gets its own TGW route table
and blackhole routes to every other spoke that is not in `allowed_environment_pairs`. This means:

- Spoke-to-spoke traffic is **dropped at the Transit Gateway** by the blackhole route. It never
  reaches the firewall. Works even for customers who choose not to deploy the Network Firewall.
- Traffic to shared infrastructure (egress, shared-services) is routed normally.
- The `0.0.0.0/0` default in each spoke's table points at the inspection VPC (or wherever your
  centralized egress lives), so outbound internet traffic still flows through inspection.
- Allowed pairs (e.g. `dev-to-stage`) get a direct spoke-to-spoke route instead of a blackhole.

**Attachment requirements for isolation to work:**

- Each spoke attachment MUST set `spoke = true` and `env_label` (`"dev"`, `"stage"`, or `"prod"`).
- Each spoke attachment MUST set `tgw_destination_cidr` to the VPC's CIDR — the module uses it
  to write blackhole routes and allowed-pair routes to that spoke.
- The inspection attachment sets `inspection = true`.
- The egress attachment sets `egress = true`.
- Any other non-spoke VPCs (shared-services, etc.) are placed in the shared-infra route table.

## Requirements

| Name | Version |
|------|---------|
| Terraform | >= 1.5.7 |
| AWS provider | >= 6.0 |

## Inputs

### Core

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `name` | Name to be used on all resources as identifier | `string` | `""` | no |
| `tags` | A map of tags to add to all resources | `map(string)` | `{}` | no |
| `region` | Region where resources will be managed | `string` | `null` | no |
| `replace_existing_association` | When true, route-table associations atomically replace any existing association on the attachment instead of failing. Needed when migrating attachments between route tables (e.g. flat → isolated topology) to avoid `Resource.AlreadyAssociated` errors. | `bool` | `true` | no |

### Transit Gateway

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `create_tgw` | Controls if TGW should be created | `bool` | `true` | no |
| `description` | Description of the Transit Gateway | `string` | `"ITGix Landing Zone - Centralized Networking - Transit Gateway"` | no |
| `amazon_side_asn` | The ASN for the Amazon side of the gateway | `string` | `null` | no |
| `enable_default_route_table_association` | Auto-associate attachments with default route table | `bool` | `true` | no |
| `enable_default_route_table_propagation` | Auto-propagate routes to default route table | `bool` | `true` | no |
| `enable_auto_accept_shared_attachments` | Auto-accept attachment requests | `bool` | `false` | no |
| `enable_vpn_ecmp_support` | Enable VPN ECMP support | `bool` | `true` | no |
| `enable_multicast_support` | Enable multicast support | `bool` | `false` | no |
| `enable_dns_support` | Enable DNS support in the TGW | `bool` | `true` | no |
| `enable_sg_referencing_support` | Enable security group referencing support | `bool` | `true` | no |
| `transit_gateway_cidr_blocks` | IPv4 or IPv6 CIDR blocks for the transit gateway | `list(string)` | `[]` | no |
| `timeouts` | Create, update, and delete timeout configurations | `object({create, update, delete})` | `null` | no |
| `tgw_tags` | Additional tags for the TGW | `map(string)` | `{}` | no |
| `tgw_default_route_table_tags` | Additional tags for the default TGW route table | `map(string)` | `{}` | no |

### VPC Attachments

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `vpc_attachments` | Map of VPC attachment definitions. See "Attachment Object Schema" below. | `any` | `{}` | no |
| `tgw_vpc_attachment_tags` | Additional tags for VPC attachments | `map(string)` | `{}` | no |

### Route Table / Routes

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `create_tgw_routes` | Controls if TGW Route Table / Routes should be created | `bool` | `true` | no |
| `transit_gateway_route_table_id` | Existing TGW Route Table ID to reuse | `string` | `null` | no |
| `tgw_route_table_tags` | Additional tags for the TGW route tables | `map(string)` | `{}` | no |

### Environment Isolation

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `enable_environment_isolation` | When true, creates per-spoke TGW route tables with blackhole routes to the other spokes. Application VPCs (dev, stage, prod) are isolated by default; shared-infrastructure connectivity is preserved. | `bool` | `false` | no |
| `allowed_environment_pairs` | Environment pairs that should retain bidirectional connectivity while isolation is on. Valid values: `dev-to-stage`, `dev-to-prod`, `stage-to-prod`. A listed pair gets a direct spoke-to-spoke route instead of a blackhole. Validated. | `list(string)` | `[]` | no |

### Resource Access Manager (cross-account sharing)

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `share_tgw` | Whether to share the TGW with other accounts | `bool` | `false` | no |
| `ram_name` | Name of the RAM resource share | `string` | `""` | no |
| `ram_allow_external_principals` | Allow principals outside the organization | `bool` | `false` | no |
| `ram_principals` | List of principals to share TGW with | `list(string)` | `[]` | no |
| `ram_resource_share_arn` | ARN of RAM resource share | `string` | `""` | no |
| `ram_tags` | Additional tags for the RAM | `map(string)` | `{}` | no |

## Attachment Object Schema

Each entry in `vpc_attachments` is a map with the following fields:

| Field | Type | Required | Purpose |
|-------|------|----------|---------|
| `vpc_id` | `string` | yes | Target VPC id |
| `subnet_ids` | `list(string)` | yes | Subnets used by the attachment |
| `vpc_attachment_name` | `string` | no | Tag `Name` for the attachment |
| `dns_support` | `bool` | no | Enable DNS support on the attachment |
| `ipv6_support` | `bool` | no | Enable IPv6 support |
| `appliance_mode_support` | `bool` | no | Required for the inspection VPC (Network Firewall) |
| `security_group_referencing_support` | `bool` | no | Cross-VPC SG referencing |
| `tgw_destination_cidr` | `string` | required for isolation | The VPC's CIDR. Used by the module to build inspection return routes, spoke blackhole routes, and allowed-pair routes. |
| `spoke` | `bool` | required for isolation | Marks the attachment as an application spoke (dev/stage/prod). Only spokes get per-environment route tables. |
| `env_label` | `string` | required for isolation | One of `"dev"`, `"stage"`, `"prod"`. Used to match `allowed_environment_pairs` entries like `dev-to-stage`. |
| `inspection` | `bool` | at most one attachment | Marks the inspection (firewall) VPC. |
| `egress` | `bool` | at most one attachment | Marks the egress (NAT) VPC. |
| `blackhole` | `bool` | no | Force a specific inspection return route to be a blackhole. |
| `tags` | `map(string)` | no | Extra tags for this attachment. |

An attachment that has neither `spoke`, `inspection`, nor `egress` set is treated as
**shared infrastructure** (e.g. shared-services VPC) and is placed in the shared-infra route
table in isolated mode.

## Outputs

| Name | Description |
|------|-------------|
| `ec2_transit_gateway_id` | EC2 Transit Gateway ID |
| `ec2_transit_gateway_arn` | EC2 Transit Gateway ARN |
| `tgw_inspection_route_table_id` | Inspection route table id (flat or isolated mode, whichever is active) |
| `tgw_common_route_table_id` | Common route table id (flat mode only) |
| `tgw_isolated_spoke_route_table_ids` | Map of spoke key → route table id (isolated mode only) |
| `tgw_isolated_shared_infra_route_table_id` | Shared-infra route table id (isolated mode only) |
| `tgw_inspection_routes` | Object with inspection route ids (return routes + `0.0.0.0/0` → egress) |
| `tgw_common_routes` | Object with common route ids (flat mode) |
| `tgw_inspection_association_id` | Route-table association id for the inspection attachment |
| `tgw_route_table_propagation_ids` | List of route table propagation ids |

## Usage — Flat mode (simple, no environment isolation)

```hcl
module "transit_gateway" {
  source = "git::https://github.com/itgix/tf-module-aws-transit-gateway.git?ref=v2.2.0"

  name        = "my-tgw"
  description = "Central Transit Gateway"

  enable_auto_accept_shared_attachments = true

  vpc_attachments = {
    shared = {
      vpc_id     = "vpc-aaa111"
      subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
    }
  }

  share_tgw      = true
  ram_name       = "tgw-share"
  ram_principals = ["arn:aws:organizations::123456789012:organization/o-abc123"]

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

## Usage — Isolated mode (application environments isolated)

Full example with inspection, egress, three spokes, and shared-services. `dev-to-stage` is
allowed as a selective exception; all other spoke-to-spoke traffic is dropped at the TGW via
blackhole routes.

```hcl
module "transit_gateway" {
  source = "git::https://github.com/itgix/tf-module-aws-transit-gateway.git?ref=v2.2.0"

  name = "itgix-shared-services-tgw"

  # Don't let AWS auto-associate/propagate — this module manages the topology.
  enable_default_route_table_association = false
  enable_default_route_table_propagation = false

  # Turn on isolated mode. Each spoke gets its own route table with blackhole
  # routes to the other spokes. Works with or without a Network Firewall.
  enable_environment_isolation = true

  # Optional selective exceptions. dev<->stage keeps connectivity;
  # dev<->prod and stage<->prod stay blackholed.
  allowed_environment_pairs = ["dev-to-stage"]

  vpc_attachments = {
    egress_vpc = {
      vpc_attachment_name = "egress-vpc"
      vpc_id              = module.egress_vpc.vpc_id
      subnet_ids          = module.egress_vpc.private_subnets
      egress              = true
    }

    inspection_vpc = {
      vpc_attachment_name    = "inspection-vpc"
      vpc_id                 = module.inspection_vpc.vpc_id
      subnet_ids             = module.inspection_vpc.transit_gateway_subnets
      appliance_mode_support = true   # required for Network Firewall
      inspection             = true
    }

    application_vpc_dev = {
      vpc_attachment_name  = "app-dev"
      vpc_id               = module.application_vpc_dev.vpc_id
      subnet_ids           = module.application_vpc_dev.private_subnets
      spoke                = true
      env_label            = "dev"
      tgw_destination_cidr = "10.3.0.0/16"   # required for isolation
    }

    application_vpc_stg = {
      vpc_attachment_name  = "app-stage"
      vpc_id               = module.application_vpc_stg.vpc_id
      subnet_ids           = module.application_vpc_stg.private_subnets
      spoke                = true
      env_label            = "stage"
      tgw_destination_cidr = "10.4.0.0/16"
    }

    application_vpc_prod = {
      vpc_attachment_name  = "app-prod"
      vpc_id               = module.application_vpc_prod.vpc_id
      subnet_ids           = module.application_vpc_prod.private_subnets
      spoke                = true
      env_label            = "prod"
      tgw_destination_cidr = "10.5.0.0/16"
    }

    shared_services_vpc = {
      vpc_attachment_name = "shared-services"
      vpc_id              = module.shared_services_vpc.vpc_id
      subnet_ids          = module.shared_services_vpc.private_subnets
    }
  }

  tags = {
    Environment = "shared-services"
    ManagedBy   = "terraform"
  }
}
```

Resulting topology (isolated mode with `allowed_environment_pairs = ["dev-to-stage"]`), showing
the new source-to-destination route-table names:

| Route table | Associated attachment(s) | Notable routes |
|-------------|-------------------------|----------------|
| `<name>-inspection-to-egress` | inspection | return routes to every VPC + `0.0.0.0/0` → egress |
| `<name>-dev-to-inspection` | dev | `10.4/16` → stage (allowed), `10.5/16` → **blackhole** (prod), `0.0.0.0/0` → inspection |
| `<name>-stage-to-inspection` | stage | `10.3/16` → dev (allowed), `10.5/16` → **blackhole** (prod), `0.0.0.0/0` → inspection |
| `<name>-prod-to-inspection` | prod | `10.3/16` → **blackhole**, `10.4/16` → **blackhole**, `0.0.0.0/0` → inspection |
| `<name>-shared-to-inspection` | egress + shared-services | `0.0.0.0/0` → inspection |

In flat mode (`enable_environment_isolation = false`) the names are `<name>-apps-and-shared-to-inspection`
(all non-inspection VPCs — dev, stage, prod, shared-services, egress) and
`<name>-inspection-to-egress` (inspection VPC).

## Migration Notes (Flat → Isolated)

Switching an existing deployment from flat to isolated changes every route-table association.
Two things to know:

1. **`replace_existing_association = true` is the default** — the module tells AWS to atomically
   move each attachment to its new route table instead of failing with `Resource.AlreadyAssociated`.
   This shrinks the connectivity gap during migration to near-zero.

2. **Data-plane blip.** Even with atomic replace, TGW route/association updates are not
   instantaneous. Traffic transiting the TGW may see a short interruption during the migration.
   For production accounts, plan a maintenance window. Greenfield accounts deploy isolated from
   day one with no interruption.

## Notes

- The `replace_existing_association` flag applies to every association resource created by the
  module. Set it to `false` only if you want AWS to reject the apply when an attachment is
  already associated (e.g. as a safety guard in accounts you don't want to auto-migrate).
- The isolated inspection route table contains return routes to every VPC and a `0.0.0.0/0`
  route to the egress attachment. If you disable the inspection VPC entirely, spokes will still
  have `0.0.0.0/0 → inspection` in their route tables — plan accordingly.
- Isolation is enforced by TGW blackhole routes. If you also run a Network Firewall, you can
  layer firewall rules on top for defense-in-depth, but this module does not require it.
