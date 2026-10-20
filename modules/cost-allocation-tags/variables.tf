variable "tag_keys" {
  description = "Tag keys to activate as cost allocation tags, for example `[\"Environment\", \"Project\"]`. Write each key as it appears on your resources, without the `user:` prefix. AWS refuses to activate a key that no billed resource has used yet, so tag a resource first. Activation is not retroactive, and the data can take up to 24 hours to show."
  type        = list(string)

  validation {
    condition     = alltrue([for k in var.tag_keys : can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+@-]{1,128}$", k))])
    error_message = "Every tag key must be 1 to 128 characters of letters, digits, spaces and _ . : / = + - @."
  }

  validation {
    condition     = alltrue([for k in var.tag_keys : !startswith(k, "user:")])
    error_message = "Write tag keys without the `user:` prefix. AWS adds it in the console."
  }

  validation {
    condition     = length(distinct(var.tag_keys)) == length(var.tag_keys)
    error_message = "tag_keys must not repeat a key."
  }
}
