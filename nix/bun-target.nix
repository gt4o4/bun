{
  self,
  bunPackages,
  commonToolchainEnv,
  # x64 CPU tier the build will target. One of: "penryn", "nehalem", "haswell".
  # Selects the corresponding `release-${target}` build profile and feeds the
  # name into pname / version / build-dir / meta.description.
  target,

  lib,
  stdenv,
  fetchgit,
  fetchurl,
  bun,
  rustPlatform,
  coreutils,
  cacert,
  # Dynamic-linked system deps shared across release-tier builds.
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

  webkitRev = "5488984d20e0dbfe4be2c3ba8fb18eb81a5e0e8b";
  # Stable zig. Must match scripts/build/zig.ts::ZIG_COMMIT — parallel zig
  # + LTO is pathologically slow on these release-tier builds, so we stay on
  # serial codegen.
  zigCommit = "04e7f6ac1e009525bc00934f20199c68f04e0a24";
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
      patches = [ "patches/lshpack/bss-huff-tables.patch" ];
    };
    mimalloc = {
      owner = "oven-sh";
      repo = "mimalloc";
      rev = "f15aecb94fc8096008bf87b90c53ed682026914a";
      hash = "sha256-2Yt/MV8WuCzUO342p+H3POrpQi+Luo67mYmceKVCd/w=";
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
    libjpeg-turbo = {
      owner = "libjpeg-turbo";
      repo = "libjpeg-turbo";
      rev = "e352b02f794f701407b39af08576035ba3360d60";
      hash = "sha256-RA86lDkMeOq4j3S5KUTS9rJI5ZLphEEuOJiF37V5a/A=";
      patches = [ ];
    };
    libspng = {
      owner = "randy408";
      repo = "libspng";
      rev = "fb768002d4288590083a476af628e51c3f1d47cd";
      hash = "sha256-1laBMpDXCnULaedoMj/zs4da34wujC/bTlfKFGer+Go=";
      patches = [ ];
    };
    libwebp = {
      owner = "webmproject";
      repo = "libwebp";
      rev = "b7e29b9d75bd31422b00c2a446d49d7af06c328d";
      hash = "sha256-dvuJtEVP8hYbsMyiz4MuGbi0ABsO9C+8wrSkN8lFsrY=";
      patches = [ ];
    };
    lsqpack = {
      owner = "litespeedtech";
      repo = "ls-qpack";
      rev = "1e9c5b8e59f8161c54f168a570c8bfdc59ded0c3";
      hash = "sha256-6dir5bfB41uZCKlSHirNfB0XVHurwB1zxyl+Aq67zC0=";
      patches = [ ];
    };
    lsquic = {
      owner = "litespeedtech";
      repo = "lsquic";
      rev = "3181911301b1aa4f54c1ed690901abc674ee08fb";
      hash = "sha256-+MuQ+zJ+uRWXwjFjv1lsDRiCVgvjW2Ydm6hIkcxGFzU=";
      patches = [ ];
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
    hash = "sha256-xFxCb5MFJnTw65XDwkq4x+AcKULsmDfj1T+O0cQhOMo=";
    deepClone = true;
    leaveDotGit = false;
  };

  zigZip = fetchurl {
    url = "https://github.com/oven-sh/zig/releases/download/autobuild-${zigCommit}/bootstrap-x86_64-linux-musl.zip";
    hash = "sha256-DAm0TAskMtetinWbaFuorh+IOQKFGsUuKCrWCom+vkI=";
  };

  nodeHeaders = fetchurl {
    url = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-headers.tar.gz";
    hash = "sha256-BF6b9HfNXbDsZ/jBpjun94Te3+LFgePQ7Qm4jpEV3Qc=";
  };

  # FOD: download cache from `bun install` (hashing node_modules would be
  # fragile due to symlinks / hoisting).
  bunInstallCache = stdenv.mkDerivation {
    pname = "bun-${target}-install-cache";
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
  pname = "bun-${target}";
  version = "1.3.14-${target}-${bunVersion}";

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

  # Nix doesn't touch the ELF at all: no autoPatchelfHook, no RUNPATH
  # shrink, no strip, no interpreter swap. NEEDEDs stay as bare sonames
  # (libz.so.1 etc.) but PT_INTERP keeps the /nix/store path the linker
  # baked in — so $out/bin/bun runs on this nix host as-is, but needs a
  # one-off `patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2` by
  # the end user to run on FHS distros. glibc floor is 2.34 (RHEL 9 /
  # Ubuntu 22.04+) via the compat stdenv passed in from flake.nix.
  nativeBuildInputs = bunPackages ++ [ coreutils ];
  buildInputs = [
    icu
    zstd
    brotli
    libdeflate
    c-ares
    zlib-ng # flake.nix passes this with withZlibCompat=true (libz.so.1 soname)
    hdrhistogram_c
    libuv
    libhwy # .a-only in nixpkgs; statically linked
  ];

  # lolhtml's -Zbuild-std=std,panic_abort (lolhtml.ts:84) requires nightly
  # Rust + rust-src. nixpkgs only ships stable rustc. Disable the
  # immediate-abort path — the only penalty is ~230 KB extra (backtrace code
  # in the precompiled std's panic handler). The stable -Cpanic=abort path
  # still fires and the FFI boundary is abort-on-unwind regardless.
  postPatch = ''
    substituteInPlace scripts/build/deps/lolhtml.ts \
      --replace-fail 'cfg.release && canBuildStdImmediateAbort' 'false'
  '';

  dontUseCmakeConfigure = true;
  # Skip every stdenv step that touches the ELF. Ninja already stripped
  # (see [645/646] strip bun); nothing to shrink or patch afterwards.
  dontStrip = true;
  dontPatchELF = true;
  # Same reason as the devShell: nixpkgs' default fortify wraps glibc
  # prototypes with warn_unused_result, which trips -Werror on bun's
  # getgroups() call in BunProcess.cpp.
  hardeningDisable = [ "fortify" ];

  # GIT_SHA: src = self strips .git, so feed rev from flake metadata.
  # LD_LIBRARY_PATH: post-link smoke test runs the bare-NEEDED binary.
  BUN_INSTALL_CACHE_DIR = "${bunInstallCache}";
  BUN_WEBKIT_PATH = "${webkitSrc}";
  GIT_SHA =
    if self ? rev then
      self.rev
    else if self ? dirtyRev then
      lib.removeSuffix "-dirty" self.dirtyRev
    else
      "unknown";
  # Only buildInputs. No libstdc++ here: sub-native release tiers skip
  # the post-link smoke test, so bun-profile never runs inside the sandbox.
  LD_LIBRARY_PATH = lib.makeLibraryPath finalAttrs.buildInputs;

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

    # Zig compiler (oven-sh/zig fork). fetchZig (zig.ts:557) handles
    # extract + hoist + .zig-commit + zig.exe/zls.exe symlinks; bun's
    # fetch() supports file:// URLs.
    bun scripts/build/fetch-cli.ts zig \
      "file://${zigZip}" \
      "$PWD/vendor/zig" \
      '${zigCommit}'

    bun scripts/build/fetch-cli.ts prebuilt nodejs \
      "file://${nodeHeaders}" \
      "$BUN_INSTALL/build-cache/nodejs-headers-${nodeVer}" \
      '${nodeVer}' \
      include/node/openssl include/node/uv include/node/uv.h

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    bun scripts/build.ts --profile=release-${target} --build-dir=build/release-${target}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/release-${target}/bun $out/bin/bun
    ln -s bun $out/bin/bunx
    runHook postInstall
  '';

  meta = with lib; {
    description = {
      penryn = "Bun JavaScript runtime built for Penryn (pre-SSE4.2 x86_64)";
      nehalem = "Bun JavaScript runtime built for Nehalem (SSE4.2 + POPCNT, no AVX)";
      haswell = "Bun JavaScript runtime built for Haswell (AVX2, BMI2)";
    }.${target};
    homepage = "https://github.com/oven-sh/bun";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "bun";
  };
})
