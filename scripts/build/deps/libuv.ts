/**
 * libuv — cross-platform async I/O. Bun uses it on Windows ONLY, for the
 * event loop and file I/O (Windows' IOCP model needs a proper abstraction
 * layer). On unix, bun's event loop is custom (kqueue/epoll direct).
 *
 * Built everywhere despite being windows-only at runtime, because node-api
 * addons may reference libuv symbols and expect them to link.
 */

import type { Dependency, NestedCmakeBuild } from "../source.ts";

// Latest HEAD as of pin — includes recursion bug fix #4784 (a stack
// overflow in uv__run_timers with many concurrent timers).
const LIBUV_COMMIT = "f3ce527ea940d926c40878ba5de219640c362811";

export const libuv: Dependency = {
  name: "libuv",

  source: cfg => {
    if (cfg.systemDeps.has("libuv")) {
      // nixpkgs-unstable ships libuv 1.52.0; bun's pin f3ce527e is ~45
      // commits behind 1.52.0 but in its ancestry. On Linux bun only links
      // libuv so node-api addons can resolve symbols against it; the C API
      // is stable across these commits, so the drift is low-risk on this
      // target. Revisit if behavioral regressions show up in addon users.
      return { kind: "system", linkFlags: ["-luv"], trackLibs: ["uv"] };
    }
    return {
      kind: "github-archive",
      repo: "libuv/libuv",
      commit: LIBUV_COMMIT,
    };
  },

  // Windows-only patch. Kept in the identity hash regardless of systemDeps
  // so identity stays stable across configurations — the patch is a no-op
  // when source is kind:"system" (no fetch → no apply).
  patches: ["patches/libuv/fix-win-pipe-cancel-race.patch"],

  build: cfg => {
    if (cfg.systemDeps.has("libuv")) {
      return { kind: "none" };
    }
    const spec: NestedCmakeBuild = {
      kind: "nested-cmake",
      targets: ["uv_a"],
      args: {
        LIBUV_BUILD_SHARED: "OFF",
        LIBUV_BUILD_TESTS: "OFF",
        LIBUV_BUILD_BENCH: "OFF",
      },
    };

    if (cfg.windows) {
      // libuv's windows code has a handful of int-conversion warnings that
      // clang-cl elevates. /DWIN32 /D_WINDOWS are what MSVC's cmake preset
      // would add automatically; libuv's headers gate win32 paths on them.
      spec.extraCFlags = ["/DWIN32", "/D_WINDOWS", "-Wno-int-conversion"];
    }

    return spec;
  },

  provides: cfg => {
    if (cfg.systemDeps.has("libuv")) {
      // Headers come from nixpkgs libuv.dev via CPATH.
      return { libs: [], includes: [] };
    }
    return {
      // uv_a → libuv.lib on windows (the cmake target sets OUTPUT_NAME=libuv),
      // libuv's cmake sets OUTPUT_NAME=libuv on Windows to avoid conflicts
      // with system uv.lib. Unix uses the bare name.
      libs: [cfg.windows ? "libuv" : "uv"],
      includes: ["include"],
    };
  },
};
