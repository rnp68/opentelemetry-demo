import http from 'k6/http';
import { check, sleep } from 'k6';

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
  const res = http.post('http://localhost:8080/api/checkout', payload, params);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  sleep(1);
}
