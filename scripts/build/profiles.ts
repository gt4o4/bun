/**
 * Build profiles — named configuration presets.
 *
 * Stateless: every `bun run build --profile=X` resolves fresh. No persistence,
 * no stickiness. To override a single field, pass CLI flags on top of a profile.
 *
 * Each profile is a `PartialConfig`; `resolveConfig()` fills the rest with
 * defaults derived from the target platform + profile values.
 *
 * ## Naming convention
 *
 * `<buildtype>[-<webkit-mode>][-<feature>]`
 *
 *   debug              → Debug build, prebuilt WebKit (the default)
 *   debug-local        → Debug build, local WebKit (you cloned vendor/WebKit/)
 *   release            → Release build, prebuilt WebKit (LTO, as CI ships)
 *   release-local      → Release build, local WebKit
 *   release-assertions → Release + runtime assertions enabled
 *   release-asan       → Release + address sanitizer
 *   ci-build           → what CI runs: the full build, linked from an object archive
 *
 * If you don't specify a profile, `debug` is used.
 */

import type { PartialConfig } from "./config.ts";
import { BuildError } from "./error.ts";

export type ProfileName = keyof typeof profiles;

export const profiles = {
  /** Default local dev: debug + prebuilt WebKit. ASAN defaults on for supported platforms. */
  debug: {
    buildType: "Debug",
    webkit: "prebuilt",
  },

  /** Debug with local WebKit (user clones vendor/WebKit/). */
  "debug-local": {
    buildType: "Debug",
    webkit: "local",
  },

  /** Debug without ASAN — faster builds, less safety. */
  "debug-no-asan": {
    buildType: "Debug",
    webkit: "prebuilt",
    asan: false,
  },

  /**
   * Android aarch64 cross-compile. Requires ANDROID_NDK_ROOT.
   * Sanitizers are forced off in resolveConfig() regardless of profile.
   */
  android: {
    buildType: "Debug",
    os: "linux",
    arch: "aarch64",
    abi: "android",
    webkit: "prebuilt",
  },

  "android-release": {
    buildType: "Release",
    os: "linux",
    arch: "aarch64",
    abi: "android",
    webkit: "prebuilt",
  },

  /**
   * FreeBSD x64 cross-compile. Requires FREEBSD_SYSROOT (extracted base.txz).
   * Sanitizers are forced off in resolveConfig() regardless of profile.
   */
  freebsd: {
    buildType: "Debug",
    os: "freebsd",
    arch: "x64",
    webkit: "prebuilt",
  },

  "freebsd-arm64": {
    buildType: "Debug",
    os: "freebsd",
    arch: "aarch64",
    webkit: "prebuilt",
  },

  "freebsd-release": {
    buildType: "Release",
    os: "freebsd",
    arch: "x64",
    webkit: "prebuilt",
  },

  /**
   * Windows cross-compile from a non-Windows host: clang-cl + lld-link from
   * the host LLVM plus an xwin-style Windows sysroot (see config.ts
   * `winsysroot`). On a Windows host just use the regular debug/release
   * profiles. Sanitizers are forced off in resolveConfig().
   */
  "windows-x64": {
    buildType: "Debug",
    os: "windows",
    arch: "x64",
    webkit: "prebuilt",
  },

  "windows-arm64": {
    buildType: "Debug",
    os: "windows",
    arch: "aarch64",
    webkit: "prebuilt",
  },

  "windows-x64-release": {
    buildType: "Release",
    os: "windows",
    arch: "x64",
    webkit: "prebuilt",
  },

  "windows-arm64-release": {
    buildType: "Release",
    os: "windows",
    arch: "aarch64",
    webkit: "prebuilt",
  },

  /**
   * Release build: the codegen CI ships (ThinLTO across bun, the `-lto`
   * WebKit prebuilt's bitcode and Rust; no PGO or symbol ordering — those are
   * CI post-steps). `--lto=off` trades that for fast relinks while iterating.
   */
  release: {
    buildType: "Release",
    webkit: "prebuilt",
  },

  /** Release with local WebKit. */
  "release-local": {
    buildType: "Release",
    webkit: "local",
    lto: false,
  },

  /**
   * Nix release tiers (nix/bun-target.nix, built under the flake's compat
   * stdenv so the binary's glibc floor stays at 2.34 — RHEL 9 / Ubuntu
   * 22.04+). Shared shape:
   *
   *   webkit: "local"     — the prebuilt is nehalem-only and built against a
   *                         different libstdc++; every tier compiles WebKit
   *                         under the same compat stdenv.
   *   lto: true           — required for a Release local WebKit: deps/webkit.ts
   *                         silently downgrades the nested build to
   *                         RelWithDebInfo (no -O3) when lto is off.
   *   dynamicLibstdcxx    — the compat host's libstdc++ is the target ABI.
   *   systemDeps          — link compatible shared deps from the system
   *                         instead of statically bundling them: shared-
   *                         library .text pages dedup across the several bun
   *                         processes these boxes run, an RSS win the static
   *                         build doesn't get. In `systemDeps` mode a dep's
   *                         `source()` returns `kind: "system"`, so its
   *                         tarball is never fetched.
   *                         libjpeg-turbo requires Bun's fatal-error patch
   *                         and exported warning-completion accessor; the
   *                         Nix compat package supplies both.
   *
   * systemDeps membership: hdrhistogram and libhwy match bun's pin exactly
   * in nixpkgs; libhwy ships .a only (no runtime dedup, but skips a ~50 MB
   * fetch + nested cmake). libuv is not linked on Linux at all upstream
   * (in-tree node-api stubs; deps/libuv.ts is Windows-only), so it is not a
   * system dep either. Skipped:
   * boringssl/mimalloc/tinycc (oven-sh forks), libarchive/lolhtml/lshpack
   * (load-bearing patches), picohttpparser (single-source direct compile),
   * and since 1.4.x c-ares — upstream's accept-rdata-compression.patch
   * (lenient RDATA name compression for dns.resolveSrv) would be lost.
   */

  /**
   * Pre-SSE4.2 build targeting Penryn (late Core 2 Duo, 2008).
   *
   * Runtime caveats — verified by disassembly of the produced binary:
   *
   *   1. WebAssembly v128 SIMD opcodes SIGILL. JSC's in-place WASM
   *      interpreter (InPlaceInterpreter64.asm) emits AVX ops (vpshufb,
   *      vroundps, vroundpd) unconditionally in `ipint_simd_*`.
   *
   *   2. WebAssembly i32.popcnt / i64.popcnt opcodes SIGILL. The LLInt
   *      WASM interpreter's `ipint_i32_popcnt` / `ipint_i64_popcnt`
   *      symbols emit native `popcntq` directly (Penryn lacks POPCNT;
   *      Nehalem is the floor for that).
   *
   * Plain JS (all four JIT tiers, including FTL via runtime supportsAVX()
   * fallbacks), Bun APIs, and WASM modules that don't use SIMD or popcnt
   * all work. PCLMUL appears in the binary but only in zlib-ng's
   * runtime-dispatched CRC32 fast path, and POPCNT also appears in
   * simdutf's `westmere` kernel — both behind runtime CPU dispatch.
   */
  "release-penryn": {
    buildType: "Release",
    webkit: "local",
    x64Cpu: "penryn",
    lto: true,
    dynamicLibstdcxx: true,
    // Sub-native tier: validated on the deployed machine / under qemu.
    smokeTest: false,
    systemDeps: [
      "zstd",
      "brotli",
      "libdeflate",
      "zlib",
      "hdrhistogram",
      "highway",
      "libspng",
      "libwebp",
      "libjpeg-turbo",
    ],
  },

  /**
   * x64 baseline build targeting Nehalem (2008): SSE4.2 + POPCNT, no AVX —
   * upstream's shipped x64 tier, rebuilt under the compat stdenv.
   *
   * Runtime caveat: WebAssembly v128 SIMD still SIGILLs because JSC's LLInt
   * `ipint_simd_*` emits AVX (vpshufb/vroundps/vroundpd) — Haswell is the
   * floor for that. Plain JS, native popcntq (Nehalem+), and non-SIMD WASM
   * all work.
   */
  "release-nehalem": {
    buildType: "Release",
    webkit: "local",
    x64Cpu: "nehalem",
    lto: true,
    dynamicLibstdcxx: true,
    // Sub-native tier: validated on the deployed machine / under qemu.
    smokeTest: false,
    systemDeps: [
      "zstd",
      "brotli",
      "libdeflate",
      "zlib",
      "hdrhistogram",
      "highway",
      "libspng",
      "libwebp",
      "libjpeg-turbo",
    ],
  },

  /**
   * x64 Haswell (2013) — AVX2 + BMI2, no runtime caveats. Same CPU target
   * as upstream's pre-1.4 default, with the compat glibc floor.
   */
  "release-haswell": {
    buildType: "Release",
    webkit: "local",
    x64Cpu: "haswell",
    lto: true,
    dynamicLibstdcxx: true,
    systemDeps: [
      "zstd",
      "brotli",
      "libdeflate",
      "zlib",
      "hdrhistogram",
      "highway",
      "libspng",
      "libwebp",
      "libjpeg-turbo",
    ],
  },

  /**
   * Release + assertions + logs. RelWithDebInfo → cargo `release` profile
   * with `debug-assertions = true` (runtime safety checks), matching the
   * old cmake build:assert script.
   */
  "release-assertions": {
    buildType: "RelWithDebInfo",
    webkit: "prebuilt",
    assertions: true,
    logs: true,
  },

  /**
   * Release + ASAN + assertions. For testing prod-ish builds with
   * sanitizer — catches memory bugs that only manifest at -O3. Assertions
   * on too (the CMake build:asan did this) since if you're debugging
   * memory you probably also want the invariant checks.
   */
  "release-asan": {
    buildType: "Release",
    webkit: "prebuilt",
    asan: true,
    assertions: true,
  },

  /** CI: a release build on one agent; build.ts packages and uploads the zips (scripts/build/ci.ts). */
  "ci-build": {
    buildType: "Release",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },
} as const satisfies Record<string, PartialConfig>;

/**
 * Look up a profile by name.
 */
/** Profiles that were removed, with what replaces them — a build dir configured under one says so on its next regen. */
const retiredProfiles: Record<string, string> = {
  btg: "--profile=release (LTO is on by default now)",
  "ci-release": "--profile=release --ci=on --buildkite=on (LTO is on by default now)",
};

export function getProfile(name: string): PartialConfig {
  if (name in retiredProfiles) {
    throw new BuildError(`Profile "${name}" no longer exists; use ${retiredProfiles[name]}`, {
      hint: "Re-run the build script with the new flags for this build dir (that rewrites its configure.json), or remove the build dir",
    });
  }
  if (name in profiles) {
    // The const assertion means values are readonly; spread into mutable PartialConfig.
    return { ...profiles[name as ProfileName] };
  }
  throw new BuildError(`Unknown profile: "${name}"`, {
    hint: `Available profiles: ${Object.keys(profiles).join(", ")}`,
  });
}
