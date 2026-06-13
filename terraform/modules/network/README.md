# Module: `network`

A 3-AZ VPC for one ArcadeDB cell-hosting region, with **private-only data
subnets**, intra (no-egress) subnets for VPC endpoints, optional public subnets
for NAT/LBs, and interface + gateway **VPC endpoints**. Encodes the residency
and "no public DB" invariants at the network layer.

> **CTO-package status:** basic boilerplate template — parameterised + validate-clean,
> **not applied to AWS**. Real CIDRs/AZs/region come from the environment `tfvars`.

## What it creates

| Resource | Notes |
|---|---|
| `aws_vpc` | DNS support + hostnames on. |
| `aws_subnet.private` ×3 | DATA tier (nodes + DB pods). No public IPs (**prime directive #4**). Tagged `kubernetes.io/role/internal-elb`. |
| `aws_subnet.intra` ×3 | No default route → endpoints/control-plane internals only. |
| `aws_subnet.public` ×3 | Optional (NAT + internal/ingress LBs only — **never DB**). Tagged `kubernetes.io/role/elb`. |
| `aws_internet_gateway`, `aws_nat_gateway` | NAT one-per-AZ (HA) or single (cost lever for non-prod). |
| Route tables | Public→IGW, private→NAT, intra→(endpoints only). |
| `aws_security_group.endpoints` | 443 from the VPC CIDR only. |
| `aws_vpc_endpoint` | S3 + DynamoDB gateway; interface endpoints (ECR, STS, Secrets, Logs, KMS, AMP, ELB, EC2, ASG). |
| `aws_flow_log` + log group | VPC Flow Logs → CloudWatch (audit layer 1). 365-day retention, KMS-encrypted. |

## Design invariants enforced

- **3 AZs exactly** (`var.azs` validated to length 3) — one Raft node per AZ (prime directive #3).
- **No public DB** — data subnets never get public IPs; DB ports never reach a public subnet/LB (prime directive #4).
- **Residency** — `var.region` must be in `var.allowed_regions` or the plan fails (a `terraform_data` precondition), complementing the SCP + CI gate (ADR-0007).
- **Cost** — VPC endpoints keep S3/ECR/registry traffic off NAT; `single_nat_gateway` for non-prod.

## Usage

```hcl
module "network" {
  source = "../../modules/network"

  name            = "kb-eu-prod"
  geo             = "eu"
  env             = "prod"
  region          = "eu-central-1"
  allowed_regions = ["eu-central-1", "eu-west-1"]

  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnet_cidrs = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
  intra_subnet_cidrs   = ["10.10.48.0/22", "10.10.52.0/22", "10.10.56.0/22"]
  public_subnet_cidrs  = ["10.10.60.0/24", "10.10.61.0/24", "10.10.62.0/24"]

  single_nat_gateway    = false # prod: one NAT per AZ
  flow_logs_kms_key_arn = module.kms.logs_key_arn
  flow_logs_role_arn    = module.iam.flow_logs_role_arn

  tags = { cost-center = "platform" }
}
```

## Key inputs

See [`variables.tf`](variables.tf). Most-used: `name`, `geo`, `env`, `region`,
`allowed_regions`, `vpc_cidr`, `azs`, the three `*_subnet_cidrs`,
`single_nat_gateway`, `interface_endpoints`.

## Key outputs

`vpc_id`, `vpc_cidr`, `private_subnet_ids`, `intra_subnet_ids`,
`public_subnet_ids`, `private_route_table_ids`, `endpoints_security_group_id`,
`interface_endpoint_ids`, `azs`. See [`outputs.tf`](outputs.tf).

## Validate (no AWS)

```bash
tofu init -backend=false && tofu validate && tflint
```

## Phase-0/LLD follow-ups

- IPAM pool wiring for CIDR allocation (currently a variable).
- Per-environment endpoint list tuning; PrivateLink endpoint service for the
  platform API lives in the `eks`/app wiring, not here.
- Tighten the endpoints SG egress (currently all-egress for endpoint responses).
