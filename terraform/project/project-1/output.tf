output "pe_agw_hub_to_prj1_ip" {
  value = azurerm_private_endpoint.agw_hub_project.private_service_connection.0.private_ip_address
}

output "pe_lbi_hub_to_prj1_ip" {
  value = azurerm_private_endpoint.lbi_hub_to_project.private_service_connection.0.private_ip_address
}
