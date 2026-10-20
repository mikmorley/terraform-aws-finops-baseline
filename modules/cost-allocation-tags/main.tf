resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(var.tag_keys)

  tag_key = each.value
  status  = "Active"
}
