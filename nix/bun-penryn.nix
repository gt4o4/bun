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
  # systemDeps). The build still fetches each dep's github archive for headers,
  # but skips the static-archive build and links the .so from these inputs.
  zstd,
  brotli,
  libdeflate,
  c-ares,
  zlib-ng,
  hdrhistogram_c,
  libuv,
  autoPatchelfHook,
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

  # 15 vendored deps that bun's build system normally fetches into vendor/<name>/.
  # `hash` is the RAW GitHub archive tarball hash (fetchurl, not fetchFromGitHub):
  # we pre-populate scripts/build/fetch-cli.ts's tarball cache and let it do
  # extract + patch + stamp with bun's own logic. Patch application flags,
  # CRLF normalization, and identity format all stay in sync with the build
  # system automatically.
  deps = {
    boringssl = {
      owner = "oven-sh";
      repo = "boringssl";
      rev = "0c5fce43b7ed5eb6001487ee48ac65766f5ddcd1";
      hash = "sha256-pBSx0QX+8QVpe3QowL5ff8Z0iYSeqidpMa6DRNeKmbg=";
      patches = [ ];
    };
    brotli = {
      owner = "google";
      repo = "brotli";
      rev = "v1.1.0";
      hash = "sha256-5yCmyilCi4A/StFlNxdx9TmPq6OX7fZ3iDehhZnqE/8=";
      patches = [ ];
    };
    cares = {
      owner = "c-ares";
      repo = "c-ares";
      rev = "3ac47ee46edd8ea40370222f91613fc16c434853";
      hash = "sha256-jJQRbLNmrkpE5IfaTZ9+c2KH0ynvpviP3wd80tCi5Lg=";
      patches = [ ];
    };
    hdrhistogram = {
      owner = "HdrHistogram";
      repo = "HdrHistogram_c";
      rev = "be60a9987ee48d0abf0d7b6a175bad8d6c1585d1";
      hash = "sha256-gRxeWuUwOnWt5QaIiAr2qtXS+VHsV4X2gYa9GGNc38k=";
      patches = [ ];
    };
    highway = {
      owner = "google";
      repo = "highway";
      rev = "ac0d5d297b13ab1b89f48484fc7911082d76a93f";
      hash = "sha256-p6gW9LYqBBT/DTnAqIdYR0aN1vfJrXF4GiRGmnVs3qc=";
      patches = [ "patches/highway/silence-warnings.patch" ];
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
    libdeflate = {
      owner = "ebiggers";
      repo = "libdeflate";
      rev = "c8c56a20f8f621e6a966b716b31f1dedab6a41e3";
      hash = "sha256-HlzAa9vz4SRdi4nJ41iPUH48i8U/6Lgil3Cp6GYd6oE=";
      patches = [ ];
    };
    libuv = {
      owner = "libuv";
      repo = "libuv";
      rev = "f3ce527ea940d926c40878ba5de219640c362811";
      hash = "sha256-RgQNUeiqhqfITjd+Ik1CfDUCLsbj7Y7TmUk7DYV00M8=";
      patches = [ "patches/libuv/fix-win-pipe-cancel-race.patch" ];
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
    zlib = {
      owner = "zlib-ng";
      repo = "zlib-ng";
      rev = "12731092979c6d07f42da27da673a9f6c7b13586";
      hash = "sha256-oNKl0SLIS1ank6FVOpwzJ/sut0ab96hreePHvl2S6NY=";
      patches = [ "patches/zlib/clang-cl-arm64.patch" ];
    };
    zstd = {
      owner = "facebook";
      repo = "zstd";
      rev = "f8745da6ff1ad1e7bab384bd1f9d742439278e99";
      hash = "sha256-SwvR8M+yXmG5EDw18nOVUw/1tMDSUToA/XRYSehepSw=";
      patches = [ ];
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
  depCacheName = name: d:
    "${name}-${builtins.substring 0 16 (
      builtins.hashString "sha256"
        "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz"
    )}.tar.gz";

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
  # unzip/xz/pkg-config. We add only what the Nix build needs beyond that:
  # coreutils (explicit), autoPatchelfHook (RPATH fixup), icu (Penryn binary
  # links system ICU 76).
  nativeBuildInputs = bunPackages ++ [
    coreutils
    autoPatchelfHook
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
    cp -a "${bunNodeModules}/node_modules" node_modules
    chmod -R u+w node_modules
    for wp in \
      packages/bun-types \
      packages/@types/bun \
      packages/bun-error \
      src/node-fallbacks \
    ; do
      if [ -d "${bunNodeModules}/$wp/node_modules" ]; then
        cp -a "${bunNodeModules}/$wp/node_modules" "$wp/node_modules"
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
    mkdir -p "$BUN_INSTALL/build-cache/tarballs"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: d:
        ''cp "${depTarballs.${name}}" "$BUN_INSTALL/build-cache/tarballs/${depCacheName name d}"''
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

    # 2. WebKit source. `release-penryn` forces webkit=local — bun's build
    #    system runs a nested cmake build on it (scripts/build/deps/webkit.ts
    #    lines 203-298). The profile's x64Cpu=penryn flows through
    #    computeCpuTargetFlags() into CMAKE_C_FLAGS/CMAKE_CXX_FLAGS, so the
    #    nested WebKit compile targets Penryn too.
    echo "==> vendor/WebKit"
    cp -r --no-preserve=mode "${webkitSrc}" vendor/WebKit
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
      if self ? rev then self.rev
      else if self ? dirtyRev then lib.removeSuffix "-dirty" self.dirtyRev
      else "unknown"
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

  meta = with lib; {
    description = "Bun JavaScript runtime built for Penryn (pre-SSE4.2 x86_64)";
    homepage = "https://github.com/oven-sh/bun";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "bun";
  };
}
