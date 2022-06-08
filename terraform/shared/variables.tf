variable "prefix" {
  type = string
}

variable "shared_rg" {
  type = object({
    name     = string
    location = string
  })
  default = {
    name     = "rg-vnet-nat-pattern-with-pl-shared"
    location = "japaneast"
  }
}

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}
