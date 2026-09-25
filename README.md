# AKS technical guides and validation resources

This repository contains practical documentation, queries, validation procedures, and retained evidence for investigating Azure Kubernetes Service (AKS) behavior and configuration.

## Contents

### [CoreDNS](coredns/)

Documentation and repeatable validation assets for AKS CoreDNS upstream behavior, including selection policies, timeouts, failover, active health checks, recovery, and application impact.

See the [CoreDNS guide](coredns/README.md) for links to the individual responses and validation resources.

### [KQL and Azure Resource Graph queries](kql-stuff/)

Read-only query guides for AKS resource investigation, including AKS and VMSS tag-capacity assessment, current networking configuration inventory, and historical networking analysis.

See the [KQL query guide](kql-stuff/README.md) for links to the available query documents.

## Usage

Review each folder's README, prerequisites, permissions, limitations, and safety guidance before running commands or queries. Execute validation procedures only in an authorized environment.

