# AKS CoreDNS behavior and failover validation

This directory documents how the CoreDNS `forward` plugin behaves in Azure Kubernetes Service (AKS), with a focus on upstream DNS selection, timeout behavior, failover, health checking, application impact, and persistence of supported custom configuration.

The responses combine CoreDNS and AKS guidance with repeatable validation procedures and retained evidence from an AKS test environment. They distinguish CoreDNS capabilities from the AKS-supported customization boundary. Most behavior tests use isolated namespace-local resources. The explicitly approved persistence tests also cover a temporary `coredns-custom` rule, managed CoreDNS rolling restarts, and a control-plane-only upgrade; they do not directly edit the managed main Corefile.

## Responses

1. [Selection policy and custom configuration persistence](responses/01-Selection-policy.md) explains upstream selection policies, eligibility, caching, the AKS customization boundary, and whether `coredns-custom` survives observation, pod replacement, and a tested upgrade.
2. [Timeout before trying another upstream](responses/02-Timeout-before-next-upstream.md) describes CoreDNS dial and read timeouts, how different network failures affect delay, and how client deadlines influence the result.
3. [Failover mechanism](responses/03-Failover-mechanism.md) explains request-level fallback, learned upstream health, DNS response-code handling, recovery, and behavior when every upstream is unavailable.
4. [Active health checks](responses/04-Active-health-checks.md) covers the error-triggered health-check loop, probe behavior, `max_fails`, endpoint eligibility, and recovery.
5. [Application and user impact](responses/05-Application-and-user-impact.md) describes how DNS failures can produce increased latency, lookup errors, retry amplification, and user-visible effects depending on application behavior.

## Validation assets

The [validation](validation/) directory contains the Kubernetes manifests, PowerShell deployment and test scripts, cleanup tooling, and retained test results used to validate the documented behavior.

### Custom configuration persistence results

- [SP-14: observation](validation/results/aks01day2-custom-config-20261002-live.md) - PASS on attempt 2: 31 unchanged snapshots over 1,154.510 seconds.
- [SP-15: control-plane upgrade](validation/results/aks01day2-custom-config-20261002-sp15.md) - PARTIAL PASS: the actual 1.35.7 to 1.36.3 control-plane upgrade preserved custom data and identity, but the rotating public DNS answer did not meet the fixed-address assertion. Node pools remained on 1.35.7.
- [SP-16: one-time patch persistence](validation/results/aks01day2-custom-config-20261002-sp16.md) - PASS on attempt 2: the rule survived pod replacement and 31 snapshots over 1,183.785 seconds; all 31 DNS checks met their assertions and cleanup was verified.

The [standalone SP-16 runner](validation/Test-CoreDNSCustomConfigPersistence.ps1) automatically loads the [shared lifecycle helper](validation/CoreDNSCustomConfig.Helpers.ps1). Failed attempts and their cleanup results are retained separately; the reports state the limits of each result.

Run validation only in an authorized test cluster. Review each response's prerequisites, safety guidance, expected results, pass/fail criteria, and cleanup instructions before executing a test.

## Technical blog

- [CoreDNS in AKS: service discovery, upstream DNS, and failover](blog/AKS-CoreDNS-Failover-Blog.md).
- [Word edition](blog/CoreDNS_in_AKS.docx).
- Banner artwork: [PNG](blog/AKS-CoreDNS-Failover-Banner.png) and [SVG](blog/AKS-CoreDNS-Failover-Banner.svg).
