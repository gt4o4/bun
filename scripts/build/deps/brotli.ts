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

  // Always fetch — bun's C++ side reads <brotli/encode.h> / <brotli/decode.h>
  // from the bundled `c/include`. Even in `cfg.systemDeps.has("brotli")` mode
  // we keep the source so the included header set matches the version we
  // pinned, decoupling from whatever brotli nixpkgs happens to ship.
  source: () => ({
    kind: "github-archive",
    repo: "google/brotli",
    commit: BROTLI_COMMIT,
  }),

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
      return {
        libs: [],
        includes: ["c/include"],
        // Link order: dec/enc both reference common, common LAST.
        linkFlags: ["-lbrotlidec", "-lbrotlienc", "-lbrotlicommon"],
        trackLibs: ["brotlidec", "brotlienc", "brotlicommon"],
      };
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
