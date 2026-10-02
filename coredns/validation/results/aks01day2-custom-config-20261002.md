# Custom CoreDNS ConfigMap lifecycle: blocked validation attempt

> Historical access attempt. After the cluster started, SP-14 was rerun and passed on its second live attempt. SP-15 remains deferred by the operator. See the [subsequent live results](aks01day2-custom-config-20261002-live.md); the observations below describe only the earlier blocked preflight.

- Attempt date: 2026-10-02.
- Requested context: `aks01day2`.
- Intended namespace/resource: `kube-system/coredns-custom`.
- Scope: read-only access checks; no upgrade, restart, apply, patch, or delete operation.
- Overall result: **BLOCKED/NOT ESTABLISHED**, not a persistence failure or a successful upgrade test.
- Related response: [Selection policy and AKS customization lifecycle](../../responses/01-Selection-policy.md).

## Observed preflight

| Command | Exit code | Observed output |
| --- | --- | --- |
| `kubectl config current-context` | 0 | `aks01day2` |
| `kubectl version -o json --request-timeout=20s` | 1 | Client version `v1.36.1`; no server version. API hostname lookup failed with `no such host`. |
| `kubectl get configmap coredns-custom -n kube-system -o json --show-managed-fields=true --request-timeout=20s` | 1 | API discovery and ConfigMap retrieval failed because the API hostname did not resolve. |

Relevant failure text, with the API hostname redacted:

```text
Unable to connect to the server: dial tcp: lookup [AKS API hostname]: no such host
```

This demonstrates that this client could not resolve the configured API endpoint. It does not identify the underlying cause, establish that the cluster was deleted, or imply that in-cluster DNS was unhealthy.

The documented `Get-CustomDnsSnapshot` helper was also executed at approximately **2026-10-02T12:49:16Z**. It stopped explicitly at the same ConfigMap read with the same hostname-resolution error; it did not return an empty or successful snapshot.

## Case outcomes

| Case | Result | Evidence and missing requirements |
| --- | --- | --- |
| `SP-14-CUSTOM-CONFIG-OBSERVATION` | BLOCKED/NOT ESTABLISHED | Zero complete snapshots; no payload hash, ConfigMap UID, or current replica count. The 31-snapshot, minimum-900-second observation was not started. Restore access before retrying. |
| `SP-15-CUSTOM-CONFIG-UPGRADE` | BLOCKED/NOT ESTABLISHED | Zero before/after snapshot pairs and zero custom DNS queries. No upgrade was authorized or executed and no custom query inputs were supplied. Requires access, a valid baseline, a reviewed custom query, and a separately approved completed upgrade. |

## State and interpretation

No Kubernetes resources were changed and no temporary namespace or fault policy was created. There is no cleanup operation to perform. Current managed CoreDNS and retained lab health could not be verified through the unreachable API.

Historical September evidence is retained separately. In particular, the September 24 observation of a `test.server` key is not evidence of October 2 persistence or upgrade survival.

Microsoft's current [AKS customization guidance](https://learn.microsoft.com/en-us/azure/aks/coredns-custom) was reviewed on 2026-10-02. It identifies `coredns-custom` as the supported customization mechanism, requires `.server` or `.override` keys, warns of version-dependent configuration values, and documents a rolling restart after configuration changes. It does not publish a fixed interval for resetting custom data or an unconditional all-version persistence guarantee.

The [CoreDNS 1.13.1 reload interval](https://github.com/coredns/coredns/blob/v1.13.1/plugin/reload/README.md) is a file-change check, not a ConfigMap deletion or overwrite timer. No controller interval was measured by this blocked attempt.

## Local document and helper validation

- The response validator passed with 16 cases and 16 mappings.
- Exact validation-item backlinks and all table-of-contents anchors were checked.
- All 21 PowerShell blocks parsed successfully.
- The two new cases passed the strict detailed-Established checks. Historical case evidence was left unchanged.
- Eleven synthetic helper checks passed: unchanged data, key-order/metadata-only changes, changed text data, changed binary data, a deleted key, a recreated object, unavailable replicas, an API command failure, a valid DNS answer, `SERVFAIL`, and an unexpected address.

These are local checks of the instructions and assertions, not evidence of live AKS reconciliation behavior or upgrade persistence.
