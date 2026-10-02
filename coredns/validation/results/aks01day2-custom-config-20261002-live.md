# Custom CoreDNS ConfigMap lifecycle: live validation results

> **Historical scope:** This report records the SP-14 run ending at `2026-10-02T13:41:55.8348744Z` and the SP-15 deferral in effect at that time. That deferral is not the current status: after the later [SP-16 test passed and cleanup was verified](aks01day2-custom-config-20261002-sp16.md), the approved SP-15 control-plane-only upgrade to 1.36.3 reached Azure `Succeeded` at `2026-10-02T14:55:43Z`. Both node pools remained on 1.35.7, and the custom payload, UID, and resourceVersion were preserved. The full case did not pass its fixed-address DNS criterion: after an API-to-kubelet HTTP 500, the read-only retry returned `NOERROR` with a different public A record. See the [completed SP-15 report](aks01day2-custom-config-20261002-sp15.md) for the measured outcome and test-input limitation. The original deferral and zero-write findings below remain unchanged as historical evidence, not an upgrade result.

## Scope and outcome

- Cluster: `aks01day2`; custom resource: `kube-system/coredns-custom`.
- Execution date: 2026-10-02. All times below are UTC.
- Kubernetes version: `v1.35.7`.
- CoreDNS image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`.
- SP-14: **PASS on attempt 2**. Attempt 1 failed the availability gate and is retained separately.
- SP-15: **BLOCKED/NOT ESTABLISHED**. The operator selected "Run SP-14 only; leave SP-15 pending an approved upgrade."
- Cluster writes by these tests: **0**. No upgrade, restart, apply, patch, deletion, fault policy, or namespace creation was performed.
- Instructions: [Selection policy and AKS customization lifecycle](../../responses/01-Selection-policy.md).

## Startup and baseline

The earlier [access attempt](aks01day2-custom-config-20261002.md) failed because the API hostname did not resolve. The cluster was subsequently starting, so readiness was polled every 30 seconds, plus request duration, with a 30-minute limit. At `12:57:19.5279583Z`, the API readiness endpoint returned `ok` and managed CoreDNS was 2/2 Available.

Azure subsequently reported `Running` / `Succeeded`; both node pools were `Succeeded` on Kubernetes 1.35.7. A read-only upgrade listing offered 1.36.3, but no upgrade was authorized or initiated.

Before the first attempt completed, checks of the retained `coredns-failover-validation` namespace found:

| Check | Result |
| --- | --- |
| Base Deployments | All six Available |
| NetworkPolicies | 0 |
| Direct primary query | `NOERROR`, `192.0.2.10`, 4 ms |
| Direct secondary query | `NOERROR`, `192.0.2.20`, 24 ms |
| Sequential resolver query | `NOERROR`, `192.0.2.10`, 4 ms |
| Managed Corefile | `reload`, `import custom/*.override`, and `import custom/*.server` present |
| Managed `coredns` ConfigMap resourceVersion | `22591546` |

These DNS checks validate the retained lab paths, not the custom `test.server` rule or upgrade persistence.

## SP-14 attempt 1: failed availability gate

The first observation ran from `13:15:26.2144476Z` to `13:19:19.1396495Z`, spanning **232.925 seconds** and **7 of 31 required snapshots**.

- All seven snapshots retained the same custom data hash, UID, and resourceVersion.
- The first six snapshots showed managed CoreDNS 2/2 Available.
- Snapshot 06 showed **1/2 Available**, so the documented assertion stopped the run with exit code 1.
- No passing `result.json` was produced for this attempt. It did not satisfy the full observation duration or health criteria.
- Subsequent read-only inspection found replacement CoreDNS pods created at `13:19:17Z` and `13:19:27Z`, with readiness-probe connection-refused events during the replacement window.
- By `13:20:30.0970145Z`, CoreDNS was again 2/2 Available. The inspected events establish pod replacement and recovery, but not who initiated replacement.
- No changes were made to force recovery, and no acceptance threshold was relaxed.

Raw evidence: [attempt 1, seven snapshots and failure](aks01day2-custom-config-20261002-sp14-attempt1.json).

## SP-14 attempt 2: passing full observation

After confirming CoreDNS was fully Available again, the same documented helper and SP-14 commands were executed without changing the sample count, sleep interval, or pass criteria.

| Measurement | Observed result |
| --- | --- |
| First snapshot | `2026-10-02T13:21:20.9144166Z` |
| Last snapshot | `2026-10-02T13:40:35.4671367Z` |
| Complete snapshots | **31/31** |
| Stopwatch duration | **1,154.510 seconds**, or 19 minutes 14.510 seconds |
| Timestamp-to-timestamp span | 1,154.552720 seconds |
| Required minimum duration | 900 seconds |
| Actual spacing between snapshot timestamps | 37.797435 to 40.653631 seconds |
| Custom data keys | `test.server` in all 31 snapshots |
| Binary data keys | None in all 31 snapshots |
| Unique custom payload hashes | **1** |
| Unique custom ConfigMap UIDs | **1** |
| Custom ConfigMap resourceVersion | `22928117`, unchanged |
| Managed CoreDNS availability | **2/2 in all 31 snapshots** |
| Managed CoreDNS Deployment resourceVersion | `23707464`, unchanged throughout attempt 2 |
| Kubernetes/CoreDNS version changes | 0 |
| Test process exit code | 0 |

The loop sleeps for 30 seconds **between** snapshots. Four sequential API reads, serialization, and writing each sample add time, so the full run exceeds 15 minutes. The small difference between the stopwatch duration and snapshot timestamp span reflects where timing begins and ends; both exceed the required 900 seconds.

Custom ConfigMap identity:

```text
UID: 733fabca-7d66-4c20-8d54-08e8d89dd46b
Payload SHA-256: 038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63
```

The complete payload hash covers all keys and values in both `data` and `binaryData`, with keys sorted ordinally. Metadata is excluded from this hash and checked separately.

Raw evidence: [attempt 2, all 31 snapshots and final health](aks01day2-custom-config-20261002-sp14-attempt2.json).

## Reconciliation interpretation

The custom ConfigMap carried these labels throughout the passing observation:

```yaml
addonmanager.kubernetes.io/mode: EnsureExists
k8s-app: kube-dns
kubernetes.io/cluster-service: "true"
```

Its field-manager entries were `kubectl-create` and `kubectl-client-side-apply`; the latter recorded a data update at `2026-09-24T04:34:21Z`.

Under the [upstream add-on manager's documented semantics](https://github.com/kubernetes/kubernetes/blob/master/cluster/addons/addon-manager/README.md), `EnsureExists` creates a missing object without continually resetting the data of an existing object. `Reconcile` restores managed template fields. These labels and field-manager records do not establish which controller currently acts on AKS or its schedule.

**`Reconcile` is an alternative value of the `addonmanager.kubernetes.io/mode` key, not a separate label. It was not observed on either ConfigMap.** A follow-up read-only comparison on 2026-10-02 found `addonmanager.kubernetes.io/mode=EnsureExists` on `coredns-custom`; the main `coredns` ConfigMap had no `addonmanager.kubernetes.io/mode` key and instead carried `app.kubernetes.io/managed-by=Eno`. The custom ConfigMap had no `app.kubernetes.io/managed-by` key. A missing mode label does not establish a default mode or prove that no controller reconciles the resource. See the [inspection commands and observed label table](../../responses/01-Selection-policy.md#how-to-check-the-actual-management-labels).

**The observed result is "no custom data or identity change during the sampled window," not "no reconciliation ever occurs."** A controller can check an unchanged object without writing to it. A finite sample cannot establish the controller's interval, exclude a change and restoration between samples, or guarantee behavior in all future releases. Automatic recreation would not necessarily restore the previous custom data.

The [CoreDNS reload interval](https://github.com/coredns/coredns/blob/v1.13.1/plugin/reload/README.md) concerns configuration-file checks, not ConfigMap overwrites. The [AKS customization guidance](https://learn.microsoft.com/en-us/azure/aks/coredns-custom) remains the support reference.

## SP-15: deferred, not an upgrade result

SP-15 was not executed. The operator explicitly deferred upgrade authorization after the available target was identified.

- Actual Kubernetes-version upgrades performed: **0**.
- Before/after upgrade evidence pairs: **0**.
- SP-15 custom DNS queries: **0**.
- Missing requirements: an approved upgrade scope/target, a fresh baseline, a reviewed custom DNS query and stable expected answer, and evidence of the completed operation.

A cluster start, replacement CoreDNS pods, and a passing SP-14 observation are not substitutes for a real Kubernetes-version upgrade. The expectation that custom entries survive normal upgrades remains qualified guidance, not an established result from this run.

## Final health and noninterference

Final checks completed at `13:41:55.8348744Z`:

- Managed CoreDNS: **2/2 Available**.
- Retained lab: **6/6 Deployments Available**, with no extra Deployments or NetworkPolicies.
- Nodes: **4/4 Ready**, all on `v1.35.7`.
- Azure: cluster and both node pools `Succeeded`, power state `Running`, version 1.35.7.
- Sequential lab query: `NOERROR`, `192.0.2.10`, **4 ms**.
- Custom UID, resourceVersion, and payload hash still matched the passing run.
- Managed `coredns` ConfigMap resourceVersion remained `22591546`.
- Managed Corefile SHA-256 remained `CB8A44B03292FE63D373FFF5418FA2DDE2705CD30FBB24D6F73B89E914C05A5A`.
- No cleanup was required because the tests created or modified no cluster resources.

## Evidence handling

Both attempts are retained separately; the passing rerun does not erase the first attempt's health failure. The initial hostname-resolution blocker is also retained as historical context.

The result bundle omits the local evidence-directory path and redacts private lab Service addresses from `dig` server lines. Custom DNS values are represented by their hash rather than copied into the snapshot output. Test status, timings, replica counts, object identity, and configuration hashes are preserved.
