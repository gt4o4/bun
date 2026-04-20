/**
 * Brotli — high-ratio compression. Backs the `br` Content-Encoding in fetch
 * and bun's --compress bundler flag.
 */

import type { Dependency, NestedCmakeBuild } from "../source.ts";

// Upstream brotli pins releases by tag, not commit. A retag would change
// what we fetch — if that ever matters, resolve the tag to a sha and pin that.
const BROTLI_COMMIT = "v1.1.0";

export const brotli: Dependency = {
  name: "brotli",

  source: cfg => {
    if (cfg.systemDeps.has("brotli")) {
      // <brotli/{encode,decode}.h> resolve from the toolchain's default
      // include path (CPATH on Nix from buildInputs, /usr/include
      // elsewhere). nixpkgs brotli ships v1.1.0 — same as our pin.
      return {
        kind: "system",
        commit: BROTLI_COMMIT,
        linkFlags: ["-lbrotlidec", "-lbrotlienc", "-lbrotlicommon"],
        trackLibs: ["brotlidec", "brotlienc", "brotlicommon"],
      };
    }
    return {
      kind: "github-archive",
      repo: "google/brotli",
      commit: BROTLI_COMMIT,
    };
  },

  build: cfg => {
    if (cfg.systemDeps.has("brotli")) {
      return { kind: "none" };
    }
    const spec: NestedCmakeBuild = {
      kind: "nested-cmake",
      args: {
        BROTLI_BUILD_TOOLS: "OFF",
        BROTLI_EMSCRIPTEN: "OFF",
        BROTLI_DISABLE_TESTS: "ON",
      },
    };

    // LTO miscompile: on linux-x64 with AVX (non-baseline), BrotliDecompress
    // errors out mid-stream. Root cause unknown — likely an alias-analysis
    // issue around brotli's ring-buffer copy hoisting. -fno-lto sidesteps it.
    // Linux-only: clang's LTO on darwin/windows has a different codepath.
    // x64+non-baseline only: the SSE/AVX path is where the miscompile lives;
    // baseline (SSE2-only) doesn't hit it.
    if (cfg.linux && cfg.x64 && !cfg.baseline) {
      spec.extraCFlags = ["-fno-lto"];
    }

    return spec;
  },

  provides: cfg => {
    if (cfg.systemDeps.has("brotli")) {
      // Link flags + tracking are already declared on the system Source;
      // nothing extra to provide here.
      return { libs: [], includes: [] };
    }
    return {
      // Order matters for static linking: common must come LAST on the link
      // line (dec and enc both depend on it — unresolved symbols from dec/enc
      // are searched for in later libs).
      libs: ["brotlidec", "brotlienc", "brotlicommon"],
      includes: ["c/include"],
    };
  },
};
