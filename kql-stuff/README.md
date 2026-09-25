# AKS KQL and Azure Resource Graph queries

This directory contains read-only queries and guidance for investigating Azure Kubernetes Service (AKS) resource configuration. The documents are intended for cluster inventory, capacity assessment, and troubleshooting in Azure Resource Graph or the specified Kusto environment.

## Query guides

1. [AKS and VMSS tag queries](AKS-ARG-TAG-QUERIES.md) provides Azure Resource Graph queries for counting tags on AKS clusters and associated Virtual Machine Scale Sets, identifying resources nearing the 50-tag limit, and reviewing remaining tag capacity.
2. [AKS networking queries](AKS-NETWORKING-QUERIES.md) provides an Azure Resource Graph query for classifying current AKS networking configurations and a complementary Kusto snapshot query for historical investigation of Kubenet and Azure CNI Overlay configurations.

Review each guide's access requirements, execution environment, interpretation guidance, and limitations before running its queries.

