### 3\. Failover mechanism

**Question:** What happens, and what is the failover mechanism, when an upstream DNS server becomes unavailable?

#### Table of Contents

*   [Introduction](#introduction)
*   [Answer](#answer)
*   [Theory](#theory)
*   [Items to Validate](#items-to-validate)
*   [Dedicated failover validation suite](#dedicated-failover-validation-suite)
    *   [FM-01: Version, fixture, and direct upstreams](#fm-01-baseline-version-fixture-and-direct-upstreams)
    *   [FM-02: Sequential primary preference](#fm-02-sequential-sequential-primary-preference)
    *   [FM-03: Primary UDP server sends no reply](#fm-03-udp-drop-primary-udp-server-sends-no-reply)
    *   [FM-04: Primary TCP connection receives no reply](#fm-04-tcp-drop-primary-tcp-connection-receives-no-reply)
    *   [FM-05: TCP connection refusal](#fm-05-refusal-tcp-connection-refusal)
    *   [FM-06: RCODE response versus explicit failover](#fm-06-rcode-rcode-response-versus-explicit-failover)
    *   [FM-07: `max_fails` and learned health](#fm-07-health-learning-max_fails-and-learned-health)
    *   [FM-08: Recovery and primary re-entry](#fm-08-recovery-recovery-and-primary-re-entry)
    *   [FM-09: Policy interaction](#fm-09-policy-policy-interaction)
    *   [FM-10: All upstreams unhealthy](#fm-10-all-unhealthy-all-upstreams-unhealthy)
    *   [FM-11: Client deadline and retry budget](#fm-11-client-budget-client-deadline-and-retry-budget)
    *   [FM-12: Metrics and logs](#fm-12-observability-metrics-and-logs)
    *   [FM-13: AKS support boundary and noninterference](#fm-13-aks-boundary-aks-support-boundary-and-noninterference)
    *   [FM-14: Cleanup and final health](#fm-14-cleanup-cleanup-and-final-health)
*   [Evidence handling](#evidence-handling)
*   [Limitations](#limitations)
*   [Conclusion](#conclusion)
*   [Authoritative links](#authoritative-links)

#### Introduction

CoreDNS `forward` treats a transport exchange error differently from a DNS response. A transport error can make the active request try another eligible upstream and also starts in-band health checking. A DNS RCODE such as `SERVFAIL`, `REFUSED`, or `NXDOMAIN` is a completed exchange and is returned by default; the optional `failover` directive can instead retry selected RCODEs. This distinction determines whether an AKS workload sees a delayed answer, an error, or a client-side timeout.

The evidence below was measured on `aks01day2` with the AKS and isolated lab image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`, whose binary reports CoreDNS 1.13.1. Testing used only the disposable namespace `coredns-failover-validation-fm`; it never changed `kube-system`. The retained result is [aks01day2-failover-20260924.md](../validation/results/aks01day2-failover-20260924.md).

#### Answer

When a selected upstream exchange fails, CoreDNS 1.13.1's `forward` plugin can try another available upstream in the same request, while an in-band health-check loop begins for the failed endpoint. With `policy sequential`, the first healthy configured endpoint is preferred, so a learned-unhealthy primary is omitted and the secondary is selected. A successful health check makes the primary eligible again.

The result depends on how the server or network fails. In this cluster, when the test network blocked UDP replies from the primary server without returning an error, CoreDNS waited about two seconds and then used the backup server. A closed TCP port failed immediately and returned the backup answer with 0 ms of displayed DNS query time. When the first TCP connection received no reply, CoreDNS waited 30 seconds and returned `SERVFAIL` without a backup answer. Therefore, having a backup server does not guarantee that every failed request succeeds.

Valid DNS responses do not mark an endpoint transport-unhealthy. Without `failover`, the tested resolver returned `SERVFAIL`, `REFUSED`, and `NXDOMAIN` from the primary. With `failover SERVFAIL REFUSED NXDOMAIN`, each query continued to the secondary and returned `NOERROR` with `192.0.2.20`.

If every endpoint is unhealthy, default `forward` behavior still selects an unhealthy endpoint at random. `failfast_all_unhealthy_upstreams` instead immediately returns `SERVFAIL`. `max_fails 0` disables health-based removal, but exchange-error fallback can still occur. These are CoreDNS behaviors, not AKS availability guarantees.

#### Theory

##### Exchange loop and health state

The version-matched [`forward` documentation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md) states that the plugin reuses sockets, supports UDP and TCP, and performs in-band health checks after errors. By default, a health check runs every 0.5 seconds and recursively queries `. IN NS`. Any DNS response shows transport health, even an error RCODE; exchange failures are what increment health-check failures. `max_fails` controls how many failed health checks mark an upstream unhealthy, not how many client queries may fail.

The source for the tested release shows the active proxy loop and optional RCODE retry in [`plugin/forward/forward.go`](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/forward.go). The same release documents a fixed two-second reply timeout and a TCP connection timeout that starts at 30 seconds and can decrease to one second after recent fast connections. This explains why a missing UDP reply, an immediate TCP refusal, and a TCP connection that receives no reply have different outcomes.

##### Selection, all-unhealthy behavior, and recovery

`sequential` starts with the first healthy configured upstream, `round_robin` rotates through healthy upstreams, and the default `random` policy chooses a healthy upstream randomly. Policy determines the starting candidate; it does not turn an RCODE into a transport failure.

When no endpoint is healthy, default behavior randomly selects an unhealthy endpoint and increments `coredns_forward_healthcheck_broken_total`. `failfast_all_unhealthy_upstreams` returns `SERVFAIL` without a new proxy request. Recovery is automatic because successful in-band checks clear the unhealthy state.

##### Protocol fallback is different

`force_tcp` makes upstream exchanges use TCP. `prefer_udp` first tries UDP upstream for an incoming TCP request, and a truncated UDP response may lead to TCP. That UDP-to-TCP transition is protocol fallback, not failover to a different upstream.

##### AKS support boundary

The isolated suite proves behavior of the recorded CoreDNS image and configuration. It does not authorize replacement of the AKS-managed root forwarder. Microsoft documents supported AKS customization through the `coredns-custom` ConfigMap, with `.server` or `.override` keys and a documented CoreDNS rollout. The managed Corefile remained read-only throughout this validation.

#### Items to Validate

| Item to Validate | Validation Method | Mapped FM Test Case |
| --- | --- | --- |
| Version, fixture health, and direct upstream identity | Record image/binary, availability, managed resourceVersion, and direct answers. | `FM-01-BASELINE` |
| Sequential primary preference | Sample the healthy sequential resolver and count distinct answers. | `FM-02-SEQUENTIAL` |
| Fallback when the primary UDP server sends no reply | Block replies from the primary server without returning an error, then measure one uncached UDP query. | `FM-03-UDP-DROP` |
| Result when the first TCP connection receives no reply | Force TCP, block traffic to the primary without returning an error, and record exactly what the client receives. | `FM-04-TCP-DROP` |
| TCP connection-refusal fallback | Use a closed primary pod port, prove refusal directly, and query through the resolver. | `FM-05-REFUSAL` |
| Default and explicit RCODE failover | Compare three RCODEs with and without `failover`. | `FM-06-RCODE` |
| `max_fails` and learned health | Compare first/subsequent timings for `max_fails 1` and repeated timings for `max_fails 0`. | `FM-07-HEALTH-LEARNING` |
| Recovery and re-entry | Restore connectivity and poll until sequential selection returns the primary. | `FM-08-RECOVERY` |
| Policy interaction | Sample `sequential`, `round_robin`, and `random` while healthy and degraded. | `FM-09-POLICY` |
| All-upstreams-unhealthy behavior | Compare default spray metrics and responses with fail-fast request-counter deltas. | `FM-10-ALL-UNHEALTHY` |
| Client deadline and retry interaction | Compare one-second single/retried attempts with a longer fresh attempt. | `FM-11-CLIENT-BUDGET` |
| Metrics and logs | Capture proxy counters, health failures, all-unhealthy counters, and timestamped logs. | `FM-12-OBSERVABILITY` |
| AKS managed-resource noninterference | Compare managed resourceVersion and availability before/after namespace-local tests. | `FM-13-AKS-BOUNDARY` |
| Cleanup and retained-lab health | Delete the disposable namespace, then query and inspect the retained lab and managed CoreDNS. | `FM-14-CLEANUP` |

#### Dedicated failover validation suite

##### Common prerequisites

Run from the repository root in PowerShell. The setup reads the checked-in lab, changes only Kubernetes `metadata.name`/`metadata.namespace` values equal to the original namespace in memory, and submits the resulting stream. Resolver targets are then rebuilt from the new namespace's dynamic Service IPs.

```powershell
$ErrorActionPreference = "Stop"
$ns = "coredns-failover-validation-fm"
$manifest = ".\07-CoreDNS\validation\coredns-failover-lab.yaml"
if ((kubectl config current-context) -ne "aks01day2") { throw "Wrong context." }

function Invoke-Kubectl {
    param([string[]]$Arguments)
    $output = & kubectl @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $output }
    $output.Trim()
}

function Set-FmResolver {
    param(
        [ValidateSet("resolver-sequential","resolver-round-robin","resolver-rcode-failover")]
        [string]$Name,
        [ValidateSet("sequential","round_robin","random")]
        [string]$Policy = "sequential",
        [int]$MaxFails = 1,
        [string[]]$Extra = @(),
        [string[]]$Targets = @()
    )
    if ($Targets.Count -eq 0) {
        $primary = Invoke-Kubectl @("get","service","upstream-primary","-n",$ns,"-o","jsonpath={.spec.clusterIP}")
        $secondary = Invoke-Kubectl @("get","service","upstream-secondary","-n",$ns,"-o","jsonpath={.spec.clusterIP}")
        if (-not $primary -or -not $secondary) { throw "Missing dynamic Service IP." }
        $Targets = @("${primary}:53", "${secondary}:53")
    }
    $options = @(
        "        policy $Policy"
        "        max_fails $MaxFails"
        "        health_check 500ms"
    ) + ($Extra | ForEach-Object { "        $_" })
    $corefile = @"
.:53 {
    errors
    log
    ready
    health
    prometheus :9153
    forward . $($Targets -join " ") {
$($options -join "`n")
    }
}
"@
    kubectl create configmap $Name -n $ns "--from-literal=Corefile=$corefile" `
        --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "ConfigMap update failed." }
    Invoke-Kubectl @("rollout","restart","deployment/$Name","-n",$ns) | Out-Null
    Invoke-Kubectl @("rollout","status","deployment/$Name","-n",$ns,"--timeout=180s") | Out-Null
}

function Set-FmDropPolicy {
    param([switch]$All)
    $name = if ($All) { "fm-all-drop" } else { "fm-primary-drop" }
    $values = if ($All) { "[upstream-primary, upstream-secondary]" } else { "[upstream-primary]" }
    @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $name
  namespace: $ns
spec:
  podSelector:
    matchExpressions:
    - key: app.kubernetes.io/name
      operator: In
      values: $values
  policyTypes: [Ingress]
  ingress: []
"@ | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Fault policy creation failed." }
}

function Remove-FmFaults {
    kubectl delete networkpolicy fm-primary-drop fm-all-drop -n $ns --ignore-not-found | Out-Null
}

kubectl delete namespace $ns --ignore-not-found --wait=true | Out-Null
$source = Get-Content $manifest -Raw
$isolated = [regex]::Replace(
    $source,
    "(?m)^(\s*(?:name|namespace):\s*)coredns-failover-validation\s*$",
    ('${1}' + $ns)
)
$isolated | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Isolated fixture deployment failed." }
Invoke-Kubectl @("wait","--for=condition=Available","deployment","--all","-n",$ns,"--timeout=240s") | Out-Null
Set-FmResolver -Name resolver-sequential
Set-FmResolver -Name resolver-round-robin -Policy round_robin
Set-FmResolver -Name resolver-rcode-failover
$managedBefore = Invoke-Kubectl @(
    "get","configmap","coredns","-n","kube-system",
    "-o","jsonpath={.metadata.resourceVersion}"
)
```

#### FM-01-BASELINE: Version, fixture, and direct upstreams

**Validates item:** Version, fixture health, and direct upstream identity

**Purpose:** Establish the exact binary, healthy starting state, distinct answers, and managed CoreDNS baseline.

**Prerequisites:** Common prerequisites completed; no fault policy exists.

**Commands:**

```powershell
Remove-FmFaults
kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.spec.template.spec.containers[0].image}{'\n'}"
kubectl exec -n $ns deployment/resolver-sequential -- coredns -version
kubectl get deployment -n $ns
kubectl exec -n $ns deployment/dns-client -- dig @upstream-primary answer.validation.test A +short
kubectl exec -n $ns deployment/dns-client -- dig @upstream-secondary answer.validation.test A +short
"ManagedResourceVersionBefore=$managedBefore"
```

**Expected result:** Six Deployments are Available; upstreams answer `192.0.2.10` and `192.0.2.20`; image and binary are recorded.

**Pass/fail criteria:** All baseline reads and direct queries succeed with the exact distinct answers.

**Evidence to capture:** Image, binary output, Deployment availability, direct answers, and managed resourceVersion.

**Established `aks01day2` evidence:** On 2026-09-24, all six Deployments were Available. Managed and lab images were `v1.13.1-20`; the lab binary reported CoreDNS 1.13.1, Go 1.26.5, revision `1db4568df6aaacda6ebbce87717156bd855f8103`. Direct answers were `192.0.2.10` and `192.0.2.20`. PASS.

#### FM-02-SEQUENTIAL: Sequential primary preference

**Validates item:** Sequential primary preference

**Purpose:** Prove deterministic first-upstream selection while both upstreams are healthy.

**Prerequisites:** Healthy direct baseline.

**Commands:**

```powershell
try {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
    1..8 | ForEach-Object {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +short
    }
}
finally {
    Remove-FmFaults
}
```

**Expected result:** All eight queries return `192.0.2.10`, the answer configured on the first upstream server. No query returns the backup-server answer `192.0.2.20`.

**Pass/fail criteria:** Pass when exactly eight answers are returned, all eight equal `192.0.2.10`, and no timeout or other address appears.

**Evidence to capture:** Output from `Set-FmResolver`, the ordered list of all eight answers, the resolver Corefile, and final fault-policy absence.

**Established `aks01day2` evidence:** The test began by calling `Remove-FmFaults`, so no simulated DNS failure was active. `Set-FmResolver -Name resolver-sequential` reported `configmap/resolver-sequential unchanged`, confirming that the resolver already had the expected sequential configuration and did not require a configuration update. All eight queries completed successfully. The ordered results were `192.0.2.10` eight times, with no `192.0.2.20`, timeout, or unexpected answer. This proves that while both upstream servers are healthy, the sequential policy consistently chooses the first configured server. It does not test failure behavior; that is covered by FM-03 and later cases. The `finally` block removed any test fault again. FM-02 passed.

#### FM-03-UDP-DROP: Primary UDP server sends no reply

**Validates item:** Fallback when the primary UDP server sends no reply

**Purpose:** Confirm what the client receives when the primary DNS server does not reply to a UDP query and the network returns no immediate error.

**Prerequisites:** NetworkPolicy enforcement and healthy direct upstreams.

**Commands:**

```powershell
try {
    Remove-FmFaults
    Set-FmDropPolicy
    Set-FmResolver -Name resolver-sequential
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +notcp +time=5 +tries=1 +stats
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** CoreDNS waits about two seconds for the primary server. When no reply arrives, it sends the same request to the backup server and returns `NOERROR` with `192.0.2.20`.

**Pass/fail criteria:** Pass when one client query returns `NOERROR`, answer `192.0.2.20`, and a query time between 1,500 and 3,500 ms. This proves that the backup answer was returned without requiring the client to send another query.

**Evidence to capture:** The created NetworkPolicy, resolver configuration status, complete `dig` output, response code, returned IP address, query time, and cleanup output.

**Established `aks01day2` evidence:** The test first removed old fault settings, then created NetworkPolicy `fm-primary-drop`, which blocked traffic to the primary DNS pod without returning an immediate error. The sequential resolver ConfigMap was already correct and reported `unchanged`. A single UDP query was sent with `+notcp`. CoreDNS returned `NOERROR` and backup-server answer `192.0.2.20` in 2,004 ms. The DNS client sent only one query; CoreDNS performed the fallback internally after the primary did not reply. The result falls inside the 1,500-3,500 ms pass range. The `finally` block removed the fault policy and restored the sequential resolver. FM-03 passed.

#### FM-04-TCP-DROP: Primary TCP connection receives no reply

**Validates item:** Result when the first TCP connection receives no reply

**Purpose:** Determine what the client receives when CoreDNS opens its first TCP connection to the primary server but the network returns neither a reply nor an immediate error.

**Prerequisites:** NetworkPolicy enforcement and a freshly restarted resolver configured to use TCP for upstream DNS requests.

**Commands:**

```powershell
try {
    Remove-FmFaults
    Set-FmDropPolicy
    Set-FmResolver -Name resolver-sequential -Extra @("force_tcp")
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=40 +tries=1 +stats
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** Record the exact response instead of assuming that the backup server will answer. On the tested CoreDNS 1.13.1 configuration, CoreDNS can wait about 30 seconds for the first TCP connection and then return `SERVFAIL` without an IP address.

**Pass/fail criteria:** The behavior-characterization test passes when the complete response code, answer count, and query time are captured and cleanup succeeds. A separate claim that the backup server answered passes only if `192.0.2.20` is actually present.

**Evidence to capture:** Created NetworkPolicy, resolver configuration showing `force_tcp`, full `dig` output, response code, answer count, query time, server address, resolver logs, and cleanup output.

**Established `aks01day2` evidence:** The test removed old faults, created NetworkPolicy `fm-primary-drop`, and configured the sequential resolver with `force_tcp`. One client query was sent with `+tcp` and a 40-second client timeout. CoreDNS returned `SERVFAIL` after 30,004 ms. The DNS header showed `ANSWER: 0`, so the client received no IP address. The backup-server address `192.0.2.20` did not appear, which means CoreDNS did not complete a successful fallback within that query. The behavior-characterization test passed because the exact outcome was captured. The stronger claim that a configured backup always makes the request succeed did not pass. The `finally` block removed the fault and restored the normal sequential resolver.

#### FM-05-REFUSAL: TCP connection refusal

**Validates item:** TCP connection-refusal fallback

**Purpose:** Compare an immediate TCP connection refusal with a TCP connection that receives no reply.

**Prerequisites:** Primary pod and secondary Service are healthy.

**Commands:**

```powershell
try {
    $primaryPodIp = Invoke-Kubectl @(
        "get","pod","-n",$ns,"-l","app.kubernetes.io/name=upstream-primary",
        "-o","jsonpath={.items[0].status.podIP}"
    )
    $secondaryIp = Invoke-Kubectl @(
        "get","service","upstream-secondary","-n",$ns,"-o","jsonpath={.spec.clusterIP}"
    )
    kubectl exec -n $ns deployment/dns-client -- `
        dig "@$primaryPodIp" -p 5300 answer.validation.test A +tcp +time=3 +tries=1
    Set-FmResolver -Name resolver-sequential -Extra @("force_tcp") `
        -Targets @("${primaryPodIp}:5300", "${secondaryIp}:53")
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +tcp +time=5 +tries=1 +stats
}
finally {
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** Direct query proves `connection refused`; resolver query returns the secondary promptly.

**Pass/fail criteria:** Direct refusal is explicit and the resolver returns `NOERROR` with `192.0.2.20`.

**Evidence to capture:** Both full `dig` outputs and resolver logs.

**Established `aks01day2` evidence:** The test first identified the primary DNS pod IP and confirmed that TCP port 5300 on that pod was closed. A direct query to that closed port returned `connection refused` and `dig` exited with code 9, proving that the failure was immediate rather than a timeout. The sequential resolver was then configured to try the closed primary-pod port first and the healthy backup DNS Service second, using TCP for both. The resolver query returned `NOERROR` and backup answer `192.0.2.20`; `dig` displayed a query time of 0 ms, meaning the result completed in less than one millisecond at its displayed precision. This proves that an immediate connection refusal lets CoreDNS move to the backup server without waiting for the 30-second TCP connection timeout. The `finally` block restored the normal sequential resolver. FM-05 passed.

#### FM-06-RCODE: RCODE response versus explicit failover

**Validates item:** Default and explicit RCODE failover

**Purpose:** Prove that DNS responses are returned by default and retried only when configured.

**Prerequisites:** Namespace-local upstream ConfigMaps may be temporarily extended; managed CoreDNS remains untouched.

**Commands:**

```powershell
try {
    $primaryCorefile = @'
.:53 {
    errors
    log
    prometheus :9153
    template IN A servfail.validation.test {
        rcode SERVFAIL
    }
    template IN A refused.validation.test {
        rcode REFUSED
    }
    template IN A nxdomain.validation.test {
        rcode NXDOMAIN
    }
    template IN NS . {
        rcode NOERROR
    }
}
'@
    $secondaryCorefile = @'
.:53 {
    errors
    log
    prometheus :9153
    template IN A servfail.validation.test {
        answer "{{ .Name }} 30 IN A 192.0.2.20"
    }
    template IN A refused.validation.test {
        answer "{{ .Name }} 30 IN A 192.0.2.20"
    }
    template IN A nxdomain.validation.test {
        answer "{{ .Name }} 30 IN A 192.0.2.20"
    }
    template IN NS . {
        rcode NOERROR
    }
}
'@
    foreach ($entry in @(
        @("upstream-primary",$primaryCorefile),
        @("upstream-secondary",$secondaryCorefile)
    )) {
        kubectl create configmap $entry[0] -n $ns `
            "--from-literal=Corefile=$($entry[1])" --dry-run=client -o yaml |
            kubectl apply -f -
    }
    kubectl rollout restart deployment/upstream-primary deployment/upstream-secondary -n $ns
    Invoke-Kubectl @("rollout","status","deployment/upstream-primary","-n",$ns,"--timeout=180s") | Out-Null
    Invoke-Kubectl @("rollout","status","deployment/upstream-secondary","-n",$ns,"--timeout=180s") | Out-Null
    Set-FmResolver -Name resolver-sequential
    Set-FmResolver -Name resolver-rcode-failover `
        -Extra @("failover SERVFAIL REFUSED NXDOMAIN")
    foreach ($name in @("servfail","refused","nxdomain")) {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential "$name.validation.test" A +time=5 +tries=1
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-rcode-failover "$name.validation.test" A +time=5 +tries=1
    }
}
finally {
    $isolated | kubectl apply -f - | Out-Null
    Invoke-Kubectl @(
        "rollout","restart","deployment/upstream-primary","deployment/upstream-secondary",
        "-n",$ns
    ) | Out-Null
    Invoke-Kubectl @("rollout","status","deployment/upstream-primary","-n",$ns,"--timeout=180s") | Out-Null
    Invoke-Kubectl @("rollout","status","deployment/upstream-secondary","-n",$ns,"--timeout=180s") | Out-Null
    Set-FmResolver -Name resolver-sequential
    Set-FmResolver -Name resolver-round-robin -Policy round_robin
    Set-FmResolver -Name resolver-rcode-failover
}
```

**Expected result:** Default statuses are `SERVFAIL`, `REFUSED`, and `NXDOMAIN`; explicit failover returns `NOERROR` and the secondary for all three.

**Pass/fail criteria:** All six results match exactly and the configured resolver remains Ready.

**Evidence to capture:** Six full queries, ConfigMaps, rollout status, and startup logs.

**Established `aks01day2` evidence:** The primary test server was configured to return three different DNS responses: `SERVFAIL`, `REFUSED`, and `NXDOMAIN`. The backup test server was configured to return `192.0.2.20` for the same three names. Six comparisons were then run. The normal sequential resolver returned the primary server's original response each time and returned no IP address, showing that these DNS responses do not cause another upstream attempt by default. The resolver configured with `failover SERVFAIL REFUSED NXDOMAIN` returned `NOERROR` and `192.0.2.20` for all three names, showing that the explicit `failover` setting caused CoreDNS to ask the backup server. An earlier compact one-line test configuration was malformed and was excluded; only the repaired multiline configuration is retained as evidence. The `finally` block restored both upstream ConfigMaps and all resolver configurations. FM-06 passed.

#### FM-07-HEALTH-LEARNING: `max_fails` and learned health

**Validates item:** `max_fails` and learned health

**Purpose:** Compare first failure with learned state and show that `max_fails 0` prevents removal.

**Prerequisites:** Healthy restored upstreams and enforced NetworkPolicy.

**Commands:**

```powershell
try {
    Set-FmDropPolicy
    Set-FmResolver -Name resolver-sequential -MaxFails 1
    1..4 | ForEach-Object {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats
        Start-Sleep -Seconds 1
    }
    kubectl get --raw `
        "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
    Set-FmResolver -Name resolver-sequential -MaxFails 0
    1..3 | ForEach-Object {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats
    }
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** `max_fails 1` has one delayed result followed by fast secondary results and nonzero health failures; `max_fails 0` repeatedly encounters primary delay.

**Pass/fail criteria:** All answers are secondary; timing pattern and metric agree with the expected state behavior.

**Evidence to capture:** Seven full queries, same-process metrics, and resolver logs.

**Established `aks01day2` evidence:** The test blocked replies from the primary server without returning an immediate error. With `max_fails 1`, the first query waited 2,004 ms before returning backup answer `192.0.2.20`. The next three queries returned the same backup answer in 0 ms because CoreDNS had marked the primary unavailable and stopped trying it for normal requests. The health-check failure counter reached 16 while CoreDNS continued checking the unavailable primary in the background. The resolver was then restarted with `max_fails 0`, which disables marking an upstream unavailable. All three queries still reached the backup, but they took 2,000, 2,004, and 2,004 ms because each request tried the nonresponsive primary first. This proves that `max_fails` changes whether later requests skip the failed server; it does not prevent same-request fallback. Cleanup removed the fault and restored the normal resolver. FM-07 passed.

#### FM-08-RECOVERY: Recovery and primary re-entry

**Validates item:** Recovery and re-entry

**Purpose:** Prove that restored connectivity makes the sequential primary eligible again.

**Prerequisites:** Healthy primary before fault injection.

**Commands:**

```powershell
try {
    Set-FmDropPolicy
    Set-FmResolver -Name resolver-sequential
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 | Out-Null
    Start-Sleep -Seconds 2
    Remove-FmFaults
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $answer = kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A +short
        "$((Get-Date).ToString('o')) $answer"
        if ($answer -contains "192.0.2.10") { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** Primary answer appears within 15 seconds.

**Pass/fail criteria:** `192.0.2.10` appears before the deadline.

**Evidence to capture:** Poll timestamps/answers, stopwatch boundary, metrics, and logs.

**Established `aks01day2` evidence:** The test first blocked the primary server and sent a query so CoreDNS would detect the failure and use the backup. After a two-second wait for health checking, the fault policy was removed without restarting the resolver. The very first recovery poll returned primary answer `192.0.2.10`, proving that CoreDNS automatically made the recovered primary eligible again. The timestamp captured with that answer showed 5,870 ms, and the stopwatch stopped at 5,878 ms. Those values include Kubernetes API communication and `kubectl exec` process startup, so CoreDNS may have detected recovery earlier. The result passed the 15-second criterion but does not define a guaranteed recovery time. Cleanup confirmed that no fault remained and restored the standard resolver configuration. FM-08 passed.

#### FM-09-POLICY: Policy interaction

**Validates item:** Policy interaction

**Purpose:** Separate selection policy from learned-unhealthy exclusion.

**Prerequisites:** Healthy restored upstreams.

**Commands:**

```powershell
$results = [System.Collections.Generic.List[object]]::new()
$resolvers = @(
    "resolver-sequential",
    "resolver-round-robin",
    "resolver-rcode-failover"
)

function Add-FmPolicySamples {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Resolver,
        [int]$Count = 12
    )

    1..$Count | ForEach-Object {
        $trial = $_
        $output = @(kubectl exec -n $ns deployment/dns-client -- `
            dig "@$Resolver" answer.validation.test A +time=5 +tries=1 +short)
        if ($LASTEXITCODE -ne 0) {
            throw "$Phase query $trial failed for $Resolver."
        }

        $answers = @($output | Where-Object {
            $_ -match "^\d{1,3}(\.\d{1,3}){3}$"
        })
        if ($answers.Count -ne 1) {
            throw "$Phase query $trial for $Resolver returned $($answers.Count) A answers."
        }

        $results.Add([pscustomobject]@{
            Phase = $Phase
            Resolver = $Resolver
            Trial = $trial
            Answer = $answers[0]
        })
    }
}

try {
    Set-FmResolver -Name resolver-sequential -Policy sequential
    Set-FmResolver -Name resolver-round-robin -Policy round_robin
    Set-FmResolver -Name resolver-rcode-failover -Policy random

    foreach ($resolver in $resolvers) {
        Add-FmPolicySamples -Phase "Healthy" -Resolver $resolver
    }

    Set-FmDropPolicy
    Start-Sleep -Seconds 4

    foreach ($resolver in $resolvers) {
        Add-FmPolicySamples -Phase "Primary unavailable" -Resolver $resolver
    }
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential -Policy sequential
    Set-FmResolver -Name resolver-round-robin -Policy round_robin
    Set-FmResolver -Name resolver-rcode-failover -Policy sequential `
        -Extra @("failover SERVFAIL")
}

"Ordered results:"
$results | Format-Table Phase,Resolver,Trial,Answer -AutoSize

$summary = @(
    $results |
        Group-Object Phase,Resolver |
        ForEach-Object {
            $group = $_.Group
            [pscustomobject]@{
                Phase = $group[0].Phase
                Resolver = $group[0].Resolver
                Total = $group.Count
                Primary = @($group | Where-Object {
                    $_.Answer -eq "192.0.2.10"
                }).Count
                Backup = @($group | Where-Object {
                    $_.Answer -eq "192.0.2.20"
                }).Count
                Unexpected = @($group | Where-Object {
                    $_.Answer -notin @("192.0.2.10","192.0.2.20")
                }).Count
            }
        }
)

"Summary:"
$summary | Sort-Object Phase,Resolver | Format-Table -AutoSize

$healthySequential = $summary | Where-Object {
    $_.Phase -eq "Healthy" -and
    $_.Resolver -eq "resolver-sequential"
}
$healthyRoundRobin = $summary | Where-Object {
    $_.Phase -eq "Healthy" -and
    $_.Resolver -eq "resolver-round-robin"
}
$healthyRandom = $summary | Where-Object {
    $_.Phase -eq "Healthy" -and
    $_.Resolver -eq "resolver-rcode-failover"
}
$degraded = @($summary | Where-Object {
    $_.Phase -eq "Primary unavailable"
})

if ($healthySequential.Primary -ne 12 -or
    $healthySequential.Backup -ne 0 -or
    $healthySequential.Unexpected -ne 0) {
    throw "Healthy sequential results did not match 12 primary and 0 backup."
}
Write-Host "[PASS] Healthy sequential: 12 primary, 0 backup, 0 unexpected."

if ($healthyRoundRobin.Primary -ne 6 -or
    $healthyRoundRobin.Backup -ne 6 -or
    $healthyRoundRobin.Unexpected -ne 0) {
    throw "Healthy round-robin results did not match 6 primary and 6 backup."
}
Write-Host "[PASS] Healthy round-robin: 6 primary, 6 backup, 0 unexpected."

if ($healthyRandom.Total -ne 12 -or
    $healthyRandom.Unexpected -ne 0) {
    throw "Healthy random results did not contain exactly 12 expected answers."
}
if ($healthyRandom.Primary -eq 0 -or $healthyRandom.Backup -eq 0) {
    Write-Warning "This random sample used only one upstream. Record the result as statistically inconclusive and repeat with a larger sample."
}
if ($healthyRandom.Primary -gt 0 -and $healthyRandom.Backup -gt 0) {
    Write-Host "[PASS] Healthy random: $($healthyRandom.Primary) primary, $($healthyRandom.Backup) backup, 0 unexpected."
}

if (@($degraded | Where-Object {
    $_.Total -ne 12 -or
    $_.Primary -ne 0 -or
    $_.Backup -ne 12 -or
    $_.Unexpected -ne 0
}).Count -ne 0) {
    throw "At least one policy returned a non-backup answer after the primary was unavailable."
}
Write-Host "[PASS] Primary unavailable: all three policies returned 0 primary and 12 backup answers."
Write-Host "[PASS] FM-09 completed successfully. All 72 answers were expected."
```

**Expected result:** Healthy sequential uses primary; round-robin alternates; random has no exact ratio. Once learned unhealthy, every policy uses secondary.

**Pass/fail criteria:** The summary must show healthy sequential as 12 primary and 0 backup, healthy round-robin as 6 primary and 6 backup, and every policy after primary failure as 0 primary and 12 backup. Random healthy results must total 12 with no unexpected address; its exact primary/backup split is recorded but is not fixed.

**Evidence to capture:** All 72 ordered results, the six-row summary table, assertion output, all three resolver ConfigMaps, the primary-fault policy, and cleanup output.

**Established `aks01day2` evidence:** The raw output contained 72 IP addresses, and the counts were calculated by resolver and phase. While both servers were healthy, sequential returned 12 primary and 0 backup answers, round-robin returned 6 primary and 6 backup answers, and random returned 7 primary and 5 backup answers. These healthy totals add up to 36 queries: 25 primary and 11 backup answers. The 7/5 random split is only the result of this sample and is not a guaranteed ratio. After NetworkPolicy `fm-primary-drop` blocked the primary server and CoreDNS had four seconds to detect the failure, each policy received 12 more queries. Sequential, round-robin, and random each returned 0 primary and 12 backup answers, for 36 backup answers and no other result. Across both phases, all 72 queries returned one expected IP address and no timeout or unexpected answer occurred. This proves that policy controls distribution while both servers are healthy, but all three policies exclude the primary after CoreDNS marks it unavailable. The `finally` block removed the fault and restored sequential, round-robin, and RCODE-failover resolvers to their normal configurations. FM-09 passed.

Established summary:

| Phase | Resolver policy | Total | Primary `192.0.2.10` | Backup `192.0.2.20` | Unexpected |
| --- | --- | --- | --- | --- | --- |
| Healthy | Sequential | 12 | 12 | 0 | 0 |
| Healthy | Round-robin | 12 | 6 | 6 | 0 |
| Healthy | Random | 12 | 7 | 5 | 0 |
| Primary unavailable | Sequential | 12 | 0 | 12 | 0 |
| Primary unavailable | Round-robin | 12 | 0 | 12 | 0 |
| Primary unavailable | Random | 12 | 0 | 12 | 0 |
| **All healthy queries** | **All policies** | **36** | **25** | **11** | **0** |
| **All primary-unavailable queries** | **All policies** | **36** | **0** | **36** | **0** |
| **Complete test** | **Both phases** | **72** | **25** | **47** | **0** |

#### FM-10-ALL-UNHEALTHY: All upstreams unhealthy

**Validates item:** All-upstreams-unhealthy behavior

**Purpose:** Compare default unhealthy-endpoint spray with fail-fast.

**Prerequisites:** Both upstreams directly healthy before isolation.

**Commands:**

```powershell
try {
    Set-FmDropPolicy -All
    Set-FmResolver -Name resolver-sequential
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=6 +tries=1 | Out-Null
    Start-Sleep -Seconds 3
    1..3 | ForEach-Object {
        kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential "spray$_.validation.test" A +time=3 +tries=1 +stats
    }
    kubectl get --raw `
        "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
    Set-FmResolver -Name resolver-sequential `
        -Extra @("failfast_all_unhealthy_upstreams")
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=6 +tries=1 | Out-Null
    Start-Sleep -Seconds 3
    $before = kubectl get --raw `
        "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential failfast.validation.test A +time=3 +tries=1 +stats
    $after = kubectl get --raw `
        "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
    Compare-Object ($before -split "`n") ($after -split "`n")
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** Default samples expend an unhealthy attempt and increment the broken-health metric; fail-fast returns immediate `SERVFAIL` without increasing proxy request counts.

**Pass/fail criteria:** Metric and count delta, not latency alone, distinguish the modes.

**Evidence to capture:** Queries, before/after metrics, pod identity, and logs.

**Established `aks01day2` evidence:** The test blocked both upstream DNS servers. With the normal configuration, CoreDNS first learned that both servers were unavailable. Three later queries each returned `SERVFAIL` after 2,000 ms. The metric `coredns_forward_healthcheck_broken_total` reached 3, showing that CoreDNS still made one last attempt to an unavailable upstream for each query. The resolver was then restarted with `failfast_all_unhealthy_upstreams`. After both servers were again known unavailable, the measured query returned `SERVFAIL` in 0 ms. Proxy request counts were 0 before and after that query, proving that fail-fast returned the error without trying either upstream. Cleanup removed the all-server fault and restored the normal resolver. FM-10 passed.

#### FM-11-CLIENT-BUDGET: Client deadline and retry budget

**Validates item:** Client deadline and retry interaction

**Purpose:** Show that resolver behavior and client willingness to wait are separate.

**Prerequisites:** Fresh resolver and enforced primary drop.

**Commands:**

```powershell
try {
    Set-FmDropPolicy
    Set-FmResolver -Name resolver-sequential
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=1 +tries=1 +stats
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=1 +tries=2 +stats
    Set-FmResolver -Name resolver-sequential
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** One second is too short for the cold UDP path; retry timing may benefit from learned health; five seconds receives the secondary.

**Pass/fail criteria:** Exact exits and answers are recorded without claiming retries always succeed.

**Evidence to capture:** Three full outputs and resolver logs over the same interval.

**Established `aks01day2` evidence:** The primary server was blocked without returning an immediate error. With a one-second client timeout and one attempt, the client stopped waiting before CoreDNS completed fallback; `dig` exited with code 9 and received no answer. With the same one-second timeout but two attempts, the request returned `NOERROR` and the backup answer because the additional attempt occurred after CoreDNS had learned more about the failed primary. The resolver was then reset to remove that learned state. With a five-second timeout and one attempt, the query returned `NOERROR` and `192.0.2.20` in 2,004 ms, giving CoreDNS enough time to wait for the primary and use the backup. This proves that client timeout and retry settings can determine whether the caller sees success, but it does not guarantee that two short attempts always succeed. Cleanup removed the fault and restored the resolver. FM-11 passed.

#### FM-12-OBSERVABILITY: Metrics and logs

**Validates item:** Metrics and logs

**Purpose:** Generate known DNS events in one CoreDNS process, then prove that its metrics and logs describe those same events.

**Prerequisites:** Metrics Service and query logging enabled in the isolated fixture. This case creates all events it needs and does not depend on earlier cases.

**Commands:**

```powershell
$metricsPath = "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"

function Get-FmMetrics {
    (kubectl get --raw $metricsPath) -join "`n"
}

function Get-FmMetricTotal {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$MetricName,
        [string]$RequiredLabel = ""
    )

    $total = 0.0
    foreach ($line in $Text -split "`n") {
        if ($line -match "^$([regex]::Escape($MetricName))(?:\{(?<labels>[^}]*)\})?\s+(?<value>[0-9.eE+-]+)$") {
            if (-not $RequiredLabel -or $Matches.labels -like "*$RequiredLabel*") {
                $total += [double]$Matches.value
            }
        }
    }
    $total
}

try {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential

    $podIdentity = kubectl get pod -n $ns `
        -l app.kubernetes.io/name=resolver-sequential `
        -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,RESTARTS:.status.containerStatuses[0].restartCount
    $metricsBefore = Get-FmMetrics

    "HEALTHY_PRIMARY_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats

    "PRIMARY_SERVFAIL_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential rcode.validation.test A +time=5 +tries=1 +stats

    Set-FmDropPolicy
    "PRIMARY_NO_REPLY_BACKUP_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats
    Start-Sleep -Seconds 2

    Remove-FmFaults
    Start-Sleep -Seconds 2
    "RECOVERED_PRIMARY_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats

    Set-FmDropPolicy -All
    "ALL_UNAVAILABLE_PRIMING_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential all-down-prime.validation.test A +time=6 +tries=1 +stats
    Start-Sleep -Seconds 3
    "ALL_UNAVAILABLE_MEASURED_QUERY"
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential all-down-measured.validation.test A +time=3 +tries=1 +stats

    $metricsAfter = Get-FmMetrics
    $logs = kubectl logs -n $ns deployment/resolver-sequential `
        --since=15m --timestamps

    $healthFailures = Get-FmMetricTotal `
        -Text $metricsAfter `
        -MetricName "coredns_proxy_healthcheck_failures_total"
    $brokenHealth = Get-FmMetricTotal `
        -Text $metricsAfter `
        -MetricName "coredns_forward_healthcheck_broken_total"
    $noErrorRequests = Get-FmMetricTotal `
        -Text $metricsAfter `
        -MetricName "coredns_proxy_request_duration_seconds_count" `
        -RequiredLabel 'rcode="NOERROR"'
    $servfailRequests = Get-FmMetricTotal `
        -Text $metricsAfter `
        -MetricName "coredns_proxy_request_duration_seconds_count" `
        -RequiredLabel 'rcode="SERVFAIL"'

    $summary = [pscustomobject]@{
        HealthCheckFailures = $healthFailures
        AllUpstreamsUnhealthyEvents = $brokenHealth
        NoErrorProxyRequests = $noErrorRequests
        ServfailProxyRequests = $servfailRequests
        LogLines = @($logs).Count
    }

    $podIdentity
    "Metric summary:"
    $summary | Format-List
    "Matching metrics:"
    $metricsAfter -split "`n" |
        Select-String -Pattern `
            "coredns_proxy_request_duration_seconds_count|coredns_proxy_healthcheck_failures_total|coredns_forward_healthcheck_broken_total"
    "Timestamped logs:"
    $logs

    if ($healthFailures -le 0) {
        throw "No primary health-check failure was recorded."
    }
    if ($brokenHealth -le 0) {
        throw "No all-upstreams-unhealthy event was recorded."
    }
    if ($noErrorRequests -lt 3) {
        throw "Expected at least three NOERROR proxy requests."
    }
    if ($servfailRequests -lt 1) {
        throw "Expected at least one SERVFAIL proxy request."
    }
    if (($logs -join "`n") -notmatch "answer\.validation\.test|rcode\.validation\.test|all-down") {
        throw "Expected query names were not present in resolver logs."
    }

    Write-Host "[PASS] FM-12 generated and correlated requests, health failures, all-unhealthy behavior, metrics, and logs in one resolver process."
}
finally {
    Remove-FmFaults
    Set-FmResolver -Name resolver-sequential
}
```

**Expected result:** The summary reports at least one primary health-check failure, at least one all-upstreams-unhealthy event, at least three `NOERROR` proxy requests, at least one `SERVFAIL` proxy request, and logs containing the generated query names. All evidence comes from the same resolver pod process.

**Pass/fail criteria:** All four metric assertions pass, the expected query names appear in timestamped logs, the pod identity is captured, and cleanup restores the normal resolver. Reading empty counters immediately after a restart does not pass because no test events have been generated.

**Evidence to capture:** Pod name, UID, restart count, all generated query outputs, before/after raw metrics, calculated metric summary, timestamped logs, fault-policy creation/removal, and resolver restoration.

**Established `aks01day2` evidence:** The self-contained test ran against pod `resolver-sequential-6b79b65767-g8nq4`, UID `69819cd1-80eb-4146-83c7-a7ace3d4f98c`, restart count 0. The metric summary reported 18 health-check failures, 1 all-upstreams-unhealthy event, 3 `NOERROR` proxy requests, 1 `SERVFAIL` proxy request, and 12 log lines. The 18 health-check failures were split across the two upstream servers as 11 and 7. The three successful proxy requests were two requests to the primary and one fallback request to the backup. The one `SERVFAIL` proxy request went to the primary.

The timestamped logs matched every generated phase:

1.  The healthy primary query returned `NOERROR` in 0.000873783 seconds.
2.  The primary DNS-error query returned `SERVFAIL` in 0.000665194 seconds.
3.  When the primary sent no reply, CoreDNS returned `NOERROR` through the backup in 2.002345239 seconds.
4.  After recovery, the primary returned `NOERROR` in 0.001365263 seconds.
5.  With both upstreams unavailable, the priming query ended after 6.003115926 seconds and logged a UDP timeout.
6.  The measured all-unavailable query ended after 2.001139613 seconds and logged another UDP timeout.

`coredns_forward_healthcheck_broken_total` was 1, proving that CoreDNS entered the state where all upstream health checks had failed. The query counts, health-check counters, pod identity, and timestamped logs all came from the same resolver process. Every FM-12 assertion passed, the script printed `[PASS] FM-12 generated and correlated requests, health failures, all-unhealthy behavior, metrics, and logs in one resolver process.`, and the `finally` block removed the faults and restored the normal sequential resolver. FM-12 passed.

#### FM-13-AKS-BOUNDARY: AKS support boundary and noninterference

**Validates item:** AKS managed-resource noninterference

**Purpose:** Confirm namespace isolation and unchanged managed DNS state.

**Prerequisites:** Read-only access to `kube-system`.

**Commands:**

```powershell
$managedAfter = kubectl get configmap coredns -n kube-system `
    -o jsonpath="{.metadata.resourceVersion}"
if ($managedAfter -ne $managedBefore) {
    throw "Managed Corefile resourceVersion changed."
}
kubectl get deployment coredns -n kube-system
kubectl get configmap coredns-custom -n kube-system -o name
kubectl get all,configmap,networkpolicy -n $ns -o name
"ManagedResourceVersionBefore=$managedBefore"
"ManagedResourceVersionAfter=$managedAfter"
```

**Expected result:** Test objects occur only in the isolated namespace; managed CoreDNS remains Available and its Corefile resourceVersion is unchanged.

**Pass/fail criteria:** Before/after resourceVersions match and managed replicas remain Available.

**Evidence to capture:** ResourceVersions, availability, `coredns-custom` presence, and namespace-scoped inventory after redaction.

**Established `aks01day2` evidence:** Before failover testing, the managed `kube-system/coredns` ConfigMap resourceVersion was recorded as `22591546`. After all namespace-local tests, it was still `22591546`, proving that the managed Corefile was not changed during the test window. The managed CoreDNS Deployment remained 2/2 Available. The supported `coredns-custom` ConfigMap was present but was only read, not modified. An inventory found 48 test objects inside the disposable failover namespace, confirming that the test resources were scoped there rather than placed in `kube-system`. Together, the unchanged managed resourceVersion, managed availability, and namespace inventory satisfy the noninterference criterion. FM-13 passed.

#### FM-14-CLEANUP: Cleanup and final health

**Validates item:** Cleanup and retained-lab health

**Purpose:** Remove all FM resources and prove both the retained base lab and managed CoreDNS remain healthy.

**Prerequisites:** Run even after an earlier failure.

**Commands:**

```powershell
try {
    Remove-FmFaults
}
finally {
    kubectl delete namespace $ns --ignore-not-found --wait=true
}
kubectl get namespace $ns
kubectl get deployment -n coredns-failover-validation
kubectl exec -n coredns-failover-validation deployment/dns-client -- `
    dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
kubectl get deployment coredns -n kube-system
kubectl get configmap coredns -n kube-system -o jsonpath="{.metadata.resourceVersion}{'\n'}"
```

**Expected result:** The FM namespace is absent; all six retained lab Deployments and both managed replicas are Available; retained sequential query returns primary.

**Pass/fail criteria:** All final health assertions hold and no FM policy or object remains.

**Evidence to capture:** Namespace-not-found output, Deployment availability, primary answer, and final managed resourceVersion.

**Established `aks01day2` evidence:** Cleanup first removed any remaining FM fault policies and then deleted the disposable `coredns-failover-validation-fm` namespace. A namespace lookup confirmed that it no longer existed. The separate retained validation namespace remained available with all six Deployments at 1/1 Available. A final DNS query through its sequential resolver returned primary answer `192.0.2.10`, confirming normal operation. Managed CoreDNS remained 2/2 Available, and the managed Corefile ConfigMap resourceVersion remained `22591546`. This proves that all temporary FM resources were removed without damaging the reusable lab or managed AKS DNS. FM-14 passed.

#### Evidence handling

*   The retained result contains measured counts, statuses, timings, cleanup state, and interpretation boundaries, not credentials or full environment manifests.
*   DNS timing uses `dig` `Query time`. The recovery stopwatch explicitly includes Kubernetes API and process startup overhead.
*   TEST-NET addresses identify synthetic answers. Dynamic cluster and pod IPs are deliberately omitted.
*   Metric comparisons use the same resolver process unless a restart is explicitly part of the test.

#### Limitations

1.  Results establish CoreDNS 1.13.1 behavior for this isolated fixture on 2026-09-24, not an AKS DNS SLA.
2.  When the first TCP connection received no reply, the request did not return the backup answer. It waited about 30 seconds and returned `SERVFAIL`, so successful fallback must not be assumed.
3.  NetworkPolicy behavior depends on the cluster network implementation; FM-03 established enforcement only for this tested path.
4.  Random samples show eligibility, not fairness or a guaranteed ratio.
5.  The fixture intentionally omits caching so repeated queries reach `forward`.
6.  Query logging was enabled in the disposable lab and is not asserted to be enabled in managed AKS CoreDNS.

#### Conclusion

CoreDNS failover does not guarantee that every request succeeds. When the primary UDP server sent no reply, CoreDNS reached the backup server after about two seconds. When a TCP connection was refused immediately, CoreDNS also reached the backup quickly. However, when the first TCP connection received no reply or error, CoreDNS waited about 30 seconds and returned `SERVFAIL` without a backup answer. Explicit DNS-response failover, health learning, automatic recovery, all-unhealthy fail-fast behavior, policy interaction, client deadlines, metrics, cleanup, and AKS noninterference were also directly established.

#### Authoritative links

*   [CoreDNS 1.13.1 `forward` plugin documentation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
*   [CoreDNS 1.13.1 `forward` implementation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/forward.go)
*   [CoreDNS 1.13.1 proxy implementation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/proxy.go)
*   [Microsoft: Customize CoreDNS with Azure Kubernetes Service](https://learn.microsoft.com/azure/aks/coredns-custom)
*   [Microsoft: Troubleshoot CoreDNS in Azure Kubernetes Service](https://learn.microsoft.com/azure/aks/coredns-troubleshoot)
*   [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   [Local isolated lab source](../validation/coredns-failover-lab.yaml)
*   [Established FM result](../validation/results/aks01day2-failover-20260924.md)
