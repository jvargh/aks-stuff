# One-time custom CoreDNS rule: SP-16 live results

## Scope and outcome

- Cluster: `aks01day2`; custom resource: `kube-system/coredns-custom`.
- Client namespace: `coredns-failover-validation`; client: `deployment/dns-client`.
- Date: 2026-10-02. All times below are UTC.
- Kubernetes: `v1.35.7`; CoreDNS image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`.
- **PASS on attempt 2**, from `14:24:04.5125497Z` to `14:47:47.7366769Z`, including cleanup.
- Attempt 1 **failed** because its `hosts` rule specified invalid TTL 0; its cleanup passed. It is not counted as successful validation.
- This case tested a new rule applied once, activation, another CoreDNS pod replacement, finite observation, and removal. It did not upgrade AKS or replace nodes.
- Instructions: [SP-16](../../responses/01-Selection-policy.md#sp-16-custom-config-patch-persistence-apply-once-and-verify-custom-dns-persistence).

## What changed

The runner first backed up the existing custom ConfigMap privately. It added only `sp16-dd8b44139468.server`, using a resourceVersion-guarded JSON Patch. The rule returned `192.0.2.123` for `answer.sp16-dd8b44139468.test.` with TTL **1 second** and no cache plugin in that server block.

Before changing managed DNS, an isolated pod using the same CoreDNS image successfully parsed and served the exact rule. The temporary syntax-validation pod and ConfigMap were then deleted. The runner started in a fresh PowerShell process with no lifecycle helper preloaded; automatic helper loading succeeded.

Three managed CoreDNS rolling restarts were performed: activation, the persistence check without reapplying the rule, and cleanup. The managed main Corefile was not edited.

## Observation and identity

| Measurement | Result |
| --- | --- |
| First observation snapshot | `2026-10-02T14:26:47.6348604Z` |
| Last observation snapshot | `2026-10-02T14:46:31.4229211Z` |
| Complete snapshots | **31/31** |
| Stopwatch duration | **1,183.785 seconds**, or 19 minutes 43.785 seconds |
| Required minimum | 900 seconds |
| Managed CoreDNS availability | **2/2 in every snapshot** |
| Distinct patched payload hashes | 1 |
| Patched resourceVersion | `23735051`, unchanged throughout observation |
| Original custom entry | `test.server`, retained unchanged |
| Custom ConfigMap UID | `733fabca-7d66-4c20-8d54-08e8d89dd46b`, unchanged |
| Kubernetes/CoreDNS version changes during the case | 0 |
| Recorded errors in attempt 2 | 0 |
| Test process exit code | 0 |

The loop sleeps for 30 seconds between snapshots. Kubernetes API calls and evidence writing add time; the observation is longer than 15 minutes by design.

| State | Payload SHA-256 | Custom resourceVersion |
| --- | --- | --- |
| Before patch | `038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63` | `23733445` |
| Rule active | `2F2958B438382F823ABCE5E2C172ABD186618F9CF8557FED701CF0B96D8DC912` | `23735051` |
| After cleanup | `038194A7CD599F56E1FC40D4BDEBEB509434928FF249E9E810E69CEF9FC3CA63` | `23744277` |

The hash covers all `data` and `binaryData` keys and values. The changed resourceVersion across patch and removal is expected; it is not evidence of losing the original configuration.

## Pod replacement and DNS

| Stage | Measured result |
| --- | --- |
| Before patch | Test name: 3/3 `NXDOMAIN`; normal Kubernetes Service lookup: 3/3 correct |
| Isolated syntax validation | 1/1 `NOERROR`, exactly `192.0.2.123`, TTL 1 |
| Activation restart | Both pod UIDs replaced; recorded rollout `14:25:19.1643391Z` to `14:25:27.9579380Z` |
| After activation | Test name: 3/3 `NOERROR`, exact answer and TTL; normal Service lookup: 3/3 correct |
| Second restart, without another patch | Both pod UIDs replaced again; recorded rollout `14:26:05.7667138Z` to `14:26:14.2189039Z` |
| After second restart | Test name: 3/3 `NOERROR`, exact answer and TTL; normal Service lookup: 3/3 correct |
| After observation | Test name: 3/3 `NOERROR`, exact answer and TTL; normal Service lookup: 3/3 correct |
| After cleanup restart | Test name: 3/3 `NXDOMAIN`; normal Service lookup: 3/3 correct |

Each group of three checked the `kube-dns` Service and both current managed CoreDNS pods directly. In total, **31/31 recorded DNS checks met their assertions**: 25 `NOERROR` responses and six expected `NXDOMAIN` responses. The 25 positive checks comprise ten test-rule checks, including the isolated preflight, and 15 normal Service lookups.

The two verification rollouts retained their old/new pod UID sets in the raw evidence and shared no old UIDs with their corresponding new sets. The cleanup restart is the third restart; it is not an additional entry in the result's two-element `Rollouts` array.

## Cleanup

Cleanup removed only the owned test key using ConfigMap UID, key-value, and resourceVersion checks. It then completed a rolling restart and verified:

- Original custom payload hash and UID restored; only `test.server` remains.
- CoreDNS 2/2 Available.
- Removed test name returns `NXDOMAIN` through the Service and both replicas.
- Normal Kubernetes Service discovery succeeds on all three paths.
- Managed `coredns` Corefile unchanged, with ConfigMap resourceVersion still `22591546`.
- Temporary syntax-validation pod and ConfigMap deleted.

The separately queued SP-15 preflight independently checked the restored custom hash/UID, absence of SP-16 keys and syntax resources, managed Corefile resourceVersion, and healthy CoreDNS before submitting its approved upgrade. SP-15 is a separate operation, not part of this SP-16 result.

## Failed first attempt

The first attempt specified `ttl 0`. The [version-matched CoreDNS 1.13.1 `hosts` parser](https://github.com/coredns/coredns/blob/v1.13.1/plugin/hosts/setup.go) accepts TTL values from **1 through 65535**, and reported:

```text
plugin/hosts: /etc/coredns/custom/sp16-8516efac7300.server:5 - Error during parsing: ttl provided is invalid
```

Its activation rollout timed out after 240 seconds. Two replacement pods could not start while an original pod remained Available. The runner removed its key, restarted CoreDNS, and verified recovery to 2/2 Available with the original custom payload/UID and managed Corefile restored or unchanged as applicable.

The correction was TTL 1 plus the isolated same-image parser/answer preflight. The failed attempt remains a **FAIL with cleanup PASS**, rather than being overwritten by the retry.

## Interpretation and evidence

This establishes that this newly applied rule stayed active through another complete CoreDNS pod replacement and the 31-snapshot observation without reapplication. It does not prove indefinite persistence, continuous outage-free DNS, node replacement, node-pool upgrades, cluster recreation, or immunity to another writer.

- [Attempt 2: passing structured evidence](aks01day2-custom-config-20261002-sp16-attempt2.json).
- [Attempt 1: failure and successful rollback](aks01day2-custom-config-20261002-sp16-attempt1.json).
- [Standalone test runner](../Test-CoreDNSCustomConfigPersistence.ps1).

Published attempt 2 evidence redacts 15 remaining private IPv4 occurrences. DNS server addresses were already replaced with descriptive placeholders by the runner. The full original ConfigMap backup remains private and is not included.

The process exit code and fresh-process helper-loading result were captured by the execution session; the published result JSON does not have separate fields for them. Its `Status`, `Errors`, DNS outputs, snapshots, two verification rollouts, and cleanup status are the structured evidence for the assertions above.
