// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
package main

import "testing"

func TestPodNamePattern(t *testing.T) {
	cases := []struct {
		pod  string
		want string
	}{
		{"product-catalog-6d5f7c9b8-x2x4z", "product-catalog"},
		{"product-catalog2-6d5f7c9b8-x2x4z", "product-catalog2"},
		{"opentelemetry-demo-product-catalog2-6d5f7c9b8-x2x4z", "product-catalog2"},
		{"frontend-6d5f7c9b8-x2x4z", ""},
		{"myproduct-catalog-6d5f7c9b8-x2x4z", ""},
	}
	for _, c := range cases {
		got := ""
		if m := podNamePattern.FindStringSubmatch(c.pod); len(m) > 1 {
			got = m[1]
		}
		if got != c.want {
			t.Errorf("pod %q: got %q, want %q", c.pod, got, c.want)
		}
	}
}
