# AKS CoreDNS behavior and failover validation

This directory documents how the CoreDNS `forward` plugin behaves in Azure Kubernetes Service (AKS), with a focus on upstream DNS selection, timeout behavior, failover, health checking, and application impact.

The responses combine CoreDNS and AKS guidance with repeatable validation procedures and retained evidence from an isolated AKS test environment. They distinguish CoreDNS capabilities from the AKS-supported customization boundary and avoid modifying managed `kube-system` resources during testing.

## Responses

1. [Selection policy](responses/01-Selection-policy.md) explains the available upstream selection policies, including sequential selection, and how policy interacts with upstream eligibility, caching, and AKS customization.
2. [Timeout before trying another upstream](responses/02-Timeout-before-next-upstream.md) describes CoreDNS dial and read timeouts, how different network failures affect delay, and how client deadlines influence the result.
3. [Failover mechanism](responses/03-Failover-mechanism.md) explains request-level fallback, learned upstream health, DNS response-code handling, recovery, and behavior when every upstream is unavailable.
4. [Active health checks](responses/04-Active-health-checks.md) covers the error-triggered health-check loop, probe behavior, `max_fails`, endpoint eligibility, and recovery.
5. [Application and user impact](responses/05-Application-and-user-impact.md) describes how DNS failures can produce increased latency, lookup errors, retry amplification, and user-visible effects depending on application behavior.

## Validation assets

The [validation](validation/) directory contains the Kubernetes manifests, PowerShell deployment and test scripts, cleanup tooling, and retained test results used to validate the documented behavior.

Run validation only in an authorized test cluster. Review each response's prerequisites, safety guidance, expected results, pass/fail criteria, and cleanup instructions before executing a test.

