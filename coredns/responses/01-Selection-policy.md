### 1\. Selection policy and custom configuration persistence

#### Table of Contents

*   [Introduction](#introduction)
*   [Answer](#answer)
    *   [Can Microsoft change the AKS-managed Corefile to sequential?](#can-microsoft-change-the-aks-managed-corefile-to-sequential)
    *   [Will upgrades or reconciliation remove coredns-custom?](#will-upgrades-or-reconciliation-remove-coredns-custom)
    *   [Persistence of custom configuration](#persistence-of-custom-configuration)
    *   [How to check the actual management labels](#how-to-check-the-actual-management-labels)
*   [Detailed theory](#detailed-theory)
    *   [Policy semantics](#policy-semantics)
    *   [Transport errors, DNS RCODEs, and health](#transport-errors-dns-rcodes-and-health)
    *   [Caching and statistically meaningful queries](#caching-and-statistically-meaningful-queries)
    *   [AKS customization boundary](#aks-customization-boundary)
    *   [Reconciliation is not configuration reload](#reconciliation-is-not-configuration-reload)
*   [Items to Validate](#items-to-validate)
*   [Dedicated selection-policy validation suite](#dedicated-selection-policy-validation-suite)
    *   [Common prerequisites](#common-prerequisites)
    *   [Fixture-extension helper](#fixture-extension-helper)
    *   [Read-only ConfigMap lifecycle helper](#read-only-configmap-lifecycle-helper)
    *   [SP-00: Managed baseline and default](#sp-00-managed-default-random-managed-baseline-and-default)
    *   [SP-01: Omitted policy behavior](#sp-01-default-random-sample-omitted-policy-behavior)
    *   [SP-02: Explicit random policy](#sp-02-explicit-random-sample-explicit-random-policy)
    *   [SP-03: Round-robin with two healthy upstreams](#sp-03-round-robin-healthy-round-robin-with-two-healthy-upstreams)
    *   [SP-04: First healthy upstream preference](#sp-04-sequential-healthy-order-first-healthy-upstream-preference)
    *   [SP-05: First upstream unavailable](#sp-05-sequential-primary-failure-first-upstream-unavailable)
    *   [SP-06: Preferred secondary unavailable](#sp-06-sequential-secondary-failure-preferred-secondary-unavailable)
    *   [SP-07: Preferred upstream re-enters service](#sp-07-sequential-recovery-preferred-upstream-re-enters-service)
    *   [SP-08: RCODE is not transport failure](#sp-08-dns-rcode-vs-selection-rcode-is-not-transport-failure)
    *   [SP-09: Repeated trials](#sp-09-repeatability-and-sample-size-repeated-trials)
    *   [SP-10: Parser and image compatibility](#sp-10-syntax-and-version-parser-and-image-compatibility)
    *   [SP-11: Read-only AKS configuration inspection](#sp-11-aks-support-boundary-read-only-aks-configuration-inspection)
    *   [SP-12: Logs and forward metrics](#sp-12-observability-logs-and-forward-metrics)
    *   [SP-13: Remove test resources](#sp-13-cleanup-and-noninterference-remove-test-resources)
    *   [SP-14: Observe custom configuration over time](#sp-14-custom-config-observation-observe-custom-configuration-over-time)
    *   [SP-15: Compare custom configuration across an approved upgrade](#sp-15-custom-config-upgrade-compare-custom-configuration-across-an-approved-upgrade)
    *   [SP-16: Apply once and verify custom DNS persistence](#sp-16-custom-config-patch-persistence-apply-once-and-verify-custom-dns-persistence)
*   [Evidence handling](#evidence-handling)
*   [Limitations](#limitations)
*   [Conclusion](#conclusion)
*   [Authoritative links](#authoritative-links)

#### Introduction

AKS deploys CoreDNS as the cluster DNS service. Workload pods normally send DNS queries to the `kube-dns` Service, and the AKS-managed CoreDNS configuration decides whether to answer locally or forward a query to an upstream resolver. Selection policy matters only when a `forward` stanza has more than one eligible upstream. It determines which healthy upstream CoreDNS tries first; it does not replace transport retry, health checking, response-code failover, caching, or the retry and timeout behavior of the calling application.

There are two separate questions in AKS:

1.  Does the CoreDNS `forward` plugin support ordered upstream selection?
2.  Can that policy be applied through an AKS-supported customization boundary?

The first answer is determined by the CoreDNS version and is testable in an isolated namespace. The second is determined by AKS support policy. AKS owns the main `coredns` ConfigMap and Deployment in `kube-system`; directly editing their managed configuration is not a durable or supported customization. Microsoft documents the `coredns-custom` ConfigMap for custom server blocks and overrides. SP-00 through SP-15 do not write `kube-system` resources. **SP-16 is a separately approved exception:** it adds one temporary custom key and uses the documented CoreDNS rolling-restart procedure to validate activation and persistence. It never edits the managed main Corefile and removes only its own test key afterward.

#### Answer

**Question:** Can CoreDNS upstream selection be changed from round-robin to sequential?

Yes. CoreDNS supports `random`, `round_robin`, and `sequential` in the `forward` plugin. To prefer upstreams in configured order, use:

```
forward . 10.0.0.20 10.0.0.21 {
    policy sequential
}
```

However, the premise that the current AKS behavior is round-robin must first be verified. In CoreDNS 1.13.1, omitting `policy` means `random`, not `round_robin`. The established `aks01day2` baseline used `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20` and its managed Corefile contained `forward . /etc/resolv.conf` with no explicit policy. Therefore, its effective policy was the version-matched default, `random`.

A domain-specific `coredns-custom` server block can use the built-in `forward` plugin with `policy sequential`. This validation does not prove that the AKS-managed root forwarder can be globally replaced or overridden in a supported way. Obtain current Microsoft guidance before attempting that cluster-wide production change.

##### Can Microsoft change the AKS-managed Corefile to sequential?

**Microsoft controls the AKS-managed Corefile, but there is no documented customer setting that asks AKS to change its managed root `forward` block from the default policy to `sequential`.** Microsoft could change the managed implementation through an AKS product update, but customers cannot directly edit that main Corefile or rely on a support request to make a customer-specific change to it.

Microsoft's AKS documentation states that AKS is a managed service, customers cannot modify the main CoreDNS Corefile, and supported customization must use the separate `coredns-custom` ConfigMap. Therefore:

*   **For a specific DNS domain:** use a supported `.server` entry in `coredns-custom` and place `policy sequential` inside that custom forward block.
*   **For every externally forwarded DNS query:** the current documentation does not provide a supported customer option to replace the AKS-managed root directive `forward . /etc/resolv.conf` with a sequential policy.
*   **If the requirement is a Microsoft-managed global change:** raise it with Microsoft as a product/support question or feature request. Do not present it as an available AKS configuration until Microsoft confirms and documents that capability.

Reference: [Customize CoreDNS for Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/coredns-custom).

##### Will upgrades or reconciliation remove coredns-custom?

**Question:** Will the `coredns-custom` ConfigMap be wiped out during AKS upgrades, or reset by reconciliation at a fixed interval?

**Normally, no.** `kube-system/coredns-custom` is the supported place for customer DNS configuration, and its entries are expected to remain across normal AKS upgrades. On `aks01day2`, the completed tests verified that existing custom data survived the tested control-plane upgrade, and that a newly applied rule remained active through CoreDNS pod replacement and a finite observation window. This is separate from the AKS-managed `kube-system/coredns` ConfigMap, whose main Corefile AKS controls and may replace or reconcile.

The distinction matters:

| Resource or operation | What to expect |
| --- | --- |
| `coredns` ConfigMap and CoreDNS Deployment | AKS manages these resources. Direct changes to the main Corefile are unsupported and must not be relied on to survive reconciliation or upgrades. |
| `coredns-custom` ConfigMap | Use supported `.server` and `.override` entries for customer configuration. A normal upgrade is not intended to clear those entries. Keep the desired configuration in source control and validate it before and after upgrades. |
| CoreDNS pod replacement | Replacing a pod does not itself delete a separate ConfigMap. The new pod must still be able to load the custom configuration with the upgraded CoreDNS version. |
| GitOps, Helm, scripts, or an administrator | Another writer can replace or delete this ConfigMap. An empty desired-state manifest or a delete/recreate operation is different from AKS normally preserving custom data. |

**There is no documented fixed interval in the cited AKS customization guidance at which `coredns-custom` data is wiped or reset.** No reset was observed in the completed observation tests. That does not establish whether or how often a controller checks the object, and does not support quoting a 30-second or one-minute AKS reset interval.

The Microsoft article, reviewed on **2026-10-02**, establishes the supported customization mechanism but does not give an unconditional, all-version persistence guarantee or a reconciliation timer. The completed tests below provide evidence for the recorded cluster and operations, not every future release. The article also warns that configuration values can change between CoreDNS versions. **Preserving the ConfigMap and preserving its DNS behavior are separate checks.**

**Completed validation on `aks01day2`, 2026-10-02:**

| Test case | Outcome | What the result establishes |
| --- | --- | --- |
| [SP-14: observe custom configuration over time](#sp-14-custom-config-observation-observe-custom-configuration-over-time) | **PASS, attempt 2** | All 31 snapshots over **1,154.510 seconds** retained the same custom data, UID, and resourceVersion, with CoreDNS 2/2 Available. No reset was observed at the sampled times; this does not establish a reconciliation interval or exclude changes between samples. [Observation evidence](../validation/results/aks01day2-custom-config-20261002-live.md). |
| [SP-15: compare custom configuration across an approved upgrade](#sp-15-custom-config-upgrade-compare-custom-configuration-across-an-approved-upgrade) | **PARTIAL PASS** | The actual **control-plane-only upgrade from 1.35.7 to 1.36.3** completed with Azure `Succeeded`. The custom data hash, UID, and resourceVersion stayed unchanged; both node pools remained on 1.35.7. Managed CoreDNS moved to image `v1.14.3-11` and was 2/2 Available. **Configuration preservation passed**, but the full DNS criterion was not met: after an initial API-to-kubelet HTTP 500, the retry returned `NOERROR` with a different public A record. The rotating public name was unsuitable for a fixed-address assertion; this is not evidence of ConfigMap loss. [Upgrade and DNS evidence](../validation/results/aks01day2-custom-config-20261002-sp15.md). |
| [SP-16: apply once and verify custom DNS persistence](#sp-16-custom-config-patch-persistence-apply-once-and-verify-custom-dns-persistence) | **PASS, attempt 2** | A newly applied rule remained active after activation, another complete CoreDNS pod replacement **without reapplication**, and 31 snapshots over **1,183.785 seconds**. All **31 DNS checks** met their assertions through the isolated preflight, Service, and individual replicas. Cleanup removed the test rule, restored the original custom data and UID, and verified normal DNS. This tests a one-time patch and pod replacement, not an AKS or node-pool upgrade. [Patch-persistence evidence](../validation/results/aks01day2-custom-config-20261002-sp16.md). |

The earlier SP-14 availability-related failure and SP-16 invalid-TTL failure with successful rollback remain in the linked evidence; neither was counted as a pass. SP-16 intentionally changed the custom ConfigMap resourceVersion when adding and removing its test rule.

**The supported conclusion is that custom configuration persisted through the tested observation windows, CoreDNS pod replacement, and the recorded control-plane upgrade.** These tests do not establish node-pool upgrade or reimage behavior, indefinite persistence, or continuous DNS availability. A full cluster rebuild is not the only way to lose custom entries: another administrator, deployment system, or delete/recreate operation can still change them.

**This does not mean that `coredns-custom` is never reconciled or checked.** The observed ConfigMap has `addonmanager.kubernetes.io/mode: EnsureExists`, not `Reconcile`; these are alternative values of the same label key. Under the upstream add-on manager's documented semantics, `EnsureExists` creates a missing object but does not continually reset an existing object's custom data. The label alone does not establish which controller currently acts on AKS or its schedule. A controller can check an unchanged object without writing to it. Also, recreating a deleted object from a template would not necessarily restore its previous custom entries; keep a separate desired-state backup.

##### Persistence of custom configuration

**The `coredns-custom` ConfigMap is the supported location for custom DNS configuration in AKS, and its entries are expected to remain across normal AKS upgrades.** It is separate from the AKS-managed `coredns` ConfigMap, whose main configuration AKS controls.

**For the "patch once" question: a supported change to `coredns-custom` is expected to persist without periodic reapplication, but a full cluster rebuild is not the only event that can remove it.** CoreDNS pod restarts and node replacement do not themselves delete this separate Kubernetes object. However, a later administrator change, an apply/patch from a deployment pipeline, GitOps or Helm managing the same resource, or deletion and recreation of the ConfigMap can overwrite or remove the custom entries.

If the whole cluster is recreated, deploy the custom configuration again as part of provisioning; replacing or reimaging nodes in the existing cluster is not the same operation. If GitOps or another deployment system owns the ConfigMap, update its desired-state manifest rather than relying only on a live patch that the next deployment might undo. This guidance applies to `coredns-custom`, not direct edits to the AKS-managed `coredns` ConfigMap.

Our read-only checks found:

*   **`coredns-custom`:** `addonmanager.kubernetes.io/mode=EnsureExists`.
*   **`coredns`:** no `addonmanager.kubernetes.io/mode` label; it carries `app.kubernetes.io/managed-by=Eno`.

`EnsureExists` and `Reconcile` are alternative values of the same label key, not separate labels. **We did not observe `Reconcile` on either ConfigMap.** Under the upstream add-on manager's documented behavior, `EnsureExists` creates a missing object rather than continually resetting an existing object's custom data.

However, these labels alone do not establish which controller currently acts on the resource or its schedule. **The absence of `Reconcile` does not mean the ConfigMap is never checked or reconciled.** Microsoft's published guidance does not specify a fixed interval that resets `coredns-custom` entries.

The read-only **SP-14** run completed 31 snapshots over **1,154.510 seconds**, with no changes to the existing custom configuration, object identity, or resourceVersion. The separate **SP-16** run then added one unique rule once. It returned exactly `192.0.2.123` with `NOERROR` and TTL 1 through the DNS Service and both managed replicas after activation, after a second restart without reapplying the rule, and after **31 snapshots over 1,183.785 seconds**. The patched data hash and resourceVersion stayed unchanged throughout that observation, with CoreDNS 2/2 Available at every sample. Cleanup removed the test key, restored the original data and UID, and verified normal Service discovery plus `NXDOMAIN` for the removed name. This establishes finite persistence through the tested CoreDNS pod replacement, not AKS upgrades, node replacement, indefinite persistence, or continuous availability. See the [SP-16 result and retained attempts](../validation/results/aks01day2-custom-config-20261002-sp16.md).

The separately approved SP-15 control-plane-only upgrade completed with Azure `Succeeded` at `2026-10-02T14:55:43Z`, reaching 1.36.3 while both node pools remained on 1.35.7. **The custom data, UID, and resourceVersion were preserved**, with CoreDNS 2/2 Available on its upgraded image. The DNS retry also returned `NOERROR`, but its public A record changed from `150.171.110.195` to `150.171.109.183`. That rotating record did not meet the stable-answer prerequisite, so the full case is not a PASS even though configuration preservation was verified. The initial API-to-kubelet HTTP 500 and the failed fixed-address assertion are retained in the [upgrade results](../validation/results/aks01day2-custom-config-20261002-sp15.md).

We recommend keeping the configuration in source control and verifying its contents and DNS behavior after upgrades. After the initial approved change, also follow Microsoft's documented CoreDNS rolling-restart procedure and verify that the custom rule is actually being used; saving the ConfigMap alone does not prove the running DNS configuration has changed. Automatic recreation should not be relied on to restore deleted custom entries.

Reference: [Microsoft's AKS CoreDNS customization guidance](https://learn.microsoft.com/en-us/azure/aks/coredns-custom).

##### How to check the actual management labels

**There is no separate "reconciliation label" in the observed output.** The label key is `addonmanager.kubernetes.io/mode`. `EnsureExists` and `Reconcile` are alternative values of that same key in the upstream add-on manager, not two separate labels.

To check the labels on `coredns-custom`, run this read-only command:

```
kubectl --context=aks01day2 get configmap coredns-custom -n kube-system --show-labels
```

The observed custom ConfigMap labels were:

```
addonmanager.kubernetes.io/mode=EnsureExists,k8s-app=kube-dns,kubernetes.io/cluster-service=true
```

To compare the labels on both ConfigMaps without changing them:

```
kubectl --context=aks01day2 --request-timeout=20s get configmap coredns coredns-custom -n kube-system --show-labels
```

The read-only check on **2026-10-02** returned:

| ConfigMap | `addonmanager.kubernetes.io/mode` | `app.kubernetes.io/managed-by` |
| --- | --- | --- |
| `coredns-custom` | `EnsureExists` | Not present |
| `coredns` | Not present | `Eno` |

**Neither ConfigMap showed `addonmanager.kubernetes.io/mode=Reconcile`.** The main `coredns` ConfigMap did not have the add-on manager mode key at all. Earlier references to `Reconcile` explain an upstream mode; they are not a claim that this mode was observed on either AKS ConfigMap.

For a focused PowerShell view that explicitly reports missing labels:

```
$raw = kubectl --context=aks01day2 --request-timeout=20s get configmap coredns coredns-custom -n kube-system -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to read the CoreDNS ConfigMaps." }
$configMaps = ($raw -join "`n") | ConvertFrom-Json
foreach ($configMap in $configMaps.items) {
    $mode = $configMap.metadata.labels.'addonmanager.kubernetes.io/mode'
    $managedBy = $configMap.metadata.labels.'app.kubernetes.io/managed-by'
    [pscustomobject]@{
        ConfigMap = $configMap.metadata.name
        AddonManagerMode = if ([string]::IsNullOrWhiteSpace($mode)) { "Not present" } else { $mode }
        ManagedBy = if ([string]::IsNullOrWhiteSpace($managedBy)) { "Not present" } else { $managedBy }
    }
}
```

Do not interpret an absent mode label as `Reconcile`, `EnsureExists`, or "no reconciliation." The mode label only has the meaning assigned by a controller that actually uses it; other controllers need not use it. AKS management of the main Corefile is established by Microsoft's support guidance, not by assuming an absent `Reconcile` value. The observed `Eno` label is metadata, not a measurement of controller activity or timing. Do not add or change labels to try to control AKS reconciliation.

#### Detailed theory

##### Policy semantics

| Policy | Selection behavior |
| --- | --- |
| `random` | Selects an eligible upstream randomly. This is the default when `policy` is omitted. |
| `round_robin` | Rotates the initial selection among eligible upstreams. |
| `sequential` | Tries eligible upstreams in configured order, so the first healthy upstream is preferred. |

An upstream is eligible when the forward proxy does not currently regard it as down. With `sequential`, "first" means first in the `forward` argument list, not lowest IP, fastest response, or primary according to an external DNS system. A policy chooses the first endpoint to try. If that exchange has a network error, CoreDNS can try another endpoint.

##### Transport errors, DNS RCODEs, and health

A timeout, refused connection, or other exchange error is a transport failure. The forward proxy can try another upstream. A valid DNS message carrying `SERVFAIL`, `REFUSED`, or another RCODE is not a transport failure. By default, CoreDNS returns that response instead of trying the next server. The separate `failover` option can list RCODEs that should cause another upstream to be tried, for example:

```
failover SERVFAIL REFUSED
```

After an exchange error, CoreDNS starts in-band health checking of that upstream. In the fixture, `max_fails 1` and `health_check 500ms` make the state transition easier to observe. Any DNS response to the health probe establishes network reachability; an RCODE such as `SERVFAIL` does not by itself mean that the endpoint is unhealthy.

##### Caching and statistically meaningful queries

Policy is evaluated when the `forward` plugin performs an upstream exchange. An answer served from cache would not demonstrate upstream selection. The fixture resolver Corefiles intentionally omit the `cache` plugin. The upstream answer TTL is 30 seconds, but it is irrelevant while the resolver has no cache. Random behavior is probabilistic: observing both endpoints supports the claim that both are eligible, but a finite sample can never prove perfect randomness or a precise 50/50 distribution. Round-robin tests must also avoid parallel queries when the assertion depends on exact alternation.

##### AKS customization boundary

Do not edit the managed `coredns` ConfigMap. For a domain-specific forwarding rule, the supported shape is a key ending in `.server` in `coredns-custom`:

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  example.server: |
    example.internal:53 {
        errors
        forward . 10.0.0.20 10.0.0.21 {
            policy sequential
        }
    }
```

This is an explanatory example, not a command to apply. The upstreams, zone, network path, ownership, and change approval must be established for the target environment.

##### Reconciliation is not configuration reload

Three different activities are often called "refresh":

1.  **Resource reconciliation:** a controller compares a Kubernetes object with its desired state and may write to the API. Which controller owns which fields matters. The historical Kubernetes add-on manager distinguishes `Reconcile`, which restores configured fields, from `EnsureExists`, which creates a missing object without continually restoring an existing object's data. Those are upstream controller semantics, not proof that every current AKS cluster uses that controller or interval. Do not add or change those labels to bypass AKS management. The retained 2026-09-24 observation identified `Eno` on the managed ConfigMap. The 2026-10-02 live snapshots found the `EnsureExists` label on the custom ConfigMap, with field-manager entries for `kubectl-create` and `kubectl-client-side-apply`; these observations do not identify a current controller execution or its schedule.
2.  **ConfigMap volume projection:** Kubernetes eventually updates mounted ConfigMap files after the API object changes. Projection delay depends on the kubelet's synchronization and change-detection settings. A `subPath` mount does not receive those updates. This activity does not clear the API object's data.
3.  **CoreDNS reload:** if the effective Corefile enables `reload`, the CoreDNS 1.13.1 plugin checks file changes with a default interval of **30 seconds plus or minus 15 seconds of jitter**. This is a file-change check, not an AKS ConfigMap overwrite timer. Imported-file changes are supported in this CoreDNS version. Projection delay is additional, so the plugin interval is not an end-to-end configuration activation guarantee. Follow the Microsoft-documented rolling-restart procedure for an approved customization change. SP-14 and SP-15 do not initiate that restart; the separately approved SP-16 does.

A changed `resourceVersion` means the object was updated, not necessarily that custom data was lost. Compare the keys and values in both `data` and `binaryData`. A changed UID means the object was recreated, even if the name and data are identical. `managedFields` and ownership labels are useful clues, but they are not a complete audit trail or a guaranteed controller schedule. Use Kubernetes API audit logs, if already collected, to identify a writer when investigating an unexpected change.

#### Items to Validate

| Item to Validate | Validation Method | Mapped SP Test Case |
| --- | --- | --- |
| Managed baseline and effective default | Record the managed image and Corefile, verify no explicit policy, and match the image to versioned CoreDNS documentation. | `SP-00-MANAGED-DEFAULT-RANDOM` |
| Default `random` behavior | Run an isolated resolver with two upstreams and no `policy` line; collect a sufficiently large uncached sample. | `SP-01-DEFAULT-RANDOM-SAMPLE` |
| Explicit `random` behavior | Run the same isolated resolver with `policy random`; collect an uncached sample from both upstreams. | `SP-02-EXPLICIT-RANDOM-SAMPLE` |
| `round_robin` behavior | Query the existing round-robin resolver serially and verify that both healthy fixture answers occur. | `SP-03-ROUND-ROBIN-HEALTHY` |
| Healthy `sequential` ordering | Query the existing sequential resolver repeatedly and verify that only the first configured upstream answers. | `SP-04-SEQUENTIAL-HEALTHY-ORDER` |
| Primary failure | Silently drop traffic to the first upstream and verify that sequential selection reaches the second upstream. | `SP-05-SEQUENTIAL-PRIMARY-FAILURE` |
| Secondary failure | Use a secondary-first sequential extension, isolate that endpoint, and verify fallback to the primary. | `SP-06-SEQUENTIAL-SECONDARY-FAILURE` |
| Recovery | Restore the preferred upstream and verify that health checking returns it to service. | `SP-07-SEQUENTIAL-RECOVERY` |
| DNS RCODE distinction | Compare sequential resolution with and without `failover SERVFAIL`. | `SP-08-DNS-RCODE-VS-SELECTION` |
| Repeatability and sample-size limits | Repeat samples, report counts, and avoid claiming deterministic distribution from random results. | `SP-09-REPEATABILITY-AND-SAMPLE-SIZE` |
| Syntax and version compatibility | Prove the exact image starts successfully with each policy and record parser errors, image digest, and version. | `SP-10-SYNTAX-AND-VERSION` |
| AKS support boundary | Read managed and custom ConfigMaps without modifying them and compare the proposed change with Microsoft AKS guidance. | `SP-11-AKS-SUPPORT-BOUNDARY` |
| Observability | Capture resolver logs and forward-proxy metrics before, during, and after an outage. | `SP-12-OBSERVABILITY` |
| Cleanup | Remove fault and extension resources, restore the reusable base lab, and prove that `kube-system` was not changed. | `SP-13-CLEANUP-AND-NONINTERFERENCE` |
| Custom configuration remains unchanged during the observation window | Take 31 read-only snapshots, with 30 seconds between snapshots, and compare object identity and a hash of all custom data. | `SP-14-CUSTOM-CONFIG-OBSERVATION` |
| Custom configuration and a matching DNS answer survive an approved upgrade | Capture before/after snapshots and a known custom DNS answer around an independently approved Kubernetes-version upgrade; verify the completed operation separately. | `SP-15-CUSTOM-CONFIG-UPGRADE` |
| A one-time custom rule becomes active and persists through CoreDNS pod replacement and observation | Add one unique test-only key, check its uncached answer on every managed replica and the DNS Service after activation and another restart, observe 31 snapshots, then remove the key and verify recovery. | `SP-16-CUSTOM-CONFIG-PATCH-PERSISTENCE` |

#### Dedicated selection-policy validation suite

This suite covers upstream-selection policy and the lifecycle of its supported AKS custom configuration. It can be executed independently of the other four question-specific suites. **SP-14 and SP-15 use only the read-only lifecycle helper below, not the fixture deployment, fault policies, or cleanup procedures for SP-00 through SP-13.**

**SP-16 reuses that helper but changes cluster DNS.** It requires explicit approval for one temporary custom rule and three CoreDNS rolling restarts: activation, persistence verification, and cleanup. Run it only on the approved non-production cluster, with no overlapping configuration changes or upgrades. Do not run SP-13 as its cleanup.

##### Common prerequisites

*   PowerShell 7 or Windows PowerShell with `kubectl` and `az` available.
*   Permission to read `kube-system` and create namespaced resources.
*   The current context must be the intended non-production validation cluster.
*   NetworkPolicy enforcement must be available for outage cases.
*   Run commands from the repository root.
*   Use a separate PowerShell terminal for the metrics port-forward in SP-11.
*   The fixture uses documentation-only addresses `192.0.2.10` and `192.0.2.20` as returned answers. These are not upstream Service IPs.

Establish credentials and deploy the existing isolated fixture:

```
az aks get-credentials --resource-group aks01day2-rg --name aks01day2 --overwrite-existing
$expectedContext = "aks01day2"
$actualContext = (kubectl config current-context).Trim()
if ($actualContext -ne $expectedContext) {
    throw "Wrong kubectl context: $actualContext"
}

.\07-CoreDNS\validation\Deploy-CoreDNSFailoverLab.ps1

$ns = "coredns-failover-validation"
kubectl wait --for=condition=Available deployment --all -n $ns --timeout=180s
$primaryIP = (kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$secondaryIP = (kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$image = (kubectl get deployment resolver-sequential -n $ns `
    -o jsonpath="{.spec.template.spec.containers[0].image}").Trim()
kubectl get deployment,service,networkpolicy -n $ns -o wide
```

Expected prerequisite result: all six existing Deployments are Available, both upstream Service IP variables are nonempty, and `$image` is recorded.

Pass/fail: pass only if the context check succeeds, all fixture Deployments are Available, and no command mutates `kube-system`. Otherwise stop.

Evidence to capture:

```
kubectl config current-context
kubectl get deployment,service,networkpolicy -n $ns -o wide
kubectl get deployment resolver-sequential -n $ns -o yaml
kubectl get configmap resolver-sequential -n $ns -o yaml
```

##### Fixture-extension helper

SP-01, SP-02, and SP-06 require resolvers not present in the checked-in fixture. This is explicitly a **fixture extension**. The following commands create ephemeral ConfigMaps and Deployments without editing fixture files. Run this helper once in the same PowerShell session:

If an earlier version of these functions is already loaded in the current PowerShell session, rerun the entire helper block below before retrying. Function definitions already loaded in memory are not updated when this Markdown file changes.

```
function New-PolicyResolver {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FirstUpstream,
        [Parameter(Mandatory)][string]$SecondUpstream,
        [AllowEmptyString()][string]$PolicyLine
    )

    if ([string]::IsNullOrWhiteSpace($image)) {
        throw "The CoreDNS image variable is empty. Run the Common prerequisites first."
    }
    if ([string]::IsNullOrWhiteSpace($FirstUpstream) -or
        [string]::IsNullOrWhiteSpace($SecondUpstream)) {
        throw "Both upstream Service IPs are required. Run the Common prerequisites first."
    }

    $corefile = @"
.:53 {
    errors
    log
    ready
    health
    prometheus :9153
    forward . $FirstUpstream $SecondUpstream {
$PolicyLine
        max_fails 1
        health_check 500ms
    }
}
"@

    kubectl create configmap $Name -n $ns `
        "--from-literal=Corefile=$corefile" --dry-run=client -o yaml |
        kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "ConfigMap creation failed for $Name" }

    # Delete an older extension created by a previous version of this helper.
    # The old selector is immutable and cannot be corrected with kubectl apply.
    kubectl delete deployment $Name -n $ns --ignore-not-found --wait=true
    if ($LASTEXITCODE -ne 0) { throw "Existing Deployment cleanup failed for $Name" }

    $deployment = @{
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = @{
            name = $Name
            namespace = $ns
            labels = @{
                "app.kubernetes.io/name" = $Name
                "app.kubernetes.io/part-of" = "coredns-failover-validation"
            }
        }
        spec = @{
            replicas = 1
            selector = @{
                matchLabels = @{
                    "app.kubernetes.io/name" = $Name
                }
            }
            template = @{
                metadata = @{
                    labels = @{
                        "app.kubernetes.io/name" = $Name
                        "app.kubernetes.io/part-of" = "coredns-failover-validation"
                    }
                }
                spec = @{
                    containers = @(
                        @{
                            name = "coredns"
                            image = $image
                            args = @("-conf", "/etc/coredns/Corefile")
                            ports = @(
                                @{ name = "dns-udp"; containerPort = 53; protocol = "UDP" }
                                @{ name = "dns-tcp"; containerPort = 53; protocol = "TCP" }
                                @{ name = "metrics"; containerPort = 9153; protocol = "TCP" }
                            )
                            readinessProbe = @{
                                httpGet = @{ path = "/ready"; port = 8181 }
                            }
                            resources = @{
                                requests = @{ cpu = "10m"; memory = "20Mi" }
                                limits = @{ cpu = "100m"; memory = "64Mi" }
                            }
                            securityContext = @{
                                allowPrivilegeEscalation = $false
                                capabilities = @{
                                    add = @("NET_BIND_SERVICE")
                                    drop = @("ALL")
                                }
                                readOnlyRootFilesystem = $true
                                runAsNonRoot = $true
                                runAsUser = 65532
                                seccompProfile = @{ type = "RuntimeDefault" }
                            }
                            volumeMounts = @(
                                @{ name = "config"; mountPath = "/etc/coredns"; readOnly = $true }
                            )
                        }
                    )
                    volumes = @(
                        @{ name = "config"; configMap = @{ name = $Name } }
                    )
                }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress

    $deployment | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Deployment creation failed for $Name" }
    kubectl rollout status deployment/$Name -n $ns --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "Resolver did not become ready: $Name" }
}

function Get-ResolverPodIP {
    param([Parameter(Mandatory)][string]$Name)
    $podIPOutput = kubectl get pod -n $ns -l "app.kubernetes.io/name=$Name" `
        -o jsonpath="{.items[0].status.podIP}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$podIPOutput)) {
        throw "No ready pod IP was found for resolver $Name."
    }
    $podIP = ([string]$podIPOutput).Trim()
    $podIP
}

function Invoke-PolicySample {
    param(
        [Parameter(Mandatory)][string]$Server,
        [int]$Count = 64,
        [string]$Name = "answer.validation.test"
    )

    if ($Count -lt 1) { throw "Count must be at least 1." }
    if ($Server -notmatch "^(?:\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)$") {
        throw "Server must be an IPv4 address or DNS name."
    }
    if ($Name -notmatch "^[A-Za-z0-9.-]+$") {
        throw "Name contains unsupported characters."
    }

    # Run the loop inside one client-pod session. This avoids one Kubernetes API
    # exec/TLS handshake per sample, which can make a large sample unreliable.
    $sampleScript = 'i=1; while [ "$i" -le "$3" ]; do dig "@$1" "$2" A +time=5 +tries=1 +short || exit 1; i=$((i+1)); done'
    $output = kubectl exec -n $ns deployment/dns-client -- `
        sh -c $sampleScript -- $Server $Name $Count
    if ($LASTEXITCODE -ne 0) {
        throw "DNS sample failed against $Server."
    }

    $answers = @($output | Where-Object {
        $_ -match "^\d{1,3}(\.\d{1,3}){3}$"
    } | ForEach-Object { $_.Trim() })
    if ($answers.Count -ne $Count) {
        throw "Expected $Count DNS answers from $Server but received $($answers.Count)."
    }
    $answers
}
```

The generated Deployment uses the image entry point and supplies the same `-conf` arguments as the checked-in Deployments. It deliberately uses the pod IP directly, so no additional DNS Service is needed. If the pod is recreated, call `Get-ResolverPodIP` again.

##### Read-only ConfigMap lifecycle helper

For SP-14 and SP-15, use **PowerShell 7**, an already configured `kubectl` context, and read permission for ConfigMaps, the `kube-system` Namespace, and the CoreDNS Deployment. SP-15 additionally needs permission to execute `dig` in an existing, approved client pod. Do not deploy the outage fixture just to check ConfigMap persistence. Load the [shared helper](../validation/CoreDNSCustomConfig.Helpers.ps1) once in the same terminal as the chosen case. Run from the workspace root; for a GitHub checkout, replace `07-CoreDNS` with `coredns`. The default context is this document's lab; explicitly change it for another approved cluster. **The SP-16 script loads this helper automatically; it requires no copied function definitions or manual helper setup.**

```
. .\07-CoreDNS\validation\CoreDNSCustomConfig.Helpers.ps1 -Context "aks01day2"
```

The snapshots contain a hash, not the custom DNS values. Store the desired manifest and any full YAML backup privately in the approved configuration repository. A hash can detect a change but cannot restore lost configuration. Missing resources, access errors, and unavailable replicas stop the test explicitly; they are not treated as an empty ConfigMap or a passing result.

---

##### SP-00-MANAGED-DEFAULT-RANDOM: Managed baseline and default

**Validates item:** Managed baseline and effective default.

**Purpose:** Determine the deployed version and whether the managed Corefile actually configures `round_robin`, `sequential`, or no policy.

**Prerequisites:** Common prerequisites only. Read access to `kube-system`.

**Commands:**

```
$managedImage = kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.spec.template.spec.containers[0].image}"
$managedCorefile = kubectl get configmap coredns -n kube-system `
    -o jsonpath="{.data.Corefile}"

$managedImage
$managedCorefile
$explicitPolicies = [regex]::Matches(
    $managedCorefile,
    '(?m)^\s*policy\s+(random|round_robin|sequential)\s*$'
).Value
$explicitPolicies
```

**Expected result:** The image version is identifiable. If the relevant `forward` block has no `policy`, version-matched documentation identifies the effective policy as `random`. Do not infer a policy from traffic distribution.

**Pass/fail criteria:** Pass if the image and complete Corefile are captured, the relevant `forward` block is identified, and any policy conclusion is tied to that exact block and version. Fail if the file is partial, the image is unknown, or "round-robin" is assumed merely because multiple upstreams exist.

**Evidence to capture:** Raw image string, full Corefile, the relevant server block, command timestamp, current context, and versioned documentation URL.

**Established `aks01day2` evidence:** Image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`; the managed root forwarder was `forward . /etc/resolv.conf` with no explicit selection policy. For CoreDNS 1.13.1, the resulting default is `random`.

---

##### SP-01-DEFAULT-RANDOM-SAMPLE: Omitted policy behavior

**Validates item:** Default `random` behavior.

**Purpose:** Demonstrate that both healthy endpoints remain eligible when the policy line is omitted.

**Fixture extension required:** Yes. It creates `resolver-random-default`; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper.

**Commands:**

```
New-PolicyResolver -Name "resolver-random-default" `
    -FirstUpstream $primaryIP -SecondUpstream $secondaryIP -PolicyLine ""
$defaultRandomIP = Get-ResolverPodIP "resolver-random-default"
$defaultRandomAnswers = Invoke-PolicySample -Server $defaultRandomIP -Count 100
$defaultRandomCounts = $defaultRandomAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$defaultRandomCounts | Format-Table -AutoSize
```

**Expected result:** The answers are only `192.0.2.10` and `192.0.2.20`; both normally appear in 100 independent uncached exchanges.

**Pass/fail criteria:** Pass if there are exactly 100 valid answers, no unexpected address occurs, and each expected address occurs at least once. Fail on any query error or unexpected answer. If only one expected address appears, record an inconclusive statistical result, verify both upstreams are healthy, increase the sample, and do not relabel it an implementation failure without further evidence.

**Evidence to capture:** Generated ConfigMap YAML, Deployment YAML, image, pod IP, raw ordered answers, grouped counts, resolver logs, and upstream logs.

**Established `aks01day2` evidence:** On 2026-09-24, the corrected helper created and rolled out `resolver-random-default`. In the human-run sample shown for this case, all 100 uncached queries succeeded: `192.0.2.10` returned 42 times and `192.0.2.20` returned 58 times. An independent verification run also completed 100 queries successfully and produced the reverse 58/42 split. Both runs returned only the two expected addresses and selected both healthy upstreams. The differing distributions are expected for a random policy and must not be interpreted as a guaranteed 50/50 ratio.

---

##### SP-02-EXPLICIT-RANDOM-SAMPLE: Explicit random policy

**Validates item:** Explicit `random` behavior.

**Purpose:** Validate parser acceptance and behavior of `policy random`.

**Fixture extension required:** Yes. It creates `resolver-random-explicit`; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper.

**Commands:**

```
New-PolicyResolver -Name "resolver-random-explicit" `
    -FirstUpstream $primaryIP -SecondUpstream $secondaryIP `
    -PolicyLine "        policy random"
$explicitRandomIP = Get-ResolverPodIP "resolver-random-explicit"
$explicitRandomAnswers = Invoke-PolicySample -Server $explicitRandomIP -Count 100
$explicitRandomCounts = $explicitRandomAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$explicitRandomCounts | Format-Table -AutoSize
```

**Expected result:** The Deployment becomes Ready and both expected addresses normally appear; there is no parser error for `policy random`.

**Pass/fail criteria:** Pass if all 100 responses contain only expected addresses, both occur, and logs contain no policy parser error. Apply the same statistical-inconclusive rule as SP-01 if only one expected answer occurs.

**Evidence to capture:** Corefile, rollout status, image, ordered answers, counts, and `kubectl logs deployment/resolver-random-explicit -n $ns`.

**Established `aks01day2` evidence:** On 2026-09-24, the human-run sample created and successfully rolled out `resolver-random-explicit` with `policy random`. All 100 uncached queries succeeded: `192.0.2.10` returned 47 times and `192.0.2.20` returned 53 times. No unexpected address was reported. This establishes parser acceptance of `policy random` in the tested CoreDNS image and confirms that both healthy upstreams were eligible. The 47/53 split is one probabilistic sample, not a balancing guarantee or proof of an exact 50/50 distribution.

---

##### SP-03-ROUND-ROBIN-HEALTHY: Round-robin with two healthy upstreams

**Validates item:** `round_robin` behavior.

**Purpose:** Show that explicit `round_robin` selects both eligible upstreams.

**Prerequisites:** Existing fixture only. Both upstream Deployments Available.

**Commands:**

```
kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
    --ignore-not-found
kubectl rollout restart deployment/resolver-round-robin -n $ns
kubectl rollout status deployment/resolver-round-robin -n $ns --timeout=120s
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-primary answer.validation.test A +time=2 +tries=1 +short
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-secondary answer.validation.test A +time=2 +tries=1 +short
kubectl get configmap resolver-round-robin -n $ns -o jsonpath="{.data.Corefile}"
$roundRobinAnswers = Invoke-PolicySample `
    -Server "resolver-round-robin" -Count 20
$roundRobinAnswers
$roundRobinCounts = $roundRobinAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$roundRobinCounts | Format-Table -AutoSize
```

**Expected result:** Both `192.0.2.10` and `192.0.2.20` appear, with no other answer. Commands are serial to avoid making a stronger ordering claim under concurrency.

**Pass/fail criteria:** Pass if 20 answers are returned and both expected addresses occur. Fail if an unexpected address, timeout, or only one address occurs while both upstreams are demonstrably healthy.

**Evidence to capture:** Resolver Corefile, ordered answers, grouped counts, resolver logs, both upstream logs, and pod readiness.

**Established `aks01day2` evidence:** On 2026-09-24, after removing the stale primary-outage policy, restarting the resolver, and proving both upstreams directly reachable, all 20 queries succeeded. `192.0.2.10` returned 10 times and `192.0.2.20` returned 10 times. The exact 10/10 split is an observation from this serial sample, not a general concurrency or fairness guarantee.

---

##### SP-04-SEQUENTIAL-HEALTHY-ORDER: First healthy upstream preference

**Validates item:** Healthy `sequential` ordering.

**Purpose:** Validate deterministic first-healthy preference.

**Prerequisites:** Existing fixture only. No outage NetworkPolicy may exist.

**Commands:**

```
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
    --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-primary answer.validation.test A +time=2 +tries=1 +short
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-secondary answer.validation.test A +time=2 +tries=1 +short
kubectl get configmap resolver-sequential -n $ns -o jsonpath="{.data.Corefile}"
$sequentialHealthy = Invoke-PolicySample `
    -Server "resolver-sequential" -Count 20
$sequentialHealthy
$sequentialHealthy | Group-Object | Select-Object Name,Count
```

**Expected result:** Every answer is `192.0.2.10`, the first upstream in the effective Corefile.

**Pass/fail criteria:** Pass only if all 20 queries succeed and all 20 return `192.0.2.10`. Any secondary answer, unexpected answer, or query failure fails this deterministic case.

**Evidence to capture:** Effective Corefile, primary and secondary Service IPs, ordered answers, grouped counts, logs, and absence of outage NetworkPolicies.

**Established `aks01day2` evidence:** On 2026-09-24, after removing the stale primary-outage policy, restarting the resolver, and proving both upstreams directly reachable, all 20 queries returned the first configured upstream answer, `192.0.2.10`. No secondary or unexpected answer occurred.

---

##### SP-05-SEQUENTIAL-PRIMARY-FAILURE: First upstream unavailable

**Validates item:** Primary failure.

**Purpose:** Verify that a transport failure at the preferred upstream allows selection of the next upstream.

**Prerequisites:** Existing fixture, a NetworkPolicy-enforcing data plane, and successful SP-04. This test changes only the validation namespace.

**Commands:**

```
try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s

    $primaryFailureOutput = kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    $primaryFailureOutput

    Start-Sleep -Seconds 3
    $primaryDownSample = Invoke-PolicySample `
        -Server "resolver-sequential" -Count 10
    $primaryDownSample | Group-Object | Select-Object Name,Count
}
finally {
    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
}
```

**Expected result:** The first exchange may show approximately the version's network-error timeout before returning `192.0.2.20`. After the primary is marked down, the sample returns only `192.0.2.20` without repeatedly waiting for the primary.

**Pass/fail criteria:** Pass if the first sufficiently patient query succeeds with `NOERROR` and `192.0.2.20`, and all later queries return the secondary. Fail if the secondary is never reached, an unexpected address occurs, or the NetworkPolicy does not actually isolate primary ingress.

**Evidence to capture:** NetworkPolicy YAML, first full `dig` output including status and query time, subsequent answers, resolver logs, health metrics, and NetworkPolicy-capability confirmation.

**Established `aks01day2` evidence:** On 2026-09-24, the first query returned the secondary answer `192.0.2.20` in 2,003 ms. After health detection, all 10 follow-up queries returned `192.0.2.20`. The outage policy was removed in cleanup. This is consistent with the earlier 1,999 ms first-failure observation and 0-3 ms known-unhealthy observations.

---

##### SP-06-SEQUENTIAL-SECONDARY-FAILURE: Preferred secondary unavailable

**Validates item:** Secondary failure.

**Purpose:** Test the symmetric failure path with the existing secondary listed first and the existing primary listed second.

**Fixture extension required:** Yes. It creates `resolver-sequential-secondary-first` plus an ephemeral NetworkPolicy; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper. Remove the primary outage before starting.

**Commands:**

```
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
    --ignore-not-found

New-PolicyResolver -Name "resolver-sequential-secondary-first" `
    -FirstUpstream $secondaryIP -SecondUpstream $primaryIP `
    -PolicyLine "        policy sequential"
$secondaryFirstIP = Get-ResolverPodIP "resolver-sequential-secondary-first"

$beforeSecondaryOutage = Invoke-PolicySample `
    -Server $secondaryFirstIP -Count 5
$beforeSecondaryOutage

try {
@"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: simulate-secondary-dns-packet-loss
  namespace: coredns-failover-validation
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: upstream-secondary
  policyTypes:
    - Ingress
  ingress: []
"@ | kubectl apply -f -

    kubectl rollout restart deployment/resolver-sequential-secondary-first -n $ns
    kubectl rollout status deployment/resolver-sequential-secondary-first `
        -n $ns --timeout=120s
    $secondaryFirstIP = Get-ResolverPodIP "resolver-sequential-secondary-first"

    $secondaryFailureOutput = kubectl exec -n $ns deployment/dns-client -- `
        dig "@$secondaryFirstIP" answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    $secondaryFailureOutput

    Start-Sleep -Seconds 3
    $secondaryDownSample = Invoke-PolicySample `
        -Server $secondaryFirstIP -Count 10
    $secondaryDownSample | Group-Object | Select-Object Name,Count
}
finally {
    kubectl delete networkpolicy simulate-secondary-dns-packet-loss `
        -n $ns --ignore-not-found
}
```

**Expected result:** Before isolation all five answers are `192.0.2.20`. After isolation, the first patient query and all subsequent queries return `192.0.2.10`.

**Pass/fail criteria:** Pass only if ordering is proven before the outage and fallback to the primary is proven after the outage. Fail if the precondition is not established, NetworkPolicy is not enforced, or any post-outage answer is unexpected.

**Evidence to capture:** Extension Corefile and Deployment, NetworkPolicy YAML, before/after ordered answers, first full `dig` output and query time, logs, and metrics.

**Established `aks01day2` evidence:** On 2026-09-24, all five healthy precondition queries returned the preferred secondary answer `192.0.2.20`. With secondary ingress silently dropped, the first fallback returned `192.0.2.10` in 2,007 ms, and all 10 follow-up queries returned `192.0.2.10`. The secondary-outage policy was removed in cleanup.

---

##### SP-07-SEQUENTIAL-RECOVERY: Preferred upstream re-enters service

**Validates item:** Recovery.

**Purpose:** Verify that removal of the primary outage permits the first configured endpoint to become eligible again.

**Prerequisites:** Existing fixture and a NetworkPolicy-enforcing data plane. This case creates and removes its own primary outage.

**Commands:**

```
try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
    Start-Sleep -Seconds 2

    $recoveryStart = Get-Date
    kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
        --ignore-not-found

    $recovered = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A `
            +time=5 +tries=1 +short
        $elapsedMs = [int]((Get-Date) - $recoveryStart).TotalMilliseconds
        "$elapsedMs ms : $($answer -join ',')"
        if ($answer -contains "192.0.2.10") {
            $recovered = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $recovered) { throw "Primary did not re-enter the sample window" }
}
finally {
    kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
        --ignore-not-found
}
```

**Expected result:** `192.0.2.10` reappears after health checks can reach the primary. The measured interval is an observation, not a production recovery SLO.

**Pass/fail criteria:** Pass if the primary answer returns within the declared 10-second, 20-attempt observation window. Fail if it does not. A test failure does not prove permanent exclusion; preserve logs and metrics for diagnosis.

**Evidence to capture:** Deletion timestamp, every timestamped answer, time-to-first-primary, resolver logs, health-check counters, and final NetworkPolicy list.

**Established `aks01day2` evidence:** Recovery has been observed in repeated runs. The primary answer returned after approximately 3,645 ms in the original validation and within 8,829 ms in the 2026-09-24 independent rerun. Both observations were inside the declared 10-second window. The elapsed value includes `kubectl exec` and API overhead and is not a production recovery SLO.

---

##### SP-08-DNS-RCODE-VS-SELECTION: RCODE is not transport failure

**Validates item:** DNS RCODE distinction.

**Purpose:** Prove that selection policy alone does not retry a valid `SERVFAIL`, and that `failover SERVFAIL` is a separate option.

**Prerequisites:** Existing fixture. Remove both outage policies first.

**Commands:**

```
kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
kubectl rollout restart deployment/resolver-rcode-failover -n $ns
kubectl rollout status deployment/resolver-rcode-failover -n $ns --timeout=120s

$withoutRcodeFailover = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential rcode.validation.test A `
    +time=5 +tries=1 +comments +answer
$withRcodeFailover = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-rcode-failover rcode.validation.test A `
    +time=5 +tries=1 +comments +answer

"Without failover SERVFAIL:"
$withoutRcodeFailover
"With failover SERVFAIL:"
$withRcodeFailover
kubectl get configmap resolver-sequential resolver-rcode-failover `
    -n $ns -o yaml
```

**Expected result:** The sequential resolver without `failover SERVFAIL` returns `status: SERVFAIL` and no A answer. The otherwise comparable resolver with that option returns `status: NOERROR` and `192.0.2.20`.

**Pass/fail criteria:** Pass only if both halves match. Fail if selection policy alone retries SERVFAIL or the explicit failover resolver does not reach the secondary.

**Evidence to capture:** Both full `dig` outputs, both Corefiles, resolver logs, and upstream logs showing which endpoint received each query.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 after removing outage policies and restarting both resolvers. Without `failover SERVFAIL`, the result was `SERVFAIL` with no A answer. With `failover SERVFAIL`, the result was `NOERROR` with `192.0.2.20`.

---

##### SP-09-REPEATABILITY-AND-SAMPLE-SIZE: Repeated trials

**Validates item:** Repeatability and sample-size limits.

**Purpose:** Separate deterministic sequential behavior from probabilistic random behavior and expose trial-to-trial variation.

**Prerequisites:** SP-01 through SP-04; all upstreams healthy; random resolver pod IPs refreshed after any restart.

**Commands:**

```
kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found
foreach ($resolver in @(
    "resolver-random-default",
    "resolver-random-explicit",
    "resolver-round-robin",
    "resolver-sequential"
)) {
    kubectl rollout restart deployment/$resolver -n $ns
    kubectl rollout status deployment/$resolver -n $ns --timeout=120s
}

$defaultRandomIP = Get-ResolverPodIP "resolver-random-default"
$explicitRandomIP = Get-ResolverPodIP "resolver-random-explicit"

$repeatability = foreach ($trial in 1..5) {
    foreach ($case in @(
        @{ Name = "default-random"; Server = $defaultRandomIP },
        @{ Name = "explicit-random"; Server = $explicitRandomIP },
        @{ Name = "round-robin"; Server = "resolver-round-robin" },
        @{ Name = "sequential"; Server = "resolver-sequential" }
    )) {
        $answers = Invoke-PolicySample -Server $case.Server -Count 100
        [pscustomobject]@{
            Trial = $trial
            PolicyCase = $case.Name
            Total = $answers.Count
            Primary = @($answers | Where-Object { $_ -eq "192.0.2.10" }).Count
            Secondary = @($answers | Where-Object { $_ -eq "192.0.2.20" }).Count
            Unexpected = @(
                $answers | Where-Object {
                    $_ -notin @("192.0.2.10", "192.0.2.20")
                }
            ).Count
        }
    }
}
$repeatability | Format-Table -AutoSize
```

**Expected result:** Sequential is 100 primary answers in every healthy trial. Random trials contain only expected answers and ordinarily include both. Round-robin contains both. Exact random ratios are not acceptance criteria.

**Pass/fail criteria:** Pass deterministic sequential only at 500/500 primary. For random cases, pass data integrity only when totals are complete and no unexpected answer occurs; report endpoint coverage separately. Never claim a uniform distribution from five trials. A statistical fairness test would need a predeclared hypothesis, independence assumptions, and a larger sample.

**Evidence to capture:** Trial table, raw answers retained separately, Corefiles, pod identities, restart counts, timestamps, and any throttling or query errors.

**Established `aks01day2` evidence:** The complete five-trial matrix ran on 2026-09-24 with 2,000 successful queries and no unexpected answers. Default-random primary counts by trial were 46, 45, 51, 55, and 47, totaling 244 primary and 256 secondary. Explicit-random primary counts were 58, 43, 50, 41, and 60, totaling 252 primary and 248 secondary. Round-robin returned 50 primary and 50 secondary in every trial, totaling 250/250. Sequential returned 100 primary and zero secondary in every trial, totaling 500/0. The random totals demonstrate variation and endpoint coverage, not a guaranteed ratio.

---

##### SP-10-SYNTAX-AND-VERSION: Parser and image compatibility

**Validates item:** Syntax and version compatibility.

**Purpose:** Confirm that policy syntax is accepted by the exact runtime image, not merely by current online documentation.

**Prerequisites:** All four policy resolver variants deployed.

**Commands:**

```
$policyResolvers = @(
    "resolver-random-default",
    "resolver-random-explicit",
    "resolver-round-robin",
    "resolver-sequential",
    "resolver-sequential-secondary-first"
)

kubectl get deployment $policyResolvers -n $ns `
    -o custom-columns="NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas"

foreach ($resolver in $policyResolvers) {
    "===== $resolver Corefile ====="
    kubectl get configmap $resolver -n $ns -o jsonpath="{.data.Corefile}"
    "`n===== $resolver logs ====="
    kubectl logs deployment/$resolver -n $ns --tail=100
}

kubectl exec -n $ns deployment/resolver-sequential -- coredns -version
kubectl get pod -n $ns -l app.kubernetes.io/name=resolver-sequential `
    -o jsonpath="{.items[0].status.containerStatuses[0].imageID}"
```

**Expected result:** Every Deployment is Ready and Available, logs have no `Unknown property`, parse, or startup error, and the runtime version and image digest are recorded. Omitted, `random`, `round_robin`, and `sequential` syntax all start successfully.

**Pass/fail criteria:** Pass only for syntax actually started by the recorded image. If `-version` is unsupported by the packaged binary, record that command failure but use image tag, immutable image ID, readiness, and logs. Fail policy compatibility if the resolver enters CrashLoopBackOff or logs a parser error.

**Evidence to capture:** Corefiles, readiness table, logs, image tag, image ID, version output or its error, Kubernetes events, and documentation tag.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 for all five resolver variants. Omitted-policy random, explicit `random`, `round_robin`, `sequential`, and secondary-first `sequential` each had one Ready and Available replica, used `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`, and had no parser errors in the sampled logs. The binary reported CoreDNS 1.13.1, and the sequential pod image ID was `sha256:b1b16649b9a06534471ed990bb952b756f456241fe3c0a378da33cfe7dedfa51`.

---

##### SP-11-AKS-SUPPORT-BOUNDARY: Read-only AKS configuration inspection

**Validates item:** AKS support boundary.

**Purpose:** Distinguish CoreDNS capability from what AKS supports customers changing.

**Prerequisites:** Read access to the two ConfigMaps. This is read-only.

**Commands:**

```
kubectl get configmap coredns -n kube-system -o yaml
kubectl get configmap coredns-custom -n kube-system -o yaml `
    --ignore-not-found
kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.metadata.labels}{'\n'}{.metadata.annotations}{'\n'}"
```

Review the output against the current Microsoft document linked below. Do not run `kubectl edit`, `kubectl patch`, or `kubectl apply` against the managed `coredns` ConfigMap.

**Expected result:** The managed Corefile and any current custom keys are recorded. A proposed domain-specific key ends in `.server` or `.override` and uses only supported built-in plugins. No command changes `kube-system`.

**Pass/fail criteria:** Pass if the implementation recommendation stays within the documented `coredns-custom` mechanism, or explicitly records that a global root-forwarder change needs Microsoft confirmation. Fail if the plan directly edits the managed ConfigMap or assumes the isolated lab authorizes a global change.

**Evidence to capture:** Read-only YAML, Microsoft document retrieval date, proposed zone scope, policy Corefile, ownership approval, and a before/after resourceVersion comparison if a separately approved custom change is later performed.

**Established `aks01day2` evidence:** Read-only inspection on 2026-09-24 showed two Available managed CoreDNS replicas. The managed `coredns` ConfigMap had resourceVersion `22591546`, label `app.kubernetes.io/managed-by: Eno`, root directive `forward . /etc/resolv.conf`, and no explicit selection policy. The existing `coredns-custom` ConfigMap contained one supported `.server` key named `test.server`. No `kube-system` resource was changed. This evidence confirms the customization boundary but does not authorize replacing the managed root forwarder.

---

##### SP-12-OBSERVABILITY: Logs and forward metrics

**Validates item:** Observability.

**Purpose:** Make policy and health-state conclusions auditable.

**Prerequisites:** Existing fixture. Use SP-04, SP-05, and SP-07 to generate healthy, outage, and recovery traffic.

**Commands:**

```
$metricsPath = "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
function Get-ResolverMetrics {
    (kubectl get --raw $metricsPath) -join "`n"
}
function Measure-MetricTotal {
    param([string]$Text, [string]$MetricName)
    $total = 0.0
    foreach ($line in $Text -split "`n") {
        if ($line -match "^$([regex]::Escape($MetricName))(?:\{[^}]*\})?\s+([0-9.eE+-]+)$") {
            $total += [double]$Matches[1]
        }
    }
    $total
}

kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
    --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s

$metricsBefore = Get-ResolverMetrics
$healthBefore = Measure-MetricTotal $metricsBefore `
    "coredns_proxy_healthcheck_failures_total"
$requestsBefore = Measure-MetricTotal $metricsBefore `
    "coredns_proxy_request_duration_seconds_count"

try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    Start-Sleep -Seconds 3

    $metricsDuring = Get-ResolverMetrics
    $healthDuring = Measure-MetricTotal $metricsDuring `
        "coredns_proxy_healthcheck_failures_total"
    $requestsDuring = Measure-MetricTotal $metricsDuring `
        "coredns_proxy_request_duration_seconds_count"
    kubectl logs deployment/resolver-sequential -n $ns --since=10m `
        --timestamps

    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
    Start-Sleep -Seconds 2
    $recoveryAnswer = kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short

    $metricsAfter = Get-ResolverMetrics
    $healthAfter = Measure-MetricTotal $metricsAfter `
        "coredns_proxy_healthcheck_failures_total"
    $requestsAfter = Measure-MetricTotal $metricsAfter `
        "coredns_proxy_request_duration_seconds_count"

    [pscustomobject]@{
        HealthBefore = $healthBefore
        HealthDuring = $healthDuring
        HealthAfter = $healthAfter
        RequestsBefore = $requestsBefore
        RequestsDuring = $requestsDuring
        RequestsAfter = $requestsAfter
        RecoveryAnswer = $recoveryAnswer -join ","
    } | Format-List
}
finally {
    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
}
```

**Expected result:** Query logs identify forwarded requests and metrics expose forward-proxy requests and health-check failures. Counter names and labels must be interpreted from the version actually deployed. Counters are cumulative for the process and reset on pod restart.

**Pass/fail criteria:** Pass if logs and metric snapshots can be time-correlated with the test, and the outage produces a nonzero health-check-failure series. Fail if evidence is missing, taken from the wrong pod, or compared across a restart without acknowledging reset.

**Evidence to capture:** Pod UID, restart count, all three metric snapshots, timestamped logs, exact queries, outage apply/delete times, and CoreDNS image.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 through the Kubernetes API metrics proxy, without a port-forward. After a fresh resolver restart, health-check failures increased from 0 before the outage to 4 during it and 9 after recovery probing. Forward request count increased from 0 to 1 during the outage query and to 2 after the recovery query. The recovery answer was `192.0.2.10`, and five timestamped resolver log lines were captured.

---

##### SP-13-CLEANUP-AND-NONINTERFERENCE: Remove test resources

**Validates item:** Cleanup.

**Purpose:** Restore the validation cluster and prove that cleanup is scoped.

**Prerequisites:** Evidence from all required cases has been saved outside the namespace.

**Commands:**

```
$ns = "coredns-failover-validation"

kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found

kubectl delete deployment `
    resolver-random-default `
    resolver-random-explicit `
    resolver-sequential-secondary-first `
    -n $ns --ignore-not-found
kubectl delete configmap `
    resolver-random-default `
    resolver-random-explicit `
    resolver-sequential-secondary-first `
    -n $ns --ignore-not-found

.\07-CoreDNS\validation\Deploy-CoreDNSFailoverLab.ps1

kubectl get namespace $ns
kubectl get deployment -n $ns
kubectl get deployment,configmap,networkpolicy -n $ns -o name |
    Select-String "resolver-random-default|resolver-random-explicit|resolver-sequential-secondary-first|simulate-.*-dns-packet-loss"
kubectl get deployment coredns -n kube-system
kubectl get configmap coredns -n kube-system `
    -o jsonpath="{.metadata.resourceVersion}{'\n'}"
```

**Expected result:** The three extension resolvers and both fault policies are absent. The validation namespace remains available with the six base Deployments healthy for later human testing. The managed CoreDNS Deployment remains Available, and the test suite never writes a `kube-system` resource.

**Pass/fail criteria:** Pass if no extension or fault resource is returned, all six base Deployments are Available, and managed CoreDNS remains Available. Compare the final managed ConfigMap `resourceVersion` with SP-00 evidence; investigate any unexpected change rather than attributing it automatically to this suite, because AKS itself may reconcile resources.

**Evidence to capture:** Delete output, final namespace and base Deployment status, empty extension-resource search, final managed CoreDNS status and resourceVersion, current context, and cleanup timestamp.

**Established `aks01day2` evidence:** Executed on 2026-09-24. Both fault policies and all three extension resolver ConfigMaps and Deployments were removed. The base lab was reapplied and retained with all six base Deployments Available. No extension match remained. Managed CoreDNS retained two Available replicas, and the managed Corefile ConfigMap resourceVersion remained `22591546`.

---

##### SP-14-CUSTOM-CONFIG-OBSERVATION: Observe custom configuration over time

**Validates item:** Custom configuration remains unchanged during the observation window.

**Purpose:** Detect deletion, recreation, or changed custom data during a declared idle window without changing DNS. This does not measure the AKS controller's reconciliation interval.

**Prerequisites:** Load the read-only ConfigMap lifecycle helper. The existing ConfigMap must contain at least one reviewed custom key. Coordinate a window without planned configuration writes or upgrades. Use a private local results directory; review identifying metadata before sharing.

**Commands:**

```
$observationDirectory = Join-Path $PWD ("coredns-custom-observe-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $observationDirectory
$baseline = Get-CustomDnsSnapshot
$baseline | ConvertTo-Json -Depth 15 |
    Set-Content -LiteralPath (Join-Path $observationDirectory "sample-00.json") -Encoding utf8
if (($baseline.DataKeys.Count + $baseline.BinaryDataKeys.Count) -eq 0) {
    throw "No custom data exists to validate; an empty ConfigMap is not a persistence test."
}
Assert-CustomDnsPreserved -Before $baseline -After $baseline
$clock = [System.Diagnostics.Stopwatch]::StartNew()
for ($index = 1; $index -le 30; $index++) {
    Start-Sleep -Seconds 30
    $sample = Get-CustomDnsSnapshot
    $sample | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath (Join-Path $observationDirectory ("sample-{0:D2}.json" -f $index)) -Encoding utf8
    Assert-CustomDnsPreserved -Before $baseline -After $sample
    if ($sample.KubernetesVersion -cne $baseline.KubernetesVersion -or
        ($sample.CoreDnsImages -join ",") -cne ($baseline.CoreDnsImages -join ",")) {
        throw "An upgrade overlapped the idle test. Retain the observations and use SP-15."
    }
}
$clock.Stop()
if ($clock.Elapsed.TotalSeconds -lt 900) { throw "Observation window was shorter than 900 seconds." }
[pscustomobject]@{
    Status = "PASS"
    Snapshots = 31
    ObservationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
    PayloadSha256 = $baseline.PayloadSha256
    FinalAvailableReplicas = $sample.AvailableReplicas
    FinalDeploymentResourceVersion = $sample.ManagedDeploymentResourceVersion
    EvidenceDirectory = $observationDirectory
} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $observationDirectory "result.json")
```

**Expected result:** All 31 snapshots have the same ConfigMap UID, cluster identity, and payload hash across at least 900 seconds. CoreDNS remains fully Available at each sample. Metadata-only `resourceVersion` changes are recorded but are not classified as data loss.

**Pass/fail criteria:** PASS only after all 31 successful comparisons and the minimum observation duration. A missing ConfigMap, changed UID or data hash, or unavailable CoreDNS fails the check and requires investigation. API/access failure or an overlapping upgrade leaves the idle test BLOCKED/INCONCLUSIVE, not PASS. If interrupted, the saved samples are partial evidence; there will be no passing `result.json`.

**Evidence to capture:** All timestamped snapshots, the final result, any command error, and the selected observation window. Use the [management-label commands](#how-to-check-the-actual-management-labels) to record which labels and values actually exist; record absence explicitly rather than assuming `Reconcile`. Labels are context, not this test's pass/fail condition. If an unexpected change occurs, retain relevant API audit events and the owners/field managers. Do not automatically attribute the change to AKS.

**Established `aks01day2` evidence:** PASS on 2026-10-02 for the second attempt, observing `kube-system/coredns-custom` on Kubernetes `v1.35.7` with CoreDNS image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`. The 31 snapshots ran from `13:21:20.9144166Z` to `13:40:35.4671367Z`; the test timer measured 1,154.510 seconds, exceeding the 900-second requirement. All snapshots retained the single `test.server` key, no binary keys, UID `733fabca-7d66-4c20-8d54-08e8d89dd46b`, resourceVersion `22928117`, and payload SHA-256 `038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63`. CoreDNS was 2/2 Available in all 31 samples; its Deployment resourceVersion stayed `23707464` during this attempt. Attempt 1 failed the availability gate after seven snapshots over 232.925 seconds when CoreDNS was 1/2 Available; its custom data and identity remained unchanged, and that failure was not counted as a pass. Final checks found all six retained lab Deployments Available, zero lab NetworkPolicies, four Ready nodes, and a healthy primary answer `192.0.2.10` with `NOERROR` in 4 ms. The managed Corefile hash and ConfigMap resourceVersion `22591546` matched the earlier baseline. No cluster resource was changed, so no cleanup was needed. This establishes unchanged configuration at the sampled times, not the absence of controller checks, a reconciliation interval, continuous DNS availability, or upgrade persistence. See the [readable results](../validation/results/aks01day2-custom-config-20261002-live.md), [31-snapshot evidence](../validation/results/aks01day2-custom-config-20261002-sp14-attempt2.json), and [failed first attempt](../validation/results/aks01day2-custom-config-20261002-sp14-attempt1.json).

---

##### SP-15-CUSTOM-CONFIG-UPGRADE: Compare custom configuration across an approved upgrade

**Validates item:** Custom configuration and a matching DNS answer survive an approved upgrade.

**Purpose:** Test both stored configuration and one known DNS behavior across a real AKS Kubernetes-version upgrade. A CoreDNS pod restart alone is not an upgrade test.

**Prerequisites:** Load the read-only ConfigMap lifecycle helper. Supply an independently approved upgrade plan, a private backup of the custom manifest, and an existing Linux client pod with `dig` that can reach the `kube-dns` Service. Pick a stable A-record answer for a name handled by the existing custom rule. The example client reference below is usable only if that retained lab client already exists and is approved; otherwise substitute your own client. Do not create or change `coredns-custom` to manufacture this precondition.

**Stable-answer prerequisite:** Use an existing controlled record whose expected address will remain fixed throughout the upgrade window. A rotating public record is not suitable merely because one preflight query succeeds. If this prerequisite cannot be met, report configuration preservation separately rather than claiming the whole case passed. Preparing a new controlled test rule requires separate approval before the baseline and upgrade.

**Commands:**

Before the approved upgrade, substitute the query inputs and run:

```
$customQueryName = "REPLACE_WITH_A_NAME_MATCHING_YOUR_CUSTOM_RULE"
$expectedAddress = "REPLACE_WITH_EXPECTED_IPV4"
$clientNamespace = "coredns-failover-validation"
$clientResource = "deployment/dns-client"
if ($customQueryName -like "REPLACE_*" -or $expectedAddress -like "REPLACE_*") {
    throw "Supply a reviewed custom DNS name and its stable expected IPv4 answer."
}
if ($customQueryName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*[.]?$') {
    throw "Use a DNS name without shell metacharacters."
}
$parsedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($expectedAddress, [ref]$parsedAddress) -or
    $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "The expected answer must be a valid IPv4 address."
}
function Get-CustomDnsAnswer {
    $dnsService = Invoke-LifecycleKubectl -Arguments @(
        "get", "service", "kube-dns", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    if (-not $dnsService.spec.clusterIP -or $dnsService.spec.clusterIP -eq "None") {
        throw "The kube-dns Service has no cluster IP."
    }
    $answer = Invoke-LifecycleKubectl -Arguments @(
        "exec", "-n", $clientNamespace, $clientResource, "--",
        "dig", "@$($dnsService.spec.clusterIP)", $customQueryName, "A",
        "+time=5", "+tries=1", "+comments", "+answer", "+stats"
    )
    $answer
}
function Assert-CustomDnsAnswer {
    param([Parameter(Mandatory)][string]$Answer)
    if ($Answer -notmatch 'status:\s+NOERROR,' -or
        $Answer -notmatch "(?m)\sIN\s+A\s+$([regex]::Escape($expectedAddress))\s*$") {
        throw "The custom DNS query did not return NOERROR and the expected A record."
    }
}
$upgradeDirectory = Join-Path $PWD ("coredns-custom-upgrade-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $upgradeDirectory
$beforeUpgrade = Get-CustomDnsSnapshot
$beforeUpgrade | ConvertTo-Json -Depth 15 |
    Set-Content -LiteralPath (Join-Path $upgradeDirectory "before.json") -Encoding utf8
if (($beforeUpgrade.DataKeys.Count + $beforeUpgrade.BinaryDataKeys.Count) -eq 0) {
    throw "No custom configuration exists to validate."
}
Assert-CustomDnsPreserved -Before $beforeUpgrade -After $beforeUpgrade
$beforeAnswer = Get-CustomDnsAnswer
$beforeAnswer | Set-Content -LiteralPath (Join-Path $upgradeDirectory "before-dig.txt") -Encoding utf8
Assert-CustomDnsAnswer -Answer $beforeAnswer
"Baseline saved. Keep this terminal open. Evidence directory: $upgradeDirectory"
```

**Stop here until the cluster owner performs the separately approved upgrade.** This case's commands do not initiate an upgrade or mutate managed DNS. Record the operation's UTC start/end, old/target version, control-plane-only or full-cluster scope, and successful completion status from Azure. For a full-cluster upgrade, also verify the intended node pools finished; a changed API-server version alone does not prove that. If no actual upgrade occurs, mark this case BLOCKED/NOT ESTABLISHED.

After the operation has completed, run in the same terminal:

```
$afterUpgrade = Get-CustomDnsSnapshot
$afterUpgrade | ConvertTo-Json -Depth 15 |
    Set-Content -LiteralPath (Join-Path $upgradeDirectory "after.json") -Encoding utf8
$afterAnswer = Get-CustomDnsAnswer
$afterAnswer | Set-Content -LiteralPath (Join-Path $upgradeDirectory "after-dig.txt") -Encoding utf8
Assert-CustomDnsPreserved -Before $beforeUpgrade -After $afterUpgrade
Assert-CustomDnsAnswer -Answer $afterAnswer
if ($beforeUpgrade.KubernetesVersion -ceq $afterUpgrade.KubernetesVersion) {
    throw "No Kubernetes-version change was observed; an upgrade is not established."
}
[pscustomobject]@{
    Status = "CHECKS PASSED; operator must attach successful upgrade-operation evidence"
    From = $beforeUpgrade.KubernetesVersion
    To = $afterUpgrade.KubernetesVersion
    UnchangedPayloadSha256 = $afterUpgrade.PayloadSha256
    AvailableReplicas = $afterUpgrade.AvailableReplicas
    DesiredReplicas = $afterUpgrade.DesiredReplicas
} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $upgradeDirectory "comparison.json")
```

**Expected result:** The approved Kubernetes-version transition completes on the same cluster. The custom ConfigMap retains its UID and all data; both DNS samples contain `NOERROR` and the expected address. Managed CoreDNS is fully Available after the upgrade. Its image, managed configuration, pods, and `resourceVersion` may legitimately change.

**Pass/fail criteria:** PASS only with successful upgrade-operation evidence, two complete snapshots showing the intended version transition, unchanged custom UID and data hash, and two successful DNS checks. Lost/changed data or a failed DNS check prevents a whole-case PASS; report which criterion failed. A DNS answer difference alone does not establish that the stored configuration changed, especially if the stable-answer prerequisite was not met. A changed UID must be investigated as recreation, even if the values were restored; it does not pass this strict unchanged-object criterion. Missing operation evidence, missing baseline, or no version transition is BLOCKED/NOT ESTABLISHED. A node-image-only update or same-version reconciliation needs its own operation evidence and is not covered by this version-change gate.

**Evidence to capture:** Before/after snapshots, full `dig` outputs, approved operation scope and completion record, CoreDNS image versions, and relevant errors/audit events. Keep configuration and operation identifiers private when sharing a sanitized result. This test makes no configuration change and requires no cluster cleanup; do not run SP-13 as part of it.

**Established `aks01day2` evidence:** PARTIAL PASS on 2026-10-02: **the actual upgrade and custom ConfigMap preservation passed; the complete DNS criterion was not met.** This is not a blanket failure of configuration persistence and is not a full SP-15 PASS.

*   **PASS: upgrade and configuration preservation.** The control plane upgraded from `1.35.7` to `1.36.3`, and `coredns-custom` retained its complete data, UID, and resourceVersion. Both node pools remained on 1.35.7, and managed CoreDNS was 2/2 Available after the upgrade.
*   **Not fully PASS: fixed-address DNS validation.** The retry returned `NOERROR`, but the public test record changed from `150.171.110.195` to `150.171.109.183`. The specific unchanged-address assertion failed because the selected rotating public record did not meet the stable-answer prerequisite. This is not evidence that the custom ConfigMap was reset or lost.
*   **Initial command-execution failure retained.** API-to-kubelet proxy HTTP 500 prevented the first post-upgrade query from executing. The later retry did execute and returned a DNS answer. The HTTP 500 was not a DNS response-code failure.

**Measured evidence:** The approved control-plane-only upgrade was submitted at `14:48:39.6662362Z` and reached Azure `Succeeded` at `14:55:43.2110925Z`, with 12 operation samples over 423.545 seconds. `syspool` and `userpool` remained `Succeeded` on 1.35.7. Before/after snapshots at `14:48:20.5347403Z` and `14:55:56.6832792Z` retained `test.server`, no binary keys, custom UID `733fabca-7d66-4c20-8d54-08e8d89dd46b`, resourceVersion `23744277`, and payload SHA-256 `038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63`; another comparison at `14:58:18.8617371Z` agreed. CoreDNS moved from image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20` to `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.14.3-11` and was 2/2 Available. The client in `coredns-failover-validation` received `NOERROR`, `150.171.110.195`, 0 ms for `microsoft.com.` before the upgrade. The read-only retry at `14:58:28.5411572Z` returned `NOERROR`, `150.171.109.183`, 4 ms. Final checks at `15:00:06.4495127Z` verified normal Service DNS, six Available lab Deployments, four Ready nodes, zero lab NetworkPolicies, and zero SP-16 syntax resources. SP-15 made no custom ConfigMap change and required no resource cleanup. The PARTIAL PASS label distinguishes the established configuration result from the unmet DNS criterion; it does not change the original full-PASS criteria or failed-run records. This establishes stored configuration preservation for this control-plane upgrade, not node-pool upgrade/reimage behavior, every replica's loaded rule, continuous DNS availability, or future-release guarantees. See the [readable upgrade results](../validation/results/aks01day2-custom-config-20261002-sp15.md), [operation and first postcheck](../validation/results/aks01day2-custom-config-20261002-sp15-upgrade.json), [read-only retry](../validation/results/aks01day2-custom-config-20261002-sp15-postcheck.json), and [final health](../validation/results/aks01day2-custom-config-20261002-sp15-final-health.json).

---

##### SP-16-CUSTOM-CONFIG-PATCH-PERSISTENCE: Apply once and verify custom DNS persistence

**Validates item:** A one-time custom rule becomes active and persists through CoreDNS pod replacement and observation.

**Purpose:** Close the gap between observing an existing ConfigMap and showing that a newly applied custom rule becomes active and remains effective after CoreDNS pods are replaced. This is not an AKS upgrade, node replacement, full-cluster rebuild, or indefinite-persistence test.

**Prerequisites:** Use PowerShell 7; the script automatically loads the shared helper from its own directory. Obtain explicit approval to patch `kube-system/coredns-custom`, create and remove a temporary syntax-validation pod/ConfigMap in the client namespace, and perform three rolling restarts of managed CoreDNS on the named non-production cluster. Require at least two healthy CoreDNS replicas, the existing `kube-dns` Service, and an approved existing Linux client with `dig` and network access to each CoreDNS pod. The retained `coredns-failover-validation` client can be used if already healthy. Coordinate a window without other ConfigMap writers or upgrades. Run only one SP-16 instance at a time; the script refuses to proceed if another SP-16 key already exists. Keep the evidence directory private because it contains a complete configuration backup.

The [test script](../validation/Test-CoreDNSCustomConfigPersistence.ps1) performs this sequence:

1.  Back up the existing custom ConfigMap and record its UID, data hash, and the managed Corefile. Check normal Kubernetes Service discovery and establish `NXDOMAIN` for a unique test name through the DNS Service and every current CoreDNS pod.
2.  First validate the exact rule using the same CoreDNS image in a unique temporary pod and ConfigMap in the existing client namespace, then remove those resources. Use an API-server dry run followed by one JSON Patch to add a uniquely named `.server` key. A `resourceVersion` precondition rejects conflicting writes. The rule uses the built-in `hosts` plugin to return documentation-only address `192.0.2.123` for one name beneath a unique `.test` zone. TTL is **1 second**, the minimum accepted by the tested `hosts` parser, and the custom block has no cache plugin. API dry run alone cannot validate CoreDNS syntax.
3.  Perform the documented activation rolling restart. Verify all pod UIDs were replaced; check the exact test answer and normal Service discovery through the Service and every managed replica.
4.  Perform a second rolling restart **without patching the rule again**. Verify another complete pod-UID replacement and repeat the per-replica/Service DNS checks.
5.  Collect 31 snapshots using the SP-14 comparison helper, with 30-second sleeps and at least 900 seconds of observation. Compare the custom UID and full data hash, Kubernetes/CoreDNS versions, and managed replica availability. Check the test answer again at the end.
6.  In `finally`, remove only the owned key using UID, value, and resourceVersion checks. Restart CoreDNS to remove the rule from active configuration. Verify the original custom data/UID, unchanged managed Corefile, `NXDOMAIN` for the removed test name, and working normal Service discovery on every current replica and the Service.

**Commands:**

Run directly from the local workspace root in a fresh PowerShell 7 terminal; no helper-loading step is needed for SP-16. For a GitHub checkout, replace `07-CoreDNS` with `coredns`. Keep both PowerShell files together in the validation directory. The approval switch is an explicit safeguard, not a substitute for change approval.

```
$evidenceDirectory = Join-Path $env:TEMP ("sp16-" + [guid]::NewGuid().ToString("N"))
.\07-CoreDNS\validation\Test-CoreDNSCustomConfigPersistence.ps1 `
    -Context "aks01day2" `
    -ClientNamespace "coredns-failover-validation" `
    -ClientResource "deployment/dns-client" `
    -EvidenceDirectory $evidenceDirectory `
    -ApproveCustomDnsChange
Get-Content -LiteralPath (Join-Path $evidenceDirectory "result.json") -Raw
```

**Expected result:** The exact rule first passes isolated validation. It is then added to managed DNS once, returns exactly `192.0.2.123` with `NOERROR` and TTL 1 after both restarts and the observation, and is removed successfully. Each restart replaces all managed pod UIDs. All 31 snapshots preserve the patched ConfigMap UID and payload, with all desired CoreDNS replicas Available. After cleanup, the original custom data and UID match the backup and every checked DNS path no longer serves the test rule. The custom ConfigMap resourceVersion and the Deployment restart annotation legitimately change; they must not be described as unchanged.

**Pass/fail criteria:** PASS only if the exact DNS answer, all-pod replacement, complete 31-snapshot/minimum-900-second observation, preserved original entries, and cleanup assertions all succeed. A DNS error, unexpected answer or TTL, overlapping upgrade, missing snapshot, unhealthy sample, changed unrelated data, or failed cleanup fails the case. `result.json` remains `RUNNING` during execution and becomes `PASS` only after cleanup succeeds; an interrupted process is not a passing test. If another writer changes the owned key or ConfigMap identity, cleanup refuses to overwrite that change and reports the need for manual investigation.

**Evidence to capture:** The result JSON containing baseline, patched, observation, and cleanup snapshots; all DNS outputs and query times; old/new pod UIDs and rollout times; the exact JSON Patch operations; and cleanup status. Keep the full configuration backup private. Publish only reviewed, sanitized evidence. Retain failed attempts separately. CoreDNS availability can change during rolling restarts; this test checks after rollout completion and at the observation points, not continuous outage-free operation.

**Established `aks01day2` evidence:** PASS on 2026-10-02 for attempt 2, from `14:24:04.5125497Z` to `14:47:47.7366769Z` UTC including cleanup, on Kubernetes `v1.35.7` with CoreDNS image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`. The existing client in `coredns-failover-validation` checked `kube-system/coredns-custom`. The rule `sp16-dd8b44139468.server` was added once and served `answer.sp16-dd8b44139468.test.` as exactly `192.0.2.123` with `NOERROR` and TTL 1. The same-image isolated preflight passed before managed DNS changed. Both recorded verification rollouts replaced both pod UIDs: activation and a second restart without reapplying the rule. All 31 snapshots from `14:26:47.6348604Z` to `14:46:31.4229211Z` retained patched payload SHA-256 `2F2958B438382F823ABCE5E2C172ABD186618F9CF8557FED701CF0B96D8DC912` and resourceVersion `23735051`, with CoreDNS 2/2 Available in every sample. The stopwatch measured 1,183.785 seconds, exceeding the 900-second requirement. All 31 recorded DNS checks met their assertions: ten positive test-rule answers (one isolated preflight plus nine Service/per-replica checks), 15 correct normal Kubernetes Service answers, and six expected `NXDOMAIN` responses (three before patching and three after cleanup). There were zero recorded errors and the test process exited 0. Cleanup performed the third restart, which is not an entry in the two-element `Rollouts` array; removed only the test key; deleted the temporary syntax pod/ConfigMap; and restored the sole original `test.server` entry, payload SHA-256 `038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63`, and UID `733fabca-7d66-4c20-8d54-08e8d89dd46b`. The custom resourceVersion changed from `23733445` before patching to `23744277` after cleanup, as expected for these writes. The managed main Corefile was unchanged, with resourceVersion still `22591546`. Attempt 1 remains FAIL with cleanup PASS because `hosts` rejected TTL 0; TTL 1 and the isolated preflight corrected that failure. The complete observation, DNS, pod-replacement, and cleanup criteria were met for attempt 2. This does not establish AKS-upgrade or node-replacement persistence, indefinite persistence, or continuous outage-free DNS. See the [readable SP-16 results](../validation/results/aks01day2-custom-config-20261002-sp16.md), [passing raw evidence](../validation/results/aks01day2-custom-config-20261002-sp16-attempt2.json), and [failed first attempt with successful rollback](../validation/results/aks01day2-custom-config-20261002-sp16-attempt1.json).

#### Evidence handling

For every case, store:

*   Case ID, UTC timestamp, operator-independent cluster/context identifier, and CoreDNS image tag plus immutable image ID.
*   Exact commands and unedited stdout/stderr.
*   Effective ConfigMaps, relevant Deployments, pod UIDs, restart counts, and NetworkPolicies.
*   Ordered answers, not only grouped counts.
*   Full `dig` status, answer, and statistics output for failure transitions.
*   Timestamped resolver and upstream logs.
*   Metrics before, during, and after fault injection.
*   A result of PASS, FAIL, BLOCKED, or STATISTICALLY INCONCLUSIVE, with the criterion cited.

Do not put credentials, subscription identifiers, private production addresses, or other PII in evidence. Redact only sensitive fields and record that redaction occurred.

For SP-14 and SP-15, retain only the lifecycle-specific evidence described in those cases; no fault resources or synthetic upstream sample is required. Keep partial or blocked attempts clearly marked. Do not turn an unreachable API, a missing ConfigMap, or a successful local test of the helper into evidence that an AKS upgrade preserved the configuration.

SP-16 has a different noninterference boundary: it intentionally changes only its unique `coredns-custom` data key and the managed Deployment's restart annotation through the supported rolling-restart command. Verify original custom data restoration and unchanged main Corefile; do not require the custom ConfigMap or Deployment resourceVersion to remain unchanged across approved writes. Do not restore an entire old ConfigMap over concurrent changes.

The [SP-16 report](../validation/results/aks01day2-custom-config-20261002-sp16.md) links both retained attempts separately. Published attempt 2 evidence contains 15 private-IPv4 redactions in addition to the DNS-server placeholders inserted by the runner. Its full original ConfigMap backup remains private. The two recorded verification rollouts and the cleanup restart are three restarts, not three `Rollouts` entries.

#### Limitations

1.  The fixture uses namespace-local CoreDNS instances. It validates CoreDNS behavior, not every detail of the AKS-managed DNS request path.
2.  NetworkPolicy behavior depends on the cluster network plugin and policy enforcement. Prove isolation rather than assuming it.
3.  Silent packet loss, connection refusal, route failure, and a valid DNS `SERVFAIL` are different failure modes with different timing.
4.  Random selection is probabilistic. Endpoint coverage in a finite sample does not establish uniformity or fairness.
5.  Round-robin order can be obscured by concurrency, retries, endpoint health changes, multiple resolver replicas, or process restarts.
6.  The fixture omits caching to isolate selection. Production caching reduces the number of upstream exchanges and changes what clients observe.
7.  The fixture uses `max_fails 1` and `health_check 500ms`; those values may differ from the managed or proposed production configuration.
8.  Results apply to the recorded image. Revalidate after an AKS or CoreDNS upgrade.
9.  Pod-IP queries in extension cases are deliberate lab shortcuts and are not a production service design.
10.  A successful domain-specific custom server block does not prove that AKS supports globally replacing its managed root forwarder.
11.  Recovery time from this lab is an observation, not an availability SLO.
12.  This procedure does not assess upstream correctness, DNSSEC, TLS, confidentiality, capacity, or application retry behavior.
13.  An unchanged 15-minute sample cannot establish a controller's interval or rule out changes between samples. A passing upgrade case applies only to that recorded cluster, version transition, and operation scope, not every future AKS release.
14.  Equal ConfigMap data does not by itself prove the configuration was loaded or that DNS stayed available throughout an upgrade. SP-15 samples a custom answer through the managed DNS Service before and after; it does not prove every replica loaded the rule, exclude cached answers, or measure continuous availability.
15.  SP-16 passed for an approved one-time rule, two complete verification pod replacements, a 31-snapshot/1,183.785-second observation, and cleanup using managed DNS. It did not test node replacement, node reimaging, AKS upgrades, or full-cluster recreation. Its point-in-time DNS and availability checks do not establish continuous availability between checks or during rollouts. No finite test proves that a later administrator or configuration-management system cannot change the object.

#### Conclusion

CoreDNS can use sequential upstream selection, and the isolated v1.13.1 AKS fixture established first-healthy ordering, transport fallback, RCODE distinction, health observability, and recovery for the cases already recorded. The managed `aks01day2` baseline was not round-robin; because it omitted `policy`, its version-matched default was random.

For AKS, use `coredns-custom` for a scoped, domain-specific configuration and validate it with the dedicated cases above. Do not directly edit the managed Corefile. Treat a requested global change to `forward . /etc/resolv.conf` as an AKS support-boundary question requiring current Microsoft confirmation.

The custom ConfigMap is expected to retain customer entries across normal upgrades; it is not the managed Corefile that AKS may restore. No fixed custom-data reset interval is documented in the cited AKS guidance. This does not mean a controller never checks the object. On 2026-10-02, SP-14 passed with 31 unchanged snapshots over 1,154.510 seconds after a separately retained availability-related failed attempt. [SP-16 passed on attempt 2](../validation/results/aks01day2-custom-config-20261002-sp16.md): a rule applied once remained active after another complete CoreDNS pod replacement and 31 snapshots over 1,183.785 seconds; all 31 DNS checks met their assertions, and cleanup restored the original custom data and healthy DNS. The failed TTL-0 first attempt and its successful rollback remain recorded. This proves the tested finite pod-replacement case, not indefinite persistence, node replacement, an AKS upgrade, or continuous availability.

SP-15's separate control-plane-only upgrade from 1.35.7 to 1.36.3 completed with Azure `Succeeded` at `2026-10-02T14:55:43Z`; both node pools remained on 1.35.7. **The actual upgrade preserved the custom payload, UID, and resourceVersion**, while managed CoreDNS moved to a new image and remained 2/2 Available at the checks. The complete case did not pass because the selected public DNS record returned a different address on retry, despite `NOERROR`; it did not satisfy the stable-answer prerequisite. That limitation and the initial API-to-kubelet HTTP 500 are retained, not hidden. Preserve a desired-state backup, use a controlled stable custom answer for future upgrade tests, and distinguish configuration preservation from the behavior of a changing upstream record.

#### Authoritative links

*   [Customize CoreDNS for Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/coredns-custom)
*   [Troubleshoot CoreDNS in Azure Kubernetes Service](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/dns/basic-troubleshooting-dns-resolution-problems)
*   [CoreDNS 1.13.1 forward plugin](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
*   [CoreDNS forward plugin metrics](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md#metrics)
*   [CoreDNS 1.13.1 reload plugin and default check interval](https://github.com/coredns/coredns/blob/v1.13.1/plugin/reload/README.md)
*   [CoreDNS 1.13.1 hosts plugin and TTL option](https://github.com/coredns/coredns/blob/v1.13.1/plugin/hosts/README.md)
*   [CoreDNS 1.13.1 hosts parser: accepted TTL range 1-65535](https://github.com/coredns/coredns/blob/v1.13.1/plugin/hosts/setup.go)
*   [Kubernetes ConfigMaps and mounted update behavior](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically)
*   [Upstream add-on manager modes, not an AKS controller contract](https://github.com/kubernetes/kubernetes/blob/master/cluster/addons/addon-manager/README.md)
*   [Upgrade the AKS cluster control plane](https://learn.microsoft.com/en-us/azure/aks/upgrade-aks-cluster)
*   [2026-10-02 custom-ConfigMap validation attempt](../validation/results/aks01day2-custom-config-20261002.md)
*   [2026-10-02 SP-14 live results and historical SP-15 deferral](../validation/results/aks01day2-custom-config-20261002-live.md)
*   [2026-10-02 SP-16 one-time-rule persistence results and both attempts](../validation/results/aks01day2-custom-config-20261002-sp16.md)
*   [Kubernetes DNS debugging](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
*   [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   [Full AKS CoreDNS failover validation plan](../AKS_CoreDNS_Failover_Validation.md)
*   [Established `aks01day2` validation result](../validation/results/aks01day2-20260923-232149.md)