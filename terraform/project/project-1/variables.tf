variable "prefix" {
  type = string
}

variable "project_rg" {
  type = object({
    name     = string
    location = string
  })
  default = {
    name     = "rg-vnet-nat-pattern-with-pl-project-1"
    location = "japaneast"
  }
}

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}

variable "shared_rg" {
  type = object({
    name     = string
    location = string
  })
  default = {
    name     = "rg-vnet-nat-pattern-with-pl-project-1"
    location = "japaneast"
  }
}

variable "shared_endpoint_agw" {
  type = object({
    subnet_id        = string
    resource_id      = string
    subresource_name = string
  })
}

variable "shared_web" {
  type = object({
    domain_name = string
    host_name   = string
  })
}

variable "shared_contents" {
  type = object({
    share_name           = string
    storage_account_name = string
    storage_account_id   = string
    storage_account_key  = string
  })
}
