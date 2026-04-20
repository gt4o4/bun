/**
 * Google Highway — portable SIMD intrinsics with runtime dispatch. Used by
 * bun's string search (indexOf fastpaths), base64 codec, and the bundler's
 * chunk hashing.
 *
 * Highway compiles every function for multiple targets (SSE2/AVX2/NEON/etc.)
 * and picks at runtime. Unlike zlib-ng it needs NO per-file `-m` flags or
 * generated config — `hwy/foreach_target.h` re-includes each TU body once
 * per ISA wrapped in `#pragma clang attribute push(target("..."))`, so a
 * single baseline compile per .cc emits all variants.
 */

import type { Dependency, DirectBuild } from "../source.ts";

const HIGHWAY_COMMIT = "2607d3b5b0113992fe84d3848859eae13b3b52c1";

export const highway: Dependency = {
  name: "highway",

  source: cfg => {
    if (cfg.systemDeps.has("highway")) {
      // nixpkgs ships libhwy.a only (no .so build); resolveSystemLib falls
      // through to the .a probe. Same template-instantiation cost in bun's
      // own TUs, but skips the github fetch + nested cmake build entirely
      // (~50 MB source + 2-3 min cmake). Headers <hwy/highway.h> resolve
      // from nixpkgs libhwy.outPath/include via the toolchain's CPATH.
      return { kind: "system", commit: HIGHWAY_COMMIT, linkFlags: ["-lhwy"], trackLibs: ["hwy"] };
    }
    return {
      kind: "github-archive",
      repo: "google/highway",
      commit: HIGHWAY_COMMIT,
    };
  },

  patches: ["patches/highway/silence-warnings.patch"],

  build: cfg => {
    if (cfg.systemDeps.has("highway")) return { kind: "none" };

    const spec: DirectBuild = {
      kind: "direct",
      lang: "cxx",
      pic: true,
      sources: [
        "hwy/abort.cc",
        "hwy/aligned_allocator.cc",
        "hwy/nanobenchmark.cc",
        "hwy/per_target.cc",
        "hwy/perf_counters.cc",
        "hwy/print.cc",
        "hwy/profiler.cc",
        "hwy/targets.cc",
        "hwy/timer.cc",
      ],
      includes: ["."],
      defines: { HWY_STATIC_DEFINE: true },
      // -fno-exceptions / -fmath-errno aren't CLOptions (clang-cl warns
      // "unknown argument ignored"). globalFlags supplies /EHs-c- and /GR-
      // on Windows; upstream's MSVC branch additionally sets the STL macro.
      cflags: cfg.windows ? ["-D_HAS_EXCEPTIONS=0"] : ["-fno-exceptions", "-fmath-errno"],
    };

    // clang-cl on arm64-windows doesn't define __ARM_NEON even though NEON
    // intrinsics work. Highway's cpu-feature detection is gated on the macro,
    // so without it you get a scalar-only build. The underlying clang does
    // support NEON here — it's a clang-cl frontend quirk.
    if (cfg.windows && cfg.arm64) spec.cflags!.push("-D__ARM_NEON=1");

    return spec;
  },

  provides: cfg => {
    if (cfg.systemDeps.has("highway")) {
      return { libs: [], includes: [] };
    }
    return {
      libs: [],
      // Highway's public header is <hwy/highway.h> but it includes siblings
      // via "" paths — need both the root and the hwy/ subdir in -I.
      includes: [".", "hwy"],
    };
  },
};
