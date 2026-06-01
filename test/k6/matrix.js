import http from 'k6/http';
import { SharedArray } from 'k6/data';
import { Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:9999';
const DATA_FILE = __ENV.DATA_FILE || './test-data.json';
const RESULTS_FILE = __ENV.RESULTS_FILE || 'test/results.json';

const TARGET_RPS = Number(__ENV.TARGET_RPS || 900);
const HOLD_STAGE = __ENV.HOLD_STAGE || '120s';
const START_RATE = Number(__ENV.START_RATE || 1);
const PRE_ALLOCATED_VUS = Number(__ENV.PRE_ALLOCATED_VUS || 100);
const MAX_VUS = Number(__ENV.MAX_VUS || 250);
const GRACEFUL_STOP = __ENV.GRACEFUL_STOP || '10s';
const REQ_TIMEOUT_MS = Number(__ENV.REQ_TIMEOUT_MS || 2001);

const testData = new SharedArray('test-data', function () {
  return JSON.parse(open(DATA_FILE)).entries;
});

const statsArr = new SharedArray('test-stats', function () {
  return [JSON.parse(open(DATA_FILE)).stats];
});

const expectedStats = statsArr[0];

const tpCount = new Counter('tp_count');
const tnCount = new Counter('tn_count');
const fpCount = new Counter('fp_count');
const fnCount = new Counter('fn_count');
const errorCount = new Counter('error_count');

export const options = {
  summaryTrendStats: ['p(99)'],
  systemTags: ['status', 'method'],
  dns: {
    ttl: '5m',
    select: 'roundRobin',
  },
  scenarios: {
    default: {
      executor: 'ramping-arrival-rate',
      startRate: START_RATE,
      timeUnit: '1s',
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: GRACEFUL_STOP,
      stages: [{ duration: HOLD_STAGE, target: TARGET_RPS }],
    },
  },
};

export function setup() {
  console.log(
    `Dataset=${DATA_FILE} total=${expectedStats.total} ` +
      `fraud=${expectedStats.fraud_count} legit=${expectedStats.legit_count} ` +
      `target_rps=${TARGET_RPS} hold=${HOLD_STAGE} timeout_ms=${REQ_TIMEOUT_MS}`
  );
}

export default function () {
  const idx = exec.scenario.iterationInTest;
  if (idx >= testData.length) return;

  const entry = testData[idx];
  const expectedApproved = entry.expected_approved;

  const res = http.post(
    `${BASE_URL}/fraud-score`,
    JSON.stringify(entry.request),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: `${REQ_TIMEOUT_MS}ms`,
    }
  );

  if (res.status === 200) {
    const body = JSON.parse(res.body);

    if (expectedApproved === body.approved) {
      if (body.approved) tnCount.add(1);
      else tpCount.add(1);
    } else {
      if (body.approved) fnCount.add(1);
      else fpCount.add(1);
    }
  } else {
    errorCount.add(1);
  }
}

export function handleSummary(data) {
  const K = 1000;
  const T_MAX_MS = 1000;
  const P99_MIN_MS = 1;
  const P99_MAX_MS = 2000;
  const EPSILON_MIN = 0.001;
  const BETA = 300;
  const TX_CORTE = 0.15;
  const SCORE_P99_CORTE = -3000;
  const SCORE_DET_CORTE = -3000;

  const httpDuration = data.metrics.http_req_duration.values;
  const p99 = httpDuration['p(99)'];

  const tp = data.metrics.tp_count ? data.metrics.tp_count.values.count : 0;
  const tn = data.metrics.tn_count ? data.metrics.tn_count.values.count : 0;
  const fp = data.metrics.fp_count ? data.metrics.fp_count.values.count : 0;
  const fn = data.metrics.fn_count ? data.metrics.fn_count.values.count : 0;
  const errs = data.metrics.error_count ? data.metrics.error_count.values.count : 0;

  const N = tp + tn + fp + fn + errs;
  const E = fp * 1 + fn * 3 + errs * 5;
  const failures = fp + fn + errs;
  const epsilon = N > 0 ? E / N : 0;
  const failureRate = N > 0 ? failures / N : 0;

  let p99Score;
  let p99CutTriggered = false;
  if (p99 <= 0) {
    p99Score = 0;
  } else if (p99 > P99_MAX_MS) {
    p99Score = SCORE_P99_CORTE;
    p99CutTriggered = true;
  } else {
    p99Score = K * Math.log10(T_MAX_MS / Math.max(p99, P99_MIN_MS));
  }

  let detScore;
  let rateComponent = 0;
  let absolutePenalty = 0;
  let cutTriggered = false;
  if (failureRate > TX_CORTE) {
    detScore = SCORE_DET_CORTE;
    cutTriggered = true;
  } else {
    rateComponent = K * Math.log10(1 / Math.max(epsilon, EPSILON_MIN));
    absolutePenalty = -BETA * Math.log10(1 + E);
    detScore = rateComponent + absolutePenalty;
  }

  const finalScore = p99Score + detScore;

  const result = {
    run: {
      data_file: DATA_FILE,
      base_url: BASE_URL,
      target_rps: TARGET_RPS,
      hold_stage: HOLD_STAGE,
      request_timeout_ms: REQ_TIMEOUT_MS,
      pre_allocated_vus: PRE_ALLOCATED_VUS,
      max_vus: MAX_VUS,
    },
    expected: expectedStats,
    p99: p99.toFixed(2) + 'ms',
    scoring: {
      breakdown: {
        false_positive_detections: fp,
        false_negative_detections: fn,
        true_positive_detections: tp,
        true_negative_detections: tn,
        http_errors: errs,
      },
      failure_rate: +(failureRate * 100).toFixed(2) + '%',
      weighted_errors_E: E,
      error_rate_epsilon: +epsilon.toFixed(6),
      p99_score: {
        value: +p99Score.toFixed(2),
        cut_triggered: p99CutTriggered,
      },
      detection_score: {
        value: +detScore.toFixed(2),
        rate_component: cutTriggered ? null : +rateComponent.toFixed(2),
        absolute_penalty: cutTriggered ? null : +absolutePenalty.toFixed(2),
        cut_triggered: cutTriggered,
      },
      final_score: +finalScore.toFixed(2),
    },
  };

  const resultJson = JSON.stringify(result, null, 2);
  const summary =
    textSummary(data, { indent: ' ', enableColors: true }) +
    '\n\n=== Rinha Score ===\n' +
    resultJson +
    '\n';

  const output = {};
  output[RESULTS_FILE] = resultJson;
  output.stdout = summary;
  return output;
}
