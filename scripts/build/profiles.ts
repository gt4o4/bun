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
 *   release            → Release build, prebuilt WebKit, no LTO
 *   release-local      → Release build, local WebKit
 *   release-assertions → Release + runtime assertions enabled
 *   release-asan       → Release + address sanitizer
 *   ci-*               → CI-specific modes (cpp-only/link-only/full)
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

  /** Release build for local testing. No LTO (that's CI-only). */
  release: {
    buildType: "Release",
    webkit: "prebuilt",
    lto: false,
  },

  /**
   * Bench-till-green profile. Mirrors the codegen the CI release build
   * actually ships (`ci-release` resolves `lto: true` for ci+release+linux),
   * so PORT-vs-SYS comparisons measure what we'd actually ship — no PGO, no
   * symbol ordering, no special-case linker layout. lto=true selects the
   * `-lto` WebKit prebuilt (LLVM bitcode, re-codegen'd `-fno-pic` under
   * `-flto=thin -fwhole-program-vtables`) so cross-TU inlining runs; without
   * it the non-LTO WebKit .a lands ~555 KB of C++ vtables in `.data.rel.ro`,
   * keeps `.eh_frame` (+962 KB), and outlines JSC slow-paths — the bench then
   * reports a ~6-8% time / ~1 MB RSS "regression" that is pure binary layout.
   */
  btg: {
    buildType: "Release",
    webkit: "prebuilt",
    lto: true,
    // Pin the build dir so `--profile=btg` alone lands here and can never
    // be confused with `--profile=release --build-dir=build/btg` (which
    // would persist lto:false and silently de-LTO the bench binary).
    buildDir: "build/btg",
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
   *   crossLangLto: false — rustc's LLVM is newer than clang 21's, so cross-
   *                         language LTO would swap the link to bare rust-lld
   *                         and bypass the rpath-injecting `ld` wrapper the
   *                         Nix build relies on. Both halves still LTO on
   *                         their own (C++ -flto=thin, Rust fat).
   *   buildStd: false     — no -Zbuild-std: the sandbox would have to vendor
   *                         rust-src's crate graph for ~200 KB of symbolizer.
   *   dynamicLibstdcxx    — the compat host's libstdc++ is the target ABI.
   *   systemDeps          — link unpatched, ABI-stable deps from the system
   *                         instead of statically bundling them: shared-
   *                         library .text pages dedup across the several bun
   *                         processes these boxes run, an RSS win the static
   *                         build doesn't get. In `systemDeps` mode a dep's
   *                         `source()` returns `kind: "system"`, so its
   *                         tarball is never fetched.
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
    crossLangLto: false,
    buildStd: false,
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
    crossLangLto: false,
    buildStd: false,
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
    crossLangLto: false,
    buildStd: false,
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
    lto: false,
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

  /** CI: compile C++ to libbun.a only (parallelized with the cargo build). */
  "ci-cpp-only": {
    buildType: "Release",
    mode: "cpp-only",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },

  /**
   * CI: compile libbun_runtime.a only. Target platform via --os/--arch
   * overrides (cargo `--target <triple>`). Superseded in CI by
   * `ci-rust-and-link`; kept for ad-hoc rust-only builds.
   */
  "ci-rust-only": {
    buildType: "Release",
    mode: "rust-only",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },

  /** CI: link prebuilt objects downloaded from sibling BuildKite jobs. */
  "ci-link-only": {
    buildType: "Release",
    mode: "link-only",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },

  /**
   * CI: cargo build + link on one machine. Polls the sibling build-cpp step
   * for its archive/dep-lib artifacts, then links and packages. Saves an
   * agent spawn vs rust-only → link-only. Resolves the full toolchain (link
   * needs ld/strip/rc), unlike rust-only.
   */
  "ci-rust-and-link": {
    buildType: "Release",
    mode: "rust-and-link",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },

  /** CI: deps + C++ + cargo + link on one agent; libbun-*.a, libbun_runtime.a and dep libs are uploaded as artifacts. */
  "ci-build": {
    buildType: "Release",
    mode: "archive-link",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
  },

  /** CI full build with LTO. */
  "ci-release": {
    buildType: "Release",
    ci: true,
    buildkite: true,
    webkit: "prebuilt",
    // lto default resolves to ON (ci + release + linux + !asan + !assertions)
  },
} as const satisfies Record<string, PartialConfig>;

/**
 * Look up a profile by name.
 */
export function getProfile(name: string): PartialConfig {
  if (name in profiles) {
    // The const assertion means values are readonly; spread into mutable PartialConfig.
    return { ...profiles[name as ProfileName] };
  }
  throw new BuildError(`Unknown profile: "${name}"`, {
    hint: `Available profiles: ${Object.keys(profiles).join(", ")}`,
  });
}
