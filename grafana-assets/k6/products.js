// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//
// Target: set DEMO_TARGET_URL (k6 run -e DEMO_TARGET_URL=https://... or the same
// environment variable for `gcx k6`), default http://localhost:8080.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.DEMO_TARGET_URL || 'http://localhost:8080';

export const options = {
  vus: 10,
  duration: '30s',
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/api/products`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  sleep(1);
}
