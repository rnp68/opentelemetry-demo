// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { getWebInstrumentations, initializeFaro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

const { NEXT_PUBLIC_OTEL_SERVICE_NAME = '', NEXT_GRAFANA_FARO_ENDPOINT = '' } =
  typeof window !== 'undefined' ? window.ENV : {};

/**
 * Starts Grafana Faro browser monitoring (RUM + browser tracing) when a Faro
 * collector URL is configured through GRAFANA_FARO_ENDPOINT.
 *
 * Returns true when Faro was started, so the caller can fall back to the plain
 * OpenTelemetry browser tracer (FrontendTracer) otherwise. Both must not run
 * together: each would instrument the same fetch/XHR calls.
 */
const Faro = (): boolean => {
  if (!NEXT_GRAFANA_FARO_ENDPOINT) {
    return false;
  }

  initializeFaro({
    url: NEXT_GRAFANA_FARO_ENDPOINT,
    app: {
      name: NEXT_PUBLIC_OTEL_SERVICE_NAME,
    },
    instrumentations: [
      // Overwriting the array would drop the default web instrumentations.
      ...getWebInstrumentations(),
      // Browser tracing (document load, fetch, XHR, user interaction) with
      // W3C trace-context propagation to the backend services.
      new TracingInstrumentation(),
    ],
  });

  return true;
};

export default Faro;
