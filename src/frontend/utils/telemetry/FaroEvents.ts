// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { faro } from '@grafana/faro-web-sdk';

/**
 * Safe wrappers around the Faro API. Faro is only initialized when
 * GRAFANA_FARO_ENDPOINT is set (and never on the server), so `faro.api` may be
 * undefined; these helpers do nothing in that case.
 */

export const pushFaroEvent = (name: string, attributes?: Record<string, string>) => {
  faro.api?.pushEvent(name, attributes);
};

export const pushFaroPage = (name: string, attributes: Record<string, string> = {}) => {
  faro.api?.pushEvent('page', { name, ...attributes });
};

export const pushFaroError = (error: unknown) => {
  faro.api?.pushError(error instanceof Error ? error : new Error(String(error)));
};

export const pushFaroLog = (message: string) => {
  faro.api?.pushLog([message]);
};
