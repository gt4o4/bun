{
  self,
  bunPackages,
  commonToolchainEnv,
  # x64 CPU tier the build will target. One of: "penryn", "nehalem", "haswell".
  # Selects the corresponding `release-${target}` build profile and feeds the
  # name into pname / version / build-dir / meta.description.
  target,
  # Build profile. Defaults to the fork's tier profile; pass an upstream one
  # (e.g. "release-local") to push it through this same derivation and tell
  # Nix-infrastructure failures apart from build-script porting failures.
  profile ? "release-${target}",

  lib,
  stdenv,
  fetchgit,
  fetchurl,
  bun,
  rustPlatform,
  coreutils,
  cacert,
  # Dynamic-linked system deps shared across release-tier builds
  # (profiles.ts `systemDeps`). c-ares is vendored again — see flake.nix.
  icu,
  zstd,
  brotli,
  libdeflate,
  zlib-ng,
  hdrhistogram_c,
  libuv,
  libhwy,
  libspng,
  libwebp,
  libjpeg,
}:

let
  bunSrc = self;
  bunVersion = self.shortRev or self.dirtyShortRev or "dev";
  # package.json "version"
  bunRelease = "1.4.2";

  # scripts/build/deps/webkit.ts WEBKIT_VERSION
  webkitRev = "2e2aa2290fac856d6f451ceacb58f7f5b44dd057";
  # scripts/build/deps/nodejs-headers.ts NODEJS_VERSION
  nodeVer = "26.3.0";

  # github-archive deps that are NOT system deps — every `repo` / `*_COMMIT`
  # pair in scripts/build/deps/*.ts whose name is absent from the tier's
  # `systemDeps`. fetch-cli.ts applies patches/<dep>/* itself, so nothing
  # here has to know about them. lolhtml and rust-argon2 are Cargo path
  # crates (vendor/lolhtml, vendor/rust-argon2) that must exist before cargo
  # runs; the ordinary fetch edges order that.
  deps = {
    boringssl = {
      repo = "oven-sh/boringssl";
      rev = "41bf9b59c2ebf277a7aa427e1ecad5cc80dd4d4f";
      hash = "sha256-pQKNVHXx6vCteFwYZmszACepIxIdYBEp9KYee/yJod0=";
    };
    cares = {
      repo = "c-ares/c-ares";
      rev = "c7a3138dcfe3bb0eaaf10c0c24c36dc66dc790ab";
      hash = "sha256-yeobMCmyOwQ3bCKb1RlInO4YCHTsSM2GOl3LpijA/gM=";
    };
    libarchive = {
      repo = "libarchive/libarchive";
      rev = "ded82291ab41d5e355831b96b0e1ff49e24d8939";
      hash = "sha256-BC8O/nFHBj/5uhDxo47QgOlJvL0Evb81kriEbdEbHaI=";
    };
    lolhtml = {
      repo = "oven-sh/lol-html";
      rev = "725ce499aa9b71e38b7a2d0a9fbb6d7294a4079e";
      hash = "sha256-r9g+2+Gi1KzLcuhpzUIYu4Zl/aK3yyxRBvxL6AABp0g=";
    };
    lshpack = {
      repo = "litespeedtech/ls-hpack";
      rev = "8905c024b6d052f083a3d11d0a169b3c2735c8a1";
      hash = "sha256-B9i/kBuxsVVD846r0jk4UZ4SEO6621Lz1lHW7xMO+XM=";
    };
    lsqpack = {
      repo = "litespeedtech/ls-qpack";
      rev = "1e9c5b8e59f8161c54f168a570c8bfdc59ded0c3";
      hash = "sha256-6dir5bfB41uZCKlSHirNfB0XVHurwB1zxyl+Aq67zC0=";
    };
    lsquic = {
      repo = "litespeedtech/lsquic";
      rev = "3181911301b1aa4f54c1ed690901abc674ee08fb";
      hash = "sha256-+MuQ+zJ+uRWXwjFjv1lsDRiCVgvjW2Ydm6hIkcxGFzU=";
    };
    mimalloc = {
      repo = "oven-sh/mimalloc";
      rev = "6a64e1ba7f5b2130d4efccb67ec87fd0003f0f6a";
      hash = "sha256-82NDQWrYI9/MphvRitS7fw2IFKt34P1e8Wn0qc3euLg=";
    };
    picohttpparser = {
      repo = "h2o/picohttpparser";
      rev = "066d2b1e9ab820703db0837a7255d92d30f0c9f5";
      hash = "sha256-Y3/yq29cf34FpbXcOT1c8v6o1HVPys6q+TX//1wTI+4=";
    };
    rust-argon2 = {
      repo = "sru-systems/rust-argon2";
      rev = "ed81866f163f0c7026aa6fd8388adf37242eb32a";
      hash = "sha256-53x5dETxkfr0iNScdsT0XBCz2SdeA2TuELbQXPvle68=";
    };
    tinycc = {
      repo = "oven-sh/tinycc";
      rev = "05f0fafaa3be31e31d7b4b5c17dc60f62c991171";
      hash = "sha256-UHUGgDEpI6Wf3TauQfcJHY415RkJ0OCyWwsz6pU0vAg=";
    };
  };
  # fetch-cli.ts:249 — the URL string doubles as the prefetch-cache key.
  depUrl = d: "https://github.com/${d.repo}/archive/${d.rev}.tar.gz";
  depTarballs = lib.mapAttrs (
    _: d:
    fetchurl {
      url = depUrl d;
      inherit (d) hash;
    }
  ) deps;

  # deps/nodejs-headers.ts — fetched through fetchPrebuilt → downloadWithRetry,
  # so the same by-url prefetch entry serves it.
  nodeHeadersUrl = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-headers.tar.gz";
  nodeHeaders = fetchurl {
    url = nodeHeadersUrl;
    hash = "sha256-/KETxdWt2L+xqjESmiSsuNSappqzwiosxWmuyIlgUm0=";
  };

  # scripts/build/download.ts: `$BUN_BUILD_PREFETCH_DIR/by-url/<sha256(url)[:32]>`
  # is consulted before any download — one key space for dep tarballs and
  # prebuilt archives alike, and a miss is a loud sandbox network error.
  prefetchKey = url: builtins.substring 0 32 (builtins.hashString "sha256" url);
  prefetchEntries =
    (lib.mapAttrsToList (name: d: {
      url = depUrl d;
      file = depTarballs.${name};
    }) deps)
    ++ [
      {
        url = nodeHeadersUrl;
        file = nodeHeaders;
      }
    ];

  # Local WebKit source (deps/webkit.ts honours $BUN_WEBKIT_PATH). Shallow:
  # nothing reads history, and oven-sh/WebKit's full history is gigabytes.
  webkitSrc = fetchgit {
    url = "https://github.com/oven-sh/WebKit.git";
    rev = webkitRev;
    hash = "sha256-EJsxFF2NIROfGkvlXTKRR+MSO1fFwquZaqD9G4gvzuU=";
  };

  # Every crates.io dependency of the workspace, straight from the root
  # Cargo.lock — it already resolves the two path crates' transitive deps and
  # has no git sources, so no outputHashes. cargo runs with --locked.
  cargoVendor = rustPlatform.importCargoLock { lockFile = "${bunSrc}/Cargo.lock"; };

  # FOD: download cache from `bun install` (hashing node_modules would be
  # fragile due to symlinks / hoisting).
  bunInstallCache = stdenv.mkDerivation {
    pname = "bun-${target}-install-cache";
    # Keyed on the release, not the commit: a FOD's store path is
    # name+hash, so naming it per commit would re-download the cache on
    # every rebuild even though the lockfiles are unchanged.
    version = bunRelease;
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
    outputHash = "sha256-HgNoT/Ky3hm1x6S8PhuLUu+/EC8mnHCjKf5ytAxBzz4=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "bun-${target}";
  version = "${bunRelease}-${target}-${bunVersion}";

  src = bunSrc;

  passthru = {
    inherit
      depTarballs
      webkitSrc
      nodeHeaders
      bunInstallCache
      cargoVendor
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
    zlib-ng # flake.nix passes this with withZlibCompat=true (libz.so.1 soname)
    hdrhistogram_c
    libuv
    libhwy # .a-only in nixpkgs; statically linked
    libspng
    libwebp
    libjpeg # nixpkgs alias for libjpeg-turbo; provides turbojpeg.h + libturbojpeg.so
  ];

  dontUseCmakeConfigure = true;
  # Skip every stdenv step that touches the ELF. Ninja already stripped
  # (bun-profile → bun); nothing to shrink or patch afterwards.
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
  # cargo must never reach for the network; the vendored sources are complete.
  CARGO_NET_OFFLINE = "true";

  configurePhase = ''
    runHook preConfigure

    # $PWD-relative build directories.
    export BUN_INSTALL="$PWD/.bun-install"
    export CARGO_HOME="$PWD/.cargo-home"
    export BUN_BUILD_PREFETCH_DIR="$PWD/.prefetch"
    mkdir -p vendor "$BUN_INSTALL/build-cache" "$CARGO_HOME" "$BUN_BUILD_PREFETCH_DIR/by-url"

    # Toolchain env (matches devShell); stdenv propagates buildInputs automatically.
    ${commonToolchainEnv}

    # Prefetch cache: every URL the fetch edges will ask for.
    ${lib.concatMapStringsSep "\n" (
      e: ''ln -s "${e.file}" "$BUN_BUILD_PREFETCH_DIR/by-url/${prefetchKey e.url}"''
    ) prefetchEntries}

    # Cargo vendor config lives in $CARGO_HOME: cargo-config.ts regenerates the
    # repo-root .cargo/config.toml (linker + rustflags only, no [source]
    # table), so the two compose.
    cat > "$CARGO_HOME/config.toml" <<EOF
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "${cargoVendor}"
    EOF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    bun scripts/build.ts --profile=${profile} --build-dir=build/${profile}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/${profile}/bun $out/bin/bun
    ln -s bun $out/bin/bunx
    runHook postInstall
  '';

  meta = with lib; {
    description =
      {
        penryn = "Bun JavaScript runtime built for Penryn (pre-SSE4.2 x86_64)";
        nehalem = "Bun JavaScript runtime built for Nehalem (SSE4.2 + POPCNT, no AVX)";
        haswell = "Bun JavaScript runtime built for Haswell (AVX2, BMI2)";
      }
      .${target};
    homepage = "https://github.com/oven-sh/bun";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "bun";
  };
})
