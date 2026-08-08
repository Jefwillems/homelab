#!/usr/bin/env fish

argparse \
    'h/help' \
    'p/prometheus=' \
    'n/namespace=' \
    'w/window=' \
    'low=' \
    'high=' \
    'a/all' \
    'insecure' \
    -- $argv
or begin
    echo "Run with --help for usage." >&2
    exit 2
end

if set -q _flag_help
    echo "Usage: resource-checker.fish [options]

Options:
  -p, --prometheus URL   Prometheus base URL (default: https://prometheus.jef.app)
  -n, --namespace NS     Restrict to a single namespace (default: all)
  -w, --window DUR       Lookback window for usage stats  (default: 7d)
      --low  FLOAT       'request too high' ratio         (default: 0.5)
      --high FLOAT       'limit  too tight' ratio         (default: 0.8)
  -a, --all              Also show containers with no findings
      --insecure         Pass -k to curl (self-signed TLS)
  -h, --help             Show this help"
    exit 0
end

set -l prom    (set -q _flag_prometheus; and echo $_flag_prometheus; or echo "https://prometheus.jef.app")
set -l ns      (set -q _flag_namespace;  and echo $_flag_namespace;  or echo "")
set -l window  (set -q _flag_window;     and echo $_flag_window;     or echo "7d")
set -l low     (set -q _flag_low;        and echo $_flag_low;        or echo "0.5")
set -l high    (set -q _flag_high;       and echo $_flag_high;       or echo "0.8")
set -l show_all (set -q _flag_all;       and echo 1;                 or echo 0)
set -l curl_opts -sS --fail-with-body
set -q _flag_insecure; and set -a curl_opts -k

# Namespace filter fragment for PromQL selectors.
set -l nsfilter ""
test -n "$ns"; and set nsfilter ",namespace=\"$ns\""

# --- Prometheus helper --------------------------------------------------------
# Runs an instant query and prints TSV: namespace<TAB>pod<TAB>container<TAB>value<TAB>tag
function _prom_query --argument-names prom query tag
    set -l url "$prom/api/v1/query"
    curl $curl_opts --no-progress-meter -G --data-urlencode "query=$query" "$url" 2>/dev/null \
        | jq -r --arg tag "$tag" '
            if .status != "success" then
                error("prometheus query failed: " + (.error // "unknown"))
            else
                .data.result[]
                | [ .metric.namespace, .metric.pod, .metric.container,
                    (.value[1] | tonumber), $tag ]
                | @tsv
            end'
end

# --- Queries ------------------------------------------------------------------
set -l cadv_sel "container!=\"\",container!=\"POD\",image!=\"\"$nsfilter"
set -l ksm_sel  "container!=\"\"$nsfilter"

# Filter every usage query against currently-existing containers so we don't
# report on ghost pods whose time-series are still inside the lookback window.
set -l live "and on (namespace,pod,container) kube_pod_container_info{$ksm_sel}"

set -l q_cpu_p95   "quantile_over_time(0.95, sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{$cadv_sel}[5m]))[$window:5m]) $live"
set -l q_cpu_max   "max_over_time(sum by (namespace,pod,container) (rate(container_cpu_usage_seconds_total{$cadv_sel}[5m]))[$window:5m]) $live"
set -l q_mem_p95   "quantile_over_time(0.95, sum by (namespace,pod,container) (container_memory_working_set_bytes{$cadv_sel})[$window:5m]) $live"
set -l q_mem_max   "max_over_time(sum by (namespace,pod,container) (container_memory_working_set_bytes{$cadv_sel})[$window:5m]) $live"
set -l q_cpu_req   "max by (namespace,pod,container) (kube_pod_container_resource_requests{resource=\"cpu\",$ksm_sel})"
set -l q_cpu_lim   "max by (namespace,pod,container) (kube_pod_container_resource_limits{resource=\"cpu\",$ksm_sel})"
set -l q_mem_req   "max by (namespace,pod,container) (kube_pod_container_resource_requests{resource=\"memory\",$ksm_sel})"
set -l q_mem_lim   "max by (namespace,pod,container) (kube_pod_container_resource_limits{resource=\"memory\",$ksm_sel})"

echo "Querying $prom (window=$window, low=$low, high=$high"(test -n "$ns"; and echo ", ns=$ns")")..." >&2

set -l rows (begin
    _prom_query $prom "$q_cpu_p95" cpu_p95
    _prom_query $prom "$q_cpu_max" cpu_max
    _prom_query $prom "$q_mem_p95" mem_p95
    _prom_query $prom "$q_mem_max" mem_max
    _prom_query $prom "$q_cpu_req" cpu_req
    _prom_query $prom "$q_cpu_lim" cpu_lim
    _prom_query $prom "$q_mem_req" mem_req
    _prom_query $prom "$q_mem_lim" mem_lim
end)

if test (count $rows) -eq 0
    echo "No results from Prometheus. Is the URL reachable and are the metrics present?" >&2
    exit 1
end

# --- Analysis (awk) -----------------------------------------------------------
# Merge rows keyed by ns/pod/container, apply rules, emit findings.
printf "%s\n" $rows | awk -v FS='\t' -v OFS='\t' \
    -v low=$low -v high=$high -v show_all=$show_all '
function human_cpu(v) {
    if (v == "" || v+0 == 0) return "-"
    if (v < 1) return sprintf("%dm", v*1000+0.5)
    return sprintf("%.2f", v)
}
function human_mem(v,   u) {
    if (v == "" || v+0 == 0) return "-"
    split("B KiB MiB GiB TiB", U, " ")
    u = 1
    while (v >= 1024 && u < 5) { v /= 1024; u++ }
    return sprintf("%.0f%s", v+0.5, U[u])
}
function suggest_cpu(v) { return human_cpu(v * 1.2) }
function suggest_mem(v) { return human_mem(v * 1.2) }
function suggest_mem_lim(v) { return human_mem(v * 1.3) }

{
    key = $1 "/" $2 "/" $3
    seen[key] = 1
    ns[key]   = $1; pod[key] = $2; ctr[key] = $3
    val[key, $5] = $4
}
END {
    fmt = "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
    printf fmt, "NAMESPACE/POD", "CONTAINER", "RES", "REQUEST", "LIMIT", "P95", "MAX", "FINDING → SUGGESTION"
    printf fmt, "-------------", "---------", "---", "-------", "-----", "---", "---", "--------------------"

    n = asorti(seen, sorted)
    for (i = 1; i <= n; i++) {
        k = sorted[i]

        cr = val[k,"cpu_req"] + 0; cl = val[k,"cpu_lim"] + 0
        cp = val[k,"cpu_p95"] + 0; cm = val[k,"cpu_max"] + 0
        mr = val[k,"mem_req"] + 0; ml = val[k,"mem_lim"] + 0
        mp = val[k,"mem_p95"] + 0; mmx = val[k,"mem_max"] + 0

        # --- CPU findings ---
        cpu_note = ""
        if (cl > 0)                                cpu_note = "CPU limit set → REMOVE it (avoid throttling)"
        else if (cr == 0)                          cpu_note = "no CPU request → set to " suggest_cpu(cp > 0 ? cp : 0.01)
        else if (cp > cr)                          cpu_note = "under-requested → raise request to " suggest_cpu(cp)
        else if (cr > 0 && cp < low * cr)          cpu_note = "over-requested → lower request to " suggest_cpu(cp > 0 ? cp : cr * low * 0.5)

        if (cpu_note != "" || show_all) {
            printf fmt, ns[k] "/" pod[k], ctr[k], "cpu",
                human_cpu(cr), human_cpu(cl), human_cpu(cp), human_cpu(cm),
                (cpu_note == "" ? "ok" : cpu_note)
        }

        # --- Memory findings ---
        mem_note = ""
        if (ml == 0)                               mem_note = "no memory limit → set to " suggest_mem_lim(mmx > 0 ? mmx : (mr > 0 ? mr : 134217728))
        else if (mr == 0)                          mem_note = "no memory request → set to " suggest_mem(mp > 0 ? mp : 67108864)
        else if (mp > mr)                          mem_note = "under-requested → raise request to " suggest_mem(mp)
        else if (mmx > high * ml)                  mem_note = "limit tight (max > " int(high*100) "% of limit) → raise limit to " suggest_mem_lim(mmx)
        else if (mr > 0 && mp < low * mr)          mem_note = "over-requested → lower request to " suggest_mem(mp > 0 ? mp : mr * low * 0.5)

        if (mem_note != "" || show_all) {
            printf fmt, ns[k] "/" pod[k], ctr[k], "mem",
                human_mem(mr), human_mem(ml), human_mem(mp), human_mem(mmx),
                (mem_note == "" ? "ok" : mem_note)
        }
    }
}' | column -t -s \t
