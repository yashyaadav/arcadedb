# Unit tests for the residency gate — run with `conftest verify --policy policy/conftest`.
package main

import future.keywords.if

# An in-geo plan (EU) must produce NO denials.
test_in_geo_allowed if {
	count(deny) == 0 with input as {
		"parameters": {"allowed_regions": ["eu-central-1", "eu-west-1"]},
		"planned_values": {"root_module": {"resources": [
			{"type": "aws_subnet", "values": {"availability_zone": "eu-central-1a"}},
			{"type": "aws_s3_bucket", "values": {"region": "eu-west-1"}},
		]}},
	}
}

# An out-of-geo region (US) in an EU plan MUST be denied.
test_out_of_geo_denied if {
	count(deny) > 0 with input as {
		"parameters": {"allowed_regions": ["eu-central-1", "eu-west-1"]},
		"planned_values": {"root_module": {"resources": [
			{"type": "aws_subnet", "values": {"availability_zone": "us-east-1a"}},
		]}},
	}
}

# A cross-region replication destination outside the geo MUST be denied.
test_cross_geo_replication_denied if {
	count(deny) > 0 with input as {
		"parameters": {"allowed_regions": ["eu-central-1", "eu-west-1"]},
		"planned_values": {"root_module": {"resources": [
			{"type": "aws_s3_bucket_replication_configuration", "values": {"destination_arn": "arn:aws:s3:us-west-2:123:bucket"}},
		]}},
	}
}
