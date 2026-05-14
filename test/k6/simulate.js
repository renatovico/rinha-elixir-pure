import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// k6 scenario for the dev-only `/debug/simulate` endpoint.
//
// Each VU iteration POSTs a small batch of synthetic payloads to the
// server, which scores them locally (no network per payload), then
// returns aggregated stats. Per-stage timings (transform_us, knn_us)
// are folded into k6 Trend metrics so we get p50/p95/p99 over time.
//
// Run:
//   BASE_URL=http://localhost:4000 BATCH=200 k6 run test/k6/simulate.js
//
// Optional env knobs:
//   BATCH       - payloads per request body (default 200)
//   FRAUD_BIAS  - 0..1 share of fraud-shaped payloads (default 0.4)
//   WARMUP      - samples discarded inside each batch (default 0)
//   STAGE_DUR   - duration of the load stage (default 30s)
//   ARRIVAL     - target requests/sec at end of stage (default 200)

const BASE_URL = __ENV.BASE_URL || 'http://localhost:4000';
const BATCH = parseInt(__ENV.BATCH || '200', 10);
const FRAUD_BIAS = parseFloat(__ENV.FRAUD_BIAS || '0.4');
const WARMUP = parseInt(__ENV.WARMUP || '0', 10);
const STAGE_DUR = __ENV.STAGE_DUR || '30s';
const ARRIVAL = parseInt(__ENV.ARRIVAL || '200', 10);

const transformP50 = new Trend('stage_transform_p50_us');
const transformP95 = new Trend('stage_transform_p95_us');
const transformP99 = new Trend('stage_transform_p99_us');
const knnP50 = new Trend('stage_knn_p50_us');
const knnP95 = new Trend('stage_knn_p95_us');
const knnP99 = new Trend('stage_knn_p99_us');
const totalP50 = new Trend('stage_total_p50_us');
const totalP95 = new Trend('stage_total_p95_us');
const totalP99 = new Trend('stage_total_p99_us');

const accuracyTrend = new Trend('sim_accuracy');
const recallTrend = new Trend('sim_recall_fraud');
const precisionTrend = new Trend('sim_precision_legit');
const throughput = new Trend('sim_throughput_per_sec');
const samplesProcessed = new Counter('sim_samples_processed');
const errorRate = new Rate('sim_error_rate');

export const options = {
    summaryTrendStats: ['min', 'p(50)', 'p(95)', 'p(99)', 'max'],
    scenarios: {
        ramp: {
            executor: 'ramping-arrival-rate',
            startRate: 1,
            timeUnit: '1s',
            preAllocatedVUs: 20,
            maxVUs: 100,
            gracefulStop: '10s',
            stages: [
                { duration: STAGE_DUR, target: ARRIVAL },
            ],
        },
    },
};

export function setup() {
    const r = http.get(`${BASE_URL}/debug/ready`);
    if (r.status !== 200) {
        throw new Error(`server not ready at ${BASE_URL}: ${r.status}`);
    }
    console.log(`Targeting ${BASE_URL} | batch=${BATCH} fraud_bias=${FRAUD_BIAS} arrival_target=${ARRIVAL}/s`);
}

export default function () {
    const body = JSON.stringify({
        count: BATCH,
        fraud_bias: FRAUD_BIAS,
        warmup: WARMUP,
    });

    const res = http.post(`${BASE_URL}/debug/simulate`, body, {
        headers: { 'Content-Type': 'application/json' },
        timeout: '30s',
    });

    const ok = check(res, {
        'status 200': (r) => r.status === 200,
    });

    if (!ok) {
        errorRate.add(1);
        return;
    }
    errorRate.add(0);

    let data;
    try {
        data = JSON.parse(res.body);
    } catch (e) {
        errorRate.add(1);
        return;
    }

    samplesProcessed.add(data.count || 0);
    accuracyTrend.add((data.accuracy || 0) * 100);
    recallTrend.add((data.recall_fraud || 0) * 100);
    precisionTrend.add((data.precision_legit || 0) * 100);
    throughput.add(data.throughput_per_sec || 0);

    if (data.latency) {
        if (data.latency.transform) {
            transformP50.add(data.latency.transform.p50);
            transformP95.add(data.latency.transform.p95);
            transformP99.add(data.latency.transform.p99);
        }
        if (data.latency.knn) {
            knnP50.add(data.latency.knn.p50);
            knnP95.add(data.latency.knn.p95);
            knnP99.add(data.latency.knn.p99);
        }
        if (data.latency.total) {
            totalP50.add(data.latency.total.p50);
            totalP95.add(data.latency.total.p95);
            totalP99.add(data.latency.total.p99);
        }
    }
}

export function handleSummary(data) {
    const m = data.metrics;
    const pick = (name, stat = 'p(99)') => (m[name] && m[name].values && m[name].values[stat] !== undefined ? +m[name].values[stat].toFixed(2) : null);

    const totalSamples = m.sim_samples_processed ? m.sim_samples_processed.values.count : 0;

    const result = {
        config: { base_url: BASE_URL, batch: BATCH, fraud_bias: FRAUD_BIAS, arrival_target: ARRIVAL },
        samples_processed: totalSamples,
        accuracy_p50_pct: pick('sim_accuracy', 'p(50)'),
        recall_fraud_p50_pct: pick('sim_recall_fraud', 'p(50)'),
        precision_legit_p50_pct: pick('sim_precision_legit', 'p(50)'),
        per_stage_us: {
            transform: { p50: pick('stage_transform_p50_us', 'p(50)'), p95: pick('stage_transform_p95_us', 'p(95)'), p99: pick('stage_transform_p99_us', 'p(99)') },
            knn:       { p50: pick('stage_knn_p50_us',       'p(50)'), p95: pick('stage_knn_p95_us',       'p(95)'), p99: pick('stage_knn_p99_us',       'p(99)') },
            total:     { p50: pick('stage_total_p50_us',     'p(50)'), p95: pick('stage_total_p95_us',     'p(95)'), p99: pick('stage_total_p99_us',     'p(99)') },
        },
        throughput_per_sec_p50: pick('sim_throughput_per_sec', 'p(50)'),
        http: {
            req_duration_p99_ms: pick('http_req_duration', 'p(99)'),
            req_failed_rate: m.http_req_failed && m.http_req_failed.values ? m.http_req_failed.values.rate : null,
            iterations: m.iterations ? m.iterations.values.count : 0,
        },
    };

    const json = JSON.stringify(result, null, 2);
    return {
        'test/results-simulate.json': json,
        stdout: '\n=== Rinha simulate ===\n' + json + '\n',
    };
}
