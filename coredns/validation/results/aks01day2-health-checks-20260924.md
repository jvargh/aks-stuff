# AKS CoreDNS active-health-check validation result

- Executed: 2026-09-24
- Cluster context: `aks01day2`
- Disposable namespace: `coredns-failover-validation-hc` (deleted)
- Image: `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`
- Binary: `CoreDNS-1.13.1`
- Managed CoreDNS: read-only throughout; ConfigMap resourceVersion `22591546`

## Summary

| Test | Status | Exact observation |
| --- | --- | --- |
| [HC-01-COMPATIBILITY](../../responses/04-Active-health-checks.md#hc-01-compatibility) | PASS | PASS: image/binary matched; direct answers were `192.0.2.10` and `192.0.2.20`. |
| [HC-02-NO-PREERROR](../../responses/04-Active-health-checks.md#hc-02-no-preerror) | PASS | PASS: counter `0 -> 0`; primary NS log count `0`. |
| [HC-03-TRIGGER](../../responses/04-Active-health-checks.md#hc-03-trigger) | PASS | Latest run: `NOERROR`, `192.0.2.20`, 2,004 ms; primary health-check failure counter 3; all-upstreams-unhealthy counter 0 because the backup remained healthy. An earlier snapshot taken later recorded 6 failures. |
| [HC-04-PROBE-SHAPE](../../responses/04-Active-health-checks.md#hc-04-probe-shape) | PARTIAL | PARTIAL: one `NS IN probe.validation.test` log showed `false` (RD clear). Exact default/custom packet cadence is blocked because no approved privileged capture image was available. |
| [HC-05-MAX-FAILS-ZERO](../../responses/04-Active-health-checks.md#hc-05-max-fails-zero) | PASS | PASS: secondary answers took 2,004, 2,000, and 2,004 ms; count `0 -> 0`. |
| [HC-06-MAX-FAILS-ONE](../../responses/04-Active-health-checks.md#hc-06-max-fails-one) | PASS | PASS: cold 2,004 ms; post-detection 0, 4, and 4 ms; failures 15. |
| [HC-07-MAX-FAILS-TWO](../../responses/04-Active-health-checks.md#hc-07-max-fails-two) | PASS | PASS: cold 2,000 ms; post-detection 4, 0, and 96 ms; failures 18. Packet-level proof of the exact second-probe transition is blocked. |
| [HC-08-SERVFAIL-HEALTH](../../responses/04-Active-health-checks.md#hc-08-servfail-health) | PASS | PASS: cold secondary in 2,008 ms; one NS SERVFAIL log; primary returned in 84 ms on a poll, 5.54 s including exec overhead. |
| [HC-09-SKIP-RECOVERY](../../responses/04-Active-health-checks.md#hc-09-skip-recovery) | PARTIAL | PARTIAL: skip was 4 ms. In the bounded post-restore sample the secondary remained selected (latest query 192 ms); HC-08 independently established re-entry. No recovery SLO is claimed. |
| [HC-10-ALL-DOWN](../../responses/04-Active-health-checks.md#hc-10-all-down) | PASS | PASS: default SERVFAIL took 2,004 ms; fail-fast SERVFAIL took 4 ms; broken-health metric family was exposed. |
| [HC-11-OBSERVABILITY](../../responses/04-Active-health-checks.md#hc-11-observability) | PASS | PASS: UID `ec3e6866-7809-437f-ae98-1bcc049a2594`; health failures 13; one request series and one resolver log line. |
| [HC-12-TRANSPORTS](../../responses/04-Active-health-checks.md#hc-12-transports) | PARTIAL | UDP returned `NOERROR` and backup `192.0.2.20` in 2,004 ms. Client TCP and forced-upstream-TCP each received no response within six seconds and exited 9. Corrected 40-second first-query and later post-detection measurements are pending. |
| [HC-13-POLICIES](../../responses/04-Active-health-checks.md#hc-13-policies) | PASS | PASS: 0 unexpected answers for all three policies; failure counters were 160, 153, and 129. |
| [HC-14-RESTART-RESET](../../responses/04-Active-health-checks.md#hc-14-restart-reset) | INCONCLUSIVE | INCONCLUSIVE: UID changed, but both measured queries were 0 ms secondary; service routing/selection did not force a primary attempt. The state-memory claim remains source-backed, not live-proven by this sample. |
| [HC-15-CLEANUP](../../responses/04-Active-health-checks.md#hc-15-cleanup) | PASS | PASS: HC namespace deleted; base returned `192.0.2.10`; six base Deployments and managed CoreDNS were Available; managed ConfigMap resourceVersion remained `22591546`. |

## Case evidence

#### HC-01-COMPATIBILITY

- **Result:** PASS: image/binary matched; direct answers were `192.0.2.10` and `192.0.2.20`.
- **Response backlink:** [Resource and version compatibility](../../responses/04-Active-health-checks.md#hc-01-compatibility)

#### HC-02-NO-PREERROR

- **Result:** PASS: counter `0 -> 0`; primary NS log count `0`.
- **Response backlink:** [No polling before an error](../../responses/04-Active-health-checks.md#hc-02-no-preerror)

#### HC-03-TRIGGER

- **Result:** PASS: `NOERROR`, backup answer `192.0.2.20`, 2,004 ms; primary health-check failure counter 3; all-upstreams-unhealthy counter 0. An earlier snapshot recorded 6 failed checks because it was taken later.
- **Response backlink:** [Network error starts the health loop](../../responses/04-Active-health-checks.md#hc-03-trigger)

#### HC-04-PROBE-SHAPE

- **Result:** PARTIAL: one `NS IN probe.validation.test` log showed `false` (RD clear). Exact default/custom packet cadence is blocked because no approved privileged capture image was available.
- **Response backlink:** [Interval and probe shape](../../responses/04-Active-health-checks.md#hc-04-probe-shape)

#### HC-05-MAX-FAILS-ZERO

- **Result:** PASS: secondary answers took 2,004, 2,000, and 2,004 ms; count `0 -> 0`.
- **Response backlink:** [`max_fails 0` disables health state](../../responses/04-Active-health-checks.md#hc-05-max-fails-zero)

#### HC-06-MAX-FAILS-ONE

- **Result:** PASS: cold 2,004 ms; post-detection 0, 4, and 4 ms; failures 15.
- **Response backlink:** [`max_fails 1` transition](../../responses/04-Active-health-checks.md#hc-06-max-fails-one)

#### HC-07-MAX-FAILS-TWO

- **Result:** PASS: cold 2,000 ms; post-detection 4, 0, and 96 ms; failures 18. Packet-level proof of the exact second-probe transition is blocked.
- **Response backlink:** [Default `max_fails 2`](../../responses/04-Active-health-checks.md#hc-07-max-fails-two)

#### HC-08-SERVFAIL-HEALTH

- **Result:** PASS: cold secondary in 2,008 ms; one NS SERVFAIL log; primary returned in 84 ms on a poll, 5.54 s including exec overhead.
- **Response backlink:** [SERVFAIL is transport-healthy](../../responses/04-Active-health-checks.md#hc-08-servfail-health)

#### HC-09-SKIP-RECOVERY

- **Result:** PARTIAL: skip was 4 ms. In the bounded post-restore sample the secondary remained selected (latest query 192 ms); HC-08 independently established re-entry. No recovery SLO is claimed.
- **Response backlink:** [Unhealthy skip and recovery](../../responses/04-Active-health-checks.md#hc-09-skip-recovery)

#### HC-10-ALL-DOWN

- **Result:** PASS: default SERVFAIL took 2,004 ms; fail-fast SERVFAIL took 4 ms; broken-health metric family was exposed.
- **Response backlink:** [All-upstreams-down behavior](../../responses/04-Active-health-checks.md#hc-10-all-down)

#### HC-11-OBSERVABILITY

- **Result:** PASS: UID `ec3e6866-7809-437f-ae98-1bcc049a2594`; health failures 13; one request series and one resolver log line.
- **Response backlink:** [Metrics and logs](../../responses/04-Active-health-checks.md#hc-11-observability)

#### HC-12-TRANSPORTS

- **Result:** PARTIAL. The UDP query returned `NOERROR` and backup `192.0.2.20` in 2,004 ms. Client TCP and forced-upstream-TCP each exceeded the six-second client timeout and exited 9 without a response. The corrected commands use 40 seconds for the first TCP query and then measure a later query after health detection. Packet proof of resolver-to-upstream protocol remains blocked.
- **Response backlink:** [UDP and TCP](../../responses/04-Active-health-checks.md#hc-12-transports)

#### HC-13-POLICIES

- **Result:** PASS: 0 unexpected answers for all three policies; failure counters were 160, 153, and 129.
- **Response backlink:** [Selection-policy interaction](../../responses/04-Active-health-checks.md#hc-13-policies)

#### HC-14-RESTART-RESET

- **Result:** INCONCLUSIVE: UID changed, but both measured queries were 0 ms secondary; service routing/selection did not force a primary attempt. The state-memory claim remains source-backed, not live-proven by this sample.
- **Response backlink:** [Restart resets learned health](../../responses/04-Active-health-checks.md#hc-14-restart-reset)

#### HC-15-CLEANUP

- **Result:** PASS: HC namespace deleted; base returned `192.0.2.10`; six base Deployments and managed CoreDNS were Available; managed ConfigMap resourceVersion remained `22591546`.
- **Response backlink:** [Cleanup and noninterference](../../responses/04-Active-health-checks.md#hc-15-cleanup)

## Cleanup

The disposable namespace was deleted and confirmed absent. The retained `coredns-failover-validation` lab had all six Deployments Available and returned `192.0.2.10` through `resolver-sequential`. Managed CoreDNS remained Available. No shared manifest, script, managed ConfigMap, or other response was modified.

## Blockers and interpretation

Packet-only interval and resolver-to-upstream transport proof was blocked by the absence of an approved privileged capture image. Upstream logs retained non-packet proof of the custom probe name and cleared RD flag. HC-09 recovery sampling and HC-14 restart routing were nondeterministic and are reported as partial/inconclusive rather than fabricated.
