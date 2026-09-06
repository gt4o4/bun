import { describe, expect, test } from "bun:test";
import { bunEnv, bunExe, tempDir } from "harness";
import { join } from "path";

// `bun build --already-bundled --bytecode` skips parsing/transforming and
// emits a JSC bytecode cache against the source bytes verbatim. The intended
// inputs are the shapes `bun build --bytecode` itself produces: the
// `// @bun @bytecode @bun-cjs` CJS wrapper (feeding it back through the
// regular bundler tree-shakes the IIFE as side-effect-free and destroys the
// body), and `// @bun @bytecode` ESM chunks as extracted from a compiled
// binary. For ESM no module_info accompanies the loose .jsc, so the runtime
// still parses once for module analysis — but the cache hit skips codegen.
describe("bun build --already-bundled", () => {
  test("emits a .jsc that the runtime accepts as a cache hit", async () => {
    const wrapped =
      `// @bun @bytecode @bun-cjs\n` +
      `(function(exports, require, module, __filename, __dirname) {` +
      `module.exports = { msg: "already-bundled works", n: 41 + 1 };` +
      `})`;

    using dir = tempDir("already-bundled-cache", {
      "input.js": wrapped,
      "consumer.js": `const m = require("./out/input.js"); console.log(m.msg, m.n);`,
    });

    await using build = Bun.spawn({
      cmd: [
        bunExe(),
        "build",
        "--already-bundled",
        "--bytecode",
        "--target=bun",
        "--format=cjs",
        "--outdir",
        join(String(dir), "out"),
        join(String(dir), "input.js"),
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [, buildStderr, buildExit] = await Promise.all([
      build.stdout.text(),
      build.stderr.text(),
      build.exited,
    ]);
    expect(buildStderr).toBe("");
    expect(buildExit).toBe(0);

    const outJs = Bun.file(join(String(dir), "out", "input.js"));
    const outJsc = Bun.file(join(String(dir), "out", "input.js.jsc"));
    expect(await outJs.exists()).toBe(true);
    expect(await outJsc.exists()).toBe(true);

    // Source is copied verbatim, byte-identical to the input.
    expect(await outJs.text()).toBe(wrapped);
    // Bytecode is non-trivial.
    expect(outJsc.size).toBeGreaterThan(64);

    await using run = Bun.spawn({
      cmd: [bunExe(), join(String(dir), "consumer.js")],
      env: { ...bunEnv, BUN_JSC_verboseDiskCache: "1" },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exit] = await Promise.all([
      run.stdout.text(),
      run.stderr.text(),
      run.exited,
    ]);
    expect(stdout).toContain("already-bundled works 42");
    expect(stderr).toMatch(/\[Disk Cache\].*Cache hit/i);
    expect(exit).toBe(0);
  }, 30_000);

  test("emits an ESM .jsc that the runtime accepts as a cache hit", async () => {
    const esm = `// @bun @bytecode\nexport const msg = "esm already-bundled works";\nexport const n = 41 + 1;\n`;

    using dir = tempDir("already-bundled-esm-cache", {
      "input.js": esm,
      "consumer.js": `import { msg, n } from "./out/input.js"; console.log(msg, n);`,
    });

    await using build = Bun.spawn({
      cmd: [
        bunExe(),
        "build",
        "--already-bundled",
        "--bytecode",
        "--target=bun",
        "--format=esm",
        "--outdir",
        join(String(dir), "out"),
        join(String(dir), "input.js"),
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [, buildStderr, buildExit] = await Promise.all([
      build.stdout.text(),
      build.stderr.text(),
      build.exited,
    ]);
    expect(buildStderr).toBe("");
    expect(buildExit).toBe(0);

    const outJs = Bun.file(join(String(dir), "out", "input.js"));
    const outJsc = Bun.file(join(String(dir), "out", "input.js.jsc"));
    expect(await outJs.text()).toBe(esm);
    expect(outJsc.size).toBeGreaterThan(64);

    await using run = Bun.spawn({
      cmd: [bunExe(), join(String(dir), "consumer.js")],
      env: { ...bunEnv, BUN_JSC_verboseDiskCache: "1" },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exit] = await Promise.all([
      run.stdout.text(),
      run.stderr.text(),
      run.exited,
    ]);
    expect(stdout).toContain("esm already-bundled works 42");
    expect(stderr).toMatch(/\[Disk Cache\].*Cache hit/i);
    expect(exit).toBe(0);
  }, 30_000);

  test("warns when the input lacks the // @bun pragma", async () => {
    using dir = tempDir("already-bundled-no-pragma", {
      "input.js": `export const x = 1;\n`,
    });
    await using build = Bun.spawn({
      cmd: [
        bunExe(),
        "build",
        "--already-bundled",
        "--bytecode",
        "--target=bun",
        "--format=esm",
        "--outdir",
        join(String(dir), "out"),
        join(String(dir), "input.js"),
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [, stderr, exit] = await Promise.all([
      build.stdout.text(),
      build.stderr.text(),
      build.exited,
    ]);
    expect(stderr).toMatch(/does not start with a `\/\/ @bun` pragma/);
    expect(exit).toBe(0);
  }, 30_000);

  test("requires --bytecode", async () => {
    using dir = tempDir("already-bundled-needs-bytecode", {
      "input.js": `// @bun @bun-cjs\n(function(exports, require, module, __filename, __dirname) {})`,
    });
    await using build = Bun.spawn({
      cmd: [
        bunExe(),
        "build",
        "--already-bundled",
        "--target=bun",
        "--format=cjs",
        "--outdir",
        join(String(dir), "out"),
        join(String(dir), "input.js"),
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [, stderr, exit] = await Promise.all([
      build.stdout.text(),
      build.stderr.text(),
      build.exited,
    ]);
    expect(stderr).toMatch(/--already-bundled requires --bytecode/);
    expect(exit).not.toBe(0);
  }, 30_000);

  test("rejects --compile (not yet supported)", async () => {
    using dir = tempDir("already-bundled-no-compile", {
      "input.js": `// @bun @bytecode @bun-cjs\n(function(exports, require, module, __filename, __dirname) {})`,
    });
    await using build = Bun.spawn({
      cmd: [
        bunExe(),
        "build",
        "--already-bundled",
        "--bytecode",
        "--compile",
        "--target=bun",
        "--format=cjs",
        "--outfile",
        join(String(dir), "out.bin"),
        join(String(dir), "input.js"),
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });
    const [, stderr, exit] = await Promise.all([
      build.stdout.text(),
      build.stderr.text(),
      build.exited,
    ]);
    expect(stderr).toMatch(/does not support --compile/);
    expect(exit).not.toBe(0);
  }, 30_000);
});
