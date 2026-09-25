# CoreDNS Timeout Validation Result

- Cluster context: `aks01day2`
- Namespace: `coredns-failover-validation`
- CoreDNS image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`
- CoreDNS binary: `CoreDNS-1.13.1`
- Executed: 2026-09-24
- Summary: 16 mapped cases executed or source-verified

| Test | Result | Observation |
| --- | --- | --- |
| TV-01-VERSION | PASS | Managed and lab images matched; both binaries reported CoreDNS 1.13.1, linux/amd64, Go 1.26.5, revision `1db4568df6aaacda6ebbce87717156bd855f8103`. |
| TV-02-DEFINITIONS | PASS | Tagged 1.13.1 sources established 2-second read timeout and adaptive 1-to-30-second dial bounds. |
| TV-03-UDP-DROP | PASS | `NOERROR`, `192.0.2.20`, 1,999 ms. |
| TV-04-TCP-DROP | PASS, characterization | Cold forced-TCP silent loss returned `SERVFAIL`, no A answer, in 29,999 ms. |
| TV-05-REFUSAL-VS-DROP | PASS | Closed-port refusal reached `192.0.2.20` in 3 ms; silent TCP drop returned `SERVFAIL` in 30,007 ms. |
| TV-06-CLIENT-DEADLINES | PASS | One second timed out with exit 9; two seconds succeeded in 1,999 ms; five seconds succeeded in 2,003 ms. |
| TV-07-HEALTH-STATE | PASS | Cold query 2,003 ms; known-unhealthy queries 0, 3, and 3 ms. |
| TV-08-MULTIPLE-FAILURES | PASS | Two failed Service IPs before the healthy secondary produced `NOERROR`, `192.0.2.20`, in 4,003 ms. |
| TV-09-RCODE | PASS | Default `SERVFAIL` in 3 ms; explicit RCODE failover returned `NOERROR`, `192.0.2.20`, in 0 ms. |
| TV-10-TCP-CONNECTION-HISTORY | PASS | The first TCP connection failure returned `SERVFAIL` in 30,003 ms. After 20 quick successful TCP connections, the next failure reached the backup server in 1,003 ms. |
| TV-11-MEASUREMENT | PASS | First run: `dig` 3 ms and full `kubectl exec` 5,480 ms. Human repeat: `dig` 0 ms, meaning less than one millisecond at displayed precision, and full command 2,748 ms. The separate queries consistently show that command startup time is not DNS latency. |
| TV-12-RECOVERY | PASS | Human rerun: backup answer observed during outage, then primary returned on the first recovery check in 2,843 ms. Earlier runs measured 3,645 ms and 5,401 ms. All values include `kubectl exec` overhead and passed the 10-second criterion. |
| TV-13-OBSERVABILITY | PASS | Human rerun: pod restart count 0; `dig` returned backup answer in 2,003 ms; primary health-check failure counter 2; backup request count 1; backup processing time about 0.725 ms; CoreDNS log duration 2.00225682 seconds. Earlier run counted 3 health-check failures because metrics were read at a different time. |
| TV-14-REPEATABILITY | PASS | Five cold UDP trials returned the secondary in 2,003, 2,003, 2,003, 2,003, and 1,999 ms. |
| TV-15-SAFETY | PASS | Human rerun matched established evidence: all six base Deployments Available; no fault policy; no alias Service; primary answer `192.0.2.10`; managed CoreDNS Available; managed Corefile resourceVersion unchanged at `22591546`. |
| TV-16-READ-TIMEOUT | PASS | Disposable parser exited 1 with `unknown property 'read_timeout'`; running resolver remained Available. |

## Interpretation

- Measurements are controlled observations from the isolated namespace, not production SLOs.
- The 2-second value describes the CoreDNS 1.13.1 per-upstream read deadline, not every failure mode.
- TCP dial behavior depends on adaptive process-local history.
- The 2-second client success is a boundary observation and does not provide a safe timeout margin.
- Recovery stopwatch values include Kubernetes API and exec startup overhead.
