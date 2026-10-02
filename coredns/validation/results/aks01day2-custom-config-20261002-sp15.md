# Custom CoreDNS configuration across a control-plane upgrade: SP-15 results

## Outcome

**SP-15: PARTIAL PASS.** The real control-plane upgrade and `coredns-custom` preservation passed. The case is **not fully PASS** because its public DNS test record returned a different IP, failing the fixed-address assertion despite `NOERROR`. The initial command-execution failure and the later DNS result are retained below. This is not a blanket failure of configuration persistence.

| Check | Result |
| --- | --- |
| Actual approved upgrade | **PASS:** control plane `1.35.7` to `1.36.3`, Azure `Succeeded` |
| Custom ConfigMap preservation | **PASS:** identical UID, complete payload hash, resourceVersion, and `test.server` entry |
| Node-pool scope | **PASS:** `syspool` and `userpool` remain `1.35.7`, both `Succeeded` |
| Managed CoreDNS after upgrade | **PASS:** 2/2 Available |
| First post-upgrade DNS command | **Execution failure:** API-to-kubelet proxy HTTP 500; no DNS answer was obtained |
| Read-only DNS retry | `NOERROR` and an A answer, but not the predeclared address |
| Original fixed-address DNS assertion | **FAIL:** `150.171.110.195` before versus `150.171.109.183` after |
| Normal Kubernetes Service DNS and final lab health | **PASS** |

This is no longer an unexecuted test awaiting authorization. Configuration persistence is established for the actual recorded upgrade. PARTIAL PASS describes that mixed outcome without changing the original full-PASS criteria or failed-run records. The full test must not be called PASS, and the different public DNS answer must not be reported as loss of ConfigMap data.

Instructions: [SP-15](../../responses/01-Selection-policy.md#sp-15-custom-config-upgrade-compare-custom-configuration-across-an-approved-upgrade).

## Scope and sequence

- Cluster/context: `aks01day2`; resource: `kube-system/coredns-custom`.
- Client: `deployment/dns-client` in `coredns-failover-validation`.
- Date: 2026-10-02. All timestamps below are UTC.
- Approval covered **control-plane-only** upgrade to `1.36.3`, after SP-16 passed and cleanup was verified.
- No node-pool upgrade, node reimage, ConfigMap modification, or manual CoreDNS restart was performed by SP-15.
- [SP-16](aks01day2-custom-config-20261002-sp16.md) finished at `14:47:47.7366769Z`. Independent preflight then checked its restored custom hash/UID, removed test key and syntax resources, and unchanged managed Corefile resourceVersion.
- Fresh SP-15 baseline: `14:48:20.5347403Z`.
- Upgrade submission started: `14:48:39.6662362Z`; submission exit code: **0**.
- Azure completion observed: `14:55:43.2110925Z`, after **423.545 seconds**.
- Twelve timestamped Azure status samples were retained. A changed API version while Azure still said `Upgrading` was not treated as completion.

Preflight confirmed target availability, cluster and node pools `Succeeded` on `1.35.7`, and Kubernetes auto-upgrade channel `none`. No API-server metric series reporting use of APIs removed in 1.36 was observed; this was not a complete workload compatibility audit. Upgrade validations were not forced or bypassed.

The operation used `az aks upgrade` with `--kubernetes-version 1.36.3 --control-plane-only --yes --no-wait`. It was submitted **once**. The later postcheck retried only read-only validation, not the upgrade.

## Before and after

| Property | Before | First complete post-upgrade snapshot |
| --- | --- | --- |
| Snapshot time | `14:48:20.5347403Z` | `14:55:56.6832792Z` |
| API-server version | `v1.35.7` | `v1.36.3` |
| Custom UID | `733fabca-7d66-4c20-8d54-08e8d89dd46b` | Same |
| Custom resourceVersion | `23744277` | `23744277` |
| Custom data keys | `test.server` | `test.server` |
| Binary data keys | None | None |
| Custom mode label | `addonmanager.kubernetes.io/mode=EnsureExists` | Same |
| CoreDNS replicas | 2/2 Available | 2/2 Available |
| CoreDNS image | `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20` | `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.14.3-11` |
| `syspool` | `1.35.7`, `Succeeded` | `1.35.7`, `Succeeded` |
| `userpool` | `1.35.7`, `Succeeded` | `1.35.7`, `Succeeded` |

The complete custom payload SHA-256 was identical before and after:

```text
038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63
```

The comparison covers all `data` and `binaryData` keys and values, not only the presence of the ConfigMap. Cluster context, `kube-system` namespace UID, and custom ConfigMap UID also matched. A second read-only comparison at `14:58:18.8617371Z` confirmed the same result.

Although node pools were not upgraded, AKS updated the managed CoreDNS image. Its new image is an observed part of this control-plane upgrade, not evidence of a node-pool upgrade.

## DNS result and test-input limitation

The existing `test.server` has a `microsoft.com:53` server block that forwards apex queries upstream. The test selected `microsoft.com.` without changing the ConfigMap.

| Observation | RCODE | A answer | DNS query time |
| --- | --- | --- | --- |
| Before upgrade, `14:48:39.6217066Z` | `NOERROR` | `150.171.110.195` | 0 ms |
| First postcheck, stopped at `14:56:02.0675288Z` | Not obtained | Not obtained | Not measured |
| Read-only retry, `14:58:28.5411572Z` | `NOERROR` | `150.171.109.183` | 4 ms |

The first postcheck failed in Kubernetes' API-to-kubelet execution path:

```text
proxy error from localhost:9443 while dialing [private IPv4 redacted]:10250,
code 500: 500 Internal Server Error
```

This was a command-execution failure, not a DNS `SERVFAIL` or timeout reported by `dig`. The later read-only retry executed successfully, but its A record differed from the fixed expected address. Both failed checks remain in the retained evidence.

**The selected public record was unsuitable for the case's stable-address prerequisite.** It had also returned `150.171.109.183` during the earlier pre-upgrade preflight, before the fresh baseline selected `150.171.110.195`. The public answer is variable; unchanged custom forwarding configuration does not guarantee that its upstream returns one permanent IP address.

The criteria were not relaxed after the result, and queries were not repeated until the original address happened to return. The observed `NOERROR` establishes a successful sampled lookup, not a passing fixed-address assertion or proof of every replica's loaded configuration. The apex query also does not exercise the custom block's wildcard rewrite.

For a future complete rerun, select an existing, approved custom name with a controlled stable answer and verify that precondition before authorizing another upgrade. If no such record exists, arrange an explicitly approved isolated test rule beforehand or report configuration preservation separately. Do not infer that a new test after the completed upgrade provides a missing before/after pair.

## Final health

Read-only checks completed at `15:00:06.4495127Z`:

- Managed CoreDNS: **2/2 Available** on the upgraded image.
- Custom ConfigMap: original hash/UID and resourceVersion `23744277`; only `test.server`.
- Normal `kubernetes.default.svc.cluster.local.` lookup: `NOERROR` with the expected Kubernetes Service address.
- Retained lab Deployments: **6/6 Available**.
- Nodes: **4/4 Ready**, all kubelets still `v1.35.7`.
- Lab NetworkPolicies: **0**.
- SP-16 syntax-validation resources: **0**.

Supplemental read-only checks during the upgrade also returned the expected primary, secondary, and sequential lab answers: `192.0.2.10` in 4 ms, `192.0.2.20` in 0 ms, and `192.0.2.10` in 0 ms respectively. These are lab health checks, not substitutes for the SP-15 custom-query criterion.

SP-15 created no disposable cluster resources and required no DNS configuration cleanup. The authorized control-plane upgrade remains in place; it was not rolled back.

## Retained evidence and interpretation

- [Upgrade operation, before/after snapshots, and first failed postcheck](aks01day2-custom-config-20261002-sp15-upgrade.json).
- [Read-only postcheck: unchanged configuration and different public DNS answer](aks01day2-custom-config-20261002-sp15-postcheck.json).
- [Final health and normal Service DNS](aks01day2-custom-config-20261002-sp15-final-health.json).
- [Supplemental read-only DNS checks during the upgrade](aks01day2-custom-config-20261002-sp15-during-upgrade-dns.json).

The first two published files each redact three private IPv4 occurrences in the original command error. Normal Service/server addresses in the final-health file use descriptive placeholders. The full custom ConfigMap backup remains private.

The supported conclusion is: **this `coredns-custom` ConfigMap survived the actual `1.35.7` to `1.36.3` control-plane upgrade without any observed data, UID, or resourceVersion change, while managed CoreDNS itself moved to a new image.** This does not establish node-pool upgrade/reimage behavior, an unlimited persistence guarantee, a reconciliation interval, continuous DNS availability, or a whole-case SP-15 PASS.
