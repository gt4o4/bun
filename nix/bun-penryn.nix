{
  # Passed from ../flake.nix — shared with devShells.default so toolchain
  # versions and env exports stay in sync.
  self,
  bunPackages,
  commonToolchainEnv,

  lib,
  stdenv,
  fetchgit,
  fetchurl,
  bun,
  rustPlatform,
  coreutils,
  cacert,
  icu,
  # System-linked deps for the release-penryn profile (scripts/build/profiles.ts
  # systemDeps). zstd's source fetch is skipped but its headers are symlinked
  # under vendor/zstd/lib for build.zig translate_c. The rest source their
  # headers from the corresponding nixpkgs .dev outputs via CPATH.
  zstd,
  brotli,
  libdeflate,
  c-ares,
  zlib-ng,
  hdrhistogram_c,
  libuv,
  libhwy,
}:
# `bun` is listed above because it's needed in the FOD's `nativeBuildInputs`
# (cacert alone isn't a package; bun is what runs `bun install`). For the main
# derivation it's already on PATH via `bunPackages`.

let
  # Source is the flake itself (this repo). Avoids pinning a bunRev hash.
  bunSrc = self;
  # Display-only revision. `self.rev` is unset when the worktree is dirty; fall
  # back to a short descriptor then.
  bunVersion = self.shortRev or self.dirtyShortRev or "dev";

  # Pinned upstream deps fetched by Bun's own build system. We reproduce their
  # fetch behavior here so the build doesn't need network access.
  webkitRev = "4d5e75ebd84a14edbc7ae264245dcd77fe597c10";
  zigCommit = "365343af4fc5a1a632e6b54aadd0b87be30edd81";
  nodeVer = "24.3.0";

  # Vendored deps that bun's build system normally fetches into vendor/<name>/.
  # `hash` is the RAW GitHub archive tarball hash (fetchurl, not fetchFromGitHub):
  # we pre-populate scripts/build/fetch-cli.ts's tarball cache and let it do
  # extract + patch + stamp with bun's own logic. Patch application flags,
  # CRLF normalization, and identity format all stay in sync with the build
  # system automatically.
  #
  # Deps the release-penryn profile links from the system (brotli, c-ares,
  # hdrhistogram_c, highway, libdeflate, libuv, zlib-ng) don't appear here
  # — their dep file's source() returns kind:"system" when
  # systemDeps.has(name), which means no fetch + no build + no headers
  # vendored (system headers come from the buildInputs' .dev outputs via
  # CPATH; libhwy is the static-archive case).
  #
  # zstd is a special case: the `kind: "system"` branch links -lzstd, but
  # build.zig:681 hardcodes `vendor/zstd/lib` as a translate_c include path
  # for zig's @cImport. We satisfy that by symlinking the nixpkgs zstd.dev
  # headers into vendor/zstd/lib in configurePhase below — no fetch needed.
  deps = {
    boringssl = {
      owner = "oven-sh";
      repo = "boringssl";
      rev = "0c5fce43b7ed5eb6001487ee48ac65766f5ddcd1";
      hash = "sha256-pBSx0QX+8QVpe3QowL5ff8Z0iYSeqidpMa6DRNeKmbg=";
      patches = [ ];
    };
    libarchive = {
      owner = "libarchive";
      repo = "libarchive";
      rev = "ded82291ab41d5e355831b96b0e1ff49e24d8939";
      hash = "sha256-BC8O/nFHBj/5uhDxo47QgOlJvL0Evb81kriEbdEbHaI=";
      patches = [
        "patches/libarchive/archive_write_add_filter_gzip.c.patch"
        "patches/libarchive/CMakeLists.txt.patch"
        "patches/libarchive/nonblocking-read.patch"
      ];
    };
    lolhtml = {
      owner = "cloudflare";
      repo = "lol-html";
      rev = "77127cd2b8545998756e8d64e36ee2313c4bb312";
      hash = "sha256-LFMWHt9jP6maz8Tq/duv1dm4GZ8JGKHMkVLLbCyb83k=";
      patches = [ ];
    };
    lshpack = {
      owner = "litespeedtech";
      repo = "ls-hpack";
      rev = "8905c024b6d052f083a3d11d0a169b3c2735c8a1";
      hash = "sha256-B9i/kBuxsVVD846r0jk4UZ4SEO6621Lz1lHW7xMO+XM=";
      patches = [ "patches/lshpack/CMakeLists.txt.patch" ];
    };
    mimalloc = {
      owner = "oven-sh";
      repo = "mimalloc";
      rev = "57029fb1f193e633462e76af745599e1dbfd4b58";
      hash = "sha256-Zjj9765yVD1xaJ2olraAlcESP8u8UXxbfZ4zoxYxf1s=";
      patches = [ ];
    };
    picohttpparser = {
      owner = "h2o";
      repo = "picohttpparser";
      rev = "066d2b1e9ab820703db0837a7255d92d30f0c9f5";
      hash = "sha256-Y3/yq29cf34FpbXcOT1c8v6o1HVPys6q+TX//1wTI+4=";
      patches = [ ];
    };
    tinycc = {
      owner = "oven-sh";
      repo = "tinycc";
      rev = "12882eee073cfe5c7621bcfadf679e1372d4537b";
      hash = "sha256-a1BIX8u/qQqZxW6OK2qSAU3NNDd9Xtsj4ZONyeyW8Ko=";
      patches = [ "patches/tinycc/tcc.h.patch" ];
    };
  };

  # Raw GitHub archive tarball per dep.
  depTarballs = lib.mapAttrs (
    _: d:
    fetchurl {
      url = "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz";
      inherit (d) hash;
    }
  ) deps;

  # Filename under $cacheDir/tarballs/ that scripts/build/fetch-cli.ts::fetchDep
  # looks up: `<name>-<sha256(url)[:16]>.tar.gz`. Matches fetch-cli.ts:154-156
  # byte-for-byte — verified with `builtins.hashString "sha256"` matching
  # `printf '%s' url | sha256sum`.
  depCacheName =
    name: d:
    "${name}-${
      builtins.substring 0 16 (
        builtins.hashString "sha256" "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz"
      )
    }.tar.gz";

  # lolhtml is built via `cargo build` against crates.io. The sandbox has no
  # network, so we materialize the vendored crate tree at eval time from the
  # lockfile. `importCargoLock` pure-fetches each crate by its per-entry hash.
  # Extract the lockfile directly from the raw tarball (we haven't unpacked it).
  lolhtmlLockfile = stdenv.mkDerivation {
    name = "lolhtml-cargo-lock";
    src = depTarballs.lolhtml;
    dontUnpack = false;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      install -Dm644 c-api/Cargo.lock $out
    '';
  };
  lolhtmlCargoVendor = rustPlatform.importCargoLock {
    lockFileContents = builtins.readFile lolhtmlLockfile;
  };

  webkitSrc = fetchgit {
    url = "https://github.com/oven-sh/WebKit.git";
    rev = webkitRev;
    hash = "sha256-bnNcqYtX8+3KL/uJW0TPU3MfByToP37S1zuqeWWMfvw=";
    deepClone = true;
    leaveDotGit = false;
  };

  zigZip = fetchurl {
    url = "https://github.com/oven-sh/zig/releases/download/autobuild-${zigCommit}/bootstrap-x86_64-linux-musl.zip";
    hash = "sha256-Baetu5WBFqAUx/qtvfsemQpc6JQRJKkcVI9F0r8NDTg=";
  };

  nodeHeaders = fetchurl {
    url = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-headers.tar.gz";
    hash = "sha256-BF6b9HfNXbDsZ/jBpjun94Te3+LFgePQ7Qm4jpEV3Qc=";
  };

  # node_modules FOD. Fixed-output derivations get network access in the Nix
  # sandbox, so `bun install --frozen-lockfile` can hit the registry. The
  # resulting tree is content-hashed so any lockfile change triggers a refetch.
  #
  # Three workspaces run `bun install` during codegen: repo root (esbuild +
  # lezer-cpp), packages/bun-error (preact), src/node-fallbacks (node polyfills).
  # buildInputs hoisted here so we can both consume them in the derivation
  # and reference their lib dirs in LD_LIBRARY_PATH at smoke-test time.
  # The smoke test runs *before* fixupPhase patches RPATH, so the dynamic
  # loader needs LD_LIBRARY_PATH to find these system .so files at link-rule
  # `--revision` time. autoPatchelfHook fixes RPATH afterward and the
  # installed binary doesn't need LD_LIBRARY_PATH.
  # zlib-ng needs ZLIB_COMPAT=ON to ship libz.so.1 (stock zlib ABI). The
  # default nixpkgs build targets libz-ng.so.2 which -lz can't find. bun
  # already builds the vendored copy with ZLIB_COMPAT=ON, so the compat
  # override keeps behavior identical, just dynamically linked.
  zlibNgCompat = zlib-ng.override { withZlibCompat = true; };

  bunBuildInputs = [
    icu
    zstd
    brotli
    libdeflate
    c-ares
    zlibNgCompat
    hdrhistogram_c
    libuv
    # nixpkgs ships libhwy.a only — no .so. Linking it dynamically would need
    # a shared-library override; we just inline the .a and skip the source
    # fetch. Same runtime behavior as building from source, faster configure.
    libhwy
  ];

  bunNodeModules = stdenv.mkDerivation {
    pname = "bun-penryn-node-modules";
    version = bunVersion;
    src = bunSrc;

    nativeBuildInputs = [
      bun
      cacert
    ];

    dontConfigure = true;
    dontPatch = true;
    dontBuild = true;
    # FODs must not contain nix-store path references. fixupPhase would
    # inject them via patchShebangs / RPATH shrinking on prebuilt binaries
    # (esbuild, lightningcss). Leave the tree as installed.
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      export HOME=$TMPDIR
      # bun install has no --install-dir flag; it writes to $PWD/node_modules
      # (and to each workspace's node_modules for nested deps). Install in
      # place, then move the resulting node_modules trees into $out — no
      # redundant `cp -a`. Inner workspace symlinks are relative
      # (node_modules/bun-types -> ../packages/bun-types) so they keep
      # resolving correctly once copied alongside packages/ in the consumer.
      for dir in "" packages/bun-error src/node-fallbacks; do
        echo "==> bun install in ''${dir:-<root>}"
        (cd "$PWD/$dir" && bun install --frozen-lockfile)
      done
      mkdir -p $out
      mv node_modules $out/node_modules
      for wp in \
        packages/bun-types \
        packages/@types/bun \
        packages/bun-error \
        src/node-fallbacks \
      ; do
        if [ -d "$wp/node_modules" ]; then
          mkdir -p "$out/$wp"
          mv "$wp/node_modules" "$out/$wp/node_modules"
        fi
      done
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-IrpMpPAdtf484RycSymFh4MAjlooXdh8sHX2xTqt/6Q=";
  };
in
stdenv.mkDerivation {
  pname = "bun-penryn";
  version = "1.3.13-penryn-${bunVersion}";

  src = bunSrc;

  passthru = {
    inherit
      depTarballs
      webkitSrc
      zigZip
      nodeHeaders
      bunNodeModules
      lolhtmlCargoVendor
      ;
  };

  # bunPackages (from flake.nix) carries cmake/ninja/clang/llvm/lld/rustc/cargo/
  # go/bun/nodejs/python/libtool/ruby/perl/openssl/zlib/libxml2/libiconv/git/
  # unzip/xz/pkg-config. We add only what the Nix build needs beyond that.
  #
  # autoPatchelfHook is intentionally NOT in nativeBuildInputs. Its job is
  # to bake nix-store RUNPATHs + interpreter into the binary so it runs
  # in-place from /nix/store. That's exactly what we DON'T want for the
  # release artifact — we want bare NEEDED entries + /lib64 interpreter so
  # the binary is portable to any glibc-≥2.40 distro. Skipping the hook
  # leaves the linker's defaults (empty RUNPATH, nix-store interpreter);
  # postInstall below swaps the interpreter to the FHS path.
  #
  # Trade-off: ./result/bin/bun won't run from /nix/store without
  # LD_LIBRARY_PATH set, because libz.so.1 etc. aren't on a default search
  # path. Use `nix shell .#bun-penryn -c bun` (which sets PATH+LD_LIBRARY_PATH
  # via the shell wrapper) or build the in-store-runnable variant by adding
  # autoPatchelfHook back. The released zip works on any standard distro
  # with the runtime libs installed (see release notes).
  nativeBuildInputs = bunPackages ++ [
    coreutils
  ];
  # Each system-linked dep here is wired through scripts/build/profiles.ts
  # (release-penryn.systemDeps) and the corresponding deps/<name>.ts file.
  # The github archive is still fetched (translate_c needs zstd headers,
  # libarchive's check_include_file needs zlib's symbols visible), but the
  # static-archive build is skipped and -l<name> picks up the .so here.
  # zlib-ng in zlib-compat mode keeps the libz.so.1 soname stable.
  buildInputs = bunBuildInputs;

  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure

    # 0. Pre-installed node_modules from the FOD above. Preserves symlinks so
    #    workspace links (node_modules/bun-types -> ../packages/bun-types)
    #    resolve correctly against our packages/ directory.
    #    --reflink=auto: COW on btrfs/xfs (instant + zero extra space), plain
    #    copy elsewhere. -a implies --no-dereference so symlinks survive.
    cp -a --reflink=auto "${bunNodeModules}/node_modules" node_modules
    chmod -R u+w node_modules
    for wp in \
      packages/bun-types \
      packages/@types/bun \
      packages/bun-error \
      src/node-fallbacks \
    ; do
      if [ -d "${bunNodeModules}/$wp/node_modules" ]; then
        cp -a --reflink=auto "${bunNodeModules}/$wp/node_modules" "$wp/node_modules"
        chmod -R u+w "$wp/node_modules"
      fi
    done

    mkdir -p vendor

    # Sandbox-friendly cache dirs. The toolchain defaults
    # ($HOME/.cargo, $HOME/.bun) live under /homeless-shelter, which is
    # read-only. Both vars are read at config-resolve time inside the build
    # (config.ts: cacheDir = $BUN_INSTALL/build-cache, tools.ts: CARGO_HOME),
    # so they have to be set before `bun scripts/build.ts` runs. Setting
    # them here also lets step 1 + step 4 below reference them by name.
    export BUN_INSTALL="$PWD/.bun-install"
    export CARGO_HOME="$PWD/.cargo-home"
    mkdir -p "$BUN_INSTALL/build-cache" "$CARGO_HOME"

    # 1. Pre-populate scripts/build/fetch-cli.ts's tarball cache. The build's
    #    ninja graph has a `dep_fetch` edge per vendored dep that invokes
    #    `bun scripts/build/fetch-cli.ts dep …` with
    #    cache=$cacheDir/tarballs (source.ts:884). fetch-cli checks that
    #    cache first and skips the network download if the tarball already
    #    exists (fetch-cli.ts:160-162), then does extract+patch+stamp itself
    #    — so we don't need to run fetch-cli ourselves.
    # Hardlink tarballs from /nix/store: free + instant + works on every fs.
    # Safe here specifically because fetch-cli only reads the tarball — no
    # chmod or write follows. (For trees we copy + chmod, hardlinks would
    # corrupt the store inode; reflinks are the right tool there.)
    mkdir -p "$BUN_INSTALL/build-cache/tarballs"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: d:
        ''ln -f "${depTarballs.${name}}" "$BUN_INSTALL/build-cache/tarballs/${depCacheName name d}" || cp --reflink=auto "${depTarballs.${name}}" "$BUN_INSTALL/build-cache/tarballs/${depCacheName name d}"''
      ) deps
    )}

    # 1b. Redirect cargo at the vendored crates for lolhtml. `cargo build`
    #     runs inside vendor/lolhtml/c-api (scripts/build/source.ts:1249),
    #     but fetch-cli.ts does `rm -rf $dest` (fetch-cli.ts:166) on each
    #     vendor/<dep>/ before extraction, so we can't leave a config there.
    #     $CARGO_HOME/config.toml takes precedence over in-project .cargo/
    #     configs (cargo docs: config hierarchy) and lives outside vendor/.
    echo "==> $CARGO_HOME/config.toml"
    {
      echo '[source.crates-io]'
      echo 'replace-with = "vendored-sources"'
      echo '[source.vendored-sources]'
      echo 'directory = "${lolhtmlCargoVendor}"'
    } > "$CARGO_HOME/config.toml"

    # 1c. zstd headers for build.zig translate_c. zstd is system-linked so we
    #     skip its fetch — but build.zig:681 has `addIncludePath("vendor/zstd/lib")`
    #     hardcoded, so zig's @cImport(@cInclude("zstd.h")) needs the headers
    #     reachable at exactly that path. Symlink nixpkgs zstd.dev/include into
    #     place; the C/C++ side doesn't need this since CPATH covers it.
    echo "==> vendor/zstd/lib (symlink to nixpkgs zstd.dev)"
    mkdir -p vendor/zstd/lib
    for h in ${zstd.dev}/include/*.h; do
      ln -sf "$h" "vendor/zstd/lib/$(basename "$h")"
    done

    # 2. WebKit source. `release-penryn` forces webkit=local — bun's build
    #    system runs a nested cmake build on it (scripts/build/deps/webkit.ts
    #    lines 203-298). The profile's x64Cpu=penryn flows through
    #    computeCpuTargetFlags() into CMAKE_C_FLAGS/CMAKE_CXX_FLAGS, so the
    #    nested WebKit compile targets Penryn too.
    echo "==> vendor/WebKit"
    # --reflink=auto: ~10GB WebKit checkout, big win on COW filesystems.
    cp -r --reflink=auto --no-preserve=mode "${webkitSrc}" vendor/WebKit
    chmod -R u+w vendor/WebKit

    # 3. Zig compiler (oven-sh/zig fork — upstream zig won't work). Hand the
    #    prefetched zip to fetch-cli via file:// URL. fetchZig (zig.ts:557)
    #    handles extract + hoist + .zig-commit stamp + zig.exe/zls.exe
    #    symlinks; bun's fetch() supports file:// natively.
    echo "==> vendor/zig (via fetch-cli)"
    bun scripts/build/fetch-cli.ts zig \
      "file://${zigZip}" \
      "$PWD/vendor/zig" \
      '${zigCommit}'

    # 4. Node.js headers. Same trick: file:// URL into fetchPrebuilt
    #    (download.ts:176). It handles extract + hoist + rm of conflicting
    #    headers + .identity stamp.
    echo "==> nodejs-headers (via fetch-cli)"
    bun scripts/build/fetch-cli.ts prebuilt nodejs \
      "file://${nodeHeaders}" \
      "$BUN_INSTALL/build-cache/nodejs-headers-${nodeVer}" \
      '${nodeVer}' \
      include/node/openssl include/node/uv include/node/uv.h

    # 5. Toolchain env. commonToolchainEnv (CC/CXX/AR/RANLIB/LD) comes from
    #    flake.nix and matches the devShell shellHook exactly. Penryn-specific
    #    extras (ICU paths, BUN_WEBKIT_PATH, GIT_SHA) are local.
    ${commonToolchainEnv}
    export CMAKE_PREFIX_PATH="${icu.dev}:${icu.out}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export CPATH="${icu.dev}/include''${CPATH:+:$CPATH}"
    export LIBRARY_PATH="${icu.out}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
    # LD_LIBRARY_PATH for the buildPhase smoke test (`bun-profile --revision`
    # runs before fixupPhase patches RPATH; without these paths the loader
    # can't find the system .so files we just linked against).
    # lib.makeLibraryPath joins <input>/lib for each input.
    export LD_LIBRARY_PATH="${stdenv.cc.cc.lib}/lib:${lib.makeLibraryPath bunBuildInputs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export BUN_WEBKIT_PATH="$PWD/vendor/WebKit"
    # `src = self` strips .git, so git rev-parse HEAD would fail and the
    # revision baked into the binary would be zero_sha. We derive a 40-char
    # sha from the flake metadata:
    #   - `self.rev`       is set when the tree is clean (exactly 40 hex chars)
    #   - `self.dirtyRev`  is set when dirty, as "<rev>-dirty" — strip suffix
    # build.zig rejects anything that isn't exactly 40 chars, so "unknown"
    # fallback leads to zero_sha in the binary. That's acceptable for
    # fully-unknown state but is a red flag when we expected dirtyRev to work.
    export GIT_SHA='${
      if self ? rev then
        self.rev
      else if self ? dirtyRev then
        lib.removeSuffix "-dirty" self.dirtyRev
      else
        "unknown"
    }'
    echo "[configurePhase] GIT_SHA='$GIT_SHA' (len ''${#GIT_SHA})"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    bun scripts/build.ts --profile=release-penryn --build-dir=build/release-penryn
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/release-penryn/bun $out/bin/bun
    ln -s bun $out/bin/bunx
    runHook postInstall
  '';

  postFixup = ''
    # Swap the linker-baked nix-store interpreter
    # (e.g. /nix/store/.../glibc/lib/ld-linux-x86-64.so.2) for the FHS path
    # every glibc distro has at /lib64. Combined with skipping
    # autoPatchelfHook (so RUNPATH stays empty and NEEDED keeps bare
    # sonames), the result is a binary you can copy to any glibc-≥2.40
    # distro and run, no nix-isms baked in.
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 $out/bin/bun
  '';

  meta = with lib; {
    description = "Bun JavaScript runtime built for Penryn (pre-SSE4.2 x86_64)";
    homepage = "https://github.com/oven-sh/bun";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "bun";
  };
}
