// End-to-end test of afterburner against the live web game, in a throwaway
// headless browser: a fresh save in its own profile, so no real save is
// touched.
//
//   cd test/e2e && npm install && npx playwright install chromium   (once)
//   bundle exec rake e2e
//
// It runs `afterburner watch` on a test port with test/e2e/fixtures as the
// Ruby scripts and a copy of test/e2e/dist as the files to sync, connects the
// game's Remote API to it, and drives the game's terminal.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { chromium } from "playwright";

const ROOT = path.resolve(import.meta.dirname, "../..");
const FIXTURES = path.join(ROOT, "test/e2e/fixtures");
const GAME_URL = process.env.GAME_URL ?? "https://bitburner-official.github.io/";
const PORT = 12536;
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), "afterburner-e2e-"));
const DIST = path.join(WORK, "dist");
const SRC = path.join(WORK, "src"); // a copy of the fixtures, so the test can edit them
const DEFINITIONS = path.join(WORK, "NetscriptDefinitions.d.ts");
const COSTS = path.join(WORK, "ram-costs.json");
const FLAGS = ["--port", String(PORT), "--src", SRC, "--dist", DIST, "--definitions", DEFINITIONS, "--costs", COSTS];

// bundle is a .bat on Windows, which spawn only runs through a shell.
const SHELL = process.platform === "win32";

const results = [];
const watchLog = [];
let watcher;
let browser;

function step(message) {
  console.log(`· ${message}`);
}

function afterburner(args, { input } = {}) {
  const child = spawn("bundle", ["exec", "exe/afterburner", ...args, ...FLAGS], { cwd: ROOT, shell: SHELL });
  const output = [];
  const collect = (chunk) => output.push(String(chunk));
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  const done = new Promise((resolve) => child.on("close", (code) => resolve({ code, output: output.join("") })));
  if (input !== undefined) child.stdin.end(input);
  return { child, output, done };
}

async function waitUntil(test, timeout, what) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await test();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

const logged = (pattern) => watchLog.find((line) => pattern.test(line));

function setUp() {
  fs.cpSync(path.join(ROOT, "test/e2e/dist"), DIST, { recursive: true });
  fs.cpSync(FIXTURES, SRC, { recursive: true });
}

function startWatching() {
  step(`starting afterburner watch on ${PORT}`);
  const started = watchLog.filter((line) => /listening on/.test(line)).length;
  watcher = spawn("bundle", ["exec", "exe/afterburner", "watch", ...FLAGS], { cwd: ROOT, shell: SHELL });
  const collect = (chunk) => {
    for (const line of String(chunk).split("\n").filter(Boolean)) {
      watchLog.push(line);
      if (process.env.VERBOSE) console.log(`  watch: ${line}`);
    }
  };
  watcher.stdout.on("data", collect);
  watcher.stderr.on("data", collect);
  return waitUntil(() => watchLog.filter((line) => /listening on/.test(line)).length > started, 15000, "afterburner to start");
}

async function openGame() {
  step(`opening ${GAME_URL}`);
  browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1400, height: 1000 }, permissions: ["local-network-access"] });
  const page = await context.newPage();
  await page.goto(GAME_URL, { waitUntil: "load", timeout: 90000 });
  await page.getByText("Exit Tutorial").click({ timeout: 60000 });
  await page.getByText("Options", { exact: true }).first().click();
  await page.getByText("Remote API", { exact: true }).first().click();
  await page.locator("input[type=text]").nth(1).fill(String(PORT));
  await page.locator("input[type=text]").nth(2).fill("1"); // reconnection delay, as the README suggests
  await page.getByRole("button", { name: "Connect" }).click();
  await waitUntil(() => logged(/greet\.rb → greet\.js/), 30000, "the stubs to reach the game");
  step("connected; stubs pushed");
  await page.getByText("Terminal", { exact: true }).first().click();
  return page;
}

const screen = (page) => page.evaluate(() => document.body.innerText);

async function terminal(page, command) {
  const input = page.locator("#terminal-input");
  await input.fill(command);
  await input.press("Enter");
}

async function closeModals(page) {
  await page.keyboard.press("Escape"); // e.g. the dialog `cat` opens
  for (const button of await page.getByRole("button", { name: "Close", exact: true }).all()) await button.click({ timeout: 1000 }).catch(() => {});
}

// Clears the terminal, runs a command, and waits for output matching pattern.
async function expectOutput(page, command, pattern, timeout = 15000) {
  await closeModals(page);
  await terminal(page, "clear");
  await terminal(page, command);
  return waitUntil(async () => (await screen(page)).match(pattern), timeout, `${pattern} after "${command}"`);
}

async function check(name, fn) {
  try {
    const detail = await fn();
    results.push({ name, ok: true });
    console.log(`  ✓ ${name}${detail ? ` (${detail})` : ""}`);
  } catch (error) {
    results.push({ name, ok: false });
    console.log(`  ✗ ${name}: ${error.message}`);
  }
}

// The game's own figure for a script, via `afterburner ram`.
async function gameRam(file) {
  const { output } = await afterburner(["ram", file]).done;
  const match = /: ([\d.]+) GB/.exec(output);
  if (!match) throw new Error(`afterburner ram ${file} said: ${output}`);
  return Number(match[1]);
}

async function localRam(file) {
  const { output } = await afterburner(["ram", path.join(SRC, file)]).done;
  return Number(/: ([\d.]+) GB/.exec(output)[1]);
}

// ramcheck.js compares every documented cost with what the game charges.
async function writeRamcheck() {
  const lister = path.join(WORK, "documented_costs.rb");
  fs.writeFileSync(lister, `require "json"\nrequire "afterburner"\nputs JSON.generate(Afterburner::Api.load(ARGV[0]).functions.to_h { [_1.qualified_name, _1.ram || 0] })\n`);
  const ruby = spawn("bundle", ["exec", "ruby", "-Ilib", lister, DEFINITIONS], { cwd: ROOT, shell: SHELL });
  let costs = "";
  ruby.stdout.on("data", (chunk) => (costs += chunk));
  await new Promise((resolve) => ruby.on("close", resolve));
  fs.writeFileSync(
    path.join(DIST, "ramcheck.js"),
    `const DOCUMENTED = ${costs.trim()};
export async function main(ns) {
  const mismatches = [];
  for (const [name, ram] of Object.entries(DOCUMENTED)) {
    let actual;
    try { actual = ns.getFunctionRamCost(name); } catch (e) { actual = String(e); }
    if (actual !== ram) mismatches.push([name, ram, actual]);
  }
  ns.tprint("RAMCHECK " + JSON.stringify({ checked: Object.keys(DOCUMENTED).length, base: ns.getFunctionRamCost("baseCost"), mismatches }));
}
`,
  );
}

async function main() {
  setUp();
  await startWatching();
  const page = await openGame();

  await check("the game's definitions are saved on connect", async () => {
    if (!fs.existsSync(DEFINITIONS)) throw new Error("no NetscriptDefinitions.d.ts");
  });

  await check("greet.rb runs: ARGV, puts/p/warn, predicates, namespaces, Records", async () => {
    await expectOutput(page, "run greet.js world", /player money is a (Float|Integer), hacking skill \d+/);
    const text = await screen(page);
    const output = text.slice(text.indexOf("run greet.js"));
    for (const expected of ["Hello, world!", "[1, :two]", "careful", "root on n00dles? false"]) {
      if (!output.includes(expected)) throw new Error(`missing "${expected}" in:\n${output.slice(0, 600)}`);
    }
    if (!/n00dles max money: \$?1\.750m/.test(output)) throw new Error(`no max money line in:\n${output.slice(0, 600)}`);
  });

  await check("a stub claims exactly what the game measures (afterburner ram)", async () => {
    const [game, local] = [await gameRam("greet.js"), await localRam("greet.rb")];
    if (game !== local) throw new Error(`game says ${game} GB, the scan says ${local} GB`);
    return `${game} GB`;
  });

  await check("uncaught errors show the Ruby message and backtrace", async () => {
    await expectOutput(page, "run boom.js", /the reactor went boom \(RuntimeError\)[\s\S]*from boom\.rb:3/);
  });

  await check("game errors arrive as a rescuable NetscriptError", async () => {
    const match = await expectOutput(page, "run rescue.js", /rescued: (.+)/);
    return match[1].slice(0, 50);
  });

  await check("require_relative works and the scan follows it; libraries get no stub", async () => {
    await expectOutput(page, "run uses_lib.js", /level via lib: \d+/);
    if ((await localRam("uses_lib.rb")) !== 1.65) throw new Error("expected 1.65 GB (base + getHackingLevel)");
    if (logged(/greeting\.js/)) throw new Error("lib/greeting.rb got a stub");
  });

  await check("ns works inside a library's methods, e.g. a Numeric patch", async () => {
    const match = await expectOutput(page, "run pct.js", /half is ([^;]+); two is (\S+)/);
    return `${match[1]}, ${match[2]}`;
  });

  await check("killing the stub stops the Ruby script", async () => {
    await expectOutput(page, "run forever.js", /forever\.js/);
    await waitUntil(() => logged(/\[forever\.rb pid \d+\] started/), 5000, "forever.rb to start");
    await terminal(page, "kill forever.js");
    await waitUntil(() => logged(/\[forever\.rb pid \d+\] killed in the game/), 5000, "afterburner to stop forever.rb");
  });

  await check("a call the scan can't see trips the game's RAM check, with a hint", async () => {
    await expectOutput(page, "run sneaky.js", /RAM USAGE ERROR[\s\S]*afterburner charges/);
  });

  await check("other files sync, including edits", async () => {
    await expectOutput(page, "run plain.js", /plain js says one/);
    fs.writeFileSync(path.join(DIST, "plain.js"), fs.readFileSync(path.join(DIST, "plain.js"), "utf8").replace("one", "two"));
    await waitUntil(() => logged(/plain\.js changed/), 5000, "the edit to sync");
    await expectOutput(page, "run plain.js", /plain js says two/);
  });

  await check("costs are measured in the game, covering where the docs are wrong", async () => {
    await writeRamcheck();
    await waitUntil(() => logged(/ramcheck\.js changed/), 5000, "ramcheck.js to sync");
    const match = await expectOutput(page, "run ramcheck.js", /RAMCHECK (\{.*\})/);
    const report = JSON.parse(match[1]);
    if (report.base !== 1.6) throw new Error(`base cost is ${report.base}`);
    const measured = JSON.parse(fs.readFileSync(COSTS, "utf8"));
    const wrong = report.mismatches.filter(([name, , actual]) => measured[name] !== actual);
    // Names stay out of the output: some belong to parts of the game you may not have reached.
    fs.writeFileSync(path.join(WORK, "ramcheck.json"), JSON.stringify(report, null, 2));
    if (Object.keys(measured).length < report.checked - 5) throw new Error(`only ${Object.keys(measured).length} of ${report.checked} measured`);
    if (wrong.length) throw new Error(`${wrong.length} measured costs disagree with the game (names in ${WORK}/ramcheck.json)`);
    return `${report.checked} functions; the docs are off for ${report.mismatches.length}, all covered`;
  });

  await check("stubs are rebuilt and re-pushed with measured costs", async () => {
    const ram = await waitUntil(async () => ((await gameRam("clear.js")) === 1.6 ? 1.6 : null), 10000, "clear.js to claim 1.6 GB");
    await expectOutput(page, "run clear.js", /cleared/);
    return `clear.js now claims ${ram} GB, from 1.8`;
  });

  await check("hot reload: an edited script restarts in place, if its RAM claim covers it", async () => {
    const script = path.join(SRC, "reloadme.rb");
    await expectOutput(page, "run reloadme.js", /reloadme says v1/);
    const started = await waitUntil(() => logged(/\[reloadme\.rb pid (\d+)\] started/), 5000, "reloadme.rb to start");
    const pid = /pid (\d+)/.exec(started)[1];

    fs.writeFileSync(script, fs.readFileSync(script, "utf8").replace("v1", "v2"));
    await waitUntil(async () => (await screen(page)).includes("reloadme says v2"), 5000, "the new code to run");
    if (!logged(new RegExp(`\\[reloadme\\.rb pid ${pid}\\] reloaded`))) throw new Error(`no reload logged for pid ${pid}`);

    // ns.get_server costs 2 GB the stub never claimed, so this edit waits for a rerun.
    fs.writeFileSync(script, fs.readFileSync(script, "utf8").replace("v2", "v3").replace("loop", 'ns.get_server("home")\nloop'));
    await waitUntil(() => logged(/reloadme\.rb pid \d+\] changed, but now needs/), 5000, "the reload to be refused");
    await new Promise((r) => setTimeout(r, 1000));
    if ((await screen(page)).includes("reloadme says v3")) throw new Error("the 2 GB edit ran anyway");
    await terminal(page, "kill reloadme.js");
    return `pid ${pid} went from v1 to v2 in place; the 2 GB edit waits for a rerun`;
  });

  await check("afterburner save downloads the live save", async () => {
    const file = path.join(WORK, "save.json.gz");
    const { code, output } = await afterburner(["save", file]).done;
    if (code !== 0) throw new Error(output);
    const save = JSON.parse(zlib.gunzipSync(fs.readFileSync(file)));
    if (save.ctor !== "BitburnerSaveObject") throw new Error(`unexpected save: ${String(save.ctor)}`);
    return `${fs.statSync(file).size} bytes`;
  });

  await check("afterburner console: IRB with ns live in the game", async () => {
    const console_ = afterburner(["console", "--ram", "2"]);
    await waitUntil(() => console_.output.join("").includes("run afterburner/console.js"), 10000, "the console to be ready");
    await expectOutput(page, "run afterburner/console.js", /afterburner\/console\.js/);
    await waitUntil(() => console_.output.join("").includes("Attached to pid"), 10000, "the console to attach");
    // ns works at the prompt, and inside a class defined there.
    console_.child.stdin.end("class Probe\n  def self.level = ns.hacking_level\nend\nputs \"level=#{Probe.level}\"\nexit\n");
    const { code, output } = await console_.done;
    if (code !== 0 || !/level=\d+/.test(output)) throw new Error(`exit ${code}:\n${output}`);
    return output.match(/level=\d+/)[0];
  });

  await check("the console script keeps running: the next console attaches without a run", async () => {
    const console_ = afterburner(["console"]);
    await waitUntil(() => console_.output.join("").includes("Attached to pid"), 10000, "the console to attach");
    if (console_.output.join("").includes("run afterburner/console.js")) throw new Error("asked to run the script again");
    console_.child.stdin.end('puts "level=#{ns.hacking_level}"\nexit\n');
    const { code, output } = await console_.done;
    if (code !== 0 || !/level=\d+/.test(output)) throw new Error(`exit ${code}:\n${output}`);
  });

  await check("the console stays open across an afterburner restart and reattaches", async () => {
    const console_ = afterburner(["console"]);
    let stopped = false;
    try {
      await waitUntil(() => console_.output.join("").includes("Attached to pid"), 10000, "the console to attach");
      const closed = new Promise((resolve) => watcher.on("close", resolve));
      watcher.kill();
      await closed;
      stopped = true;
      await waitUntil(() => console_.output.join("").includes("afterburner went away"), 10000, "the console to notice");
      const games = watchLog.filter((line) => /the game connected/.test(line)).length;
      await startWatching();
      stopped = false;
      await waitUntil(() => console_.output.join("").includes("Reattached to the console script"), 30000, "the console to reattach");
      // The game's Remote API reconnects on its own schedule; the checks after this need it.
      await waitUntil(() => watchLog.filter((line) => /the game connected/.test(line)).length > games, 30000, "the game to reconnect");
      console_.child.stdin.end('puts "level=#{ns.hacking_level}"\nexit\n');
      const { code, output } = await console_.done;
      if (code !== 0 || !/level=\d+/.test(output)) throw new Error(`exit ${code}:\n${output}`);
    } finally {
      console_.child.kill();
      if (stopped) await startWatching(); // the checks after this need it
    }
  });

  await check("Ruby sources are kept in the save, and afterburner restore brings them back", async () => {
    await expectOutput(page, "ls afterburner/src", /greet\.rb\.txt/);
    const target = path.join(WORK, "restored");
    fs.mkdirSync(target);
    const restore = spawn("bundle", ["exec", "exe/afterburner", "restore", "--port", String(PORT), "--src", target], { cwd: ROOT, shell: SHELL });
    let output = "";
    restore.stdout.on("data", (chunk) => (output += chunk));
    restore.stderr.on("data", (chunk) => (output += chunk));
    const code = await new Promise((resolve) => restore.on("close", resolve));
    if (code !== 0) throw new Error(output);
    // reloadme.rb was edited during the run, so its copy shows edits reach the save too.
    for (const name of ["greet.rb", "lib/greeting.rb", "reloadme.rb"]) {
      const restored = path.join(target, name);
      if (!fs.existsSync(restored)) throw new Error(`${name} wasn't restored:\n${output}`);
      if (fs.readFileSync(restored, "utf8") !== fs.readFileSync(path.join(SRC, name), "utf8")) throw new Error(`${name} differs`);
    }
    return `${fs.readdirSync(target, { recursive: true }).filter((f) => f.endsWith(".rb")).length} files`;
  });

  await check("a stub started while afterburner is down waits for it", async () => {
    watcher.kill();
    await new Promise((resolve) => watcher.on("close", resolve));
    await expectOutput(page, "run greet.js later", /Running script/);
    await new Promise((r) => setTimeout(r, 3000)); // the game restarting scripts before afterburner is back
    await startWatching();
    await waitUntil(async () => (await screen(page)).includes("Hello, later!"), 20000, "the waiting stub to run");
  });

  await page.screenshot({ path: path.join(WORK, "final.png") });
}

try {
  await main();
} catch (error) {
  console.log(`✗ ${error.message}`);
  results.push({ name: "harness", ok: false });
} finally {
  await browser?.close();
  watcher?.kill();
  fs.writeFileSync(path.join(WORK, "watch.log"), watchLog.join("\n"));
  const failed = results.filter((r) => !r.ok).length;
  console.log(failed ? `${failed} of ${results.length} failed. Logs and artifacts in ${WORK}` : `all ${results.length} passed`);
  process.exitCode = failed ? 1 : 0;
}
