output "active_tag_keys" {
  description = "Tag keys this module activates as cost allocation tags."
  value       = sort(keys(aws_ce_cost_allocation_tag.this))
}
