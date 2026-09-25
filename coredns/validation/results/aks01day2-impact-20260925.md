# AKS CoreDNS application-impact validation result

- Cluster context: `aks01day2`
- Kubernetes version: `v1.35.7`
- Temporary namespace: `coredns-failover-validation-imp-20260925-102725`
- Execution window: 2026-09-25T14:27:25.7971787Z to 2026-09-25T14:35:54.0206847Z
- CoreDNS image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`
- Scope: DNS-level impact; no representative application workload was supplied
- Raw evidence: [aks01day2-impact-20260925-102725.json](aks01day2-impact-20260925-102725.json)

## Results

| IMP case | Result | Exact observation |
| --- | --- | --- |
| `IMP-00-BASELINE` | PASS | Ten of ten queries returned `NOERROR` and `192.0.2.10`; query times were 4, 12, 0, 4, 0, 0, 4, 96, 0, and 0 ms. Direct primary and secondary checks returned `192.0.2.10` and `192.0.2.20` in 0 ms. All 6 Deployments were Available. |
| `IMP-01-FIRST-FAILURE` | PASS | After a resolver restart and silent primary packet loss, the first UDP query returned `NOERROR` and `192.0.2.20` in 2,000 ms. |
| `IMP-02-BUDGETS` | PASS | Independent one- and two-second tests exited with code 9 and no response. The five-second test returned `NOERROR` and `192.0.2.20` in 2,000 ms. |
| `IMP-03-LEARNED-UNHEALTHY` | PASS | The first query returned the secondary in 2,004 ms. Three later queries returned the secondary in 0, 0, and 0 ms. |
| `IMP-04-SERVFAIL` | PASS | Default handling returned `SERVFAIL` with no A record in 0 ms. Explicit `failover SERVFAIL` returned `NOERROR` and `192.0.2.20` in 0 ms. |
| `IMP-05-ALL-UNAVAILABLE` | PASS | With both upstreams blocked, the five-second client exited with code 9 and received no DNS response or A record. |
| `IMP-06-RECOVERY` | PASS | After both faults were removed without a resolver restart, the first recovery check returned `NOERROR` and `192.0.2.10`. Wall-clock time was 4,915 ms, including Kubernetes API and process startup time; DNS query time was 0 ms. |
| `IMP-07-RUNTIME-CACHE` | BLOCKED | No representative application, runtime, or cache configuration was supplied. |
| `IMP-08-CONNECTION-REUSE` | BLOCKED | No dependency protocol, connection pool, connection ID data, or method for forcing a new connection was supplied. |
| `IMP-09-RETRY-AMPLIFICATION` | BLOCKED | No application-layer retry policies or telemetry with a shared request ID were supplied. |
| `IMP-10-TRANSPORTS` | PASS | Healthy UDP and forced TCP returned the primary in 0 ms. Silent primary packet loss caused UDP to return the secondary in 2,004 ms; forced TCP returned `SERVFAIL` with no A record in 30,000 ms. |
| `IMP-11-BOUNDED-LOAD` | PASS for DNS | Fifty queries at concurrency 5 returned 50 primary answers, 0 secondary answers, and 0 unexpected lines; the command exited with code 0. |
| `IMP-12-DNS-OBSERVABILITY` | PASS | The resolver pod UID stayed the same and restart count remained 0. The query returned the secondary in 2,000 ms; health-check failures increased 0 to 2, request count increased 0 to 1, and five matching log lines were captured. |
| `IMP-13-APPLICATION-OBSERVABILITY` | BLOCKED | No representative request, shared request ID, application telemetry fields, or application log query was supplied. |
| `IMP-14-SLO-MAPPING` | BLOCKED | No workload SLO targets, request timeout, error-budget definition, or matching request telemetry was supplied. |
| `IMP-15-NEGATIVE-CONTROLS` | PASS | Healthy primary and secondary queries took 0 ms; an absent name returned `SERVFAIL` in 4 ms; the blocked primary received no response; the secondary still answered in 0 ms; the restored primary answered in 0 ms. |
| `IMP-16-REPEATABILITY` | PASS | Five first-query times were 2,004, 2,004, 2,000, 2,004, and 2,004 ms. Later-query times were 0, 0, 0, 4, and 0 ms. Every query returned `192.0.2.20`. |
| `IMP-17-CLEANUP` | PASS | The temporary namespace was deleted. The base lab had 6/6 Deployments Available and returned `NOERROR` and `192.0.2.10` in 3 ms. Managed CoreDNS remained 2/2 Available, and its Deployment resourceVersion stayed `23332770`. |

## Interpretation

- The DNS tests passed for the tested CoreDNS image and failure conditions.
- Application caching, connection reuse, retry behavior, application telemetry, and SLO impact remain untested because no representative workload was supplied.
- `dig` query time measures DNS latency. Wall-clock time around `kubectl exec` also includes Kubernetes API and process startup time.
- Health state and metrics belong to one CoreDNS process and reset when its pod restarts.
- The small concurrent-query test checks answer correctness only; it does not establish production capacity.

## Cleanup proof

The temporary namespace `coredns-failover-validation-imp-20260925-102725` was deleted and confirmed absent. No fault NetworkPolicy remained in the retained base namespace. The base lab and AKS-managed CoreDNS were healthy after the run. The pre-existing `coredns-failover-validation-imp` namespace was not changed.
