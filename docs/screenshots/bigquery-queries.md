# BigQuery Queries

All logs go into the dataset `gke-assessment.gke_logs` through two log sinks (see `terraform/observability.tf`). The tables I used:

| Table | Comes from | Used for |
|---|---|---|
| `requests` | Global LB request logs (`http_load_balancer`) | error rate, latency, Cloud Armor blocks |
| `events` | Kubernetes events | pod restarts (CrashLoopBackOff) |
| `stdout` / `stderr` | Container logs | app logs per pod |

Other tables created by the GKE sink: `kubelet`, `container_runtime`, `kube_proxy`, `cloudaudit_googleapis_com_activity`, `fluentbit` and a few more.

Tables are partitioned by day and partitions expire after 30 days, so always filter on `timestamp` to keep the scanned data small.

You can run these in the BigQuery console, or from Cloud Shell with `bq query --use_legacy_sql=false '...'`.

---

## 1. Requests by status code (quick check)

```sql
SELECT httpRequest.status AS status, COUNT(*) AS n
FROM `gke-assessment.gke_logs.requests`
GROUP BY status
ORDER BY status;
```

My result after the tests:

| status | n | meaning |
|---|---|---|
| 200 | 654 | normal traffic |
| 403 | 8 | blocked by Cloud Armor (XSS / SQLi tests) |
| 502 | 69 | requests during the failover test, before the primary backend was marked unhealthy |

![bigquery status](screenshots/13-bigquery-status-counts.png)

---

## 2. Error rate per 5 minutes (Grafana panel 1)

Counts per 5-minute bucket split into status classes. The error rate is `failed_5xx / total`.

```sql
SELECT
  TIMESTAMP_SECONDS(DIV(UNIX_SECONDS(timestamp), 300) * 300) AS time,
  COUNTIF(httpRequest.status BETWEEN 200 AND 399) AS ok_2xx,
  COUNTIF(httpRequest.status BETWEEN 400 AND 499) AS blocked_4xx,
  COUNTIF(httpRequest.status >= 500)              AS failed_5xx
FROM `gke-assessment.gke_logs.requests`
WHERE $__timeFilter(timestamp)
GROUP BY time
ORDER BY time;
```

The same thing as a percentage, if you want one number per bucket:

```sql
SELECT
  TIMESTAMP_SECONDS(DIV(UNIX_SECONDS(timestamp), 300) * 300) AS time,
  ROUND(100 * COUNTIF(httpRequest.status >= 500) / COUNT(*), 2) AS error_rate_pct
FROM `gke-assessment.gke_logs.requests`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
GROUP BY time
ORDER BY time;
```

`$__timeFilter(timestamp)` is a Grafana macro. It becomes the dashboard time range. In the BigQuery console, replace it with a normal `timestamp > ...` filter like in the second query.

---

## 3. Pod restarts (Grafana panel 2)

Every time Kubernetes backs off restarting a crashing container it writes a `BackOff` event.

```sql
SELECT
  TIMESTAMP_SECONDS(DIV(UNIX_SECONDS(timestamp), 300) * 300) AS time,
  CONCAT(jsonPayload.involvedObject.namespace, '/', jsonPayload.involvedObject.name) AS pod,
  COUNT(*) AS restarts
FROM `gke-assessment.gke_logs.events`
WHERE $__timeFilter(timestamp)
  AND jsonPayload.reason = 'BackOff'
GROUP BY time, pod
ORDER BY time;
```

Per cluster, which is what my panel shows in the legend (`gke-primary/crasher`):

```sql
SELECT
  TIMESTAMP_SECONDS(DIV(UNIX_SECONDS(timestamp), 300) * 300) AS time,
  CONCAT(resource.labels.cluster_name, '/', jsonPayload.involvedObject.name) AS pod,
  COUNT(*) AS restarts
FROM `gke-assessment.gke_logs.events`
WHERE $__timeFilter(timestamp)
  AND jsonPayload.reason = 'BackOff'
GROUP BY time, pod
ORDER BY time;
```

Note: this counts BackOff events, not the exact restart counter. For the exact number use `kubectl get pods` (RESTARTS column). The events are still a good signal that a pod is crash-looping.

---

## 4. Latency p50 / p95 / p99 (Grafana panel 3)

Only successful requests (status < 400), so Cloud Armor blocks don't pull the numbers down. The latency field comes in like `0.012s`, so I strip the `s` and convert to milliseconds.

```sql
WITH r AS (
  SELECT
    TIMESTAMP_SECONDS(DIV(UNIX_SECONDS(timestamp), 300) * 300) AS time,
    SAFE_CAST(REGEXP_REPLACE(CAST(httpRequest.latency AS STRING), r's$', '') AS FLOAT64) * 1000 AS latency_ms
  FROM `gke-assessment.gke_logs.requests`
  WHERE $__timeFilter(timestamp)
    AND httpRequest.status < 400
)
SELECT
  time,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] AS p50_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(99)] AS p99_ms
FROM r
WHERE latency_ms IS NOT NULL
GROUP BY time
ORDER BY time;
```

---

## 5. Traffic per backend (app-a vs app-b) and status

```sql
SELECT
  resource.labels.backend_service_name AS backend,
  httpRequest.status AS status,
  COUNT(*) AS n
FROM `gke-assessment.gke_logs.requests`
WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
GROUP BY backend, status
ORDER BY backend, status;
```

---

## 6. What Cloud Armor blocked

```sql
SELECT
  timestamp,
  httpRequest.remoteIp AS client_ip,
  httpRequest.requestUrl AS url,
  httpRequest.status AS status,
  jsonPayload.enforcedSecurityPolicy.name AS policy,
  jsonPayload.enforcedSecurityPolicy.priority AS rule_priority,
  jsonPayload.enforcedSecurityPolicy.outcome AS outcome
FROM `gke-assessment.gke_logs.requests`
WHERE jsonPayload.enforcedSecurityPolicy.outcome = 'DENY'
ORDER BY timestamp DESC
LIMIT 50;
```

Rule priority tells you which rule matched: 1000 = SQLi, 1001 = XSS, 2000 = rate limit.

---

## 7. App log lines per pod (namespace `apps`)

```sql
SELECT
  resource.labels.cluster_name AS cluster,
  resource.labels.pod_name AS pod,
  COUNT(*) AS log_lines
FROM `gke-assessment.gke_logs.stdout`
WHERE resource.labels.namespace_name = 'apps'
  AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
GROUP BY cluster, pod
ORDER BY cluster, log_lines DESC;
```

---

## 8. Which URLs get 4xx (bots scanning the IP)

After the IP was public for a while, I saw bursts of 4xx that were not from my tests. This shows what they were asking for:

```sql
SELECT httpRequest.requestUrl AS url, httpRequest.status AS status, COUNT(*) AS n
FROM `gke-assessment.gke_logs.requests`
WHERE httpRequest.status BETWEEN 400 AND 499
GROUP BY url, status
ORDER BY n DESC
LIMIT 20;
```
This is a quick way to confirm that a 4xx burst is internet scanners probing random paths and not a problem with the apps.
