terraform {
  required_version = "~> 1.2.1"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.9.0"
    }

    azapi = {
      source  = "azure/azapi"
      version = "~> 0.2.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }

    // TODO: This will be replaced with TLS provider once it supports pfx format
    // https://github.com/hashicorp/terraform-provider-tls/issues/205
    pkcs12 = {
      source  = "chilicat/pkcs12"
      version = "0.0.7"
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

data "http" "my_public_ip" {
  url = "https://ipconfig.io"
}

resource "azurerm_resource_group" "shared" {
  name     = var.shared_rg.name
  location = var.shared_rg.location
}

resource "random_string" "vpngw_shared_key" {
  length  = 16
  special = false
}

// (fake) On-premise VNet

resource "azurerm_virtual_network" "onprem" {
  name                = "vnet-onprem"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  address_space       = [module.onprem_vnet_subnet_addrs.base_cidr_block]
}

module "onprem_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.onprem_vnet.base_cidr_block
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
      name     = "vpngw"
      new_bits = 11
    },
  ]
}

resource "azurerm_subnet" "onprem_default" {
  name                 = "snet-onprem-default"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["default"]]
}

resource "azurerm_subnet" "onprem_aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.onprem_default,
  ]
  name                 = "snet-onprem-aci"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "onprem_vpngw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.onprem_aci,
  ]
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["vpngw"]]
}

resource "azurerm_public_ip" "onprem_vpngw" {
  name                = "pip-onprem-vpngw"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "onprem" {
  name                = "vpng-onprem"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  type = "Vpn"

  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "ipconf-onprem-vpngw"
    public_ip_address_id          = azurerm_public_ip.onprem_vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.onprem_vpngw.id
  }
}

resource "azurerm_virtual_network_gateway_connection" "onprem_to_hub" {
  name                = "vcn-onprem-to-hub"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  type = "Vnet2Vnet"

  virtual_network_gateway_id      = azurerm_virtual_network_gateway.onprem.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id

  shared_key = random_string.vpngw_shared_key.result
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "onprem_resolver" {
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-onprem-resolver"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 53
            protocol = "UDP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.onprem_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "config"
          secret = {
            Corefile = base64encode(templatefile("${path.module}/config/coredns-onprem/Corefile.tftpl",
              {
                RESOLVER_IP = jsondecode(azapi_resource.hub_resolver.output).properties.ipAddress.ip
              }
            ))
          }
        }
      ]

      containers = [
        {
          name = "coredns"
          properties = {
            image = "coredns/coredns:1.9.3"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 53
                protocol = "UDP"
              }
            ]

            command = ["/coredns", "-conf", "/config/Corefile"]

            volumeMounts = [
              {
                name      = "config"
                readOnly  = true
                mountPath = "/config"
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

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  // Do not assign rules for SSH statically, use JIT
}

resource "azurerm_public_ip" "client" {
  name                = "pip-client"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "client" {
  name                          = "nic-client"
  resource_group_name           = azurerm_resource_group.shared.name
  location                      = azurerm_resource_group.shared.location
  enable_accelerated_networking = true
  dns_servers                   = [jsondecode(azapi_resource.onprem_resolver.output).properties.ipAddress.ip]

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.onprem_default.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.client.id
  }
}

resource "azurerm_network_interface_security_group_association" "client" {
  network_interface_id      = azurerm_network_interface.client.id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "client" {
  name                            = "vm-client"
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = azurerm_resource_group.shared.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.client.id,
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

  user_data = filebase64("${path.module}/cloud-init/vm-client/cloud-config.yaml")
}

resource "azurerm_virtual_machine_extension" "aad_ssh_login_client" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.client.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

// Hub VNet

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  address_space       = [module.hub_vnet_subnet_addrs.base_cidr_block]
}

module "hub_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.hub_vnet.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 4
    },
    {
      name     = "aci"
      new_bits = 8
    },
    {
      name     = "agw"
      new_bits = 8
    },
    {
      name     = "pl"
      new_bits = 8
    },
    {
      name     = "vpngw"
      new_bits = 11
    }
  ]
}

resource "azurerm_subnet" "hub_default" {
  name                                           = "snet-hub-default"
  resource_group_name                            = azurerm_resource_group.shared.name
  virtual_network_name                           = azurerm_virtual_network.hub.name
  address_prefixes                               = [module.hub_vnet_subnet_addrs.network_cidr_blocks["default"]]
  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_subnet" "hub_aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_default,
  ]
  name                 = "snet-hub-aci"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [module.hub_vnet_subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "hub_vpngw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_aci,
  ]
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [module.hub_vnet_subnet_addrs.network_cidr_blocks["vpngw"]]
}

resource "azurerm_subnet" "hub_agw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_vpngw,
  ]
  name                 = "snet-hub-agw"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [module.hub_vnet_subnet_addrs.network_cidr_blocks["agw"]]
}

resource "azurerm_subnet" "hub_pl" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_agw,
  ]
  name                                          = "snet-hub-pl"
  resource_group_name                           = azurerm_resource_group.shared.name
  virtual_network_name                          = azurerm_virtual_network.hub.name
  address_prefixes                              = [module.hub_vnet_subnet_addrs.network_cidr_blocks["pl"]]
  enforce_private_link_service_network_policies = true
}

resource "azurerm_public_ip" "hub_vpngw" {
  name                = "pip-hub-vpngw"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "vpng-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  type = "Vpn"

  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "ipconf-hub-vpngw"
    public_ip_address_id          = azurerm_public_ip.hub_vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.hub_vpngw.id
  }
}

resource "azurerm_virtual_network_gateway_connection" "hub_to_onprem" {
  name                = "vcn-hub-to-onprem"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  type = "Vnet2Vnet"

  virtual_network_gateway_id      = azurerm_virtual_network_gateway.hub.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem.id

  shared_key = random_string.vpngw_shared_key.result
}

resource "azurerm_storage_account" "shared_contents" {
  name                     = "${var.prefix}sharedcontents"
  resource_group_name      = azurerm_resource_group.shared.name
  location                 = azurerm_resource_group.shared.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    default_action = "Deny"
    ip_rules       = [chomp(data.http.my_public_ip.body)]
  }
}

resource "azurerm_storage_share" "shared_contents" {
  name                 = "shared"
  storage_account_name = azurerm_storage_account.shared_contents.name
  quota                = 1
}

resource "azurerm_storage_share_file" "shared_html" {
  name             = "shared.html"
  storage_share_id = azurerm_storage_share.shared_contents.id
  source           = "${path.module}/contents/shared-web/shared.html"
}

resource "azurerm_private_dns_zone" "hub_fileshare" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.shared.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_fileshare" {
  name                  = "pdnsz-link-hub-fileshare"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.hub_fileshare.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

resource "azurerm_private_endpoint" "hub_shared_contents" {
  name                = "pe-shared-contents-hub-to-mt"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  subnet_id           = azurerm_subnet.hub_default.id

  private_dns_zone_group {
    name                 = "pdnszg-shared-contents-hub-to-mt"
    private_dns_zone_ids = [azurerm_private_dns_zone.hub_fileshare.id]
  }

  private_service_connection {
    name                           = "pe-connection-shared-contents-hub-to-mt"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.shared_contents.id
    subresource_names              = ["file"]
  }
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "hub_resolver" {
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-hub-resolver"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 53
            protocol = "UDP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.hub_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "config"
          secret = {
            Corefile = base64encode(file("${path.module}/config/coredns-hub/Corefile"))
          }
        }
      ]

      containers = [
        {
          name = "coredns"
          properties = {
            image = "coredns/coredns:1.9.3"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 53
                protocol = "UDP"
              }
            ]

            command = ["/coredns", "-conf", "/config/Corefile"]

            volumeMounts = [
              {
                name      = "config"
                readOnly  = true
                mountPath = "/config"
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

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  validity_period_hours = 8766
  early_renewal_hours   = 720
  is_ca_certificate     = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing"
  ]

  subject {
    common_name  = "Sample CA"
    organization = "Sample"
  }
}

resource "tls_private_key" "shared_web" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "tls_cert_request" "shared_web" {
  private_key_pem = tls_private_key.shared_web.private_key_pem

  subject {
    common_name  = "${local.shared_service.web.name}.${local.internal_domain.name}"
    organization = "Internal"
  }
}

resource "tls_locally_signed_cert" "shared_web" {
  cert_request_pem      = tls_cert_request.shared_web.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8766

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

// TODO: This will be replaced with TLS provider once it supports pfx format
// https://github.com/hashicorp/terraform-provider-tls/issues/205
resource "pkcs12_from_pem" "shared_web" {
  password        = "super-secret"
  cert_pem        = tls_locally_signed_cert.shared_web.cert_pem
  private_key_pem = tls_private_key.shared_web.private_key_pem
  ca_pem          = tls_self_signed_cert.ca.cert_pem
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "shared_web" {
  depends_on = [
    azurerm_private_endpoint.hub_shared_contents
  ]
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-shared-web"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 443
            protocol = "TCP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.hub_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "index"
          secret = {
            "index.html" = base64encode(templatefile("${path.module}/contents/shared-web/index.tftpl",
              {
                SERVICE_NAME = local.shared_service.web.name
              }
            ))
          }
        },
        {
          name = "shared"
          azureFile = {
            shareName          = azurerm_storage_share.shared_contents.name
            storageAccountName = azurerm_storage_account.shared_contents.name
            storageAccountKey  = azurerm_storage_account.shared_contents.primary_access_key
          }
        },
        {
          name = "nginx-config"
          secret = {
            "ssl.crt"    = base64encode(tls_locally_signed_cert.shared_web.cert_pem)
            "ssl.key"    = base64encode(tls_private_key.shared_web.private_key_pem)
            "nginx.conf" = base64encode(file("${path.module}/config/shared-web/nginx.conf"))
          }
        },
      ]

      containers = [
        {
          name = "tls-sidecar"
          properties = {
            image = "nginx:1.22"

            resources = {
              requests = {
                cpu        = 0.5
                memoryInGB = 0.5
              }
            }

            ports = [
              {
                port     = 443
                protocol = "TCP"
              }
            ]

            volumeMounts = [
              {
                name      = "nginx-config"
                readOnly  = true
                mountPath = "/etc/nginx"
              }
            ]
          }
        },
        {
          name = "nginx"
          properties = {
            image = "nginx:1.22"

            resources = {
              requests = {
                cpu        = 0.5
                memoryInGB = 0.5
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

resource "azurerm_private_dns_zone" "internal_poc" {
  name                = local.internal_domain.name
  resource_group_name = azurerm_resource_group.shared.name
}

resource "azurerm_private_dns_a_record" "hub_shared_web" {
  name                = local.shared_service.web.name
  zone_name           = azurerm_private_dns_zone.internal_poc.name
  resource_group_name = azurerm_resource_group.shared.name
  ttl                 = 300
  records             = ["${jsondecode(azapi_resource.shared_web.output).properties.ipAddress.ip}"]
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_internal" {
  name                  = "pdnsz-link-hub-internal"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_poc.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

resource "azurerm_public_ip" "agw_hub" {
  name                = "pip-agw-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "hub" {
  name                = "agw-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gw-ip"
    subnet_id = azurerm_subnet.hub_agw.id
  }

  // For outbound only
  frontend_ip_configuration {
    name                 = "fe-ip-ob"
    public_ip_address_id = azurerm_public_ip.agw_hub.id
  }

  frontend_port {
    name = "fe-port"
    port = 443
  }

  ssl_certificate {
    name     = "cert-shared-web"
    password = "super-secret"
    data     = pkcs12_from_pem.shared_web.result
  }

  trusted_root_certificate {
    name = "cert-ca"
    data = base64encode(tls_self_signed_cert.ca.cert_pem)
  }

  frontend_ip_configuration {
    name                            = "fe-ip"
    subnet_id                       = azurerm_subnet.hub_agw.id
    private_ip_address_allocation   = "Static"
    private_ip_address              = cidrhost(module.hub_vnet_subnet_addrs.network_cidr_blocks["agw"], 11)
    private_link_configuration_name = "pl-config"
  }

  private_link_configuration {
    name = "pl-config"
    ip_configuration {
      name                          = "pl-ip-config"
      subnet_id                     = azurerm_subnet.hub_pl.id
      private_ip_address_allocation = "Dynamic"
      primary                       = true
    }
  }

  backend_address_pool {
    name  = "shared-web-be-ap"
    fqdns = [trimsuffix(azurerm_private_dns_a_record.hub_shared_web.fqdn, ".")]
  }

  backend_http_settings {
    name                                = "shared-web-be-hs"
    cookie_based_affinity               = "Disabled"
    path                                = "/"
    port                                = 443
    protocol                            = "Https"
    trusted_root_certificate_names      = ["cert-ca"]
    pick_host_name_from_backend_address = true
    request_timeout                     = 10
    connection_draining {
      enabled           = true
      drain_timeout_sec = 10
    }
  }

  http_listener {
    name                           = "shared-web-http-ln"
    frontend_ip_configuration_name = "fe-ip"
    frontend_port_name             = "fe-port"
    protocol                       = "Https"
    ssl_certificate_name           = "cert-shared-web"
    host_name                      = trimsuffix(azurerm_private_dns_a_record.hub_shared_web.fqdn, ".")
  }

  request_routing_rule {
    name                       = "shared-web-rule"
    rule_type                  = "Basic"
    http_listener_name         = "shared-web-http-ln"
    backend_address_pool_name  = "shared-web-be-ap"
    backend_http_settings_name = "shared-web-be-hs"
    priority                   = 100
  }
}
