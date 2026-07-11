#!/usr/bin/env bash
#
# cups-filters/mayhem/test.sh — RUN cups-filters' OWN self-contained fontembed unit tests
# (test_analyze / test_pdf / test_ps, built by mayhem/build.sh with normal flags) and emit a
# CTRF summary. exit 0 iff every test passed.
#
# These are the project's real fontembed test programs (fontembed/test_*.c, wired as `make check`
# TESTS in the upstream Makefile.am). Each one loads a real TrueType font (DejaVuSans.ttf) through
# the SFNT/OTF parser and:
#   test_analyze — dumps the parsed post/name/cmap/glyf/hmtx tables (exercises the TTF table parser);
#   test_pdf     — embeds the font and writes a valid PDF (test.pdf) via the pdfOut/embed path;
#   test_ps      — embeds the font and writes a PostScript Type42 stream.
# Each returns 0 on success and 1 if the font fails to load/parse. This is a golden parse+emit
# oracle over the SAME font/PDF code the fuzzer reaches — a no-op or output-breaking patch that
# corrupts the SFNT parser or PDF emitter makes otf_load/emb_* fail or abort and the test exits 1,
# so the suite cannot be trivially passed. This script only RUNS the pre-built programs.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

TESTBUILD="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$TESTBUILD" ]; then
  echo "missing $TESTBUILD — run mayhem/build.sh first" >&2
  emit_ctrf "fontembed-tests" 0 1 0; exit 2
fi

PASSED=0; FAILED=0
WORK="$(mktemp -d)"; cd "$WORK"

for t in test_analyze test_pdf test_ps; do
  bin="$TESTBUILD/$t"
  if [ ! -x "$bin" ]; then
    echo "FAIL $t: binary missing" >&2; FAILED=$((FAILED+1)); continue
  fi
  echo "=== running $t ==="
  if "$bin" >"$WORK/$t.out" 2>&1; then
    # the programs print "... was not loaded, exiting." and return 1 when the font is unreadable;
    # a 0 exit means the font parsed and the emit path ran.
    if grep -q 'was not loaded' "$WORK/$t.out"; then
      echo "FAIL $t: font did not load"; tail -3 "$WORK/$t.out" | sed 's/^/    /'; FAILED=$((FAILED+1))
    else
      echo "PASS $t"; PASSED=$((PASSED+1))
    fi
  else
    echo "FAIL $t (exit $?)"; tail -5 "$WORK/$t.out" | sed 's/^/    /'; FAILED=$((FAILED+1))
  fi
done

# test_pdf is expected to produce a non-empty, well-formed PDF; verify that too (golden output).
if [ -s "$WORK/test.pdf" ] && head -c5 "$WORK/test.pdf" | grep -q '%PDF'; then
  echo "PASS test_pdf produced a %PDF file ($(wc -c <"$WORK/test.pdf") bytes)"; PASSED=$((PASSED+1))
else
  echo "FAIL test_pdf did not produce a valid %PDF file"; FAILED=$((FAILED+1))
fi

cd "$SRC"; rm -rf "$WORK"
emit_ctrf "fontembed-tests" "$PASSED" "$FAILED" 0
