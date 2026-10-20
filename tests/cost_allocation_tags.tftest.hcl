mock_provider "aws" {}

run "activates_each_key" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = ["Project", "Environment"]
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 2
    error_message = "Expected one cost allocation tag per key."
  }

  assert {
    condition     = alltrue([for t in aws_ce_cost_allocation_tag.this : t.status == "Active"])
    error_message = "Every tag should be Active."
  }

  assert {
    condition     = aws_ce_cost_allocation_tag.this["Project"].tag_key == "Project" && aws_ce_cost_allocation_tag.this["Environment"].tag_key == "Environment"
    error_message = "Each resource should use its own key."
  }

  assert {
    condition     = join(",", output.active_tag_keys) == "Environment,Project"
    error_message = "The output should list the keys in sorted order."
  }
}

run "empty_list_creates_nothing" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = []
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 0
    error_message = "No keys should create no resources."
  }
}

run "accepts_keys_with_allowed_punctuation" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = ["cost-center", "team:platform", "app/name", "Owner Email"]
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 4
    error_message = "Keys with letters, digits, spaces and _ . : / = + - @ should be accepted."
  }
}

run "rejects_empty_key" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = [""]
  }

  expect_failures = [var.tag_keys]
}

run "rejects_key_with_user_prefix" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = ["user:Environment"]
  }

  expect_failures = [var.tag_keys]
}

run "rejects_repeated_key" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = ["Project", "Project"]
  }

  expect_failures = [var.tag_keys]
}

run "rejects_key_with_illegal_character" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = ["Project$"]
  }

  expect_failures = [var.tag_keys]
}

run "rejects_key_over_128_characters" {
  command = plan

  module {
    source = "./modules/cost-allocation-tags"
  }

  variables {
    tag_keys = [join("", [for i in range(129) : "a"])]
  }

  expect_failures = [var.tag_keys]
}
