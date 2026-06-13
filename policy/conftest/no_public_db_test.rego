# Unit tests for the no-public-DB gate — `conftest verify --policy policy/conftest`.
package main

import future.keywords.if

# A private SG (DB ports only from the VPC CIDR) must produce NO denials.
test_private_db_sg_allowed if {
	count(deny) == 0 with input as {"resource_changes": [{
		"type": "aws_security_group",
		"change": {"after": {"ingress": [{
			"from_port": 2480, "to_port": 2480,
			"cidr_blocks": ["10.0.0.0/16"], "ipv6_cidr_blocks": [],
		}]}},
	}]}
}

# A DB port open to 0.0.0.0/0 MUST be denied.
test_public_db_port_denied if {
	count(deny) > 0 with input as {"resource_changes": [{
		"type": "aws_security_group",
		"change": {"after": {"ingress": [{
			"from_port": 2480, "to_port": 2480,
			"cidr_blocks": ["0.0.0.0/0"], "ipv6_cidr_blocks": [],
		}]}},
	}]}
}

# A wide port range (0-65535) to the world that includes a DB port MUST be denied.
test_wide_range_to_world_denied if {
	count(deny) > 0 with input as {"resource_changes": [{
		"type": "aws_security_group",
		"change": {"after": {"ingress": [{
			"from_port": 0, "to_port": 65535,
			"cidr_blocks": ["0.0.0.0/0"], "ipv6_cidr_blocks": [],
		}]}},
	}]}
}

# A security_group_rule opening Bolt (7687) to the world MUST be denied.
test_sg_rule_public_bolt_denied if {
	count(deny) > 0 with input as {"resource_changes": [{
		"type": "aws_security_group_rule",
		"change": {"after": {
			"type": "ingress", "from_port": 7687, "to_port": 7687,
			"cidr_blocks": ["0.0.0.0/0"], "ipv6_cidr_blocks": [],
		}},
	}]}
}
