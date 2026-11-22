#!/bin/bash
# Builds llama.cpp b11963 for the detected GPU arch with the patches in patches/series into /content/llama/bin, about 2 minutes.
set -uo pipefail
COMMIT=39febd2adb947b70da35e95f9351b3bf58ad170a
R=/content/res; P=/content/vm/patches; S=/content/src/llama.cpp; D=/content/llama/bin
st() { echo "$(date +%T) $*" >> $R/build.txt; }
if [ -x "$D/llama-server" ]; then st "build cached"; exit 0; fi
st "build start"
command -v cmake > /dev/null || pip install -q cmake > $R/build_cmake.log 2>&1
mkdir -p /content/src
if [ -d "$S/.git" ]; then
  git -C "$S" checkout -- . && git -C "$S" clean -fd > /dev/null 2>&1
else
  git clone -q --depth 1 --branch b11963 https://github.com/ggml-org/llama.cpp.git $S || { st "clone FAILED"; exit 1; }
fi
[ "$(git -C $S rev-parse HEAD)" = "$COMMIT" ] || { st "commit mismatch $(git -C $S rev-parse HEAD) FAILED"; exit 1; }
for p in $(grep -v '^#' $P/series); do python3 $P/$p $S >> $R/build.txt 2>&1 || { st "patch $p FAILED"; exit 1; }; done
export PATH=/usr/local/cuda/bin:$PATH
CUDA_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. ')
[ -n "$CUDA_ARCH" ] || CUDA_ARCH=120
JOBS=$(nproc 2>/dev/null || echo 16)
st "cmake arch=$CUDA_ARCH jobs=$JOBS"
cmake -S $S -B $S/build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH -DLLAMA_BUILD_TESTS=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=ON \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_WEBUI=OFF \
  -DCMAKE_BUILD_TYPE=Release > $R/build_cmake.log 2>&1 || { st "cmake FAILED: $(tail -3 $R/build_cmake.log | tr '\n' ' ')"; exit 1; }
nice -n 5 cmake --build $S/build -j "$JOBS" --target llama-server > $R/build_make.log 2>&1 || { st "make FAILED: $(grep -m3 -i error $R/build_make.log | tr '\n' ' ')"; exit 1; }
mkdir -p $D && cp -a $S/build/bin/* $D/ && find $S/build -name "*.so*" -exec cp -a {} $D/ \;
for l in libcudart.so libcublas.so libcublasLt.so; do cp -a /usr/local/cuda/lib64/$l* $D/ 2>/dev/null; done
st "build done"
