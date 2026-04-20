/**
 * HdrHistogram_c — high-dynamic-range latency histogram. Used by bun test's
 * per-test timing output and benchmark reporting.
 */

import type { Dependency } from "../source.ts";

const HDRHISTOGRAM_COMMIT = "be60a9987ee48d0abf0d7b6a175bad8d6c1585d1";

export const hdrhistogram: Dependency = {
  name: "hdrhistogram",

  source: cfg => {
    if (cfg.systemDeps.has("hdrhistogram")) {
      // nixpkgs ships hdrhistogram_c 0.11.9 from THIS exact commit (tarball
      // hash matches). <hdr/hdr_histogram.h> resolves from the toolchain
      // default include path; .so is libhdr_histogram.so.6.
      return { kind: "system", commit: HDRHISTOGRAM_COMMIT, linkFlags: ["-lhdr_histogram"], trackLibs: ["hdr_histogram"] };
    }
    return {
      kind: "github-archive",
      repo: "HdrHistogram/HdrHistogram_c",
      commit: HDRHISTOGRAM_COMMIT,
    };
  },

  build: cfg =>
    cfg.systemDeps.has("hdrhistogram")
      ? { kind: "none" }
      : {
          kind: "nested-cmake",
          args: {
            HDR_HISTOGRAM_BUILD_SHARED: "OFF",
            HDR_HISTOGRAM_BUILD_STATIC: "ON",
            // Disables the zlib-dependent log writer. We only need the in-memory
            // histogram API — serialization goes through our own code.
            HDR_LOG_REQUIRED: "DISABLED",
            HDR_HISTOGRAM_BUILD_PROGRAMS: "OFF",
          },
          libSubdir: "src",
        },

  provides: cfg =>
    cfg.systemDeps.has("hdrhistogram")
      ? { libs: [], includes: [] }  // headers via CPATH from nixpkgs dev-output
      : { libs: ["hdr_histogram_static"], includes: ["include"] },
};
