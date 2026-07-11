#!/usr/bin/env bash
#
# cups-filters/mayhem/build.sh — build OpenPrinting/cups-filters' OSS-Fuzz harness `fuzz_pdf`
# as a sanitized libFuzzer target (+ a standalone reproducer), AND build cups-filters' own
# self-contained fontembed unit tests (test_analyze / test_pdf / test_ps) for mayhem/test.sh.
#
# The OSS-Fuzz harness targets the cups-filters 1.x branch (the branch OSS-Fuzz actually builds,
# cloning `-b 1.x`). The modern `master` restructured the codebase into libcupsfilters/libppd and
# dropped filter/pdfutils.* and the fontembed/ tree the harness links against. To stay additive on
# master while keeping the 1.x harness surface alive, the needed sources are vendored into
# mayhem/vendor/ (filter/pdfutils.c + fontembed/*.c) — a one-time snapshot of the 1.x originals.
#
# Fuzzed surface (single harness, fuzz_pdf, from OpenPrinting/fuzzing):
#   filter/pdfutils.c — the pdfOut_* PDF *writer* used by cups-filters' image/text-to-PDF filters.
#   The harness embeds the attacker-controlled bytes verbatim as a page CONTENT STREAM and drives
#   pdfOut_new / pdfOut_begin_pdf / pdfOut_add_xref / pdfOut_printf / pdfOut_add_page /
#   pdfOut_finish_pdf / pdfOut_free. pdfutils.c links the self-contained fontembed library
#   (TrueType/OpenType SFNT parser + PDF font-embedding) — no poppler/qpdf/cups/freetype needed
#   for this harness, so the build stays light.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/
# STANDALONE_FUZZ_MAIN/SRC/OUT). We compile pdfutils.c + the whole fontembed library WITH
# $SANITIZER_FLAGS so the parsed/emitted code (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: DWARF < 4 required (§6.2 item 10). clang-19 emits DWARF-5 by default; be explicit.
# Threaded AFTER $SANITIZER_FLAGS so -gdwarf-3 takes precedence over any -g in SANITIZER_FLAGS.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS SRC OUT

cd "$SRC"
git config --global --add safe.directory "$SRC" 2>/dev/null || true

HARNESS_DIR="$SRC/mayhem/harnesses"
VENDOR_DIR="$SRC/mayhem/vendor"

# pdfutils.c #include "pdfutils.h" and "fontembed/embed.h"; the fontembed sources #include their
# own headers by bare name — so -I<vendor/filter> -I<vendor> -I<vendor/fontembed> covers everything.
# -fcommon tolerates the legacy duplicate tentative definitions (the OSS-Fuzz build passes
# -Wl,--allow-multiple-definition for the same reason); we keep it additive and out of the link line.
INC="-I$VENDOR_DIR/filter -I$VENDOR_DIR -I$VENDOR_DIR/fontembed"
CFLAGS_BUILD="$SANITIZER_FLAGS $DEBUG_FLAGS $INC -fcommon"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

FONTEMBED_SRCS="aglfn13 dynstring embed embed_pdf embed_sfnt fontfile frequent sfnt sfnt_subset"

# ── 1) libfontembed.a (the SFNT/TTF parser + PDF font embedder) WITH sanitizers ───────────────────
OBJS=()
for s in $FONTEMBED_SRCS; do
  obj="$BUILD/fe_$s.o"
  $CC $CFLAGS_BUILD -c "$VENDOR_DIR/fontembed/$s.c" -o "$obj"
  OBJS+=("$obj")
done
# pdfutils.c (the fuzzed PDF writer)
$CC $CFLAGS_BUILD -c "$VENDOR_DIR/filter/pdfutils.c" -o "$BUILD/pdfutils.o"
OBJS+=("$BUILD/pdfutils.o")

LIBCF="$BUILD/libcupsfilters_pdf.a"
rm -f "$LIBCF"; ar rcs "$LIBCF" "${OBJS[@]}"

# Standalone driver object (no libFuzzer runtime; reads one input file at a time).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 2) Build the harness twice: libFuzzer (-> $OUT/fuzz_pdf) + standalone reproducer ──────────────
# libFuzzer target
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/fuzz_pdf.c" $LIB_FUZZING_ENGINE "$LIBCF" \
    -o "$OUT/fuzz_pdf"

# standalone reproducer (no libFuzzer runtime)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/fuzz_pdf.c" "$BUILD/standalone_main.o" "$LIBCF" \
    -o "$OUT/fuzz_pdf-standalone"

echo "built fuzz_pdf (+ standalone)"

# ── 3) Build cups-filters' OWN self-contained fontembed unit tests with NORMAL flags (clean tree)
#       so test.sh only RUNS them. These parse a real TrueType font (DejaVuSans.ttf) through the
#       SFNT parser and emit a PDF/PS — a golden parse+emit oracle over the same code the fuzzer
#       hits. No autotools/poppler/qpdf needed: we compile the three test programs directly against
#       libfontembed, and synthesise the one config.h symbol they use (TESTFONT). ──────────────────
TESTBUILD="$SRC/mayhem-tests"
mkdir -p "$TESTBUILD"

# locate a TrueType test font (DejaVuSans.ttf is installed via the Dockerfile's fonts-dejavu-core).
TESTFONT="$(find /usr/share/fonts -name 'DejaVuSans.ttf' 2>/dev/null | head -1 || true)"
[ -n "$TESTFONT" ] || TESTFONT="$(find /usr/share/fonts -name '*.ttf' 2>/dev/null | head -1 || true)"

# config.h shim: the test programs #include "config.h" purely for the TESTFONT macro.
cat > "$TESTBUILD/config.h" <<EOF
#ifndef MAYHEM_CONFIG_H
#define MAYHEM_CONFIG_H
#define TESTFONT "${TESTFONT}"
#endif
EOF

# fontembed library with NORMAL flags (no sanitizer noise / no benign-UB aborts in the oracle).
TEST_OBJS=()
for s in $FONTEMBED_SRCS; do
  obj="$TESTBUILD/fe_$s.o"
  $CC -O2 -g $INC -fcommon -c "$VENDOR_DIR/fontembed/$s.c" -o "$obj"
  TEST_OBJS+=("$obj")
done
LIBFE_TEST="$TESTBUILD/libfontembed.a"
rm -f "$LIBFE_TEST"; ar rcs "$LIBFE_TEST" "${TEST_OBJS[@]}"

for t in test_analyze test_pdf test_ps; do
  $CC -O2 -g $INC -I"$TESTBUILD" -fcommon \
      "$VENDOR_DIR/fontembed/$t.c" "$LIBFE_TEST" \
      -o "$TESTBUILD/$t"
  echo "built test $t"
done

echo "build.sh complete:"
ls -la "$OUT/fuzz_pdf" "$OUT/fuzz_pdf-standalone" 2>&1 || true
