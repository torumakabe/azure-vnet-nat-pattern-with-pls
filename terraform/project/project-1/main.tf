terraform {
  required_version = "~> 1.2.1"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.9.0"
    }

    azapi = {
      source  = "azure/azapi"
      version = "~> 0.3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "azurerm" {
  use_oidc = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}
provider "tls" {}

resource "azurerm_resource_group" "project" {
  name     = var.project_rg.name
  location = var.project_rg.location
}

resource "azurerm_virtual_network" "project" {
  name                = "vnet-project"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  address_space       = [module.project_vnet_subnet_addrs.base_cidr_block]
}

module "project_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.project_vnet.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 4
    },
    {
      name     = "aci",
      new_bits = 8
    },
    {
      name     = "agw"
      new_bits = 8
    },
    {
      name     = "pl"
      new_bits = 8
    }
  ]
}

resource "azurerm_subnet" "project_default" {
  name                                           = "snet-project-default"
  resource_group_name                            = azurerm_resource_group.project.name
  virtual_network_name                           = azurerm_virtual_network.project.name
  address_prefixes                               = [module.project_vnet_subnet_addrs.network_cidr_blocks["default"]]
  enforce_private_link_endpoint_network_policies = true
  enforce_private_link_service_network_policies  = true
}

resource "azurerm_subnet" "project_aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_default,
  ]
  name                 = "snet-project-aci"
  resource_group_name  = azurerm_resource_group.project.name
  virtual_network_name = azurerm_virtual_network.project.name
  address_prefixes     = [module.project_vnet_subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "project_agw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_aci,
  ]
  name                 = "snet-project-agw"
  resource_group_name  = azurerm_resource_group.project.name
  virtual_network_name = azurerm_virtual_network.project.name
  address_prefixes     = [module.project_vnet_subnet_addrs.network_cidr_blocks["agw"]]
}

resource "azurerm_subnet" "project_pl" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_agw,
  ]
  name                                          = "snet-project-pl"
  resource_group_name                           = azurerm_resource_group.project.name
  virtual_network_name                          = azurerm_virtual_network.project.name
  address_prefixes                              = [module.project_vnet_subnet_addrs.network_cidr_blocks["pl"]]
  enforce_private_link_service_network_policies = true
}

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location

  // Do not assign rules for SSH statically, use JIT
}

resource "azurerm_network_interface" "jumpbox" {
  name                          = "nic-jumpbox"
  resource_group_name           = azurerm_resource_group.project.name
  location                      = azurerm_resource_group.project.location
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.project_default.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  network_interface_id      = azurerm_network_interface.jumpbox.id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "vm-jumpbox"
  resource_group_name             = azurerm_resource_group.project.name
  location                        = azurerm_resource_group.project.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.jumpbox.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    diff_disk_settings {
      option = "Local"
    }
    disk_size_gb = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "aad_ssh_login_jumpbox" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_private_dns_zone" "project_fileshare" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.project.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "project_fileshare" {
  name                  = "pdnsz-link-prj1-fileshare"
  resource_group_name   = azurerm_resource_group.project.name
  private_dns_zone_name = azurerm_private_dns_zone.project_fileshare.name
  virtual_network_id    = azurerm_virtual_network.project.id
}

resource "azurerm_private_endpoint" "shared_contents" {
  name                = "pe-shared-contents-prj1-to-mt"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  subnet_id           = azurerm_subnet.project_default.id

  private_dns_zone_group {
    name                 = "pdnszg-shared-contents-prj1-to-mt"
    private_dns_zone_ids = [azurerm_private_dns_zone.project_fileshare.id]
  }

  private_service_connection {
    name                           = "pe-connection-shared-contents-prj1-to-mt"
    is_manual_connection           = false
    private_connection_resource_id = var.shared_contents.storage_account_id
    subresource_names              = ["file"]
  }
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "project_web" {
  depends_on = [
    azurerm_private_endpoint.shared_contents
  ]
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-prj1-web"
  location  = azurerm_resource_group.project.location
  parent_id = azurerm_resource_group.project.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 80
            protocol = "TCP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.project_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "index"
          secret = {
            "index.html" = base64encode(templatefile("${path.module}/contents/project-web/index.tftpl",
              {
                SERVICE_NAME = local.project_service.web.name
              }
            ))
          }
        },
        {
          name = "shared"
          azureFile = {
            shareName          = var.shared_contents.share_name
            storageAccountName = var.shared_contents.storage_account_name
            storageAccountKey  = var.shared_contents.storage_account_key
          }
        },
      ]

      containers = [
        {
          name = "nginx"
          properties = {
            image = "nginx:1.22"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 80
                protocol = "TCP"
              }
            ]

            volumeMounts = [
              {
                name      = "index"
                mountPath = "/usr/share/nginx/html"
              },
              {
                name      = "shared"
                readOnly  = true
                mountPath = "/usr/share/nginx/html/shared"
              }
            ]
          }
        }
      ]
    }
  })

  ignore_missing_property = true
  response_export_values  = ["properties.ipAddress.ip"]
}

resource "azurerm_public_ip" "agw_prj" {
  name                = "pip-agw-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "project" {
  name                = "agw-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gw-ip"
    subnet_id = azurerm_subnet.project_agw.id
  }

  // For outbound only
  frontend_ip_configuration {
    name                 = "fe-ip-ob"
    public_ip_address_id = azurerm_public_ip.agw_prj.id
  }

  frontend_port {
    name = "fe-port"
    port = 80
  }

  frontend_ip_configuration {
    name                            = "fe-ip"
    subnet_id                       = azurerm_subnet.project_agw.id
    private_ip_address_allocation   = "Static"
    private_ip_address              = cidrhost(module.project_vnet_subnet_addrs.network_cidr_blocks["agw"], 11)
    private_link_configuration_name = "pl-config"
  }

  private_link_configuration {
    name = "pl-config"
    ip_configuration {
      name                          = "pl-ip-config"
      subnet_id                     = azurerm_subnet.project_pl.id
      private_ip_address_allocation = "Dynamic"
      primary                       = true
    }
  }

  backend_address_pool {
    name         = "project-web-be-ap"
    ip_addresses = [jsondecode(azapi_resource.project_web.output).properties.ipAddress.ip]
  }

  backend_http_settings {
    name                  = "project-web-be-hs"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 10
    connection_draining {
      enabled           = true
      drain_timeout_sec = 10
    }
  }

  http_listener {
    name                           = "project-web-http-ln"
    frontend_ip_configuration_name = "fe-ip"
    frontend_port_name             = "fe-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "project-web-rule"
    rule_type                  = "Basic"
    http_listener_name         = "project-web-http-ln"
    backend_address_pool_name  = "project-web-be-ap"
    backend_http_settings_name = "project-web-be-hs"
    priority                   = 100
  }
}

resource "azurerm_private_endpoint" "agw_hub_project" {
  name                = "pe-agw-hub-to-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  subnet_id           = var.shared_endpoint_agw.subnet_id

  private_service_connection {
    name                           = "pe-connection-agw-hub-to-prj1"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_application_gateway.project.id
    subresource_names              = ["fe-ip"]
  }
}

resource "azurerm_lb" "project" {
  name                = "lbi-prj1"
  sku                 = "Standard"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location

  frontend_ip_configuration {
    name                          = "fe-ip"
    subnet_id                     = azurerm_subnet.project_default.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_public_ip" "lbi_outbound" {
  name                = "pip-lbi-ob"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "lbi_outbound" {
  name                    = "ng-lbi-ob"
  resource_group_name     = azurerm_resource_group.project.name
  location                = azurerm_resource_group.project.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

resource "azurerm_nat_gateway_public_ip_association" "lbi_outbound" {
  nat_gateway_id       = azurerm_nat_gateway.lbi_outbound.id
  public_ip_address_id = azurerm_public_ip.lbi_outbound.id
}

resource "azurerm_subnet_nat_gateway_association" "lbi_outbound" {
  subnet_id      = azurerm_subnet.project_default.id
  nat_gateway_id = azurerm_nat_gateway.lbi_outbound.id
}

resource "azurerm_lb_backend_address_pool" "jumpbox" {
  name            = "be-pool-jumpbox"
  loadbalancer_id = azurerm_lb.project.id
}

resource "azurerm_network_interface_backend_address_pool_association" "jumpbox" {
  network_interface_id    = azurerm_network_interface.jumpbox.id
  ip_configuration_name   = azurerm_network_interface.jumpbox.ip_configuration.0.name
  backend_address_pool_id = azurerm_lb_backend_address_pool.jumpbox.id
}

resource "azurerm_lb_rule" "ssh" {
  loadbalancer_id                = azurerm_lb.project.id
  name                           = "ssh"
  protocol                       = "Tcp"
  frontend_port                  = 22
  backend_port                   = 22
  frontend_ip_configuration_name = azurerm_lb.project.frontend_ip_configuration.0.name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.jumpbox.id]
}

resource "azurerm_private_link_service" "project_lbi" {
  name                = "pl-lbi-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location

  auto_approval_subscription_ids              = [data.azurerm_client_config.current.subscription_id]
  visibility_subscription_ids                 = [data.azurerm_client_config.current.subscription_id]
  load_balancer_frontend_ip_configuration_ids = [azurerm_lb.project.frontend_ip_configuration.0.id]

  nat_ip_configuration {
    name = "primary"
    // private_ip_address         = azurerm_network_interface.jumpbox.private_ip_address
    private_ip_address_version = "IPv4"
    subnet_id                  = azurerm_subnet.project_default.id
    primary                    = true
  }
}

resource "azurerm_private_endpoint" "lbi_hub_to_project" {
  name                = "pe-lbi-hub-to-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  subnet_id           = var.shared_endpoint_agw.subnet_id

  private_service_connection {
    name                           = "pe-connection-lbi-hub-prj1"
    private_connection_resource_id = azurerm_private_link_service.project_lbi.id
    is_manual_connection           = false
  }
}

resource "azurerm_private_endpoint" "agw_project_to_hub" {
  name                = "pe-agw-prj1-to-hub"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  subnet_id           = azurerm_subnet.project_default.id

  private_service_connection {
    name                           = "pe-connection-agw-prj1-to-hub"
    is_manual_connection           = false
    private_connection_resource_id = var.shared_endpoint_agw.resource_id
    subresource_names              = [var.shared_endpoint_agw.subresource_name]
  }
}

resource "azurerm_private_dns_zone" "internal_poc" {
  name                = var.shared_web.domain_name
  resource_group_name = azurerm_resource_group.project.name
}

resource "azurerm_private_dns_a_record" "project_shared_web" {
  name                = var.shared_web.host_name
  zone_name           = azurerm_private_dns_zone.internal_poc.name
  resource_group_name = azurerm_resource_group.project.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.agw_project_to_hub.private_service_connection.0.private_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "project_internal" {
  name                  = "pdnsz-link-prj1-to-internal"
  resource_group_name   = azurerm_resource_group.project.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_poc.name
  virtual_network_id    = azurerm_virtual_network.project.id
}
