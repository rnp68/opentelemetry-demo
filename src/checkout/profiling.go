// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
package main

import (
	"os"
	"runtime"

	otelpyroscope "github.com/grafana/otel-profiling-go"
	"github.com/grafana/pyroscope-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// profilingEnabled reports whether continuous profiling is configured.
// Profiling is opt-in: it is only started when GRAFANA_PYROSCOPE_ADDR is set.
func profilingEnabled() bool {
	return os.Getenv("GRAFANA_PYROSCOPE_ADDR") != ""
}

// wrapTracerProvider links profiles to traces ("span profiles") when
// profiling is enabled; otherwise it returns the provider unchanged.
func wrapTracerProvider(tp *sdktrace.TracerProvider) {
	if profilingEnabled() {
		otel.SetTracerProvider(otelpyroscope.NewTracerProvider(tp))
		return
	}
	otel.SetTracerProvider(tp)
}

// initProfilerProvider starts the Pyroscope profiler. It returns nil when
// profiling is not configured or cannot be started; the service keeps running.
//
// Environment:
//
//	GRAFANA_PYROSCOPE_ADDR       Pyroscope / Grafana Cloud Profiles URL (required to enable)
//	GRAFANA_PYROSCOPE_AUTH_USER  basic-auth user (optional)
//	GRAFANA_PYROSCOPE_AUTH_PASS  basic-auth password or token (optional)
func initProfilerProvider() *pyroscope.Profiler {
	if !profilingEnabled() {
		log.Info("GRAFANA_PYROSCOPE_ADDR not set; continuous profiling disabled")
		return nil
	}

	tags := map[string]string{}
	if val, ok := initResource().Set().Value("service.namespace"); ok && val.Type() == attribute.STRING {
		tags["namespace"] = val.AsString()
	}

	runtime.SetMutexProfileFraction(5)
	runtime.SetBlockProfileRate(5)

	profiler, err := pyroscope.Start(pyroscope.Config{
		ApplicationName:   "checkout",
		ServerAddress:     os.Getenv("GRAFANA_PYROSCOPE_ADDR"),
		BasicAuthUser:     os.Getenv("GRAFANA_PYROSCOPE_AUTH_USER"),
		BasicAuthPassword: os.Getenv("GRAFANA_PYROSCOPE_AUTH_PASS"),
		Logger:            log,
		Tags:              tags,
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU,
			pyroscope.ProfileAllocObjects,
			pyroscope.ProfileAllocSpace,
			pyroscope.ProfileInuseObjects,
			pyroscope.ProfileInuseSpace,
			pyroscope.ProfileGoroutines,
			pyroscope.ProfileMutexCount,
			pyroscope.ProfileMutexDuration,
			pyroscope.ProfileBlockCount,
			pyroscope.ProfileBlockDuration,
		},
	})
	if err != nil {
		log.Warnf("could not start Pyroscope profiler, continuing without profiling: %v", err)
		return nil
	}
	return profiler
}
