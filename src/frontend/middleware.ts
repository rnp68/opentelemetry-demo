// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { NextRequest, NextResponse } from 'next/server';
import { trace } from '@opentelemetry/api';

/**
 * Exposes the trace context of the page request in a `server-timing` header
 * (traceparent) so Faro can link the browser's document load to the server span.
 */
export function middleware(_request: NextRequest) {
  const response = NextResponse.next();
  const current = trace.getActiveSpan();

  if (current) {
    const { traceId, spanId } = current.spanContext();
    response.headers.set('server-timing', `traceparent;desc="00-${traceId}-${spanId}-01"`);
  }
  return response;
}
