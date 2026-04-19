/**
 * ICU — Unicode/i18n. Used by JavaScriptCore for `Intl`, regex `\p{}`,
 * `String.prototype.normalize`, locale-aware collation, and friends.
 *
 * Always system-supplied. There's no source-build path for ICU in the bun
 * codebase: it's far too large to vendor + build hermetically and every
 * platform we support already ships a copy in some form. The configuration
 * picks the right -l flags per platform; the actual headers/libs come from:
 *
 *   - macOS: `libicucore.dylib` from /usr/lib (Apple-shipped, since 10.4)
 *   - Linux + prebuilt WebKit: bundled inside the WebKit tarball as static
 *     `libicudata.a` / `libicui18n.a` / `libicuuc.a` (see deps/webkit.ts:114).
 *     This dep is a no-op in that case — WebKit's `Provides.libs` covers it.
 *   - Linux + local WebKit: system ICU via `libicu-dev` / nixpkgs `icu`.
 *   - Windows: built from source by `vendor/WebKit/build-icu.ps1` and listed
 *     as preBuild outputs of WebKit (deps/webkit.ts:263). This dep is a no-op
 *     in that case too.
 *
 * Migrated from the hand-rolled `-licu*` pushes that used to live in
 * `bun.ts::systemLibs()` so the linkage is visible in the same place every
 * other dep is and ICU benefits from the standard ResolvedDep machinery
 * (header signal, implicit-input tracking).
 */

import type { Dependency } from "../source.ts";

export const icu: Dependency = {
  name: "icu",

  source: cfg => {
    if (cfg.darwin) {
      // libicucore is one fat lib that exposes the icudata/icui18n/icuuc
      // surface. -lresolv used to live next to it in systemLibs() but that's
      // for getaddrinfo(), unrelated to ICU — kept in systemLibs().
      return {
        kind: "system",
        linkFlags: ["-licucore"],
        trackLibs: ["icucore"],
      };
    }

    if (cfg.linux && cfg.webkit === "local") {
      return {
        kind: "system",
        // Order: data → i18n → uc, matching the historical systemLibs() push
        // (and ICU's own dependency order — i18n needs uc, both need data).
        linkFlags: ["-licudata", "-licui18n", "-licuuc"],
        trackLibs: ["icudata", "icui18n", "icuuc"],
      };
    }

    // Linux + prebuilt WebKit OR Windows: WebKit's own prebuilt/preBuild
    // path supplies ICU. Empty kind:"system" is a no-op both on the link
    // line and on disk.
    return { kind: "system", linkFlags: [], trackLibs: [] };
  },

  build: () => ({ kind: "none" }),

  // No headers/libs declared here — the link flags above already wire up
  // -l<name> and the resolved .so paths flow into trackedLibFiles via the
  // kind:"system" branch in resolveDep().
  provides: () => ({ libs: [], includes: [] }),
};
