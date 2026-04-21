{
  description = "Bun - A fast all-in-one JavaScript runtime";

  # Uncomment this when you set up Cachix to enable automatic binary cache
  # nixConfig = {
  #   extra-substituters = [
  #     "https://bun-dev.cachix.org"
  #   ];
  #   extra-trusted-public-keys = [
  #     "bun-dev.cachix.org-1:REPLACE_WITH_YOUR_PUBLIC_KEY"
  #   ];
  # };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Old-glibc provider for the Penryn release binary. 22.05 ships glibc
    # 2.34 — the oldest release with gcc-12 available, which we need for
    # C++23 <expected> used by WebKit/WTF. Every `bun-penryn` dep has its
    # `stdenv` overridden to this release's stdenv, so the final binary's
    # GLIBC_ symbol floor is 2.34 instead of unstable's 2.38+. Only used
    # in the bun-penryn derivation; devShell stays on unstable.
    nixpkgs-compat.url = "github:NixOS/nixpkgs/nixos-22.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-compat,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
        pkgsCompat = import nixpkgs-compat {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

        # Stdenv swapped to 22.05's gcc-12 + glibc + bintools via a fresh
        # cc-wrapper under unstable's wrapCCWith — drops the backref to
        # 22.05's stdenv that would otherwise cause overrideCC to infinitely
        # recurse.
        compatStdenv = pkgs.overrideCC pkgs.stdenv (
          pkgs.wrapCCWith {
            cc = pkgsCompat.gcc12.cc;
            libc = pkgsCompat.glibc;
            bintools = pkgsCompat.gcc12.bintools;
            gccForLibs = pkgsCompat.gcc12.cc;
          }
        );

        # LLVM 21 - matching the bootstrap script (targets 21.1.8, actual version from nixpkgs-unstable)
        llvm = pkgs.llvm_21;
        # clang 21 (from unstable) re-wrapped against 22.05's glibc + gcc-12
        # libstdc++ so emitted C/C++ doesn't pull in newer glibc symbols
        # (no __isoc23_* stdio redirects, no arc4random@2.36).
        #
        # bintools = lld 21 (inline wrapBintoolsWith) instead of gcc-12's GNU
        # binutils: both `bin/ld` and `bin/ld.lld` are wrapped, so the final
        # link — whether it goes through cc-wrapper's default ld or `-fuse-ld=lld`
        # — always hits an rpath-injecting wrapper around lld. With gcc-12's
        # bintools, `-fuse-ld=lld` used to find bare ld.lld and skip the wrapper,
        # so buildInput lib paths never made it into RUNPATH. Used by both
        # devShell and bun-penryn.
        clang = pkgs.wrapCCWith {
          cc = pkgs.clang_21.cc;
          libc = pkgsCompat.glibc;
          bintools = pkgs.wrapBintoolsWith {
            bintools = pkgs.llvmPackages_21.bintools-unwrapped;
            libc = pkgsCompat.glibc;
          };
          gccForLibs = pkgsCompat.gcc12.cc;
          # gcc 12.2's <bits/stl_tempbuf.h> triggers -Wdeprecated-declarations
          # on its own internal _Temporary_buffer. Fixed in 12.3, but 12.3
          # isn't prebuilt against old-enough glibc. Silence so deps with
          # -Werror (boringssl) still compile.
          nixSupport.cc-cflags = [ "-Wno-deprecated-declarations" ];
        };

        # Node.js 24 - matching the bootstrap script (targets 24.3.0, actual version from nixpkgs-unstable)
        nodejs = pkgs.nodejs_24;

        # ─────────────────────────────────────────────────────────────────────
        # Shared between devShell and nix/bun-penryn.nix.
        # ─────────────────────────────────────────────────────────────────────

        # Build tools + libraries required to compile bun itself. The devShell
        # adds GCC, debug tooling, and Chromium test deps on top; nix/bun-penryn
        # consumes this list as-is.
        bunPackages = [
          # Core build tools
          pkgs.cmake # Expected: 3.30+ on nixos-unstable as of 2025-10
          pkgs.ninja
          pkgs.pkg-config
          pkgs.ccache

          # Compilers and toolchain - version pinned to LLVM 21
          # (lld comes in via clang's bintools wrapper — no separate entry)
          clang
          llvm
          pkgs.rustc
          pkgs.cargo
          pkgs.go

          # Bun itself (for running build scripts via `bun bd`)
          pkgs.bun

          # Node.js - version pinned to 24
          nodejs

          # Python for build scripts
          pkgs.python3

          # Other build dependencies from bootstrap.sh
          pkgs.libtool
          pkgs.ruby
          pkgs.perl

          # Libraries
          pkgs.openssl
          pkgs.zlib
          pkgs.libxml2
          pkgs.libiconv

          # Archive tools used by the fetch pipeline
          pkgs.git
          pkgs.unzip
          pkgs.xz
        ];

        commonToolchainEnv = ''
          export CC="${pkgs.lib.getExe clang}"
          export CXX="${pkgs.lib.getExe' clang "clang++"}"
          export AR="${llvm}/bin/llvm-ar"
          export RANLIB="${llvm}/bin/llvm-ranlib"
          export CMAKE_C_COMPILER="$CC"
          export CMAKE_CXX_COMPILER="$CXX"
          export CMAKE_AR="$AR"
          export CMAKE_RANLIB="$RANLIB"
        ''
        + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
          export LD="${clang}/bin/ld"
          export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK:+$NIX_CFLAGS_LINK }-fuse-ld=lld"
        '';

        # ─────────────────────────────────────────────────────────────────────
        # devShell-only additions.
        # ─────────────────────────────────────────────────────────────────────

        devShellPackages =
          bunPackages
          ++ [
            pkgs.gcc
            pkgs.curl
            pkgs.wget
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.gdb # for debugging core dumps (from bootstrap.sh line 1535)

            # Chromium dependencies for Puppeteer testing (from bootstrap.sh lines 1397-1483)
            # X11 and graphics libraries
            pkgs.xorg.libX11
            pkgs.xorg.libxcb
            pkgs.xorg.libXcomposite
            pkgs.xorg.libXcursor
            pkgs.xorg.libXdamage
            pkgs.xorg.libXext
            pkgs.xorg.libXfixes
            pkgs.xorg.libXi
            pkgs.xorg.libXrandr
            pkgs.xorg.libXrender
            pkgs.xorg.libXScrnSaver
            pkgs.xorg.libXtst
            pkgs.libxkbcommon
            pkgs.mesa
            pkgs.nspr
            pkgs.nss
            pkgs.cups
            pkgs.dbus
            pkgs.expat
            pkgs.fontconfig
            pkgs.freetype
            pkgs.glib
            pkgs.gtk3
            pkgs.pango
            pkgs.cairo
            pkgs.alsa-lib
            pkgs.at-spi2-atk
            pkgs.at-spi2-core
            pkgs.libgbm # for hardware acceleration
            pkgs.liberation_ttf # fonts-liberation
            pkgs.atk
            pkgs.libdrm
            pkgs.xorg.libxshmfence
            pkgs.gdk-pixbuf
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # macOS specific dependencies
            pkgs.darwin.apple_sdk.frameworks.CoreFoundation
            pkgs.darwin.apple_sdk.frameworks.CoreServices
            pkgs.darwin.apple_sdk.frameworks.Security
          ];

      in
      {
        devShells.default =
          (pkgs.mkShell.override {
            stdenv = pkgs.clangStdenv;
          })
            {
              packages = devShellPackages;
              hardeningDisable = [ "fortify" ];

              shellHook =
                commonToolchainEnv
                + ''
                  export CMAKE_SYSTEM_PROCESSOR="$(uname -m)"
                  export TMPDIR="''${TMPDIR:-/tmp}"
                ''
                + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                  export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath devShellPackages}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                ''
                + ''

                  # Print welcome message
                  echo "====================================="
                  echo "Bun Development Environment"
                  echo "====================================="
                  echo "Node.js: $(node --version 2>/dev/null || echo 'not found')"
                  echo "Bun: $(bun --version 2>/dev/null || echo 'not found')"
                  echo "Clang: $(clang --version 2>/dev/null | head -n1 || echo 'not found')"
                  echo "CMake: $(cmake --version 2>/dev/null | head -n1 || echo 'not found')"
                  echo "LLVM: ${llvm.version}"
                  echo ""
                  echo "Quick start:"
                  echo "  bun bd                    # Build debug binary"
                  echo "  bun bd test <test-file>   # Run tests"
                  echo "====================================="
                '';

              # Additional environment variables
              CMAKE_BUILD_TYPE = "Debug";
              ENABLE_CCACHE = "1";
            };

        packages = {
          # `nix build .#bun-penryn` — reproducible Bun built for Penryn
          # (pre-SSE4.2 x86_64). See nix/bun-penryn.nix for details.
          #
          # Runtime libs are compiled against 22.05's stdenv so the binary's
          # GLIBC floor is 2.34. ICU is taken from 22.05 directly (71.1);
          # rebuilding from unstable source would cost ~30 min with no
          # functional gain — WebKit doesn't need 76-only API. Everything
          # else uses unstable sources on the compat stdenv, keeping
          # versions current while capping the glibc ABI surface.
          bun-penryn = pkgs.callPackage ./nix/bun-penryn.nix {
            inherit self bunPackages commonToolchainEnv;
            stdenv = compatStdenv;
            # ICU straight from compat pin (71.1) — skip the ~30min rebuild.
            inherit (pkgsCompat) icu;
            # Runtime deps: unstable sources rebuilt against compat stdenv.
            zstd = pkgs.zstd.override { stdenv = compatStdenv; };
            brotli = pkgs.brotli.override { stdenv = compatStdenv; };
            libdeflate = pkgs.libdeflate.override { stdenv = compatStdenv; };
            c-ares = pkgs.c-ares.override { stdenv = compatStdenv; };
            # withZlibCompat=true keeps the libz.so.1 soname bun's -lz expects
            # (native zlib-ng ships libz-ng.so.2).
            zlib-ng = pkgs.zlib-ng.override {
              stdenv = compatStdenv;
              withZlibCompat = true;
            };
            hdrhistogram_c = pkgs.hdrhistogram_c.override { stdenv = compatStdenv; };
            libuv = pkgs.libuv.override { stdenv = compatStdenv; };
            # libhwy tests link against gtest from unstable (built with glibc
            # 2.42 — carries __isoc23_*@2.38 refs). Disable the test build
            # since we only consume libhwy.a.
            libhwy = (pkgs.libhwy.override { stdenv = compatStdenv; }).overrideAttrs (old: {
              cmakeFlags = (old.cmakeFlags or [ ]) ++ [
                "-DBUILD_TESTING=OFF"
                "-DHWY_ENABLE_TESTS=OFF"
              ];
              doCheck = false;
            });
          };
        };
      }
    );
}
