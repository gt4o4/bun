/**
 * libuv — cross-platform async I/O. Bun uses it on Windows ONLY, for the
 * event loop and file I/O (Windows' IOCP model needs a proper abstraction
 * layer). On unix, bun's event loop is custom (kqueue/epoll direct).
 *
 * On POSIX, node-api addons that reference libuv symbols are served by
 * src/jsc/bindings/uv-posix-stubs.c + uv-posix-polyfills*.c, with headers
 * from src/jsc/bindings/libuv/ (see flags.ts) — vendor libuv is not built.
 */

import type { Dependency } from "../source.ts";

// Tip of oven-sh/libuv's `bun` branch — upstream f3ce527e + the win-pipe
// CancelIoEx race fix + ConPTY support in uv_spawn. To bump upstream, rebase
// the `bun` branch and update this SHA.
const LIBUV_COMMIT = "4dcfac4780d394e0dc2d3fb30335ca01b553eb46";

// prettier-ignore
const SHARED = [
  "fs-poll", "idna", "inet", "random", "strscpy", "strtok", "thread-common",
  "threadpool", "timer", "uv-common", "uv-data-getter-setters", "version",
];

// prettier-ignore
const WIN = [
  "async", "core", "detect-wakeup", "dl", "error", "fs", "fs-event",
  "getaddrinfo", "getnameinfo", "handle", "loop-watcher", "pipe", "thread",
  "poll", "process", "process-stdio", "signal", "snprintf", "stream", "tcp",
  "tty", "udp", "util", "winapi", "winsock",
];

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
      repo: "oven-sh/libuv",
      commit: LIBUV_COMMIT,
    };
  },

  // Windows: only platform where bun actually uses libuv at runtime.
  // Non-windows + non-systemDeps: dep is disabled (node-api stubs are in-tree).
  enabled: cfg => cfg.windows || cfg.systemDeps.has("libuv"),

  build: cfg => {
    if (cfg.systemDeps.has("libuv")) {
      return { kind: "none" };
    }
    return {
      kind: "direct",
      sources: [...SHARED.map(s => `src/${s}.c`), ...WIN.map(s => `src/win/${s}.c`)],
      includes: ["include", "src"],
      defines: {
        WIN32_LEAN_AND_MEAN: true,
        _CRT_DECLARE_NONSTDC_NAMES: 0,
        WIN32: true,
        _WINDOWS: true,
      },
      cflags: [
        // Hex literal required — sdkddkver.h token-pastes `ver##0000`.
        "-D_WIN32_WINNT=0x0A00",
        "/clang:-fno-strict-aliasing",
        "-Wno-int-conversion",
        "/wd4996",
      ],
    };
  },

  provides: cfg => {
    if (cfg.systemDeps.has("libuv")) {
      // Headers come from nixpkgs libuv.dev via CPATH.
      return { libs: [], includes: [] };
    }
    return {
      libs: [],
      includes: ["include"],
    };
  },
};
