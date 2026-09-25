# CoreDNS Failover Validation Result

- Cluster context: `aks01day2`
- Disposable namespace: `coredns-failover-validation-fm` (deleted)
- Retained base namespace: `coredns-failover-validation` (healthy)
- CoreDNS image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`
- CoreDNS binary: `CoreDNS-1.13.1`, linux/amd64, Go 1.26.5, revision `1db4568df6aaacda6ebbce87717156bd855f8103`
- Executed: 2026-09-24
- Scope: 14 mapped FM cases; managed `kube-system` resources were read only

| Test | Result | Established observation |
| --- | --- | --- |
| FM-01-BASELINE | PASS | Six disposable Deployments were Available; direct upstream answers were `192.0.2.10` and `192.0.2.20`; managed CoreDNS was `v1.13.1-20`. |
| FM-02-SEQUENTIAL | PASS | Human rerun removed all faults, confirmed the sequential ConfigMap was already unchanged, and returned `192.0.2.10` for all eight ordered queries. No backup answer, timeout, or unexpected address occurred. |
| FM-03-UDP-DROP | PASS | NetworkPolicy `fm-primary-drop` blocked primary replies without returning an immediate error. One UDP client query returned `NOERROR` and backup answer `192.0.2.20` in 2,004 ms; CoreDNS handled fallback internally. |
| FM-04-TCP-DROP | PASS for behavior characterization; backup-success claim not met | With `force_tcp` and primary traffic blocked without an error response, one query returned `SERVFAIL` after 30,004 ms with `ANSWER: 0`. No backup IP address was returned. |
| FM-05-REFUSAL | PASS | Direct access to closed TCP port 5300 returned `connection refused` with exit 9. When that closed port was first in the resolver list, CoreDNS immediately used the backup and returned `NOERROR`, `192.0.2.20`, in less than one displayed millisecond. |
| FM-06-RCODE | PASS | The normal resolver returned primary responses `SERVFAIL`, `REFUSED`, and `NXDOMAIN` without an IP address. With explicit `failover` for those codes, all three names returned `NOERROR` and backup answer `192.0.2.20`. |
| FM-07-HEALTH-LEARNING | PASS | With `max_fails 1`, the first backup answer took 2,004 ms and the next three took 0 ms after CoreDNS marked the primary unavailable; health failures reached 16. With `max_fails 0`, all three queries paid the approximately two-second primary wait before using the backup. |
| FM-08-RECOVERY | PASS | After the primary fault was removed without restarting the resolver, the first recovery poll returned `192.0.2.10`. Measured elapsed time was 5,870-5,878 ms including Kubernetes API and process-start overhead. |
| FM-09-POLICY | PASS | All 72 results were summarized. Healthy: sequential 12/0, round-robin 6/6, random 7/5 primary/backup, totaling 25 primary and 11 backup. Primary unavailable: every policy returned 0/12, totaling 36 backup. No timeout or unexpected address occurred. |
| FM-10-ALL-UNHEALTHY | PASS | With both servers unavailable, three default queries each returned `SERVFAIL` in 2,000 ms and the broken-health metric reached 3, showing one last upstream attempt per query. Fail-fast returned `SERVFAIL` in 0 ms with no proxy-request increase. |
| FM-11-CLIENT-BUDGET | PASS | A one-second single attempt timed out with exit 9. Two one-second attempts returned the backup after learned health changed. After resolver reset, one five-second attempt returned `NOERROR`, `192.0.2.20`, in 2,004 ms. |
| FM-12-OBSERVABILITY | PASS | Self-contained run from one resolver process recorded 18 health-check failures, 1 all-upstreams-unhealthy event, three `NOERROR` and one `SERVFAIL` proxy requests, and 12 log lines. Logs correlated healthy primary, DNS error, two-second backup fallback, recovered primary, and two all-upstreams-unavailable timeouts. Cleanup restored the resolver. |
| FM-13-AKS-BOUNDARY | PASS | Managed CoreDNS remained 2/2 Available and managed Corefile resourceVersion stayed `22591546`. `coredns-custom` was read only, and 48 test objects were confined to the disposable namespace. |
| FM-14-CLEANUP | PASS | The disposable FM namespace was deleted. The retained lab remained healthy with six 1/1 Deployments and primary answer `192.0.2.10`; managed CoreDNS remained 2/2 and resourceVersion remained `22591546`. |

## Blocked or qualified outcomes

- No safely testable FM case was blocked from execution.
- FM-04 did **not** establish successful fallback when the first TCP connection received no reply. It returned `SERVFAIL` after 30,004 ms with no IP address, so the presence of a backup server must not be described as a guarantee that this request succeeds.
- The first FM-06 attempt used malformed compact fixture text and was excluded. The repaired multiline fixture was redeployed and all six retained comparisons passed.

## Interpretation

- Timings are DNS `dig` query times except FM-08, whose value includes Kubernetes API and process startup overhead.
- Random 7/5 selection is a finite observation, not a distribution guarantee.
- The result applies to the recorded CoreDNS binary, cluster path, and date; it is not an AKS service-level objective.
- Dynamic Service/pod IPs, account identifiers, and full managed manifests are omitted.

## Final environment state

- `coredns-failover-validation-fm`: deleted.
- `coredns-failover-validation`: six Deployments Available; sequential resolver returned `192.0.2.10`.
- `kube-system/coredns`: 2/2 Available; managed Corefile resourceVersion unchanged.

## Response

- [Failover mechanism response](../../responses/03-Failover-mechanism.md)
