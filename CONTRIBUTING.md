Configuring a development environment for Bun can take 10-30 minutes depending on your internet connection and computer speed. You will need ~10GB of free disk space for the repository and build artifacts.

If you are using Windows, please refer to [this guide](https://bun.com/docs/project/building-windows)

## Using Nix (Alternative)

A Nix flake is provided as an alternative to manual dependency installation:

```bash
nix develop
# or explicitly use the pure shell
# nix develop .#pure
export CMAKE_SYSTEM_PROCESSOR=$(uname -m)
bun bd
```

This provides all dependencies in an isolated, reproducible environment without requiring sudo.

## Install Dependencies (Manual)

Using your system's package manager, install Bun's dependencies:

{% codetabs group="os" %}

```bash#macOS (Homebrew)
$ brew install automake ccache cmake coreutils gnu-sed go icu4c libiconv libtool ninja pkg-config rustup-init ruby
```

```bash#Ubuntu/Debian
$ sudo apt install curl wget lsb-release software-properties-common cmake git golang libtool ninja-build pkg-config ruby-full xz-utils
```

```bash#Arch
$ sudo pacman -S base-devel cmake git go libiconv libtool make ninja pkg-config python rustup sed unzip ruby
```

```bash#Fedora
$ sudo dnf install clang21 llvm21 lld21 cmake git golang libtool ninja-build pkg-config ruby libatomic-static libstdc++-static sed unzip which libicu-devel 'perl(Math::BigInt)'
```

```bash#openSUSE Tumbleweed
$ sudo zypper install go cmake ninja automake git icu rustup
```

{% /codetabs %}

Bun is written in Rust and requires a specific nightly toolchain (pinned in [`rust-toolchain.toml`](/rust-toolchain.toml)). Install Rust via [rustup](https://rustup.rs) rather than your distro's `rust`/`cargo` packages — the build scripts use rustup to automatically install and update the pinned nightly:

```bash
$ curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Before starting, you will need to already have a release build of Bun installed, as we use our bundler to transpile and minify our code, as well as for code generation scripts.

{% codetabs %}

```bash#Native
$ curl -fsSL https://bun.com/install | bash
```

```bash#npm
$ npm install -g bun
```

```bash#Homebrew
$ brew tap oven-sh/bun
$ brew install bun
```

{% /codetabs %}

### Optional: Install `ccache`

ccache is used to cache compilation artifacts, significantly speeding up builds:

```bash
# For macOS
$ brew install ccache

# For Ubuntu/Debian
$ sudo apt install ccache

# For Arch
$ sudo pacman -S ccache

# For Fedora
$ sudo dnf install ccache

# For openSUSE
$ sudo zypper install ccache
```

Our build scripts will automatically detect and use `ccache` if available. You can check cache statistics with `ccache --show-stats`.

## Install LLVM

Bun requires LLVM 21.1.8 (`clang` is part of LLVM). This version is enforced by the build system — mismatching versions will cause memory allocation failures at runtime. In most cases, you can install LLVM through your system package manager:

{% codetabs group="os" %}

```bash#macOS (Homebrew)
$ brew install llvm@21
```

```bash#Ubuntu/Debian
$ # LLVM has an automatic installation script that is compatible with all versions of Ubuntu
$ wget https://apt.llvm.org/llvm.sh -O - | sudo bash -s -- 21 all
```

```bash#Arch
$ sudo pacman -S llvm clang lld
```

```bash#Fedora
$ sudo dnf install llvm clang lld-devel
```

```bash#openSUSE Tumbleweed
$ sudo zypper install clang21 lld21 llvm21
```

{% /codetabs %}

If none of the above solutions apply, you will have to install it [manually](https://github.com/llvm/llvm-project/releases/tag/llvmorg-21.1.8).

Make sure Clang/LLVM 21 is in your path:

```bash
$ which clang-21
```

If not, run this to manually add it:

{% codetabs group="os" %}

```bash#macOS (Homebrew)
# use fish_add_path if you're using fish
# use path+="$(brew --prefix llvm@21)/bin" if you are using zsh
$ export PATH="$(brew --prefix llvm@21)/bin:$PATH"
```

```bash#Arch
# use fish_add_path if you're using fish
$ export PATH="$PATH:/usr/lib/llvm21/bin"
```

{% /codetabs %}

> ⚠️ Ubuntu distributions (<= 20.04) may require installation of the C++ standard library independently. See the [troubleshooting section](#span-file-not-found-on-ubuntu) for more information.

## Building Bun

After cloning the repository, run the following command to build. This may take a while as it will clone submodules and build dependencies.

```bash
$ bun run build
```

The binary will be located at `./build/debug/bun-debug`. It is recommended to add this to your `$PATH`. To verify the build worked, let's print the version number on the development build of Bun.

```bash
$ build/debug/bun-debug --version
x.y.z_debug
```

## VSCode

VSCode is the recommended IDE for working on Bun, as it has been configured. Once opening, you can run `Extensions: Show Recommended Extensions` to install the recommended extensions for Rust and C++. rust-analyzer will pick up the workspace `Cargo.toml` automatically; the pinned toolchain in `rust-toolchain.toml` is used for analysis so diagnostics match the build.

If you use a different editor, point rust-analyzer (or your editor's Rust plugin) at the repo root — the Cargo workspace and `rust-toolchain.toml` are discovered automatically.

We recommend adding `./build/debug` to your `$PATH` so that you can run `bun-debug` in your terminal:

```sh
$ bun-debug
```

## Running debug builds

The `bd` package.json script compiles and runs a debug build of Bun, only printing the output of the build process if it fails.

```sh
$ bun bd <args>
$ bun bd test foo.test.ts
$ bun bd ./foo.ts
```

A full debug build can take a few minutes when Rust or C++ has changed; cargo's incremental compilation makes subsequent Rust-only rebuilds much faster. If your development workflow is "change one line, save, rebuild", you will still spend too much time waiting for the link step. Instead:

- Batch up your changes
- Use `cargo check -p <crate>` (or `bun run rust:check` for the whole workspace) to type-check Rust changes without linking. `bun run watch` runs `cargo check` on every save.
- Ensure rust-analyzer is running for inline diagnostics (if you use VSCode and install the recommended extensions, this should just work)
- Prefer using the debugger ("CodeLLDB" in VSCode) to step through the code.
- Use debug logs. `BUN_DEBUG_<scope>=1` will enable debug logging for the corresponding `declare_scope!(<scope>, ...)` / `scoped_log!(<scope>, ...)` logs. You can also set `BUN_DEBUG_QUIET_LOGS=1` to disable all debug logging that isn't explicitly enabled. To dump debug logs into a file, `BUN_DEBUG=<path-to-file>.log`. Debug logs are aggressively removed in release builds.
- src/js/\*\*.ts changes are pretty much instant to rebuild. Single-crate Rust changes and C++ changes are incremental; only the final link is unavoidable.

## Code generation scripts

Several code generation scripts are used during Bun's build process. These are run automatically when changes are made to certain files.

In particular, these are:

- `./src/codegen/generate-jssink.ts` -- Generates `build/debug/codegen/JSSink.cpp`, `build/debug/codegen/JSSink.h` which implement various classes for interfacing with `ReadableStream`. This is internally how `FileSink`, `ArrayBufferSink`, `"type": "direct"` streams and other code related to streams works.
- `./src/codegen/generate-classes.ts` -- Generates Rust & C++ bindings for JavaScriptCore classes implemented in Rust. In `**/*.classes.ts` files, we define the interfaces for various classes, methods, prototypes, getters/setters etc which the code generator reads to generate boilerplate code implementing the JavaScript objects in C++ and wiring them up to Rust.
- `./src/codegen/cppbind.ts` -- Scans the C++ bindings for functions marked with an export attribute and generates automatic Rust FFI wrappers (`cpp.rs`) for them.
- `./src/codegen/bundle-modules.ts` -- Bundles built-in modules like `node:fs`, `bun:ffi` into files we can include in the final binary. In development, these can be reloaded without rebuilding native code (you still need to run `bun run build`, but it re-reads the transpiled files from disk afterwards). In release builds, these are embedded into the binary.
- `./src/codegen/bundle-functions.ts` -- Bundles globally-accessible functions implemented in JavaScript/TypeScript like `ReadableStream`, `WritableStream`, and a handful more. These are used similarly to the builtin modules, but the output more closely aligns with what WebKit/Safari does for Safari's built-in functions so that we can copy-paste the implementations from WebKit as a starting point.

## Modifying ESM modules

Certain modules like `node:fs`, `node:stream`, `bun:sqlite`, and `ws` are implemented in JavaScript. These live in `src/js/{node,bun,thirdparty}` files and are pre-bundled using Bun.

## Release build

To compile a release build of Bun, run:

```bash
$ bun run build:release
```

The binary will be located at `./build/release/bun` and `./build/release/bun-profile`.

### Download release build from pull requests

To save you time spent building a release build locally, we provide a way to run release builds from pull requests. This is useful for manually testing changes in a release build before they are merged.

To run a release build from a pull request, you can use the `bun-pr` npm package:

```sh
bunx bun-pr <pr-number>
bunx bun-pr <branch-name>
bunx bun-pr "https://github.com/oven-sh/bun/pull/1234566"
bunx bun-pr --asan <pr-number> # Linux x64 only
```

This will download the release build from the pull request and add it to `$PATH` as `bun-${pr-number}`. You can then run the build with `bun-${pr-number}`.

```sh
bun-1234566 --version
```

This works by downloading the release build from the GitHub Actions artifacts on the linked pull request. You may need the `gh` CLI installed to authenticate with GitHub.

### Viewing CI failures from the terminal

Bun's CI runs on BuildKite. Install the [BuildKite CLI](https://github.com/buildkite/cli) (`brew install buildkite/buildkite/bk`) and set `BUILDKITE_API_TOKEN` to a read-scoped [API token](https://buildkite.com/user/api-access-tokens). The repo includes a `.bk.yaml` so `bk` commands default to the `bun` pipeline.

```sh
bun run ci:status         # progress summary for the current branch's latest build
bun run ci:errors         # rendered test-failure output, tagged [new] vs [also on main]
bun run ci:logs           # save full logs for each failed job to ./tmp/ci-<build>/
bun run ci:watch          # watch until the build finishes
bun run ci:find           # print the build number (compose with raw `bk`)
```

All of these accept a target: `#1234` (PR number), a PR URL, a branch name, or a build number. Without one they use the current git branch.

## AddressSanitizer

[AddressSanitizer](https://en.wikipedia.org/wiki/AddressSanitizer) helps find memory issues, and is enabled by default in debug builds of Bun on Linux and macOS. This covers the Rust code, the C++ bindings, and all dependencies. It makes the build take about 2x longer; if that's stopping you from being productive you can disable it with `bun run build:debug:noasan` (or pass `--asan=off` to `scripts/build.ts`), but generally we recommend batching your changes up between builds.

To build a release build with Address Sanitizer, run:

```bash
$ bun run build:asan
```

In CI, we run our test suite with at least one target that is built with Address Sanitizer.

## Building WebKit locally + Debug mode of JSC

WebKit is not cloned by default (to save time and disk space). To clone and build WebKit locally, run:

```bash
# Clone WebKit into ./vendor/WebKit
$ git clone https://github.com/oven-sh/WebKit vendor/WebKit

# Check out the version pinned in WEBKIT_VERSION in scripts/build/deps/webkit.ts
# (a commit sha or an autobuild-* release tag; this handles both)
$ bun sync-webkit-source

# Build bun with the local JSC build — this automatically configures and builds JSC
$ bun run build:local
```

`bun run build:local` handles everything: configuring JSC, building JSC, and building Bun. On subsequent runs, JSC will incrementally rebuild if any WebKit sources changed. `ninja -Cbuild/debug-local` also works after the first build, and will build Bun+JSC.

The build output goes to `./build/debug-local` (instead of `./build/debug`), so you'll need to update a couple of places:

- The first line in [`src/js/builtins.d.ts`](/src/js/builtins.d.ts)
- The `CompilationDatabase` line in [`.clangd` config](/.clangd) should be `CompilationDatabase: build/debug-local`
- In [`.vscode/launch.json`](/.vscode/launch.json), many configurations use `./build/debug/`, change them as you see fit

Note that the WebKit folder, including build artifacts, is 8GB+ in size.

If you are using a JSC debug build and using VScode, make sure to run the `C/C++: Select a Configuration` command to configure intellisense to find the debug headers.

Note that if you make changes to our [WebKit fork](https://github.com/oven-sh/WebKit), you will also have to change `WEBKIT_VERSION` in [`scripts/build/deps/webkit.ts`](/scripts/build/deps/webkit.ts) to point to your commit hash or release tag.

## Building the release tiers (Penryn / Nehalem / Haswell)

Upstream ships one x64 binary, targeting Nehalem (SSE4.2). This fork adds three
`release-<tier>` profiles — `release-penryn` (SSE4.1 only: late Core 2 Duo,
early Atoms), `release-nehalem` (upstream's tier) and `release-haswell`
(AVX2 + BMI2) — meant to be built under the Nix flake's compat stdenv so the
binary's glibc floor stays at 2.34 (RHEL 9 / Ubuntu 22.04+). No prebuilt
artifact is shipped from upstream for any of them.

### Using the Nix derivation

```sh
# From a flake that locks this one as an input (this repo ships no flake.lock
# on purpose — the consumer pins nixpkgs, nixpkgs-compat and fenix):
nix build --override-input bun "git+file://$PWD/submodules/bun?ref=main" .#bun-haswell
./result/bin/bun --version
```

The derivation lives at [`nix/bun-target.nix`](/nix/bun-target.nix) and pins
every input: WebKit (`WEBKIT_VERSION`), the node headers, the vendored dep
tarballs (exposed to the build scripts through `BUN_BUILD_PREFETCH_DIR`), the
whole crates.io graph from `Cargo.lock` (`rustPlatform.importCargoLock`) and
the exact nightly from `rust-toolchain.toml` (via fenix). Network is only
needed for one fixed-output derivation that runs `bun install
--frozen-lockfile`. Everything else is hermetic.

### Manual build

```sh
# 1. Clone WebKit at the pinned commit (no prebuilt exists below nehalem, and
#    the tiers build WebKit with their own -march anyway)
git clone https://github.com/oven-sh/WebKit vendor/WebKit
git -C vendor/WebKit checkout <commit_hash>   # see WEBKIT_VERSION in scripts/build/deps/webkit.ts

# 2. Build — sets -march=<tier> for bun + all deps + the local WebKit,
#    -Ctarget-cpu=<tier> for the Rust half
bun run build --profile=release-penryn --build-dir=build/release-penryn
```

The system libraries below (their `-dev` packages) must be installed: in
`systemDeps` mode the deps are linked with `-l<name>` from the toolchain's
default search path and their headers resolve from the default include path.

### What the profiles do

- `x64Cpu: "<tier>"` → `-march=<tier>` for bun's own C/C++, every vendored dep
  that still builds from source, and the nested WebKit cmake invocation;
  `rustCpuTargetFlags()` derives the matching `-Ctarget-cpu=` from the same
  table, so the two halves cannot drift apart.
- `lto: true` — C++ `-flto=thin`, Rust fat LTO via the workspace profile.
  Required: without it `scripts/build/deps/webkit.ts` silently downgrades the
  nested WebKit build to `RelWithDebInfo` (no `-O3`).
- `crossLangLto: false` — rustc's bundled LLVM is newer than clang 21's, so
  cross-language LTO would swap the link to bare `rust-lld` and bypass the
  rpath-injecting `ld` wrapper the Nix build relies on. Both halves still LTO
  on their own; only the cross-language inlining is lost.
- `buildStd: false` — no `-Zbuild-std`: a sandboxed build would otherwise have
  to vendor rust-src's own crate graph for ~200 KB of std symbolizer.
- `dynamicLibstdcxx: true` — `-lstdc++ -lgcc_s` instead of the static copies;
  the compat host's libstdc++ is the target ABI.
- `systemDeps`: zstd, brotli, libdeflate, zlib, hdrhistogram, highway, libspng,
  libwebp, libjpeg-turbo. Each switches its `source()` to `kind: "system"`, so
  the profile links it from the host's package manager (nixpkgs in the Nix
  path) instead of bundling it statically — shared-library pages dedup across
  the several bun processes these boxes run. Still vendored: boringssl,
  mimalloc, tinycc (oven-sh forks), libarchive, lol-html, ls-hpack (load-bearing
  patches), ls-qpack, lsquic, picohttpparser, and since 1.4.x c-ares (upstream
  patches it: `patches/cares/accept-rdata-compression.patch`). libuv is not
  linked on Linux at all upstream.
- `smokeTest: false` on the sub-native tiers (penryn, nehalem): the binary is
  validated on the deployed machine or under qemu instead.

### Runtime requirements (manual / non-Nix builds)

The tier binaries dynamically link against:

```
libstdc++.so.6, libgcc_s.so.1
libicui18n.so.<N>, libicuuc.so.<N>   # the ICU the WebKit build saw (71 in the Nix build)
libz.so.1
libzstd.so.1
libbrotlidec.so.1, libbrotlienc.so.1
libdeflate.so.0
libhdr_histogram.so.6
libspng.so.0
libturbojpeg.so.0
libwebp.so.7, libwebpmux.so.3, libwebpdemux.so.2
libc.so.6, libm.so.6   # glibc ≥ 2.34 (compat stdenv)
```

libhwy is static-only in nixpkgs and is linked in. Under Nix the consumer
(`bun-compat.nix` in nix-configs) resolves all of these with autoPatchelf;
on an FHS distro also swap the interpreter:
`patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 bun`.

### Runtime caveats

JSC's runtime CPU dispatch handles SSE4.2/AVX/AVX2 fallbacks for plain
JavaScript across all four JIT tiers. Two narrow code paths still emit
post-Penryn instructions unconditionally and will SIGILL if exercised:

| Code path                      | Symbol(s)                                      | Op emitted                              | Impact                                                 |
| ------------------------------ | ---------------------------------------------- | --------------------------------------- | ------------------------------------------------------ |
| WASM v128 SIMD opcodes         | `ipint_simd_*` (LLInt)                         | `vpshufb`, `vroundps`, `vroundpd` (AVX) | penryn + nehalem: guest module using v128 SIMD SIGILLs |
| WASM `i{32,64}.popcnt` opcodes | `ipint_i32_popcnt`, `ipint_i64_popcnt` (LLInt) | native `popcntq`                        | penryn only                                            |

Plain JS, Bun APIs and WASM modules that don't use those opcodes all work.
PCLMUL and POPCNT also appear elsewhere in the binary (zlib-ng's CRC32,
simdutf's `westmere` kernel) but those are runtime-dispatched.

### Verifying the binary

```sh
# Confirm system-linked deps resolve at runtime:
ldd build/release-penryn/bun | grep -E 'libz|libzstd|libbrotli|libicu|libhdr|libspng|libwebp|libturbojpeg'

# Run on emulated Penryn / Nehalem:
qemu-x86_64 -cpu Penryn build/release-penryn/bun -e 'console.log(Bun.version)'
qemu-x86_64 -cpu Nehalem build/release-nehalem/bun -e 'console.log(Bun.version)'

# Pin the floor: -cpu Conroe (no SSE4.1) should SIGILL the penryn binary:
qemu-x86_64 -cpu Conroe build/release-penryn/bun -e 'console.log(Bun.version)'
```

## Troubleshooting

### 'span' file not found on Ubuntu

> ⚠️ Please note that the instructions below are specific to issues occurring on Ubuntu. It is unlikely that the same issues will occur on other Linux distributions.

The Clang compiler typically uses the `libstdc++` C++ standard library by default. `libstdc++` is the default C++ Standard Library implementation provided by the GNU Compiler Collection (GCC). While Clang may link against the `libc++` library, this requires explicitly providing the `-stdlib` flag when running Clang.

Bun relies on C++20 features like `std::span`, which are not available in GCC versions lower than 11. GCC 10 doesn't have all of the C++20 features implemented. As a result, running `make setup` may fail with the following error:

```
fatal error: 'span' file not found
#include <span>
         ^~~~~~
```

The issue may manifest when initially running `bun setup` as Clang being unable to compile a simple program:

```
The C++ compiler

  "/usr/bin/clang++-21"

is not able to compile a simple test program.
```

To fix the error, we need to update the GCC version to 11. To do this, we'll need to check if the latest version is available in the distribution's official repositories or use a third-party repository that provides GCC 11 packages. Here are general steps:

```bash
$ sudo apt update
$ sudo apt install gcc-11 g++-11
# If the above command fails with `Unable to locate package gcc-11` we need
# to add the APT repository
$ sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
# Now run `apt install` again
$ sudo apt install gcc-11 g++-11
```

Now, we need to set GCC 11 as the default compiler:

```bash
$ sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 100
$ sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 100
```

### libarchive

If you see an error on macOS when compiling `libarchive`, run:

```bash
$ brew install pkg-config
```

### macOS `library not found for -lSystem`

If you see this error when compiling, run:

```bash
$ xcode-select --install
```

### Cannot find `libatomic.a`

Bun defaults to linking `libatomic` statically, as not all systems have it. If you are building on a distro that does not have a static libatomic available, you can run the following command to enable dynamic linking:

```bash
$ bun run build -DUSE_STATIC_LIBATOMIC=OFF
```

The built version of Bun may not work on other systems if compiled this way.

## Using bun-debug

- Disable logging: `BUN_DEBUG_QUIET_LOGS=1 bun-debug ...` (to disable all debug logging)
- Enable logging for a specific scope: `BUN_DEBUG_EventLoop=1 bun-debug ...` (to enable `scoped_log!(EventLoop, ...)` output)
- Bun transpiles every file it runs, to see the actual executed source in a debug build find it in `/tmp/bun-debug-src/...path/to/file`, for example the transpiled version of `/home/bun/index.ts` would be in `/tmp/bun-debug-src/home/bun/index.ts`
