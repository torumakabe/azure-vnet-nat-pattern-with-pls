locals {
  tenant_id = data.azurerm_client_config.current.tenant_id
  current_client = {
    subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
    object_id       = data.azurerm_client_config.current.object_id
  }
  project_vnet = {
    base_cidr_block = "10.0.0.0/16"
  }
  project_service = {
    web = {
      name = "project1-web"
    }
  }
}

data "azurerm_client_config" "current" {}
