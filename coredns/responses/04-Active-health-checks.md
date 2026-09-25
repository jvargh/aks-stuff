### 4\. Active health checks

**Question:** Does CoreDNS actively health-check upstream servers?

#### Table of Contents

*   [Introduction](#introduction)
*   [Answer](#answer)
*   [Theory](#theory)
*   [Items to Validate](#items-to-validate)
*   [Dedicated health-check validation suite](#dedicated-health-check-validation-suite)
    *   [HC-01: Resource and version compatibility](#hc-01-compatibility)
    *   [HC-02: No polling before an error](#hc-02-no-preerror)
    *   [HC-03: Network error starts the health loop](#hc-03-trigger)
    *   [HC-04: Interval and probe shape](#hc-04-probe-shape)
    *   [HC-05: `max_fails 0`](#hc-05-max-fails-zero)
    *   [HC-06: `max_fails 1`](#hc-06-max-fails-one)
    *   [HC-07: Default `max_fails 2`](#hc-07-max-fails-two)
    *   [HC-08: SERVFAIL is transport-healthy](#hc-08-servfail-health)
    *   [HC-09: Unhealthy skip and recovery](#hc-09-skip-recovery)
    *   [HC-10: All-upstreams-down behavior](#hc-10-all-down)
    *   [HC-11: Metrics and logs](#hc-11-observability)
    *   [HC-12: UDP and TCP](#hc-12-transports)
    *   [HC-13: Selection-policy interaction](#hc-13-policies)
    *   [HC-14: Restart resets learned health](#hc-14-restart-reset)
    *   [HC-15: Cleanup and reusable-lab verification](#hc-15-cleanup)
*   [Evidence handling](#evidence-handling)
*   [Limitations](#limitations)
*   [Conclusion](#conclusion)
*   [Authoritative links](#authoritative-links)

#### Introduction

This answer covers the CoreDNS `forward` plugin in the AKS lab image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`. It distinguishes continuous polling from CoreDNS's error-triggered health loop and keeps all writes in the disposable `coredns-failover-validation-hc` namespace.

#### Answer

Yes, after a forwarded exchange encounters a network error. CoreDNS does not continuously poll an untouched healthy upstream. The default loop sends recursive `. IN NS` checks every 0.5 seconds; `health_check` can change duration, recursion, and domain. Any DNS response, including SERVFAIL, demonstrates transport reachability. `max_fails` defaults to 2, `max_fails 0` disables checking, and learned health is process-local. AKS supports custom CoreDNS fragments through `coredns-custom`; this isolated result does not authorize editing the managed root Corefile.

#### Theory

A timeout, refusal, or connection error starts the loop. DNS RCODEs are responses rather than network errors. Consecutive failed probes reach `max_fails` and remove the endpoint from eligibility; recovery makes it eligible again. Selection policy operates on that eligible set. If every endpoint is down, default CoreDNS tries an unhealthy endpoint, whereas `failfast_all_unhealthy_upstreams` immediately returns SERVFAIL. `failover SERVFAIL` governs client-exchange retry and does not redefine probe health.

#### Items to Validate

| Item to Validate | Validation Method | Mapped HC Test Case |
| --- | --- | --- |
| Resource and version compatibility | Record image, binary version, direct upstream answers, readiness, and managed resourceVersion. | `HC-01-COMPATIBILITY` |
| No polling before an error | Compare health-check counters and upstream NS logs across a healthy five-second idle window. | `HC-02-NO-PREERROR` |
| Network error starts the health loop | Silently drop primary ingress, send one query, and inspect failure metrics. | `HC-03-TRIGGER` |
| Interval and probe shape | Use `health_check 2s no_rec domain probe.validation.test`; inspect upstream logs and packet capture when authorized. | `HC-04-PROBE-SHAPE` |
| `max_fails 0` disables health state | Run three queries during silent loss and compare health-check count. | `HC-05-MAX-FAILS-ZERO` |
| `max_fails 1` transition | Trigger once, wait, then issue three queries. | `HC-06-MAX-FAILS-ONE` |
| Default `max_fails 2` | Omit `max_fails`, trigger loss, and correlate failures with later queries. | `HC-07-MAX-FAILS-TWO` |
| SERVFAIL is transport-healthy | Make `. IN NS` return SERVFAIL, trigger loss, restore transport, and poll. | `HC-08-SERVFAIL-HEALTH` |
| Unhealthy skip and recovery | Trigger silent loss, prove fast secondary, restore ingress, and poll for primary. | `HC-09-SKIP-RECOVERY` |
| All-upstreams-down behavior | Block both upstreams and compare default behavior with `failfast_all_unhealthy_upstreams`. | `HC-10-ALL-DOWN` |
| Metrics and logs | Correlate pod UID, request/health metrics, logs, and the triggering query. | `HC-11-OBSERVABILITY` |
| UDP and TCP | Repeat loss with client UDP, client TCP, and `force_tcp`. | `HC-12-TRANSPORTS` |
| Selection-policy interaction | For sequential, round\_robin, and random, trigger health failure then sample eight answers. | `HC-13-POLICIES` |
| Restart resets learned health | Prove skip, restart the resolver while loss remains, and compare the first query. | `HC-14-RESTART-RESET` |
| Cleanup and noninterference | Delete the HC namespace, verify the retained base lab and managed CoreDNS. | `HC-15-CLEANUP` |

#### Dedicated health-check validation suite

##### Common prerequisites

The lab is created from the existing manifest by replacing the namespace only in memory. Service IPs are read after creation and injected dynamically. Never write `kube-system`. The wrapper makes every case independent and always removes faults.

```powershell
$ErrorActionPreference = "Stop"
$ns = "coredns-failover-validation-hc"
if ((kubectl config current-context).Trim() -ne "aks01day2") { throw "Wrong context" }
$manifest = (Get-Content -Raw ".\07-CoreDNS\validation\coredns-failover-lab.yaml").Replace("coredns-failover-validation", $ns)
$manifest | kubectl apply -f -
kubectl wait --for=condition=Available deployment --all -n $ns --timeout=240s
$primaryIp = (kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$secondaryIp = (kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$outage = (Get-Content -Raw ".\07-CoreDNS\validation\primary-outage-networkpolicy.yaml").Replace("coredns-failover-validation", $ns)
$allOutage = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-all-lab-upstreams
  namespace: $ns
spec:
  podSelector:
    matchExpressions:
      - key: app.kubernetes.io/name
        operator: In
        values:
          - upstream-primary
          - upstream-secondary
  policyTypes:
    - Ingress
  ingress: []
"@
function Set-HCResolver { param([string]$Policy="sequential",[string]$Max="max_fails 1",[string]$Health="health_check 500ms",[string]$Extra="")
    $cf = ".:53 {`n errors`n log`n ready`n health`n prometheus :9153`n forward . $primaryIp $secondaryIp {`n policy $Policy`n $Max`n $Health`n $Extra`n }`n}"
    kubectl create configmap resolver-sequential -n $ns "--from-literal=Corefile=$cf" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
}
function Invoke-HCCase { param([string]$Id,[scriptblock]$Body)
    try { kubectl delete networkpolicy simulate-primary-dns-packet-loss block-all-lab-upstreams -n $ns --ignore-not-found; & $Body }
    finally { kubectl delete networkpolicy simulate-primary-dns-packet-loss block-all-lab-upstreams -n $ns --ignore-not-found }
}
```

#### HC-01-COMPATIBILITY

##### HC-01-COMPATIBILITY: Resource and version compatibility

**Validates item:** Resource and version compatibility.

**Purpose:** Record image, binary version, direct upstream answers, readiness, and managed resourceVersion.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-01-COMPATIBILITY" -Body {
kubectl exec -n $ns deployment/resolver-sequential -- coredns -version
kubectl exec -n $ns deployment/dns-client -- dig @$primaryIp answer.validation.test A +short
kubectl exec -n $ns deployment/dns-client -- dig @$secondaryIp answer.validation.test A +short
}
```

**Expected result:** Image `v1.13.1-20`, binary `CoreDNS-1.13.1`, both direct answers, and Ready resources are present.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The compatibility check used the isolated health-check namespace and did not modify managed CoreDNS. The test image was `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`, and the binary reported CoreDNS 1.13.1. Direct queries proved that the two synthetic upstream servers were distinct and reachable: the primary returned `192.0.2.10` and the backup returned `192.0.2.20`. The resolver and upstream Deployments were Ready, and the managed CoreDNS resourceVersion was recorded for the later noninterference check. These results establish the exact CoreDNS version and a healthy starting point for the remaining cases. HC-01 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-01-compatibility).

#### HC-02-NO-PREERROR

##### HC-02-NO-PREERROR: No polling before an error

**Validates item:** No polling before an error.

**Purpose:** Compare health-check counters and upstream NS logs across a healthy five-second idle window.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-02-NO-PREERROR" -Body {
Set-HCResolver
$before = kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
$start=(Get-Date).ToUniversalTime().ToString("o"); Start-Sleep 5
$after = kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
kubectl logs -n $ns deployment/upstream-primary --since-time=$start | Select-String "NS IN"
}
```

**Expected result:** Counter is unchanged and no NS probe is logged.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The resolver was restarted into a healthy state and no DNS query or fault was introduced during a five-second idle window. The health-check counter was 0 before the wait and remained 0 afterward. The primary upstream logs contained zero `. IN NS` health-check queries for the same time window. This proves that CoreDNS did not continuously poll an untouched healthy upstream during the observed period; health checking starts after an exchange error. The result is limited to the five-second observation window and the available metric/log visibility. Cleanup confirmed that no fault policy remained. HC-02 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-02-no-preerror).

#### HC-03-TRIGGER

##### HC-03-TRIGGER: Network error starts the health loop

**Validates item:** Network error starts the health loop.

**Purpose:** Silently drop primary ingress, send one query, and inspect failure metrics.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-03-TRIGGER" -Body {
Set-HCResolver
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 3
kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics" | Select-String "healthcheck"
}
```

**Expected result:** The backup server returns `192.0.2.20` after the approximately two-second wait for the primary. The primary-server health-check failure counter becomes greater than zero. `coredns_forward_healthcheck_broken_total` remains 0 because the backup server is still healthy.

**Pass/fail criteria:** Pass when the query returns `NOERROR` and `192.0.2.20` in 1,500-3,500 ms, the primary health-check failure counter is greater than zero, and the all-upstreams-unhealthy counter remains 0.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The test restarted the sequential resolver, then applied a NetworkPolicy that blocked replies from the primary server without returning an immediate error. The client query returned `NOERROR` and backup answer `192.0.2.20` in 2,004 ms. The primary health-check failure counter was 3 when metrics were read, proving that the failed client exchange started repeated checks of the unavailable primary. An earlier run read the metric later and recorded 6 failures; the difference is expected because CoreDNS continues checking the unavailable server and the counter depends on when it is sampled. `coredns_forward_healthcheck_broken_total` was 0, which is correct because only the primary had failed and the backup remained healthy. The result satisfies all HC-03 criteria. Cleanup removed the fault policy. HC-03 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-03-trigger).

#### HC-04-PROBE-SHAPE

##### HC-04-PROBE-SHAPE: Interval and probe shape

**Validates item:** Interval and probe shape.

**Purpose:** Use `health_check 2s no_rec domain probe.validation.test`; inspect upstream logs and packet capture when authorized.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-04-PROBE-SHAPE" -Body {
Set-HCResolver -Health "health_check 2s no_rec domain probe.validation.test"
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1
Start-Sleep 3
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns --ignore-not-found
kubectl logs -n $ns deployment/upstream-primary --since=30s | Select-String "NS IN probe.validation.test"
}
```

**Expected result:** The custom NS name is logged; packets establish exact cadence and RD.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The resolver was configured with `health_check 2s no_rec domain probe.validation.test`, then the primary was made unavailable to start health checking. After connectivity was restored, the primary upstream log contained an `NS IN probe.validation.test` query and showed the recursion flag as `false`, confirming both the custom health-check name and `no_rec` behavior. Only one delivered probe was visible in application logs. Proving the exact two-second cadence and comparing it with the default 0.5-second cadence requires packet timestamps, but no approved privileged packet-capture image was available. Therefore, probe name and recursion behavior were established, while exact cadence remains blocked. HC-04 is partial, not a full pass. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-04-probe-shape).

#### HC-05-MAX-FAILS-ZERO

##### HC-05-MAX-FAILS-ZERO: `max_fails 0` disables health state

**Validates item:** `max_fails 0` disables health state.

**Purpose:** Run three queries during silent loss and compare health-check count.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-05-MAX-FAILS-ZERO" -Body {
Set-HCResolver -Max "max_fails 0"
$outage | kubectl apply -f -
1..3 | ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats }
}
```

**Expected result:** Every query retries the primary and no checks are recorded.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The resolver was configured with `max_fails 0`, which disables upstream health checking and prevents CoreDNS from marking the primary unavailable. The primary server was then blocked without an immediate error. Three client queries all reached the backup server, but each first waited for the nonresponsive primary: query times were 2,004, 2,000, and 2,004 ms. The health-check count remained 0 before and after the queries. This proves that same-request fallback still works, but every new request pays the primary timeout because CoreDNS never learns to remove that server from normal selection. Cleanup removed the fault and restored the resolver. HC-05 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-05-max-fails-zero).

#### HC-06-MAX-FAILS-ONE

##### HC-06-MAX-FAILS-ONE: `max_fails 1` transition

**Validates item:** `max_fails 1` transition.

**Purpose:** Trigger once, wait, then issue three queries.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-06-MAX-FAILS-ONE" -Body {
Set-HCResolver -Max "max_fails 1"
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 3
1..3 | ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats }
}
```

**Expected result:** Post-detection queries skip the primary in under 500 ms.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The resolver was configured with `max_fails 1`, and the primary was blocked. The first query waited 2,004 ms before returning the backup answer because CoreDNS had not yet marked the primary unavailable. After three seconds of health checking, three more queries returned the backup in 0, 4, and 4 ms. The health-check failure counter reached 15. This proves that one failed health check was enough for CoreDNS to stop trying the primary on later requests, removing the repeated two-second delay. The counter continued increasing because CoreDNS kept checking the primary in the background. Cleanup restored normal connectivity and configuration. HC-06 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-06-max-fails-one).

#### HC-07-MAX-FAILS-TWO

##### HC-07-MAX-FAILS-TWO: Default `max_fails 2`

**Validates item:** Default `max_fails 2`.

**Purpose:** Omit `max_fails`, trigger loss, and correlate failures with later queries.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-07-MAX-FAILS-TWO" -Body {
Set-HCResolver -Max ""
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 6
1..3 | ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats }
}
```

**Expected result:** After repeated failed probes, queries skip the primary.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** This case omitted `max_fails`, so CoreDNS used the documented default value of 2. With the primary blocked, the first query reached the backup after 2,000 ms. After six seconds of failed health checks, three later queries reached the backup in 4, 0, and 96 ms, and the health-check failure counter reached 18. These results prove that CoreDNS eventually marked the primary unavailable and skipped it on later requests. They do not directly prove the exact moment when the second failed probe caused the state change, because packet-level timing was not available. Cleanup removed the fault and restored the resolver. HC-07 passed for observed skip behavior; the exact second-probe transition remains blocked. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-07-max-fails-two).

#### HC-08-SERVFAIL-HEALTH

##### HC-08-SERVFAIL-HEALTH: SERVFAIL is transport-healthy

**Validates item:** SERVFAIL is transport-healthy.

**Purpose:** Make `. IN NS` return SERVFAIL, trigger loss, restore transport, and poll.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-08-SERVFAIL-HEALTH" -Body {
# Apply a namespace-local upstream Corefile whose `template IN NS .` returns SERVFAIL.
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 3
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns
1..20 | ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +short; Start-Sleep -Milliseconds 250 }
}
```

**Expected result:** A SERVFAIL health response permits the primary to re-enter.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The primary upstream was configured so its health-check query `. IN NS` returned `SERVFAIL`. The primary was then blocked, and the first client query reached the backup after 2,008 ms, starting the health loop. After connectivity was restored, the upstream log captured one NS health query returning `SERVFAIL`. CoreDNS treated that DNS response as proof that the server was reachable and made the primary eligible again. A later poll returned the primary answer in 84 ms; the complete polling operation took 5.54 seconds including Kubernetes API and process-start overhead. This proves that any DNS response, including `SERVFAIL`, counts as transport health. Cleanup restored the original upstream configuration. HC-08 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-08-servfail-health).

#### HC-09-SKIP-RECOVERY

##### HC-09-SKIP-RECOVERY: Unhealthy skip and recovery

**Validates item:** Unhealthy skip and recovery.

**Purpose:** Trigger silent loss, prove fast secondary, restore ingress, and poll for primary.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-09-SKIP-RECOVERY" -Body {
Set-HCResolver
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 3
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns
1..20 | ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +short; Start-Sleep -Milliseconds 250 }
}
```

**Expected result:** Secondary is fast while down and primary eventually returns.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The primary was blocked and the first query triggered failure detection. After three seconds, a later query reached the backup in 4 ms, proving that CoreDNS had learned to skip the unavailable primary. The fault was then removed and the case issued 20 bounded recovery polls. During this sample, the resolver continued selecting the backup; the latest measured query was 192 ms, and the primary did not reappear before the sample ended. Therefore, the skip behavior was established, but this case did not establish recovery time or primary re-entry. HC-08 independently proved that re-entry can occur. HC-09 is partial and no recovery guarantee is claimed. Cleanup removed the fault. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-09-skip-recovery).

#### HC-10-ALL-DOWN

##### HC-10-ALL-DOWN: All-upstreams-down behavior

**Validates item:** All-upstreams-down behavior.

**Purpose:** Block both upstreams and compare default behavior with `failfast_all_unhealthy_upstreams`.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-10-ALL-DOWN" -Body {
Set-HCResolver
$allOutage | kubectl apply -f -
Start-Sleep 5
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Set-HCResolver -Extra "failfast_all_unhealthy_upstreams"
Start-Sleep 5
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
}
```

**Expected result:** Default attempts an unhealthy endpoint; fail-fast returns SERVFAIL immediately.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** Both upstream servers were blocked and CoreDNS was allowed time to mark them unavailable. With the default configuration, the measured query returned `SERVFAIL` after 2,004 ms because CoreDNS still made a last attempt to an unavailable upstream. The resolver was then restarted with `failfast_all_unhealthy_upstreams`. Under the same all-down condition, the next query returned `SERVFAIL` in 4 ms instead of waiting for another upstream attempt. The `coredns_forward_healthcheck_broken_total` metric family was exposed for the all-unhealthy state. This proves that fail-fast changes latency by returning immediately once every upstream is known unavailable. Cleanup removed the all-server block and restored the standard resolver. HC-10 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-10-all-down).

#### HC-11-OBSERVABILITY

##### HC-11-OBSERVABILITY: Metrics and logs

**Validates item:** Metrics and logs.

**Purpose:** Correlate pod UID, request/health metrics, logs, and the triggering query.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-11-OBSERVABILITY" -Body {
Set-HCResolver
$uid=kubectl get pod -n $ns -l app.kubernetes.io/name=resolver-sequential -o jsonpath="{.items[0].metadata.uid}"
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics" | Select-String "coredns_(proxy|forward)"
kubectl logs -n $ns deployment/resolver-sequential --since=30s
}
```

**Expected result:** Evidence comes from one resolver lifetime.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The case recorded resolver pod UID `ec3e6866-7809-437f-ae98-1bcc049a2594` before introducing the fault, so all metrics and logs could be tied to one CoreDNS process. A primary failure was triggered and the client query reached the backup. The resulting metric snapshot contained 13 health-check failures and one proxy request series, and the resolver log contained the matching query line. This establishes correlation between the client-visible request, CoreDNS health activity, proxy metrics, and logs from the same process. It does not claim that metric presence alone proves causation; the shared UID and time window provide that link. Cleanup removed the fault. HC-11 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-11-observability).

#### HC-12-TRANSPORTS

##### HC-12-TRANSPORTS: UDP and TCP

**Validates item:** UDP and TCP.

**Purpose:** Compare the first and later queries for client UDP, client TCP, and a resolver forced to use TCP upstream.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-12-TRANSPORTS" -Body {
    try {
        $results = [System.Collections.Generic.List[object]]::new()
        $cases = @(
        @{
            Name = "Client UDP"
            ClientArgs = @("+notcp")
            ResolverExtra = ""
            FirstTimeout = 6
        },
        @{
            Name = "Client TCP"
            ClientArgs = @("+tcp")
            ResolverExtra = ""
            FirstTimeout = 40
        },
        @{
            Name = "Forced upstream TCP"
            ClientArgs = @("+notcp")
            ResolverExtra = "force_tcp"
            FirstTimeout = 40
        }
    )

        foreach ($case in $cases) {
            kubectl delete networkpolicy simulate-primary-dns-packet-loss `
                -n $ns --ignore-not-found | Out-Null
            Set-HCResolver -Extra $case.ResolverExtra
            $outage | kubectl apply -f - | Out-Null

            foreach ($phase in @("First query","After health detection")) {
                if ($phase -eq "After health detection") {
                    Start-Sleep -Seconds 3
                }

            $timeout = if ($phase -eq "First query") {
                $case.FirstTimeout
            }
            else {
                6
            }
            $arguments = @(
                "exec","-n",$ns,"deployment/dns-client","--",
                "dig","@resolver-sequential","answer.validation.test","A"
            ) + $case.ClientArgs + @(
                "+time=$timeout","+tries=1","+comments","+answer","+stats"
            )
            $output = @(& kubectl @arguments 2>&1)
            $exitCode = $LASTEXITCODE
            $text = $output -join "`n"

            $statusMatch = [regex]::Match($text, "status:\s+([A-Z]+)")
            $answerMatch = [regex]::Match(
                $text,
                "\sIN\s+A\s+(\d{1,3}(?:\.\d{1,3}){3})"
            )
            $timeMatch = [regex]::Match(
                $text,
                "Query time:\s+(\d+)\s+msec"
            )

                $results.Add([pscustomobject]@{
                Mode = $case.Name
                Phase = $phase
                ExitCode = $exitCode
                Status = if ($statusMatch.Success) {
                    $statusMatch.Groups[1].Value
                } else {
                    "NO_RESPONSE"
                }
                Answer = if ($answerMatch.Success) {
                    $answerMatch.Groups[1].Value
                } else {
                    ""
                }
                QueryMs = if ($timeMatch.Success) {
                    [int]$timeMatch.Groups[1].Value
                } else {
                    $null
                }
            })

                "$($case.Name) - $phase"
                $output
            }

            kubectl delete networkpolicy simulate-primary-dns-packet-loss `
                -n $ns --ignore-not-found | Out-Null
        }

    "Transport summary:"
    $results | Format-Table -AutoSize

    $udpFirst = $results | Where-Object {
        $_.Mode -eq "Client UDP" -and $_.Phase -eq "First query"
    }
    if ($udpFirst.Status -ne "NOERROR" -or
        $udpFirst.Answer -ne "192.0.2.20" -or
        $udpFirst.QueryMs -lt 1500 -or
        $udpFirst.QueryMs -gt 3500) {
        throw "The first UDP query did not return the expected backup answer."
    }

    $later = @($results | Where-Object {
        $_.Phase -eq "After health detection"
    })
    if (@($later | Where-Object {
        $_.Status -ne "NOERROR" -or
        $_.Answer -ne "192.0.2.20" -or
        $_.QueryMs -ge 500
    }).Count -ne 0) {
        throw "At least one later transport query did not quickly use the backup."
    }

        Write-Host "[PASS] HC-12: UDP fallback was measured, TCP first-query outcomes were recorded, and all later queries quickly used the backup."
    }
    finally {
        kubectl delete networkpolicy simulate-primary-dns-packet-loss `
            -n $ns --ignore-not-found | Out-Null
        Set-HCResolver
    }
}
```

**Expected result:** The first UDP query returns the backup in about two seconds. A first TCP query can take much longer and may return `SERVFAIL` or exceed a short client timeout because opening a new TCP connection can wait close to 30 seconds. After CoreDNS marks the primary unavailable, a later query in every mode returns the backup in under 500 ms.

**Pass/fail criteria:** Pass when the first UDP query returns `NOERROR` and `192.0.2.20` in 1,500-3,500 ms, every later query returns the backup in under 500 ms, all first-query TCP outcomes are retained, and cleanup removes the actual `simulate-primary-dns-packet-loss` policy. Packet-level proof of resolver-to-upstream protocol remains a separate blocked subclaim.

**Evidence to capture:** Resolver configuration for each mode, all six complete `dig` outputs, the transport summary table, exit codes, response codes, answers, query times, fault-policy state, logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The transport test started each mode with a freshly restarted resolver and a policy that blocked replies from the primary server. For the client UDP mode, the query returned `NOERROR` and backup answer `192.0.2.20` in 2,004 ms. This establishes the first-query UDP behavior: CoreDNS waited for the primary reply, then returned the backup answer within the expected two-second range.

For the client TCP mode, no DNS response arrived within the six-second client timeout and `dig` exited with code 9. For the resolver configured with `force_tcp`, the UDP client query also received no response within six seconds and exited with code 9. These two outcomes establish only that six seconds was not long enough to observe the final fresh-TCP result. CoreDNS can wait close to 30 seconds while opening a new TCP connection, so a longer client timeout is required.

HC-12 is therefore partial. The UDP first-query result is established and passes. The final fresh-TCP outcomes and the later post-detection queries are not yet established and must be measured with the corrected commands, which allow 40 seconds for each first TCP query and then issue a second query after health detection. Packet-level proof of the resolver-to-upstream protocol is also still blocked because no approved packet-capture method was available. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-12-transports).

#### HC-13-POLICIES

##### HC-13-POLICIES: Selection-policy interaction

**Validates item:** Selection-policy interaction.

**Purpose:** For sequential, round\_robin, and random, trigger health failure then sample eight answers.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-13-POLICIES" -Body {
foreach($policy in @("sequential","round_robin","random")) { Set-HCResolver -Policy $policy; $outage|kubectl apply -f -; 1..6|ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +short }; Start-Sleep 4; 1..8|ForEach-Object { kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +short }; kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns --ignore-not-found }
}
```

**Expected result:** All post-detection answers are secondary.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** Sequential, round-robin, and random policies were tested separately. For each policy, the primary was blocked, six queries were used to trigger and reinforce failure detection, CoreDNS was given four seconds to update health state, and eight post-detection answers were sampled. Every post-detection answer came from the backup server; no primary or unexpected address appeared. Health-check failure counters were 160 for sequential, 153 for round-robin, and 129 for random. The counter totals differ because each resolver process performed checks for a different amount of time; they are not policy performance scores. The result proves that health eligibility is applied before selection policy, so all three policies exclude an unavailable primary. HC-13 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-13-policies).

#### HC-14-RESTART-RESET

##### HC-14-RESTART-RESET: Restart resets learned health

**Validates item:** Restart resets learned health.

**Purpose:** Prove skip, restart the resolver while loss remains, and compare the first query.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-14-RESTART-RESET" -Body {
Set-HCResolver
$outage | kubectl apply -f -
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
Start-Sleep 3
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
kubectl exec -n $ns deployment/dns-client -- dig @resolver-sequential answer.validation.test A +time=6 +tries=1 +stats
}
```

**Expected result:** A fresh process has no persisted health state.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** The primary remained blocked while the resolver was first allowed to learn the failure and was then restarted. The resolver pod UID changed, proving that a new CoreDNS process was running. However, the query before restart and the first query after restart both returned the backup in 0 ms. The Kubernetes Service or upstream-selection state did not force the new process to try the blocked primary, so the test could not demonstrate whether learned health state had been cleared. CoreDNS source documents that health state is process-local, but this sample did not prove that behavior live. HC-14 is inconclusive, not a pass or failure. Cleanup removed the fault and restored the resolver. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-14-restart-reset).

#### HC-15-CLEANUP

##### HC-15-CLEANUP: Cleanup and noninterference

**Validates item:** Cleanup and noninterference.

**Purpose:** Delete the HC namespace, verify the retained base lab and managed CoreDNS.

**Prerequisites:** Run Common prerequisites; this case creates and removes its own fault/configuration and does not depend on another case.

**Commands:**

```powershell
Invoke-HCCase -Id "HC-15-CLEANUP" -Body {
kubectl delete namespace $ns --wait=true --timeout=240s
kubectl wait --for=condition=Available deployment --all -n coredns-failover-validation --timeout=180s
kubectl exec -n coredns-failover-validation deployment/dns-client -- dig @resolver-sequential answer.validation.test A +short
kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=180s
}
```

**Expected result:** HC namespace is absent; base primary resolves; managed CoreDNS is Available and unchanged.

**Pass/fail criteria:** The expected result must be observed; partial or blocked subclaims are explicitly identified in established evidence.

**Evidence to capture:** Corefile, pod UID, UTC timestamps, complete `dig +stats`, relevant logs/metrics, and cleanup output.

**Established `aks01day2` evidence:** Cleanup deleted the disposable `coredns-failover-validation-hc` namespace and confirmed that it no longer existed. The retained base validation namespace remained healthy with all six Deployments Available. A final query through its sequential resolver returned primary answer `192.0.2.10`. Managed CoreDNS remained Available, and the managed Corefile ConfigMap resourceVersion remained `22591546`, matching the value captured before testing. These checks prove that the HC resources were removed without changing the reusable base lab or managed AKS DNS configuration. HC-15 passed. See the [retained result](../validation/results/aks01day2-health-checks-20260924.md#hc-15-cleanup).

#### Evidence handling

Raw observations are summarized in the [distinct result file](../validation/results/aks01day2-health-checks-20260924.md). Cluster-private addresses and identities are omitted. Metrics are interpreted only within one pod lifetime.

#### Limitations

1.  Exact packet cadence and forced upstream transport require an approved privileged capture path; only those packet subclaims are blocked.
2.  NetworkPolicy produces silent loss in this tested CNI; rejection has different timing.
3.  Timings characterize this lab and are not production SLOs. HC-09 and HC-14 are explicitly not promoted beyond observed evidence.

#### Conclusion

CoreDNS 1.13.1 actively probes an upstream only after network failure. The isolated AKS evidence established trigger, disabled/default thresholds, SERVFAIL transport health, skip behavior, all-down modes, observability, transport-facing behavior, policy interaction, and safe cleanup, with packet-only and nondeterministic restart/recovery subclaims clearly bounded.

#### Authoritative links

*   [CoreDNS 1.13.1 forward plugin](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
*   [CoreDNS 1.13.1 forward source](https://github.com/coredns/coredns/tree/v1.13.1/plugin/forward)
*   [CoreDNS metrics](https://coredns.io/plugins/metrics/)
*   [AKS CoreDNS customization](https://learn.microsoft.com/azure/aks/coredns-custom)
*   [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
