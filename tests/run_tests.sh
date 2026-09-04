#!/bin/zsh
# One-command test runner for nszcli.
# Usage: ./run_tests.sh [--regen]   (--regen also regenerates test data first)
set -e
cd "$(dirname "$0")/.."

PY="${PYTHON:-$(command -v python3)}"

if [[ "$1" == "--regen" ]]; then
  echo "[1/4] Regenerating test data..."
  (cd tests && "$PY" make_test_nsz.py)
else
  echo "[1/4] Keeping existing test data."
fi

echo "[2/4] Building..."
swift build 2>&1 | tail -1
BIN=$(swift build --show-bin-path)

echo "[3/4] Running CLI on all cases..."
pass=0; fail=0
for f in tests/testdata/*.nsz; do
  name=$(basename "$f" .nsz)
  out="/tmp/nszcli_test/$name"
  rm -rf "$out" && mkdir -p "$out"
  # NOTE: -o directory must exist; CLI does not create it
  if "$BIN/nszcli" "$f" -o "$out" > /dev/null 2>&1; then :; fi
  echo "--- $name"
  "$BIN/nszcli" "$f" -o "$out" 2>&1 | grep -E "VERIFIED|MISMATCH|ERROR" || true
done

echo "[4/4] Byte-level comparison against original .nsp..."
"$PY" - <<'EOF'
import struct, os, sys

BASE = os.path.join(os.path.dirname(os.path.abspath(".")), "")  # unused fallback
PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) if "__file__" in dir() else os.getcwd()

def entries_of(path):
    data = open(path, "rb").read()
    _, count, strsize = struct.unpack_from("<4sII", data, 0)
    st = data[0x10+count*0x18 : 0x10+count*0x18+strsize]
    base = 0x10+count*0x18+strsize  # PFS0 spec: offsets relative to data start
    out = []
    for i in range(count):
        off, size, nameoff = struct.unpack_from("<QQI", data, 0x10+i*0x18)
        name = st[nameoff:st.index(b"\0", nameoff)].decode()
        out.append((name, base+off, size))
    return out, data

cases = [f[:-4] for f in sorted(os.listdir("tests/testdata")) if f.endswith(".nsz")]
allok = True
for case in cases:
    oe, od = entries_of(f"/tmp/nszcli_test/{case}/{case}.nsp")
    ge, gd = entries_of(f"tests/testdata/{case}.nsp")
    gmap = {n.rsplit('.',1)[0]: gd[o:o+s] for n,o,s in ge}
    ok = True
    for n,o,s in oe:
        stem = n.rsplit('.',1)[0]
        if stem in gmap and od[o:o+s] != gmap[stem]:
            print(f"  FAIL {case}: {n} byte diff"); ok = False
    if ok:
        print(f"  PASS {case}")
    allok &= ok
print("===== ALL PASS =====" if allok else "===== FAILURES =====")
sys.exit(0 if allok else 1)
EOF
