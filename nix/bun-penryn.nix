{
  # Shared with devShells.default via ../flake.nix.
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
  # System-linked deps for release-penryn (scripts/build/profiles.ts:systemDeps).
  # Headers flow from `.dev` via CPATH; zstd.dev is additionally symlinked
  # under vendor/zstd/lib to satisfy build.zig:681's hardcoded include path.
  icu,
  zstd,
  brotli,
  libdeflate,
  c-ares,
  zlib-ng,
  hdrhistogram_c,
  libuv,
  libhwy,
}:

let
  bunSrc = self;
  bunVersion = self.shortRev or self.dirtyShortRev or "dev";

  webkitRev = "4d5e75ebd84a14edbc7ae264245dcd77fe597c10";
  zigCommit = "365343af4fc5a1a632e6b54aadd0b87be30edd81";
  nodeVer = "24.3.0";

  # Vendored deps. `hash` is the raw GitHub-archive tarball hash: we populate
  # scripts/build/fetch-cli.ts's tarball cache and let it run its own extract
  # + patch + stamp logic. Deps in release-penryn's systemDeps list don't
  # appear here — they link from bunBuildInputs and need no fetch/build.
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

  depTarballs = lib.mapAttrs (
    _: d:
    fetchurl {
      url = "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz";
      inherit (d) hash;
    }
  ) deps;

  # Cache filename fetch-cli.ts looks for: `<name>-<sha256(url)[:16]>.tar.gz`
  # (see fetch-cli.ts:154-156).
  depCacheName =
    name: d:
    "${name}-${
      builtins.substring 0 16 (
        builtins.hashString "sha256" "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz"
      )
    }.tar.gz";

  # lolhtml runs `cargo build` → needs network. Materialize the crate tree
  # from its Cargo.lock at eval time via rustPlatform.importCargoLock.
  lolhtmlLockfile = stdenv.mkDerivation {
    name = "lolhtml-cargo-lock";
    src = depTarballs.lolhtml;
    dontUnpack = false;
    dontConfigure = true;
    dontBuild = true;
    installPhase = "install -Dm644 c-api/Cargo.lock $out";
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

  # zlib-ng in native mode ships libz-ng.so.2; compat mode keeps the stock
  # libz.so.1 soname that bun's -lz expects.
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
    # libhwy is .a-only in nixpkgs; we inline it and skip the source fetch.
    libhwy
  ];

  # FOD for bun's install cache. FODs get network, so `bun install
  # --frozen-lockfile` can hit the registry. Output is the extracted
  # package cache (not a node_modules tree) — the main build points
  # BUN_INSTALL_CACHE_DIR here and runs a fresh install against it.
  # Much smaller content hash surface than a full node_modules tree:
  # only the downloaded packages affect the hash, not workspace
  # symlinks or install-time hoisting decisions.
  bunInstallCache = stdenv.mkDerivation {
    pname = "bun-penryn-install-cache";
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
    # inject them via patchShebangs / RPATH shrinking on prebuilt binaries.
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$out
      mkdir -p $out
      for dir in "" packages/bun-error src/node-fallbacks; do
        (cd "$PWD/$dir" && bun install --frozen-lockfile)
      done
      # Bun creates absolute symlinks inside the cache
      # (e.g. abort-controller/3.0.0@@@1 → $out/abort-controller@3.0.0@@@1).
      # FOD outputs can't reference their own store path, so rewrite each
      # self-pointing symlink to a relative target.
      find $out -type l | while read -r link; do
        target=$(readlink "$link")
        case "$target" in
          "$out"/*)
            rel=$(realpath --relative-to="$(dirname "$link")" "$target")
            ln -sfn "$rel" "$link"
            ;;
        esac
      done
      runHook postInstall
    '';

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-4PLfZ+YIv06fxjc02iKDdjtDX5Wmq59gZTwlD0NL+50=";
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
      bunInstallCache
      lolhtmlCargoVendor
      ;
  };

  # autoPatchelfHook is intentionally omitted — it bakes nix-store RUNPATHs +
  # interpreter into the binary. We want bare NEEDEDs + /lib64 interpreter so
  # the binary is portable to any glibc-≥2.40 distro. postFixup swaps the
  # linker-baked interpreter for the FHS path.
  # Trade-off: ./result/bin/bun won't run from /nix/store without
  # LD_LIBRARY_PATH set. Use `nix shell .#bun-penryn -c bun` or run from a
  # distro with the runtime libs installed.
  nativeBuildInputs = bunPackages ++ [ coreutils ];
  buildInputs = bunBuildInputs;

  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure

    mkdir -p vendor

    # Sandbox-friendly cache dirs. Defaults ($HOME/.cargo, $HOME/.bun) live
    # under /homeless-shelter and are read-only. Both are read at
    # config-resolve time (config.ts: cacheDir = $BUN_INSTALL/build-cache;
    # tools.ts: CARGO_HOME), so set them before `bun scripts/build.ts`.
    #
    # BUN_INSTALL_CACHE_DIR: points bun install at the cache FOD
    # (~20 MB of extracted packages) instead of the default
    # $HOME/.bun/install/cache. Codegen's `bun install --frozen-lockfile`
    # runs fresh from scratch — writes a new node_modules, reads tarball
    # contents from our /nix/store cache, needs no network.
    export BUN_INSTALL="$PWD/.bun-install"
    export CARGO_HOME="$PWD/.cargo-home"
    export BUN_INSTALL_CACHE_DIR="${bunInstallCache}"
    mkdir -p "$BUN_INSTALL/build-cache/tarballs" "$CARGO_HOME"

    # Tarball cache: ninja's dep_fetch edge invokes fetch-cli, which reads
    # from cache=$cacheDir/tarballs (source.ts:884) and skips the network
    # if the tarball exists (fetch-cli.ts:160-162). Symlink in: tar -xzmf
    # follows symlinks, so no copy is needed.
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: d:
        ''ln -sf "${depTarballs.${name}}" "$BUN_INSTALL/build-cache/tarballs/${depCacheName name d}"''
      ) deps
    )}

    # Cargo: redirect crates.io to our vendored crate tree. `cargo build`
    # runs inside vendor/lolhtml/c-api (source.ts:1249), but fetch-cli's
    # `rm -rf $dest` (fetch-cli.ts:166) wipes vendor/<dep>/ before extract
    # — so we can't put a config there. $CARGO_HOME/config.toml takes
    # precedence over in-project .cargo/ configs and survives vendor wipes.
    {
      echo '[source.crates-io]'
      echo 'replace-with = "vendored-sources"'
      echo '[source.vendored-sources]'
      echo 'directory = "${lolhtmlCargoVendor}"'
    } > "$CARGO_HOME/config.toml"

    # zstd headers: build.zig:681 hardcodes vendor/zstd/lib. Zig follows
    # directory symlinks on include paths, so one dir-level symlink works.
    mkdir -p vendor/zstd
    ln -s ${zstd.dev}/include vendor/zstd/lib

    # Zig compiler (oven-sh/zig fork). fetchZig (zig.ts:557) handles
    # extract + hoist + .zig-commit + zig.exe/zls.exe symlinks; bun's
    # fetch() supports file:// URLs.
    bun scripts/build/fetch-cli.ts zig \
      "file://${zigZip}" \
      "$PWD/vendor/zig" \
      '${zigCommit}'

    # Node.js headers: same pattern as zig, into fetchPrebuilt
    # (download.ts:176).
    bun scripts/build/fetch-cli.ts prebuilt nodejs \
      "file://${nodeHeaders}" \
      "$BUN_INSTALL/build-cache/nodejs-headers-${nodeVer}" \
      '${nodeVer}' \
      include/node/openssl include/node/uv include/node/uv.h

    # Toolchain + runtime env. commonToolchainEnv (CC/CXX/AR/RANLIB/LD)
    # comes from flake.nix and matches the devShell. No per-dep include/
    # lib paths here: stdenv's setup hooks propagate bunBuildInputs into
    # NIX_CFLAGS_COMPILE, NIX_LDFLAGS, and CMAKE_PREFIX_PATH automatically.
    ${commonToolchainEnv}

    # LD_LIBRARY_PATH for the post-link smoke test (`bun-profile --revision`).
    # The binary has empty RUNPATH and bare-soname NEEDEDs (the release
    # shape), so the loader needs these paths — same as an end user on a
    # non-Nix host without the distro packages installed.
    export LD_LIBRARY_PATH="${stdenv.cc.cc.lib}/lib:${lib.makeLibraryPath bunBuildInputs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # WebKit: build treats vendor/WebKit/ as read-only (outputs land under
    # build/<profile>/deps/WebKit/, webkit.ts:27-29). Point at the
    # /nix/store path directly, no copy.
    export BUN_WEBKIT_PATH="${webkitSrc}"

    # `src = self` strips .git → `git rev-parse HEAD` fails →
    # zero_sha baked into the binary. build.zig demands exactly 40 hex
    # chars; "unknown" falls back to zero_sha. Feed it explicitly from
    # flake metadata.
    export GIT_SHA='${
      if self ? rev then
        self.rev
      else if self ? dirtyRev then
        lib.removeSuffix "-dirty" self.dirtyRev
      else
        "unknown"
    }'

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

  # Swap the linker-baked nix-store interpreter for the FHS path so the
  # binary runs on any glibc distro. Combined with no autoPatchelfHook
  # (empty RUNPATH, bare NEEDEDs), the result is fully portable.
  postFixup = ''
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
