The Terraform module is used by the ITGix AWS Landing Zone - https://itgix.com/itgix-landing-zone/

# AWS Transit Gateway Terraform Module

This module creates an AWS Transit Gateway with VPC attachments, route tables (inspection and common), routes, and optional RAM sharing for multi-account architectures.

Part of the [ITGix AWS Landing Zone](https://itgix.com/itgix-landing-zone/).

## Resources Created

- EC2 Transit Gateway
- VPC attachments
- Route tables (inspection and common)
- Transit Gateway routes and propagations
- *(Optional)* RAM resource share for cross-account access

## Requirements

| Name | Version |
|------|---------|
| Terraform | >= 1.5.7 |
| AWS provider | >= 6.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `name` | Name to be used on all resources as identifier | `string` | `""` | no |
| `tags` | A map of tags to add to all resources | `map(string)` | `{}` | no |
| `region` | Region where resources will be managed | `string` | `null` | no |
| `create_tgw` | Controls if TGW should be created | `bool` | `true` | no |
| `description` | Description of the Transit Gateway | `string` | `"ITGix Landing Zone - Centralized Networking - Transit Gateway"` | no |
| `amazon_side_asn` | The ASN for the Amazon side of the gateway | `string` | `null` | no |
| `enable_default_route_table_association` | Auto-associate attachments with default route table | `bool` | `true` | no |
| `enable_default_route_table_propagation` | Auto-propagate routes to default route table | `bool` | `true` | no |
| `enable_auto_accept_shared_attachments` | Auto-accept attachment requests | `bool` | `false` | no |
| `enable_vpn_ecmp_support` | Enable VPN ECMP support | `bool` | `true` | no |
| `enable_multicast_support` | Enable multicast support | `bool` | `false` | no |
| `enable_dns_support` | Enable DNS support in the TGW | `bool` | `true` | no |
| `transit_gateway_cidr_blocks` | IPv4 or IPv6 CIDR blocks for the transit gateway | `list(string)` | `[]` | no |
| `timeouts` | Create, update, and delete timeout configurations | `object({create, update, delete})` | `null` | no |
| `tgw_tags` | Additional tags for the TGW | `map(string)` | `{}` | no |
| `tgw_default_route_table_tags` | Additional tags for the default TGW route table | `map(string)` | `{}` | no |
| `enable_sg_referencing_support` | Enable security group referencing support | `bool` | `true` | no |
| `vpc_attachments` | Maps of VPC details to attach to TGW | `any` | `{}` | no |
| `tgw_vpc_attachment_tags` | Additional tags for VPC attachments | `map(string)` | `{}` | no |
| `create_tgw_routes` | Controls if TGW Route Table/Routes should be created | `bool` | `true` | no |
| `transit_gateway_route_table_id` | Existing TGW Route Table ID to reuse | `string` | `null` | no |
| `tgw_route_table_tags` | Additional tags for the TGW route table | `map(string)` | `{}` | no |
| `share_tgw` | Whether to share the TGW with other accounts | `bool` | `false` | no |
| `ram_name` | Name of the RAM resource share | `string` | `""` | no |
| `ram_allow_external_principals` | Allow principals outside the organization | `bool` | `false` | no |
| `ram_principals` | List of principals to share TGW with | `list(string)` | `[]` | no |
| `ram_resource_share_arn` | ARN of RAM resource share | `string` | `""` | no |
| `ram_tags` | Additional tags for the RAM | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| `ec2_transit_gateway_id` | EC2 Transit Gateway ID |
| `ec2_transit_gateway_arn` | EC2 Transit Gateway ARN |
| `tgw_inspection_route_table_id` | Transit Gateway route table ID for inspection traffic |
| `tgw_common_route_table_id` | Transit Gateway route table ID for common traffic |
| `tgw_inspection_routes` | Transit Gateway inspection routes |
| `tgw_common_routes` | Transit Gateway common routes |
| `tgw_inspection_association_id` | TGW route table association ID for inspection attachment |
| `tgw_route_table_propagation_ids` | List of Transit Gateway route table propagation IDs |

## Usage Example

```hcl
module "transit_gateway" {
  source = "path/to/tf-module-aws-transit-gateway"

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
