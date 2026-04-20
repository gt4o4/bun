/**
 * Google Highway — portable SIMD intrinsics with runtime dispatch. Used by
 * bun's string search (indexOf fastpaths), base64 codec, and the bundler's
 * chunk hashing.
 *
 * Highway compiles every function for multiple targets (SSE2/AVX2/NEON/etc.)
 * and picks at runtime. That's why it needs PIC — the dispatch tables are
 * function pointers.
 */

import type { Dependency, NestedCmakeBuild } from "../source.ts";

const HIGHWAY_COMMIT = "ac0d5d297b13ab1b89f48484fc7911082d76a93f";

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

    const spec: NestedCmakeBuild = {
      kind: "nested-cmake",
      pic: true,
      args: {
        HWY_ENABLE_TESTS: "OFF",
        HWY_ENABLE_EXAMPLES: "OFF",
        HWY_ENABLE_CONTRIB: "OFF",
        HWY_ENABLE_INSTALL: "OFF",
      },
    };

    // clang-cl on arm64-windows doesn't define __ARM_NEON even though NEON
    // intrinsics work. Highway's cpu-feature detection is gated on the macro,
    // so without it you get a scalar-only build. The underlying clang does
    // support NEON here — it's a clang-cl frontend quirk.
    if (cfg.windows && cfg.arm64) {
      spec.extraCFlags = ["-D__ARM_NEON=1"];
      spec.extraCxxFlags = ["-D__ARM_NEON=1"];
    }

    return spec;
  },

  provides: cfg => {
    if (cfg.systemDeps.has("highway")) {
      return { libs: [], includes: [] };
    }
    return {
      libs: ["hwy"],
      // Highway's public header is <hwy/highway.h> but it includes siblings
      // via "" paths — need both the root and the hwy/ subdir in -I.
      includes: [".", "hwy"],
    };
  },
};
