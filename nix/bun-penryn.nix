{
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
  unzip,
  # Dynamic-linked system deps for release-penryn.
  icu,
  zstd,
  brotli,
  libdeflate,
  c-ares,
  zlib-ng,
  hdrhistogram_c,
  libuv,
  libhwy,
  patchelf,
}:

let
  bunSrc = self;
  bunVersion = self.shortRev or self.dirtyShortRev or "dev";

  webkitRev = "4d5e75ebd84a14edbc7ae264245dcd77fe597c10";
  # Stable zig — must match --zigCommit= passed to build.ts so the build
  # uses serial codegen (parallel zig + penryn LTO is pathologically slow).
  zigCommit = "365343af4fc5a1a632e6b54aadd0b87be30edd81";
  nodeVer = "24.3.0";

  # Source tarballs for vendored deps. systemDeps come from buildInputs instead.
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

  # Mirror fetch-cli.ts's cache filename convention.
  depCacheName =
    name: d:
    "${name}-${
      builtins.substring 0 16 (
        builtins.hashString "sha256" "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz"
      )
    }.tar.gz";

  # Vendor lolhtml's crate tree offline. Mini-derivation extracts Cargo.lock
  # from the tarball.
  lolhtmlCargoVendor = rustPlatform.importCargoLock {
    lockFileContents = builtins.readFile (
      stdenv.mkDerivation {
        name = "lolhtml-cargo-lock";
        src = depTarballs.lolhtml;
        dontConfigure = true;
        dontBuild = true;
        installPhase = "install -Dm644 c-api/Cargo.lock $out";
      }
    );
  };

  webkitSrc = fetchgit {
    url = "https://github.com/oven-sh/WebKit.git";
    rev = webkitRev;
    hash = "sha256-bnNcqYtX8+3KL/uJW0TPU3MfByToP37S1zuqeWWMfvw=";
    deepClone = true;
    leaveDotGit = false;
  };

  # oven-sh/zig fork prebuilt (not pkgs.zig). Extracted via fetch-cli.ts.
  # src narrowed to scripts/build/ to avoid hash busting on unrelated changes.
  zigExtracted =
    let
      zigZip = fetchurl {
        url = "https://github.com/oven-sh/zig/releases/download/autobuild-${zigCommit}/bootstrap-x86_64-linux-musl.zip";
        hash = "sha256-Baetu5WBFqAUx/qtvfsemQpc6JQRJKkcVI9F0r8NDTg=";
      };
    in
    stdenv.mkDerivation {
      name = "bun-zig-${zigCommit}";
      src = builtins.path {
        name = "bun-scripts-build";
        path = "${self}/scripts/build";
        recursive = true;
      };
      nativeBuildInputs = [
        bun
        unzip
      ];
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        runHook preInstall
        export HOME=$TMPDIR
        bun ./fetch-cli.ts zig "file://${zigZip}" $out "${zigCommit}"
        runHook postInstall
      '';
    };

  nodeHeaders = fetchurl {
    url = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-headers.tar.gz";
    hash = "sha256-BF6b9HfNXbDsZ/jBpjun94Te3+LFgePQ7Qm4jpEV3Qc=";
  };

  # FOD: download cache from `bun install` (hashing node_modules would be
  # fragile due to symlinks / hoisting).
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
    dontFixup = true; # FOD outputs can't reference /nix/store

    installPhase = ''
      runHook preInstall
      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$out
      mkdir -p $out
      for dir in "" packages/bun-error src/node-fallbacks; do
        (cd "$PWD/$dir" && bun install --frozen-lockfile)
      done
      # Rewrite absolute self-symlinks to relative (FOD can't reference $out).
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
stdenv.mkDerivation (finalAttrs: {
  pname = "bun-penryn";
  version = "1.3.13-penryn-${bunVersion}";

  src = bunSrc;

  passthru = {
    inherit
      depTarballs
      webkitSrc
      zigExtracted
      nodeHeaders
      bunInstallCache
      lolhtmlCargoVendor
      ;
  };

  # No autoPatchelfHook — binary stays portable (bare NEEDEDs + /lib64
  # interpreter). Needs LD_LIBRARY_PATH to run from the store.
  nativeBuildInputs = bunPackages ++ [
    coreutils
    patchelf
  ];
  buildInputs = [
    icu
    zstd
    brotli
    libdeflate
    c-ares
    (zlib-ng.override { withZlibCompat = true; }) # libz.so.1 soname for -lz
    hdrhistogram_c
    libuv
    libhwy # .a-only in nixpkgs; statically linked
  ];

  dontUseCmakeConfigure = true;

  # GIT_SHA: src = self strips .git, so feed rev from flake metadata.
  # LD_LIBRARY_PATH: post-link smoke test runs the bare-NEEDED binary.
  BUN_INSTALL_CACHE_DIR = "${bunInstallCache}";
  BUN_WEBKIT_PATH = "${webkitSrc}";
  BUN_ZIG_PATH = "${zigExtracted}";
  GIT_SHA =
    if self ? rev then
      self.rev
    else if self ? dirtyRev then
      lib.removeSuffix "-dirty" self.dirtyRev
    else
      "unknown";
  LD_LIBRARY_PATH = "${stdenv.cc.cc.lib}/lib:${lib.makeLibraryPath finalAttrs.buildInputs}";

  configurePhase = ''
    runHook preConfigure

    # $PWD-relative build directories.
    export BUN_INSTALL="$PWD/.bun-install"
    export CARGO_HOME="$PWD/.cargo-home"
    mkdir -p vendor "$BUN_INSTALL/build-cache/tarballs" "$CARGO_HOME"

    # Toolchain env (matches devShell); stdenv propagates buildInputs automatically.
    ${commonToolchainEnv}

    # Pre-populate tarball cache so dep_fetch skips network.
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: d:
        ''ln -sf "${depTarballs.${name}}" "$BUN_INSTALL/build-cache/tarballs/${depCacheName name d}"''
      ) deps
    )}

    # Cargo vendor config — lives in $CARGO_HOME so fetch-cli's vendor wipe
    # doesn't delete it.
    {
      echo '[source.crates-io]'
      echo 'replace-with = "vendored-sources"'
      echo '[source.vendored-sources]'
      echo 'directory = "${lolhtmlCargoVendor}"'
    } > "$CARGO_HOME/config.toml"

    # build.zig hardcodes vendor/zstd/lib for zstd headers.
    mkdir -p vendor/zstd
    ln -s ${zstd.dev}/include vendor/zstd/lib

    bun scripts/build/fetch-cli.ts prebuilt nodejs \
      "file://${nodeHeaders}" \
      "$BUN_INSTALL/build-cache/nodejs-headers-${nodeVer}" \
      '${nodeVer}' \
      include/node/openssl include/node/uv include/node/uv.h

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    bun scripts/build.ts --profile=release-penryn --build-dir=build/release-penryn --zigCommit=${zigCommit}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/release-penryn/bun $out/bin/bun
    ln -s bun $out/bin/bunx
    runHook postInstall
  '';

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
})
