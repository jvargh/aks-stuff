### 2\. Timeout before trying another upstream

**Question:** What is the timeout before CoreDNS tries another upstream DNS server?

#### Table of Contents

- [Introduction](#introduction)
- [Answer](#answer)
- [Theory](#theory)
  - [Transport deadlines and failover](#transport-deadlines-and-failover)
  - [Measurement and what AKS supports](#measurement-and-what-aks-supports)
- [Items to Validate](#items-to-validate)
- [Dedicated timeout validation suite](#dedicated-timeout-validation-suite)
  - [Common prerequisites](#common-prerequisites)
  - [TV-01: Verify the deployed version](#tv-01-version-verify-the-deployed-version)
  - [TV-02: Verify version-matched timeout definitions](#tv-02-definitions-verify-version-matched-timeout-definitions)
  - [TV-03: Validate silent UDP loss](#tv-03-udp-drop-validate-silent-udp-loss)
  - [TV-04: Validate TCP silent-dial behavior](#tv-04-tcp-drop-validate-tcp-silent-dial-behavior)
  - [TV-05: Compare immediate refusal with packet loss that returns no error](#tv-05-refusal-vs-drop-compare-immediate-refusal-with-packet-loss-that-returns-no-error)
  - [TV-06: Validate client deadlines](#tv-06-client-deadlines-validate-client-deadlines)
  - [TV-07: Compare the first failed query with later queries](#tv-07-health-state-compare-the-first-failed-query-with-later-queries)
  - [TV-08: Validate accumulated delays](#tv-08-multiple-failures-validate-accumulated-delays)
  - [TV-09: Distinguish DNS RCODE from transport timeout](#tv-09-rcode-distinguish-dns-rcode-from-transport-timeout)
  - [TV-10: Check how recent TCP connections change the timeout](#tv-10-tcp-connection-history-check-how-recent-tcp-connections-change-the-timeout)
  - [TV-11: Validate measurement accuracy](#tv-11-measurement-validate-measurement-accuracy)
  - [TV-12: Validate recovery](#tv-12-recovery-validate-recovery)
  - [TV-13: Validate metrics and logs](#tv-13-observability-validate-metrics-and-logs)
  - [TV-14: Validate repeated cold trials](#tv-14-repeatability-validate-repeated-cold-trials)
  - [TV-15: Validate safety and cleanup](#tv-15-safety-validate-safety-and-cleanup)
  - [TV-16: Validate read_timeout incompatibility](#tv-16-read-timeout-validate-read_timeout-incompatibility)
- [Evidence handling](#evidence-handling)
- [Limitations](#limitations)
- [Conclusion](#conclusion)
- [Authoritative links](#authoritative-links)

#### Introduction

There is no single timeout for every upstream failure. The observed delay depends on whether CoreDNS is dialing an upstream or waiting for a reply, whether the network silently drops or immediately rejects traffic, the resolver's learned health and dial state, upstream ordering, transport, and the client's own deadline.

This response separates version-matched CoreDNS behavior from AKS support policy and distinguishes static source evidence from measured `aks01day2` behavior. All 16 mapped timeout cases were executed or source-verified on 2026-09-24. All mutable tests used namespace-local lab resolvers; the managed `kube-system` CoreDNS resources were read only.

#### Answer

For CoreDNS 1.13.1, the `forward` plugin uses a fixed 2-second read timeout. When CoreDNS opens a TCP connection, an operation the CoreDNS documentation calls a **dial**, it can initially wait up to 30 seconds. CoreDNS remembers how long recent TCP connections took and can reduce that wait toward one second after several quick connections. These limits apply to each attempted upstream server, not to the client's complete DNS request.

In this document, **packet loss with no error response** means that the DNS request is sent, but the test network drops the packets and does not tell CoreDNS that anything went wrong. CoreDNS receives no reply, so it must wait for its timeout. For UDP, that wait is usually about two seconds before CoreDNS tries another server. For a new TCP connection, the wait can be much longer and can approach 30 seconds. An immediate connection refusal can move to another server without waiting for either maximum. A DNS response such as `SERVFAIL` is different because CoreDNS received a reply.

On the tested `aks01day2` cluster, silently dropped UDP traffic reached the backup DNS server after about two seconds. A silently dropped first TCP connection behaved differently: CoreDNS waited about 30 seconds and returned `SERVFAIL` instead of an IP address. After CoreDNS had recently made several fast TCP connections, it reached the backup server after about one second. These results describe this test environment and are not guaranteed production response times. CoreDNS 1.13.1 also rejected the newer `read_timeout` setting.

Validated comparison:

| Scenario | Observed result |
| --- | --- |
| First UDP query when the primary sends no reply | Secondary answer in 1,999 ms; five-repeat range 1,999-2,003 ms. |
| Two failed UDP upstream addresses | Secondary answer in 4,003 ms. |
| TCP connection refusal | Secondary answer in 3 ms. |
| First forced-TCP query when the primary sends no reply | `SERVFAIL`, no IP address, in 29,999-30,007 ms. |
| Forced-TCP query after recent fast connections | Secondary answer in 1,003 ms. |
| Queries after CoreDNS marked the primary unavailable | Secondary answers in 0-3 ms. |
| DNS `SERVFAIL` response | Returned in 3 ms by default; explicit RCODE failover returned the secondary in 0 ms. |

#### Theory

##### Transport deadlines and failover

CoreDNS 1.13.1 creates each forward proxy with a 2-second read timeout. Its transport initializes the dial estimator at 30 seconds, updates it after dial samples, and clamps the calculated timeout to the 1-to-30-second range. A useful approximation for a sequential upstream list is:

```text
resolver delay =
    sum(dial and read delay for each failed attempted upstream)
    + successful-upstream response time
```

Connection reuse, whether CoreDNS has already marked a server unavailable, recent TCP connection times, system load, client retries, and the network protocol can change the measured result.

| Outcome | Normal `forward` behavior |
| --- | --- |
| UDP request sent and response silently lost | Wait for the 2-second read deadline, then try another eligible upstream. |
| New TCP connection receives no reply | Wait for the current connection timeout, then determine whether another server can be tried. |
| Connection immediately refused | Receive a transport error and try another eligible upstream without waiting for the maximum deadline. |
| Upstream returns `SERVFAIL` or `REFUSED` | Return the DNS response unless that RCODE is listed in `failover`. |
| Upstream already marked unhealthy | Skip it while it remains down, subject to health-check and all-upstreams-down behavior. |
| Client deadline expires first | The client reports failure even if CoreDNS could later obtain an answer. |

A network error starts CoreDNS health checking. With the lab's `max_fails 1`, later queries can avoid a primary server after CoreDNS marks it unavailable. Restarting the lab resolver clears that remembered status, which is why the first failed query and later queries are measured separately.

##### Measurement and what AKS supports

DNS latency claims use `dig` `Query time`; wall-clock timing around `kubectl exec` also includes Kubernetes API, exec-stream, and process-start overhead. NetworkPolicy behavior is implementation-dependent, so every TCP test must preserve logs showing whether traffic was dropped or rejected.

CoreDNS capability does not by itself establish that a configuration is supported on managed AKS CoreDNS. The suite may read the managed image, version, availability, and resourceVersion, but it must not edit managed Deployments or ConfigMaps. Production customization must follow current Microsoft guidance for `coredns-custom`. The namespace-local lab demonstrates behavior only.

#### Items to Validate

| Item to Validate | Validation Method | Mapped TV Test Case |
| --- | --- | --- |
| Deployed CoreDNS version and image | Read the managed Deployment image and execute `coredns -version` in managed and lab pods. | `TV-01-VERSION` |
| Version-matched timeout definitions | Compare the deployed version with the tagged `forward` documentation and proxy source. | `TV-02-DEFINITIONS` |
| Silent UDP loss | Independently apply primary packet loss, restart the lab resolver, and measure the secondary answer with `dig +stats`. | `TV-03-UDP-DROP` |
| TCP silent-dial behavior | Independently force TCP, silently drop the first upstream, and use a client deadline long enough for a cold dial. | `TV-04-TCP-DROP` |
| Immediate refusal versus packet loss with no error response | Create both failure modes in one self-contained case and compare their query times and logs. | `TV-05-REFUSAL-VS-DROP` |
| Client timeout shorter than, equal to, and longer than resolver delay | Restart before each otherwise identical 1-, 2-, and 5-second client-timeout query. | `TV-06-CLIENT-DEADLINES` |
| First failed query versus later queries | Compare the first query that receives no reply with later queries after CoreDNS marks the primary unavailable. | `TV-07-HEALTH-STATE` |
| Multiple failed upstreams | Create a temporary second failed Service IP and place both failed IPs before the healthy secondary. | `TV-08-MULTIPLE-FAILURES` |
| DNS RCODE versus transport timeout | Compare immediate `SERVFAIL` behavior with and without `failover SERVFAIL`. | `TV-09-RCODE` |
| TCP connection timeout changes based on recent connections | Compare the first TCP connection failure with another failure after several quick successful TCP connections. | `TV-10-TCP-CONNECTION-HISTORY` |
| Measurement accuracy | Compare parsed `dig` `Query time` with elapsed `kubectl exec` process time. | `TV-11-MEASUREMENT` |
| Recovery | Create packet loss, establish failed health, remove the policy, and poll for the primary answer. | `TV-12-RECOVERY` |
| Metrics and logs | Capture query output, pod identity, forward metrics, and resolver logs in one fault window. | `TV-13-OBSERVABILITY` |
| Repeatability | Run five cold silent-UDP-drop trials and retain every result. | `TV-14-REPEATABILITY` |
| Safety and cleanup | Verify temporary resources are absent, the base fixture is healthy, and managed CoreDNS was not changed. | `TV-15-SAFETY` |
| `read_timeout` version incompatibility | Parse a disposable Corefile with the deployed binary without changing a running resolver. | `TV-16-READ-TIMEOUT` |

#### Dedicated timeout validation suite

##### Common prerequisites

The retained lab is described in [AKS CoreDNS Failover Validation](../AKS_CoreDNS_Failover_Validation.md) and deployed by [Deploy-CoreDNSFailoverLab.ps1](../validation/Deploy-CoreDNSFailoverLab.ps1). An operator must intentionally obtain credentials before running these proposed commands. This document was rewritten without accessing or mutating a cluster.

Run the following before each selected test case. It establishes shared variables and a clean baseline, but no case relies on another case having run:

```powershell
$ErrorActionPreference = "Stop"
$ns = "coredns-failover-validation"
$outage = ".\07-CoreDNS\validation\primary-outage-networkpolicy.yaml"
$deployLab = ".\07-CoreDNS\validation\Deploy-CoreDNSFailoverLab.ps1"

if ((kubectl config current-context) -ne "aks01day2") {
    throw "Refusing to run: expected context aks01day2."
}

kubectl delete -f $outage --ignore-not-found
kubectl delete service upstream-failed-2 -n $ns --ignore-not-found
& $deployLab
kubectl wait --for=condition=Available deployment --all -n $ns --timeout=180s

$primaryBaseline = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
if ($LASTEXITCODE -ne 0 -or $primaryBaseline -notcontains "192.0.2.10") {
    throw "Baseline failed: resolver-sequential did not return the primary answer."
}
```

Expected baseline: all six lab Deployments are available, `resolver-sequential` returns `192.0.2.10`, and the outage NetworkPolicy and `upstream-failed-2` Service are absent. Each mutating case uses `try`/`finally`, restores the reusable fixture, and changes only `$ns`.

#### TV-01-VERSION: Verify the deployed version

**Validates item:** Deployed CoreDNS version and image

**Purpose:** Establish the exact managed and lab CoreDNS versions before applying timeout expectations.

**Prerequisites:** Complete the common prerequisites. Managed CoreDNS access is read only.

**Commands:**

```powershell
$managedImage = kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.spec.template.spec.containers[0].image}"
$managedPod = kubectl get pod -n kube-system -l k8s-app=kube-dns `
    -o jsonpath="{.items[0].metadata.name}"
if (-not $managedPod) { throw "No managed CoreDNS pod found." }
$managedVersion = kubectl exec -n kube-system $managedPod -- coredns -version
$labImage = kubectl get deployment upstream-primary -n $ns `
    -o jsonpath="{.spec.template.spec.containers[0].image}"
$labVersion = kubectl exec -n $ns deployment/upstream-primary -- coredns -version

"MANAGED_IMAGE=$managedImage"
"MANAGED_VERSION=$managedVersion"
"LAB_IMAGE=$labImage"
"LAB_VERSION=$labVersion"
```

**Expected result:** The validated deployment reports CoreDNS 1.13.1 and the image tags are captured. If a different version is present, stop and use documentation and source tagged for that version.

**Pass/fail criteria:** Pass only when both binary versions and both images are nonempty and version-compatible with the expectations used by later cases.

**Evidence to capture:** Timestamp, context, pod name, both complete image references, and both raw version outputs.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24. Managed and lab images were both `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`. The managed pod was `coredns-855b679d84-jzm88`. Both binaries reported `CoreDNS-1.13.1`, `linux/amd64`, Go 1.26.5, revision `1db4568df6aaacda6ebbce87717156bd855f8103`. This satisfies the complete case.

#### TV-02-DEFINITIONS: Verify version-matched timeout definitions

**Validates item:** Version-matched timeout definitions

**Purpose:** Tie timeout values to CoreDNS 1.13.1 rather than to unversioned documentation.

**Prerequisites:** TV-01-VERSION output from the current run must identify 1.13.1. This case performs web reads and no cluster mutation.

**Commands:**

```powershell
$tag = "v1.13.1"
$readme = "https://raw.githubusercontent.com/coredns/coredns/$tag/plugin/forward/README.md"
$proxy = "https://raw.githubusercontent.com/coredns/coredns/$tag/plugin/pkg/proxy/proxy.go"
$transport = "https://raw.githubusercontent.com/coredns/coredns/$tag/plugin/pkg/proxy/persistent.go"

(Invoke-WebRequest $readme).Content |
    Select-String "dial timeout|read timeout"
(Invoke-WebRequest $proxy).Content |
    Select-String "readTimeout: 2 \* time.Second"
(Invoke-WebRequest $transport).Content |
    Select-String "minDialTimeout|maxDialTimeout|avgDialTime"
```

**Expected result:** The tagged README describes a default 30-second dial timeout that can decrease to 1 second and a static 2-second read timeout. Tagged source shows a 2-second `readTimeout` and 1- and 30-second dial bounds.

**Pass/fail criteria:** Pass when the deployed version is 1.13.1 and retained tagged documentation and source lines establish all three bounds. Untagged documentation alone fails the case.

**Evidence to capture:** Deployed version output, immutable URLs, retrieval timestamp, and complete matched lines.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 against immutable `v1.13.1` sources. The tagged forward README states that dial timeout defaults to 30 seconds and can decrease to 1 second, and read timeout is static at 2 seconds. `proxy.go` sets `readTimeout: 2 * time.Second`; `persistent.go` sets `minDialTimeout = 1 * time.Second`, `maxDialTimeout = 30 * time.Second`, and initializes `avgDialTime`. This is version-matched static source evidence, not a claim that every cluster query consumes those maxima.

#### TV-03-UDP-DROP: Validate silent UDP loss

**Validates item:** Silent UDP loss

**Purpose:** Measure what happens on the first request when the primary DNS server sends no UDP reply and the network returns no error.

**Prerequisites:** Complete the common prerequisites; verify that the NetworkPolicy implementation drops rather than rejects UDP.

**Commands:**

```powershell
try {
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s

    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +notcp +time=5 +tries=1 +comments +answer +stats
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** `NOERROR`, answer `192.0.2.20`, and `Query time` near the fixed 2-second read timeout.

**Pass/fail criteria:** Pass when the secondary answers and `Query time` is 1,500-3,000 ms. Fail on no response, a primary answer, or a time outside that band; investigate network behavior and load before interpreting a marginal result.

**Evidence to capture:** Timestamp, resolver pod UID/restart count, policy YAML, complete `dig` output, resolver logs, and post-cleanup primary answer.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24. The test network dropped UDP packets to the primary DNS server and returned no error to CoreDNS. CoreDNS waited for the missing reply, then returned `NOERROR` and the backup-server answer `192.0.2.20` in 1,999 ms. Cleanup removed the policy and restored the base fixture. This does not guarantee every UDP outage takes two seconds.

#### TV-04-TCP-DROP: Validate TCP silent-dial behavior

**Validates item:** TCP silent-dial behavior

**Purpose:** Show what happens when CoreDNS opens a new TCP connection but receives no reply and no immediate network error.

**Prerequisites:** Complete the common prerequisites. The client deadline permits a cold initial dial. Record whether the network silently drops the SYN.

**Commands:**

```powershell
$primary = kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}"
$secondary = kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}"
if (-not $primary -or -not $secondary) { throw "Required upstream Service IP is missing." }
$corefile = @"
.:53 {
    errors
    log
    ready
    health
    prometheus :9153
    forward . $primary $secondary {
        policy sequential
        force_tcp
        max_fails 1
        health_check 500ms
    }
}
"@

try {
    kubectl create configmap resolver-sequential -n $ns `
        "--from-literal=Corefile=$corefile" --dry-run=client -o yaml |
        kubectl apply -f -
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +tcp +time=40 +tries=1 +comments +answer +stats
    kubectl logs -n $ns deployment/resolver-sequential --since=2m
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** On the first TCP connection attempt after resolver restart, CoreDNS can wait close to the initial 30-second connection timeout. On the tested CoreDNS 1.13.1 path, that wait ended with `SERVFAIL` instead of an answer from the backup server. Other versions or network errors can behave differently, so retain the status, answer, timing, and logs.

**Pass/fail criteria:** Pass the characterization case when the primary failure is verified as silent TCP loss, the result is captured with its status and `Query time`, and cleanup succeeds. For this tested image, the comparison value is approximately 30 seconds with `SERVFAIL`. Do not report successful secondary failover unless an A answer is actually present.

**Evidence to capture:** Temporary Corefile, policy, full `dig` output, resolver logs, network implementation, and cleanup result.

**Established `aks01day2` evidence:** Executed on 2026-09-24 with `force_tcp`. The test network dropped traffic to the primary server and returned no immediate error. On the first query after resolver restart, CoreDNS waited 29,999 ms and returned `SERVFAIL` without an IP address. Six resolver log lines were retained. Cleanup removed the policy and restored the base fixture. This test did not show successful fallback to the backup server.

#### TV-05-REFUSAL-VS-DROP: Compare immediate refusal with packet loss that returns no error

**Validates item:** Immediate refusal versus packet loss with no error response

**Purpose:** Demonstrate in one independent case that failure mode, not only upstream order, determines failover latency.

**Prerequisites:** Complete the common prerequisites. Port 5300 in the resolver pod must be closed.

**Commands:**

```powershell
$primary = kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}"
$secondary = kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}"
$makeCorefile = {
    param([string]$first)
@"
.:53 {
    errors
    log
    ready
    health
    forward . $first $secondary {
        policy sequential
        force_tcp
        max_fails 1
        health_check 500ms
    }
}
"@
}

try {
    $refusal = & $makeCorefile "127.0.0.1:5300"
    kubectl create configmap resolver-sequential -n $ns `
        "--from-literal=Corefile=$refusal" --dry-run=client -o yaml |
        kubectl apply -f -
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    Write-Host "IMMEDIATE_REFUSAL"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=5 +tries=1 +comments +answer +stats
    kubectl logs -n $ns deployment/resolver-sequential --since=2m

    $drop = & $makeCorefile $primary
    kubectl create configmap resolver-sequential -n $ns `
        "--from-literal=Corefile=$drop" --dry-run=client -o yaml |
        kubectl apply -f -
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    Write-Host "SILENT_DROP"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=40 +tries=1 +comments +answer +stats
    kubectl logs -n $ns deployment/resolver-sequential --since=2m
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** The closed local port returns an immediate transport error and promptly reaches the secondary. The silent TCP drop is materially slower and, on the tested cold CoreDNS 1.13.1 path, returns `SERVFAIL` after approximately 30 seconds rather than reaching the secondary.

**Pass/fail criteria:** Pass when the refusal case returns the backup answer below 1,000 ms, the no-reply case is much slower, both outcomes are recorded without assuming they fail over the same way, and cleanup succeeds. Fail if port 5300 is listening or the network returns an immediate error in the no-reply test.

**Evidence to capture:** Both complete `dig` outputs, both log windows, temporary Corefiles, pod identities, and cleanup result.

**Established `aks01day2` evidence:** Executed in one run on 2026-09-24. Closed loopback port `127.0.0.1:5300` failed over to `192.0.2.20` with `NOERROR` in 3 ms. Silent primary TCP loss returned `SERVFAIL` with no A answer in 30,007 ms. The 30-second difference confirms that transport failure mode materially changes latency and outcome.

#### TV-06-CLIENT-DEADLINES: Validate client deadlines

**Validates item:** Client timeout shorter than, equal to, and longer than resolver delay

**Purpose:** Determine whether 1-, 2-, and 5-second client deadlines accommodate the approximately 2-second UDP failover path.

**Prerequisites:** Complete the common prerequisites. Every subcase starts with a fresh resolver.

**Commands:**

```powershell
try {
    kubectl apply -f $outage
    foreach ($clientTimeout in 1, 2, 5) {
        kubectl rollout restart deployment/resolver-sequential -n $ns
        kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
        Write-Host "CLIENT_TIMEOUT_SECONDS=$clientTimeout"
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A `
            "+time=$clientTimeout" +tries=1 +comments +answer +stats
        "EXIT_CODE=$LASTEXITCODE"
    }
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** One second times out. Two seconds might succeed or fail because CoreDNS itself can wait about two seconds before trying the next server. Five seconds gives CoreDNS enough time to return `192.0.2.20`.

**Pass/fail criteria:** Pass when the 1-second case fails and the 5-second case succeeds with the secondary answer. Record what happens at two seconds, but do not treat a successful result as reliable. Fail if resolver state is reused between subcases.

**Evidence to capture:** All outputs and exit codes, resolver pod identity for each restart, policy state, and cleanup result.

**Established `aks01day2` evidence:** The complete set ran on 2026-09-24 from a fresh resolver for each subcase. At 1 second, `dig` received no response and exited 9. At 2 seconds, it returned `NOERROR`, `192.0.2.20`, in 1,999 ms. At 5 seconds, it returned the same secondary answer in 2,003 ms. The 2-second test succeeded with only 1 ms to spare. A small delay could make the same setting fail, so applications should not use exactly 2 seconds as their production timeout.

#### TV-07-HEALTH-STATE: Compare the first failed query with later queries

**Validates item:** First failed query versus later queries

**Purpose:** Separate the first-request timeout cost from later routing after health detection.

**Prerequisites:** Complete the common prerequisites. Do not restart between the first and later queries.

**Commands:**

```powershell
try {
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    Write-Host "FIRST_FAILURE"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +comments +answer +stats
    Start-Sleep -Seconds 2
    1..3 | ForEach-Object {
        Write-Host "KNOWN_UNHEALTHY_TRIAL=$_"
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +comments +answer +stats
    }
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** The first query returns the secondary near two seconds; all three later queries return it without another two-second wait.

**Pass/fail criteria:** Pass when the first query is 1,500-3,000 ms and every later query is below 500 ms.

**Evidence to capture:** Four full `dig` outputs, resolver identity, health-check interval, and cleanup result.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24. During the first query, the test network dropped packets to the primary DNS server and returned no error. CoreDNS waited 2,003 ms, then returned `NOERROR` and the backup-server answer `192.0.2.20`. Without restarting CoreDNS, the next three queries went directly to the backup server in 0, 3, and 3 ms because CoreDNS had already marked the primary server unavailable. This shows why the first affected query is slower than later queries.

#### TV-08-MULTIPLE-FAILURES: Validate accumulated delays

**Validates item:** Multiple failed upstreams

**Purpose:** Show that distinct attempted upstreams can consume separate read deadlines.

**Prerequisites:** Complete the common prerequisites. The temporary alias Service must select the primary pod and expose TCP and UDP 53.

**Commands:**

```powershell
$primary = kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}"
$secondary = kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}"
try {
    kubectl create service clusterip upstream-failed-2 -n $ns `
        --tcp=53:53 --dry-run=client -o yaml |
        kubectl set selector -f - "app.kubernetes.io/name=upstream-primary" --local -o yaml |
        kubectl apply -f -
    kubectl patch service upstream-failed-2 -n $ns --type=json `
        -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"dns-udp","port":53,"protocol":"UDP","targetPort":53}}]'
    $failed2 = kubectl get service upstream-failed-2 -n $ns -o jsonpath="{.spec.clusterIP}"
    if (-not $failed2) { throw "Alias Service has no cluster IP." }
$corefile = @"
.:53 {
    errors
    log
    ready
    health
    forward . $primary $failed2 $secondary {
        policy sequential
        max_fails 1
        health_check 500ms
    }
}
"@
    kubectl create configmap resolver-sequential -n $ns `
        "--from-literal=Corefile=$corefile" --dry-run=client -o yaml |
        kubectl apply -f -
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +notcp +time=8 +tries=1 +comments +answer +stats
}
finally {
    kubectl delete -f $outage --ignore-not-found
    kubectl delete service upstream-failed-2 -n $ns --ignore-not-found
    & $deployLab
}
```

**Expected result:** The healthy secondary returns `192.0.2.20` after approximately two 2-second read deadlines.

**Pass/fail criteria:** Pass when the answer is `192.0.2.20`, `Query time` is 3,500-5,500 ms, and the temporary Service is absent afterward.

**Evidence to capture:** Service YAML/endpoints, temporary Corefile, full `dig` output, policy behavior, and resource-absence checks.

**Established `aks01day2` evidence:** Executed on 2026-09-24. The primary Service IP and a distinct alias Service IP both selected the silently dropped primary pod before the healthy secondary. The alias was `10.0.108.168`. The query returned `NOERROR` and `192.0.2.20` in 4,003 ms, consistent with two separate 2-second read deadlines. The alias Service and outage policy were removed and the base fixture restored.

#### TV-09-RCODE: Distinguish DNS RCODE from transport timeout

**Validates item:** DNS RCODE versus transport timeout

**Purpose:** Demonstrate that an immediate `SERVFAIL` response is not a read timeout.

**Prerequisites:** Complete the common prerequisites. Verify the fixture's primary returns `SERVFAIL` for `rcode.validation.test`.

**Commands:**

```powershell
kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential rcode.validation.test A +time=5 +tries=1 +comments +answer +stats
$defaultExit = $LASTEXITCODE
kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-rcode-failover rcode.validation.test A +time=5 +tries=1 +comments +answer +stats
$failoverExit = $LASTEXITCODE
"DEFAULT_EXIT=$defaultExit"
"FAILOVER_EXIT=$failoverExit"
```

**Expected result:** The default resolver promptly returns `SERVFAIL` without an A record. The explicit-failover resolver promptly returns `NOERROR` and `192.0.2.20`. Neither waits near two seconds.

**Pass/fail criteria:** Pass when status, answer, and low `Query time` show that both DNS-response paths are much faster than waiting for a server that sends no reply.

**Evidence to capture:** Both complete outputs, exit codes, relevant Corefiles, and query timestamp.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 after restarting both resolvers. The default sequential resolver returned `SERVFAIL`, no A answer, in 3 ms. The resolver configured with `failover SERVFAIL` returned `NOERROR` and `192.0.2.20` in 0 ms. Both are DNS-response paths, not read-timeout behavior.

#### TV-10-TCP-CONNECTION-HISTORY: Check how recent TCP connections change the timeout

**Validates item:** TCP connection timeout changes based on recent connections

**Purpose:** Compare cold and warmed silent TCP dial failures without relying on another case.

**Prerequisites:** Complete the common prerequisites. The network must silently drop TCP, and each phase uses fresh connections via `expire 1ms`.

**Commands:**

```powershell
$primary = kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}"
$secondary = kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}"
$corefile = @"
.:53 {
    errors
    log
    ready
    health
    forward . $primary $secondary {
        policy sequential
        force_tcp
        expire 1ms
        max_fails 1
        health_check 500ms
    }
}
"@
try {
    kubectl create configmap resolver-sequential -n $ns `
        "--from-literal=Corefile=$corefile" --dry-run=client -o yaml |
        kubectl apply -f -

    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    Write-Host "COLD_DIAL"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=40 +tries=1 +comments +answer +stats

    kubectl delete -f $outage --ignore-not-found
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    1..20 | ForEach-Object {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +tcp +time=5 +tries=1 +short
        if ($LASTEXITCODE -ne 0) { throw "Warm-up dial $_ failed." }
        Start-Sleep -Milliseconds 20
    }
    kubectl apply -f $outage
    Write-Host "WARMED_DIAL"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=40 +tries=1 +comments +answer +stats
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** On the first silent TCP connection failure, CoreDNS can wait close to 30 seconds and then return `SERVFAIL`. After CoreDNS has recently made several fast TCP connections, it remembers those connection times and can reduce the wait to about one second, allowing the secondary server to answer.

**Pass/fail criteria:** Pass when both failures are verified as silent TCP drops, the warmed query is materially faster than the cold query, both status/answer outcomes are retained, and cleanup succeeds. Do not require exactly one or 30 seconds or require the cold query to reach the secondary.

**Evidence to capture:** Both raw outputs, 20 warm-up outcomes, logs, Corefile, network behavior, and cleanup result.

**Established `aks01day2` evidence:** Executed on 2026-09-24 with `force_tcp` and `expire 1ms`. On the first TCP connection failure after resolver restart, CoreDNS waited 30,003 ms and returned `SERVFAIL` without an IP address. The test then made 20 quick successful TCP connections. On the next connection failure, CoreDNS waited only 1,003 ms before returning `NOERROR` and the backup-server answer `192.0.2.20`. This shows that CoreDNS changes its TCP connection timeout using recent connection times. It does not guarantee the same timing in production.

#### TV-11-MEASUREMENT: Validate measurement accuracy

**Validates item:** Measurement accuracy

**Purpose:** Ensure DNS latency claims use the DNS client's metric rather than Kubernetes command overhead.

**Prerequisites:** Complete the common prerequisites; no fault is required.

**Commands:**

```powershell
$output = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +comments +answer +stats
$joined = $output -join "`n"
$match = [regex]::Match($joined, "Query time:\s+(\d+)\s+msec")
if (-not $match.Success) { throw "dig Query time was not found." }
$queryMs = [int]$match.Groups[1].Value
$processMs = (Measure-Command {
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats | Out-Null
}).TotalMilliseconds
$output
"DIG_QUERY_TIME_MS=$queryMs"
"KUBECTL_PROCESS_TIME_MS=$([math]::Round($processMs))"
```

**Expected result:** Both values are present, and the full `kubectl exec` command usually takes much longer than the DNS lookup itself. A `dig` value of `0 ms` means the lookup completed in less than one millisecond at the precision `dig` displays; it does not mean that the lookup took no time. Only `DIG_QUERY_TIME_MS` should be used when reporting DNS response time.

**Pass/fail criteria:** Pass when the DNS time is read from the `Query time` line and the document does not report the full `kubectl exec` duration as DNS latency. The two commands issue separate DNS queries, so use them to demonstrate command overhead; do not subtract one value from the other as if they measured the same request.

**Evidence to capture:** Complete `dig` output and both labeled measurements.

**Established `aks01day2` evidence:** Two runs showed the same result. In the first run, `dig` reported 3 ms while the full `kubectl exec` command took 5,480 ms. In the human repeat run, `dig` reported 0 ms, meaning less than one millisecond at its displayed precision, while the full command took 2,748 ms. The commands issued separate DNS queries, so the exact values should not be subtracted. Both runs confirm that Kubernetes API communication, starting the exec session, and starting the process add seconds that are not part of DNS response time.

#### TV-12-RECOVERY: Validate recovery

**Validates item:** Recovery

**Purpose:** Confirm that removing the fault allows the primary to re-enter service without a resolver restart.

**Prerequisites:** Complete the common prerequisites.

**Commands:**

```powershell
try {
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
    Start-Sleep -Seconds 2
    kubectl delete -f $outage --ignore-not-found

    $recovery = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $answer = kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
        if ($answer -contains "192.0.2.10") { break }
        Start-Sleep -Milliseconds 250
    } while ($recovery.Elapsed.TotalSeconds -lt 10)
    $recovery.Stop()
    "RECOVERY_MS=$($recovery.ElapsedMilliseconds)"
    $answer
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** The primary answer `192.0.2.10` returns within 10 seconds.

**Pass/fail criteria:** Pass when the primary returns within 10 seconds and the outage policy is absent afterward.

**Evidence to capture:** Initial secondary answer, recovery duration, final primary answer, resource absence, and cleanup result. Disclose that repeated `kubectl exec` overhead is included in the recovery stopwatch.

**Established `aks01day2` evidence:** The human rerun first confirmed the outage by returning backup-server answer `192.0.2.20`. After the policy was removed, the first recovery check returned primary answer `192.0.2.10` and the stopwatch reported 2,843 ms. Earlier runs reported 3,645 ms and 5,401 ms. All three results satisfy the 10-second pass criterion. The stopwatch includes the time required to open and run `kubectl exec`, so CoreDNS may have detected recovery earlier than the displayed value. The variation between runs is expected and these measurements do not define a guaranteed recovery time.

#### TV-13-OBSERVABILITY: Validate metrics and logs

**Validates item:** Metrics and logs

**Purpose:** Confirm that the DNS result, CoreDNS metrics, and CoreDNS log all describe the same failed-primary and successful-backup query.

**Prerequisites:** Complete the common prerequisites. Collect the metrics and logs from the same CoreDNS pod that handled the query.

**Commands:**

```powershell
try {
    kubectl apply -f $outage
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl get pod -n $ns -l app.kubernetes.io/name=resolver-sequential `
        -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[0].restartCount
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +comments +answer +stats
    Start-Sleep -Seconds 2
    $metricsPath = "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
    kubectl get --raw $metricsPath |
        Select-String "coredns_proxy_healthcheck_failures_total|coredns_proxy_request_duration_seconds"
    kubectl logs -n $ns deployment/resolver-sequential --since=5m
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
```

**Expected result:** `dig` returns `NOERROR` and backup-server answer `192.0.2.20` after about two seconds. The health-check failure counter for the primary server is greater than zero. The request counter for the backup server is at least one. The CoreDNS log contains the same query and shows a total duration near the `dig` time.

**Pass/fail criteria:** Pass when the query output, pod identity, nonzero primary health-check failure counter, backup-server request metric, and matching CoreDNS log are captured from the same pod. The exact health-check failure count can vary because CoreDNS continues checking the unavailable server until it responds again or the test ends.

**Evidence to capture:** Timestamp, pod name, UID, restart count, complete `dig` output, primary health-check failure counter, backup-server request count and processing time, matching CoreDNS log, and cleanup result.

**Established `aks01day2` evidence:** The human rerun used pod `resolver-sequential-8454f7bdff-gc6r7`, UID `65455693-d19d-4dac-a1d6-df0cb70b0364`, restart count 0. `dig` returned `NOERROR` and backup-server answer `192.0.2.20` in 2,003 ms. The primary-server health-check failure counter was 2. The backup-server request count was 1, and CoreDNS spent about 0.725 ms processing that backup-server request. The CoreDNS log recorded the same query with a total duration of 2.00225682 seconds. This matches the expected sequence: CoreDNS waited about two seconds for the primary server, then the backup server answered in less than one millisecond. An earlier run recorded 3 health-check failures instead of 2; the difference is expected because the counter depends on when metrics are read. Cleanup removed the policy and restored the base fixture.

#### TV-14-REPEATABILITY: Validate repeated cold trials

**Validates item:** Repeatability

**Purpose:** Determine whether cold silent-UDP-loss behavior repeats across five independent resolver processes.

**Prerequisites:** Complete the common prerequisites. Preserve every trial, including outliers.

**Commands:**

```powershell
$samples = @()
try {
    kubectl apply -f $outage
    1..5 | ForEach-Object {
        kubectl rollout restart deployment/resolver-sequential -n $ns | Out-Null
        kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s | Out-Null
        $text = kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +notcp +time=5 +tries=1 +comments +answer +stats
        $joined = $text -join "`n"
        $samples += [pscustomobject]@{
            Trial = $_
            Status = [regex]::Match($joined, "status:\s+([A-Z]+)").Groups[1].Value
            Answer = [regex]::Match($joined, "\sIN\s+A\s+([0-9.]+)").Groups[1].Value
            QueryMs = [int]([regex]::Match($joined, "Query time:\s+(\d+)\s+msec").Groups[1].Value)
            ExitCode = $LASTEXITCODE
        }
    }
}
finally {
    kubectl delete -f $outage --ignore-not-found
    & $deployLab
}
$samples | Format-Table -AutoSize
```

**Expected result:** All five trials return `NOERROR`, `192.0.2.20`, and a `QueryMs` value from 1,500 through 3,000.

**Pass/fail criteria:** Pass only when every trial meets all three assertions. Do not discard outliers.

**Evidence to capture:** Per-trial table, raw output for any failure or outlier, resolver identities, and cleanup result.

**Established `aks01day2` evidence:** Executed on 2026-09-24 across five fresh resolver processes. All five trials returned exit 0, `NOERROR`, and `192.0.2.20`. Query times were 2,003, 2,003, 2,003, 2,003, and 1,999 ms. No trial was discarded, and cleanup restored the base fixture.

#### TV-15-SAFETY: Validate safety and cleanup

**Validates item:** Safety and cleanup

**Purpose:** Prove that timeout testing leaves no fault or extension, restores the fixture, and does not change managed AKS DNS.

**Prerequisites:** Capture the managed CoreDNS ConfigMap resourceVersion before any selected mutating case. Run these checks after that case.

**Commands:**

```powershell
# Capture before a mutating case:
$managedBefore = kubectl get configmap coredns -n kube-system -o jsonpath="{.metadata.resourceVersion}"

# Run the selected namespace-local case, then:
kubectl delete -f $outage --ignore-not-found
kubectl delete networkpolicy simulate-secondary-dns-packet-loss `
    timeout-all-upstreams -n $ns --ignore-not-found
kubectl delete service upstream-failed-2 -n $ns --ignore-not-found
& $deployLab
kubectl wait --for=condition=Available deployment --all -n $ns --timeout=180s

$policies = kubectl get networkpolicy -n $ns -o name
$alias = kubectl get service upstream-failed-2 -n $ns --ignore-not-found -o name
$answer = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=120s
$managedAfter = kubectl get configmap coredns -n kube-system -o jsonpath="{.metadata.resourceVersion}"

"FAULT_POLICIES=$($policies -join ',')"
"ALIAS_SERVICE=$alias"
"PRIMARY_ANSWER=$answer"
"MANAGED_RESOURCE_VERSION_BEFORE=$managedBefore"
"MANAGED_RESOURCE_VERSION_AFTER=$managedAfter"
```

**Expected result:** `FAULT_POLICIES=` and `ALIAS_SERVICE=` have nothing after the equals sign, which means no test fault or temporary alias Service remains. All six lab Deployments and managed CoreDNS are available, the primary answer is `192.0.2.10`, and the managed resourceVersion is unchanged.

**Pass/fail criteria:** Pass only when all cleanup and noninterference assertions hold. If cleanup fails, stop and remove the named namespace-scoped resources before further testing.

**Evidence to capture:** Before/after resourceVersions, absence outputs, Deployment status, final answer, context, and timestamp.

**Established `aks01day2` evidence:** Kubernetes reported all six base Deployments as Available. `FAULT_POLICIES=` was empty, proving that no test NetworkPolicy remained. `ALIAS_SERVICE=` was empty, proving that `upstream-failed-2` had been removed. `PRIMARY_ANSWER=192.0.2.10` confirmed that the sequential resolver was using the primary server again. Managed CoreDNS was Available. The managed Corefile ConfigMap resourceVersion was `22591546` before and after cleanup, confirming that this test did not change it. TV-15 passed.

#### TV-16-READ-TIMEOUT: Validate `read_timeout` incompatibility

**Validates item:** `read_timeout` version incompatibility

**Purpose:** Confirm whether the deployed parser accepts `read_timeout` without changing a ConfigMap or running resolver.

**Prerequisites:** Complete the common prerequisites and retain TV-01-VERSION output. Port 1053 is used only by a short-lived second process.

**Commands:**

```powershell
$probe = @"
.:1053 {
    forward . 192.0.2.1 {
        read_timeout 3s
    }
}
"@
$probe | kubectl exec -i -n $ns deployment/resolver-sequential -- `
    coredns -conf /dev/stdin
$exitCode = $LASTEXITCODE
"EXIT_CODE=$exitCode"
if ($exitCode -eq 0) {
    throw "The deployed parser accepted read_timeout; use its version-matched documentation."
}
```

**Expected result:** CoreDNS 1.13.1 exits nonzero and reports `unknown property 'read_timeout'`. The configured server process remains running.

**Pass/fail criteria:** Pass for 1.13.1 when the property is rejected, the exit code is nonzero, and no ConfigMap or Deployment changes. For a newer version that accepts it, mark this version-specific expectation not applicable and design a separate configured-value test.

**Evidence to capture:** TV-01 version, complete parser output, exit code, and before/after resolver readiness.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24. The disposable parser process exited 1 and reported `/dev/stdin:3 - Error during parsing: unknown property 'read_timeout'`. The running resolver had one Available replica before and after the probe, and no ConfigMap or Deployment was changed.

#### Evidence handling

*   Store raw command output with UTC timestamp, cluster/context, resolver pod name and UID, restart count, CoreDNS images/versions, test ID, and cleanup result.
*   Preserve raw `dig` output and failed/outlier samples; do not retain only a prose summary.
*   Label any future unexecuted command as **proposed**. Promote it to **established** only after the stated pass criteria and cleanup checks are evidenced.
*   Keep static source evidence distinct from cluster observations and distinguish partial established evidence from a fully passed case.
*   Redact subscription IDs, credentials, private production addresses, and personal data. The documentation-only addresses `192.0.2.10` and `192.0.2.20` are reserved examples.
*   The original run is [aks01day2-20260923-232149.md](../validation/results/aks01day2-20260923-232149.md). The complete timeout-suite rerun is [aks01day2-timeout-20260924.md](../validation/results/aks01day2-timeout-20260924.md).

#### Limitations

1.  The 1,999 ms result covers one controlled silent-UDP-loss path, not every outage or transport.
2.  A 2-second client timeout has no useful safety margin around a 2-second resolver read deadline.
3.  Multiple attempted upstreams can consume multiple per-upstream deadlines.
4.  CoreDNS remembers recent TCP connection times only inside the running process. Restarting CoreDNS clears that history. Therefore, 30 seconds is an initial maximum, not a fixed delay for every TCP failure.
5.  NetworkPolicy can drop or reject differently across network implementations; TCP cases require failure-mode evidence.
6.  `dig` `Query time` includes the client-pod network path but excludes `kubectl exec` startup.
7.  Recovery timing measured by repeated `kubectl exec` includes API and process overhead.
8.  Namespace-local behavior does not authorize editing managed AKS CoreDNS or predict an application's resolver retries and total request deadline.

#### Conclusion

For CoreDNS 1.13.1, CoreDNS waits up to two seconds for a reply from each upstream server. Opening a TCP connection can take between one and 30 seconds, depending on recent connection history. On `aks01day2`, silent UDP loss failed over in about two seconds, two failed UDP addresses took about four seconds, immediate TCP refusal failed over in 3 ms, the first silent TCP failure returned `SERVFAIL` after about 30 seconds, and later silent TCP failure reached the backup server in about one second after CoreDNS had learned from recent fast connections. Applications should choose a timeout that covers the failure they need to survive instead of assuming that two seconds is always enough.

#### Authoritative links

*   [CoreDNS 1.13.1 `forward` plugin](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
*   [CoreDNS 1.13.1 proxy implementation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/proxy.go)
*   [CoreDNS 1.13.1 source code that adjusts TCP connection timeout](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/connect.go)
*   [CoreDNS 1.13.1 transport timeout bounds](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/persistent.go)
*   [CoreDNS 1.13.1 `forward` parser](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/setup.go)
*   [Customize CoreDNS for AKS](https://learn.microsoft.com/azure/aks/coredns-custom)
*   [Troubleshoot CoreDNS on AKS](https://learn.microsoft.com/azure/aks/coredns-troubleshoot)
*   [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   [Debugging DNS resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
*   [Lab manifest](../validation/coredns-failover-lab.yaml)
*   [Primary outage policy](../validation/primary-outage-networkpolicy.yaml)
