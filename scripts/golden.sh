#!/bin/zsh
# The plugin against in-process MLXServeEngine: meshes made on the signed bundle the way Gaea runs them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through trellis2-inproc with the
# lane configurations, the BiRefNet matting step and the request the worker uses. Each pair must be the same GLB, byte
# for byte; each must be a GLB 2.0 (one JSON and one BIN chunk) with a texture of the size asked for.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases:
# - TRELLIS.2 at 512: the fox photo with its background removed (BiRefNet), the fox already cut out (its alpha used as it
#   is), the fox kept whole, another seed, faces and texture size, and the detail maps;
# - Pixal3D at 1024: its bf16 and bf16-lowmem lanes (the same GLB), and another field of view.
# FULL=1 adds TRELLIS.2 at 1024 and 1536 and Pixal3D at 1536 (7 to 11 minutes each, twice).
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/trellis2.gaeaplugin
F=$ROOT/Tests/Fixtures
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product trellis2-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/trellis2-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# TRELLIS.2 golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }
# glb <file>: "chunks=JSON,BIN texture=<side> faces=<n>" from the file itself.
glb() { python3 - $1 <<'PY'
import json, struct, sys
d = open(sys.argv[1], 'rb').read()
magic, version, length = struct.unpack('<4sII', d[:12])
chunks, i, js = [], 12, None
while i < length:
    n, t = struct.unpack('<I4s', d[i:i + 8]); chunks.append(t.decode().strip('\x00')); body = d[i + 8:i + 8 + n]
    if t == b'JSON': js = json.loads(body)
    i += 8 + n
faces = sum(js['accessors'][p['indices']]['count'] // 3 for m in js['meshes'] for p in m['primitives'])
side = 0
binstart = 12 + 8 + struct.unpack('<I', d[12:16])[0] + 8
for im in js.get('images', []):
    bv = js['bufferViews'][im['bufferView']]; png = d[binstart + bv.get('byteOffset', 0):binstart + bv.get('byteOffset', 0) + 24]
    if png[:4] == b'\x89PNG': side = max(side, *struct.unpack('>II', png[16:24]))
print(f"v{version} chunks={','.join(chunks)} texture={side} faces={faces}")
PY
}

# case <name> <model> <lane> <image> <background> <seed> <faces> <texture> [extensions JSON] [inproc flags…]
case_() {
  local name=$1 model=$2 lane=$3 image=$4 background=$5 seed=$6 faces=$7 texture=$8 ext=${9:-}; shift 9 2>/dev/null || shift $#
  local resolution=${model##*-} extra=()
  [[ -n $ext ]] && extra=(--model-params $ext)
  $CHECK $B --operation mesh.generate --model $model --lane $lane --seed $seed $extra \
    --params "{\"max_faces\":$faces,\"texture_size\":$texture,\"background\":\"$background\",\"resolution\":$resolution}" --input "image=$image" \
    --models-root "$MODELS" --budget 100000000000 --timeout 3600 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.glb
  $INPROC --image $image --model $model --lane $lane --seed $seed --faces $faces --texture-size $texture --background $background "$@" \
    --models-root "$MODELS" --out $OUT/$name-inproc.glb 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  local a=$(shasum -a 256 $OUT/$name-gpp.glb 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.glb 2>/dev/null | cut -c1-16)
  local facts=$(glb $OUT/$name-gpp.glb 2>/dev/null)
  if [[ -n $a && $a == $b && $facts == "v2 chunks=JSON,BIN texture=$texture "* ]]; then pass=$((pass+1)); say "PASS  $name: the same GLB, sha256 $a…, $facts"
  else fail=$((fail+1)); say "FAIL  $name: $a… / $b…, $facts (want v2 chunks=JSON,BIN texture=$texture)"; fi
}
# has <glb> <python expression over g, the GLB's JSON>: a fact about the file
has() { python3 - $1 "$2" <<'PY'
import json, struct, sys
d = open(sys.argv[1], 'rb').read(); n = struct.unpack('<I', d[12:16])[0]; g = json.loads(d[20:20 + n])
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

case_ remove trellis2-512 bf16 $F/fox.png remove 42 20000 512
case_ cutout trellis2-512 bf16 $F/fox-cutout.png alpha 42 20000 512
case_ keep trellis2-512 bf16 $F/fox.png keep 42 20000 512
case_ seed7 trellis2-512 bf16 $F/fox.png remove 7 60000 1024
# The detail maps (0.2.0): a normal map with TANGENT and an occlusion map, on the same geometry as the plain run.
case_ maps trellis2-512 bf16 $F/fox.png remove 42 20000 512 '{"x-trellis2.normal_map":true,"x-trellis2.ao_map":true}' --normal-map --ao-map
if has $OUT/maps-gpp.glb "all('normalTexture' in m and 'occlusionTexture' in m for m in g['materials']) and all('TANGENT' in p['attributes'] for me in g['meshes'] for p in me['primitives'])"; then
  pass=$((pass+1)); say "PASS  maps: the materials carry a normal and an occlusion texture, and the mesh TANGENT"
else fail=$((fail+1)); say "FAIL  maps: no normal or occlusion texture, or no TANGENT"; fi
if has $OUT/remove-gpp.glb "not any('normalTexture' in m or 'occlusionTexture' in m for m in g['materials'])"; then
  pass=$((pass+1)); say "PASS  remove: without the options, neither map is written"
else fail=$((fail+1)); say "FAIL  remove: a detail map without being asked"; fi
# Pixal3D (0.2.0): both lanes against in-process, and the bf16-lowmem lane's GLB is the bf16 lane's.
case_ pixal3d-bf16 pixal3d-1024 bf16 $F/fox.png remove 42 60000 1024
case_ pixal3d-lowmem pixal3d-1024 bf16-lowmem $F/fox.png remove 42 60000 1024
if cmp -s $OUT/pixal3d-bf16-gpp.glb $OUT/pixal3d-lowmem-gpp.glb; then pass=$((pass+1)); say "PASS  pixal3d: the bf16-lowmem lane's GLB is the bf16 lane's, byte for byte"
else fail=$((fail+1)); say "FAIL  pixal3d: the two lanes' GLBs differ"; fi
case_ pixal3d-fov49 pixal3d-1024 bf16 $F/fox.png remove 42 60000 1024 '{"x-pixal3d.fov":49}' --fov 49
if ! cmp -s $OUT/pixal3d-fov49-gpp.glb $OUT/pixal3d-bf16-gpp.glb; then pass=$((pass+1)); say "PASS  pixal3d: a 49° field of view gives another mesh than 20°"
else fail=$((fail+1)); say "FAIL  pixal3d: the field of view changed nothing"; fi
if [[ ${FULL:-0} == 1 ]]; then
  case_ r1024 trellis2-1024 bf16 $F/fox.png remove 42 100000 1024
  case_ r1536 trellis2-1536 bf16 $F/fox.png remove 42 100000 2048
  case_ pixal3d-1536 pixal3d-1536 bf16 $F/fox.png remove 42 100000 2048
fi

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
