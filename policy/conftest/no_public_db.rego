# "No public database" gate (prime directive #4) — fail any security group that
# opens an ArcadeDB port to the world (0.0.0.0/0 or ::/0).
#
# Runs in CI against `terraform show -json` and is unit-tested via `conftest
# verify` (see no_public_db_test.rego).
#
# Input contract: terraform plan JSON. We inspect aws_security_group(_rule)
# ingress for DB ports overlapping a public CIDR.
package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# ArcadeDB-relevant ports that must NEVER be public.
db_ports := {2480, 2424, 2434, 5432, 6379, 7687}

public_cidrs := {"0.0.0.0/0", "::/0"}

# Collect every resource's "after"/"values" object from common plan shapes.
resource_values contains rv if {
	rc := input.resource_changes[_]
	rv := {"type": rc.type, "values": rc.change.after}
}

resource_values contains rv if {
	r := input.planned_values.root_module.resources[_]
	rv := {"type": r.type, "values": r.values}
}

port_in_range(rule, p) if {
	rule.from_port <= p
	p <= rule.to_port
}

has_public_cidr(rule) if {
	some c in rule.cidr_blocks
	c in public_cidrs
}

has_public_cidr(rule) if {
	some c in rule.ipv6_cidr_blocks
	c in public_cidrs
}

deny contains msg if {
	rv := resource_values[_]
	rv.type == "aws_security_group"
	ingress := rv.values.ingress[_]
	some p in db_ports
	port_in_range(ingress, p)
	has_public_cidr(ingress)
	msg := sprintf("NO PUBLIC DB VIOLATION: security group opens DB port %d to a public CIDR (prime directive #4)", [p])
}

deny contains msg if {
	rv := resource_values[_]
	rv.type == "aws_security_group_rule"
	rv.values.type == "ingress"
	some p in db_ports
	port_in_range(rv.values, p)
	has_public_cidr(rv.values)
	msg := sprintf("NO PUBLIC DB VIOLATION: security group rule opens DB port %d to a public CIDR (prime directive #4)", [p])
}
