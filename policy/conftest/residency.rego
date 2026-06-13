# Residency gate (ADR-0007) — fail any out-of-geo region literal.
#
# Runs in CI against `terraform show -json` (plan JSON) and is unit-tested via
# `conftest verify` (see residency_test.rego). It walks every string value in the
# input and denies any AWS region/AZ that is not in the geo's allow-list.
#
# Input contract:
#   input.parameters.allowed_regions : ["eu-central-1","eu-west-1"]  (the geo allow-list)
#   everything else                  : the terraform plan JSON (or any config object)
#
# This is the "shift-left" twin of the SCP region-deny: the SCP stops it at
# runtime, this stops it before apply.
package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# Matches an AWS region core, e.g. eu-central-1, us-east-1 (AZ suffix ignored).
region_pattern := `((?:us|eu|ap|sa|ca|me|af|il|cn|gov)-[a-z]+-[0-9]+)`

allowed_regions := input.parameters.allowed_regions

# The config to scan (exclude the parameters block we injected).
scan_target := object.remove(input, ["parameters"])

region_allowed(r) if {
	some a in allowed_regions
	a == r
}

deny contains msg if {
	some path, val
	walk(scan_target, [path, val])
	is_string(val)
	matches := regex.find_all_string_submatch_n(region_pattern, val, -1)
	some m in matches
	r := m[1]
	not region_allowed(r)
	msg := sprintf("RESIDENCY VIOLATION: out-of-geo region '%s' found at path %v (allowed: %v)", [r, path, allowed_regions])
}
