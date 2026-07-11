#!/usr/bin/env bash
#
# fsnotify/mayhem/build.sh — build fsnotify's OSS-Fuzz Go fuzz target as a sanitized libFuzzer
# binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer_v2.
#
# OSS-Fuzz target (projects/fsnotify/build.sh):
#   cp $SRC/fuzz_test.go ./
#   compile_native_go_fuzzer_v2 github.com/fsnotify/fsnotify FuzzInotify FuzzInotify
# i.e. the MODERN native harness `func FuzzInotify(f *testing.F)` (fuzz_test.go, built under
# `-tags gofuzz` with go-118-fuzz-build / build_native_go_fuzzer, then linked with
# $LIB_FUZZING_ENGINE). The harness drives the inotify backend: it creates files / sub-dirs in
# a temp dir, collects the events fsnotify reports via an eventCollector (newCollector/collect/
# stop — helpers from the package's *_test.go files), builds the set of events it *expected* from
# the same operations, and cmpEvents() panics on any mismatch. The fuzzed surface is the inotify
# Watcher event pipeline (backend_inotify.go) + the event-matching logic.
#
# The harness file (fuzz_test.go) is a `package fsnotify` test file that references unexported
# *_test.go helpers (newCollector, eventCollector, mkdir, echoAppend, eventSeparator, newEvents,
# cmpEvents, join, shouldWait, …); build_native_go_fuzzer compiles it together with the package's
# test files, so those helpers resolve. go-118-fuzz-build supplies the testing.F shim.
#
# We produce:
#   /mayhem/fuzz_inotify — OSS-Fuzz target (fsnotify.FuzzInotify, go-118-fuzz-build_v2, ASan+libFuzzer)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4+ and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain is pinned under /opt/toolchains (SPEC §6.2 item 8); GOMODCACHE is set in the
# Dockerfile ENV and survives the PATCH re-run under a different $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

# The go-118-fuzz-build_v2 tool lives on PATH via /opt/toolchains/go-path/bin (set in Dockerfile).
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# Drop the OSS-Fuzz fuzz harness into the package root, exactly like projects/fsnotify/build.sh.
cp "$SRC/mayhem/fuzz_test.go" "$SRC/fuzz_test.go"

# Resolve module deps. The v2 builder generates its own in-tree `testing` shim via a build overlay,
# so (unlike the legacy go-118-fuzz-build) it does NOT need the AdamKorcz testing module dep.
go mod tidy 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: fsnotify.FuzzInotify via go-118-fuzz-build_v2 (func FuzzInotify(f *testing.F)) ─
#     This replicates compile_native_go_fuzzer_v2 -> build_native_go_fuzzer, which invokes
#     `go-118-fuzz-build_v2 -tags gofuzz -o $fuzzer.a -func FuzzInotify <abs_pkg_dir>`. The **v2**
#     builder loads the package WITH its test files (packages.Tests=true), so the harness resolves
#     the unexported *_test.go helpers (newCollector, mkdir, cmpEvents, eventSeparator, newEvents,
#     join, shouldWait, echoAppend). The legacy builder excludes *_test.go and leaves them undefined.
echo "=== building fuzz_inotify (fsnotify.FuzzInotify, go-118-fuzz-build_v2 -tags gofuzz) ==="
go-118-fuzz-build_v2 -tags gofuzz -o "$SRC/mayhem-build/fuzz_inotify.a" -func FuzzInotify "$SRC"
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_inotify.a" -o /mayhem/fuzz_inotify
echo "built /mayhem/fuzz_inotify"

echo "build.sh complete:"
ls -la /mayhem/fuzz_inotify 2>&1 || true
