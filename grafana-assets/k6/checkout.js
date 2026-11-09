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
  const payload = JSON.stringify({
    userId: 'load-test-user',
    email: 'test@example.com',
    address: {
      streetAddress: '123 Test St',
      city: 'Testville',
      state: 'CA',
      country: 'US',
      zipCode: '12345',
    },
    userCurrency: 'USD',
    creditCard: {
      creditCardNumber: '4432-8015-6152-0454',
      creditCardCvv: 672,
      creditCardExpirationYear: 2030,
      creditCardExpirationMonth: 1,
    },
  });
  const params = { headers: { 'Content-Type': 'application/json' } };

  // The order is built from the user's cart, so put something in it first.
  const added = http.post(
    `${BASE_URL}/api/cart?currencyCode=USD`,
    JSON.stringify({ userId: 'load-test-user', item: { productId: '66VCHSJNUP', quantity: 1 } }),
    params
  );
  check(added, { 'item added to cart': (r) => r.status === 200 });

  const res = http.post(`${BASE_URL}/api/checkout?currencyCode=USD`, payload, params);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  sleep(1);
}
