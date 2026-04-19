/**
 * Zstandard — fast compression with a good ratio/speed tradeoff. Backs
 * bun's install cache and the `zstd` Content-Encoding in fetch.
 *
 * In `cfg.systemDeps.has("zstd")` mode (Penryn profile) we still fetch the
 * source — build.zig::translate_c hardcodes `vendor/zstd/lib` as an include
 * path so it can @cImport zstd.h. Skipping the fetch would break the zig
 * side. We just skip the static-archive build and link `-lzstd` (the system
 * shared lib, ~600 KB) instead, so multiple bun processes share the .text
 * pages.
 */

import type { Dependency } from "../source.ts";

const ZSTD_COMMIT = "f8745da6ff1ad1e7bab384bd1f9d742439278e99";

export const zstd: Dependency = {
  name: "zstd",
  versionMacro: "ZSTD_HASH",

  // Always fetch — build.zig translate_c needs the headers either way.
  source: () => ({
    kind: "github-archive",
    repo: "facebook/zstd",
    commit: ZSTD_COMMIT,
  }),

  build: cfg => {
    if (cfg.systemDeps.has("zstd")) {
      return { kind: "none" };
    }
    return {
      kind: "nested-cmake",
      targets: ["libzstd_static"],
      // zstd's repo root has a Makefile; the cmake build files live under
      // build/cmake/. (They support meson too — build/meson/ — but we stick
      // with cmake for consistency.)
      sourceSubdir: "build/cmake",
      args: {
        ZSTD_BUILD_STATIC: "ON",
        ZSTD_BUILD_PROGRAMS: "OFF",
        ZSTD_BUILD_TESTS: "OFF",
        ZSTD_BUILD_CONTRIB: "OFF",
      },
      libSubdir: "lib",
    };
  },

  provides: cfg => {
    if (cfg.systemDeps.has("zstd")) {
      return {
        // No static archive (build was skipped).
        libs: [],
        // Headers still come from the fetched source so build.zig + bun's
        // C++ sides both see the version we pinned. nixpkgs's zstd headers
        // would also work in principle but matching commits removes a class
        // of "system zstd is older than what bun expects" surprises.
        includes: ["lib"],
        linkFlags: ["-lzstd"],
        trackLibs: ["zstd"],
      };
    }
    return {
      // Windows: cmake appends "_static" to distinguish from the DLL import lib.
      libs: [cfg.windows ? "zstd_static" : "zstd"],
      // Headers are in the SOURCE repo at lib/ (zstd.h, zdict.h).
      includes: ["lib"],
    };
  },
};
