'use strict';
/**
 * Autonomous cross-platform release builder (king's design: launch-and-forget,
 * NO human involvement). Lives inside the node/snap. On a timer it:
 *
 *   1. Detects that the bundled client/node source has a NEW version.
 *   2. CROSS-COMPILES every platform bundle from THIS one host using `pkg`
 *      (a Node.js program â†’ Windows .exe + macOS + Linux executables â€” proven:
 *      one Linux host emits all three, no per-OS machine needed).
 *   3. SHA-256s every artifact.
 *   4. Asks the witness-signers to FROST-threshold-sign the Distribution Manifest
 *      (PI-37 â€” no founder; >= threshold signers required; no single key can ship).
 *   5. Publishes artifacts to ordinary third-party hosts and the signed manifest to
 *      the mesh. Existing installs auto-verify the threshold signature + each SHA-256
 *      and self-update. The node's own endpoint is never exposed.
 *
 * Why `pkg` (and not PyInstaller): PyInstaller is native-only (a Linux host cannot
 * emit a Windows .exe), which defeats launch-and-forget. A Node.js program compiled
 * with `pkg`/Node SEA cross-compiles to all targets from a single host â€” so the
 * SNAP itself produces every platform's bundle. The client app is therefore packaged
 * as a Node program for the autonomous pipeline (the Python build remains only a
 * manual/dev convenience).
 *
 * This module shells out to `pkg`; it makes NO external API calls of its own beyond
 * fetching pkg's pinned base binaries at build time (cached in the snap after first
 * run so even that is offline thereafter). All protocol/sign/publish steps are SOV's.
 */
const { execFile, execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TARGETS = [
  { id: 'node18-win-x64',   out: 'SovWallet-win.exe', platform: 'windows' },
  { id: 'node18-macos-x64', out: 'SovWallet-macos',   platform: 'macos'   },
  { id: 'node18-linux-x64', out: 'SovWallet-linux',   platform: 'linux'   },
];

function sha256File(p) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(p));
  return h.digest('hex');
}

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    // On Windows hosts, npx/pkg are .cmd shims that execFile can't spawn without a
    // shell (EINVAL/ENOENT). The production target is the Linux snap (no shell
    // needed), but enable shell on win32 so a Windows host works too.
    const spawnOpts = { maxBuffer: 64 * 1024 * 1024, shell: process.platform === 'win32', ...opts };
    execFile(cmd, args, spawnOpts, (err, stdout, stderr) => {
      if (err) return reject(new Error((stderr || err.message || '').toString().slice(0, 2000)));
      resolve((stdout || '').toString());
    });
  });
}

/**
 * pkg keeps its base binaries in PKG_CACHE_PATH and chmods them on use. Inside the
 * snap that path is under the read-only squashfs ($SNAP/â€¦), so pkg dies with
 * `EROFS: chmod â€¦/pkg-cache/â€¦`. Copy the bundled cache once into a writable dir
 * ($SNAP_DATA on a real node, os.tmpdir elsewhere) and repoint PKG_CACHE_PATH there.
 * No-op when the cache is already writable (dev hosts) or unset. Verified on VPS4
 * 2026-08-15: read-only cache â†’ EROFS; writable copy â†’ Linux+Windows binaries built.
 */
function ensureWritablePkgCache() {
  const src = process.env.PKG_CACHE_PATH;
  if (!src || !fs.existsSync(src)) return;
  try {
    // Already writable? leave it.
    fs.accessSync(src, fs.constants.W_OK);
    // W_OK on the dir isn't enough â€” the cached files are what pkg chmods. If the
    // dir sits under a read-only snap mount, treat it as read-only regardless.
    if (!/[/\\]snap[/\\]/.test(src)) return;
  } catch (_) { /* not writable â†’ copy below */ }
  const base = process.env.SNAP_DATA || require('os').tmpdir();
  const dst = path.join(base, 'sov-pkg-cache');
  try {
    if (!fs.existsSync(dst)) {
      fs.cpSync(src, dst, { recursive: true });
      // Make every copied file writable so pkg's chmod succeeds.
      const chmodTree = (d) => {
        for (const e of fs.readdirSync(d, { withFileTypes: true })) {
          const p = path.join(d, e.name);
          try { fs.chmodSync(p, 0o755); } catch (_) {}
          if (e.isDirectory()) chmodTree(p);
        }
      };
      chmodTree(dst);
    }
    process.env.PKG_CACHE_PATH = dst;
    (global.sovLog || console).info(`[AutoBuild] pkg cache copied to writable ${dst}`);
  } catch (e) {
    (global.sovLog || console).warn(`[AutoBuild] could not stage writable pkg cache: ${e.message}`);
  }
}

/**
 * Cross-compile every platform bundle from this host.
 * @param {object} o
 * @param {string} o.entry      client/node JS entry compiled into the bundle
 * @param {string} o.outDir     where the artifacts are written
 * @param {string} [o.pkgBin]   path to the pkg CLI (bundled in the snap); defaults to `npx pkg`
 * @returns {Promise<Array<{platform,file,sha256,size}>>}
 */
async function crossCompileAll({ entry, outDir, pkgBin }) {
  fs.mkdirSync(outDir, { recursive: true });
  ensureWritablePkgCache();
  const artifacts = [];
  for (const t of TARGETS) {
    const outFile = path.join(outDir, t.out);
    const args = pkgBin
      ? [entry, '--target', t.id, '--output', outFile]
      : ['--yes', 'pkg', entry, '--target', t.id, '--output', outFile];
    // npx is `npx.cmd` on Windows hosts; on the Linux snap it's plain `npx`.
    const bin = pkgBin || (process.platform === 'win32' ? 'npx.cmd' : 'npx');
    await run(bin, args);
    if (!fs.existsSync(outFile)) throw new Error('pkg produced no artifact for ' + t.id);
    artifacts.push({
      platform: t.platform,
      file: t.out,
      sha256: sha256File(outFile),
      size: fs.statSync(outFile).size,
    });
    (global.sovLog || console).info(`[AutoBuild] built ${t.platform}: ${t.out} (${artifacts[artifacts.length - 1].sha256.slice(0, 12)}â€¦)`);
  }
  return artifacts;
}

/**
 * Build the Android APK. Android is NOT a `pkg` target â€” it's the Flutter/Gradle/
 * Android-SDK toolchain â€” but that toolchain is fully Linux-native and headless, so
 * the snap builds it with no human and no Windows/Mac. `flutter build apk --release`
 * runs Gradle + the Android SDK + JDK entirely on the command line.
 *
 * Signing: Android requires every APK be signed for install + update continuity, so
 * the build uses a FIXED app keystore (same key across releases so updates install
 * over each other). The network-trust layer is still the witness-signer threshold
 * signature over the APK's SHA-256 in the manifest; the keystore can itself be held/
 * derived by the witness-signer threshold so no single human owns it.
 *
 * @param {object} o
 * @param {string} o.flutterDir  the Flutter project root (has android/, pubspec.yaml)
 * @param {string} o.outDir      where to copy the signed APK
 * @param {string} [o.flutterBin] path to flutter (default: `flutter` on PATH)
 * @param {object} [o.env]       extra env (e.g. ANDROID_SDK_ROOT, keystore vars)
 * @returns {Promise<{platform:'android',file,sha256,size}>}
 */
/**
 * The snap ships the Flutter SDK, Android SDK and the app source under the read-only
 * squashfs ($SNAP). Flutter must WRITE to its own SDK (bin/cache/engine.stamp is
 * rewritten on every invocation) and to the project (.dart_tool, build/), and Gradle
 * may touch the Android SDK â€” all impossible read-only. Make each read-only tree
 * writable WITHOUT a slow 1.5 GB copy by overlaying it with a writable upper layer
 * (overlayfs copy-on-write), and copy the small (~70 MB) project out. Caches/HOME
 * are redirected to writable dirs. Returns { projectDir, env, flutterBin, cleanup }.
 *
 * Verified on VPS4 2026-08-16: this exact recipe (overlay flutter-sdk + android-sdk,
 * writable HOME/PUB_CACHE/GRADLE_USER_HOME, bundled git+JDK on PATH) ran `flutter pub
 * get` + `gradle assembleRelease` on-node. Falls back to a cached full SDK copy if
 * overlay mounts are unavailable (e.g. a future strict-confinement build).
 */
/** Long-lived build JVMs that outlive the build that started them. */
const BUILD_DAEMONS = ['GradleDaemon', 'KotlinCompileDaemon'];

/**
 * The one absolute path every SOV builder builds at, on every tier.
 *
 * Changing this value changes every artifact's content digest, so it is part of the
 * release protocol, not a local preference. Tier-1/2 runner scripts must use it too.
 */
const CANONICAL_BUILD_ROOT = '/sov-apkbuild';

/**
 * Stop the build daemons belonging to THIS build, and only those.
 *
 * TWO things were wrong with the `pkill -9 -f GradleDaemon` this replaces.
 *
 * 1. It was unscoped. That was harmless while the only builder was a dedicated node, but
 *    tier 3 is an OPERATOR'S OWN MACHINE (measured 2026-08-26: no node in the fleet has
 *    the ~3 GB a build needs, so the node can never be the builder). On a laptop, matching
 *    every Gradle daemon takes out the operator's own Android Studio daemon mid-edit.
 *
 * 2. It only named Gradle. Measured 2026-08-26 during a real build:
 *        KotlinCompileDaemon  766 MB
 *        KotlinCompileDaemon  1,555 MB
 *        GradleDaemon         1,529 MB
 *    The Kotlin daemons held MORE than Gradle's, there were two of them (different plugins
 *    pull different Kotlin compiler versions, each spawning its own), and one had survived
 *    from the PREVIOUS build - so they accumulate. Stopping only Gradle would have left
 *    2.3 GB behind and looked like it had worked.
 *
 * So: ask gradle to stop its own daemons first - `--stop` is scoped to the GRADLE_USER_HOME
 * it is invoked with, and lets the daemon flush its caches rather than be SIGKILLed
 * mid-write. It does NOT stop Kotlin daemons, which are separate processes, so then sweep
 * /proc for anything left. Both daemon kinds carry the gradle user home in their classpath
 * (verified), which is what makes scoping on our own paths possible at all.
 *
 * @param {string[]} scopePaths  Paths that identify our daemons (work dir, gradle home).
 * @param {string|null} gradlew  Path to the project's gradle wrapper, if it exists yet.
 * @param {object} env           Environment carrying JAVA_HOME/GRADLE_USER_HOME.
 * @returns {number}             How many were force-killed after the graceful attempt.
 */
function stopOurGradleDaemons(scopePaths, gradlew, env) {
  if (gradlew && fs.existsSync(gradlew)) {
    try {
      execFileSync(gradlew, ['--stop'], {
        cwd: path.dirname(gradlew), env, timeout: 60000, stdio: 'ignore',
      });
    } catch (_) { /* no daemon, or the wrapper cannot run â€” the sweep below still applies */ }
  }
  const scopes = scopePaths.filter(Boolean);
  if (!scopes.length) return 0;
  let killed = 0;
  const victims = [];
  try {
    for (const pid of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(pid)) continue;
      let cmd;
      try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8'); } catch (_) { continue; }
      if (!BUILD_DAEMONS.some((d) => cmd.includes(d))) continue;
      if (!scopes.some((s) => cmd.includes(s))) continue;   // someone else's daemon â€” leave it
      try { process.kill(Number(pid), 'SIGKILL'); killed += 1; victims.push(Number(pid)); } catch (_) {}
    }
  } catch (_) { /* no /proc: not Linux, and this whole path is Linux-only */ }

  // SIGKILL is ASYNCHRONOUS. The kernel returns at once, but the process keeps its open
  // files -- and therefore the overlay mounts -- until it is actually reaped. Measured
  // 2026-08-26, unmounting straight after the kill:
  //     umount: /sov-apkbuild/gc: target is busy
  //     umount: /sov-apkbuild: target is busy
  // The teardown still completed, but only because the LAZY fallback caught it. That is a
  // race that happened to be won, not a teardown that works. Wait for the victims to go.
  const deadline = Date.now() + 10000;
  while (victims.length && Date.now() < deadline) {
    if (!victims.some((p) => fs.existsSync(`/proc/${p}`))) break;
    try { execFileSync('sleep', ['0.2']); } catch (_) { break; }
  }
  return killed;
}

function prepareAndroidBuildEnv({ flutterDir }) {
  const snap = process.env.SNAP || '';
  const base = process.env.SNAP_DATA || os.tmpdir();
  const work = path.join(base, 'apkbuild');
  const flutterSdkSrc = path.join(snap, 'flutter-sdk', 'flutter');
  const androidSdkSrc = process.env.ANDROID_SDK_ROOT || path.join(snap, 'android-sdk');
  const jdk = process.env.JAVA_HOME || path.join(snap, 'usr', 'lib', 'jvm', 'java-17-openjdk-amd64');
  const pubCacheSrc    = path.join(snap, 'pub-cache');      // staged by the `pub-cache` part
  const gradleCacheSrc = path.join(snap, 'gradle-cache');   // staged by the `gradle-cache` part
  let pubCacheRoot = null;
  let gradleCacheRoot = null;

  // WHERE CACHES LIVE, AND WHY IT IS NOT INSIDE `work`.
  // `work` is wiped every build. If the gradle/pub caches lived there, each build would
  // re-fetch ~1.7 GB - which an offline node cannot do at all. So the overlay UPPER
  // layers for the two caches live here instead, and persist: the read-only bundled
  // cache is the lower layer, and this holds only the DELTA on top of it.
  // That is what makes pruning safe - deleting a delta falls back to the bundled
  // baseline, which is a local copy, not a download.
  const cacheDir = path.join(base, 'build-cache');
  fs.mkdirSync(cacheDir, { recursive: true });

  // CLEAR ANY WEDGE LEFT BY A PRIOR CRASHED BUILD.
  //
  // A plain best-effort umount is not enough. A Gradle daemon that survives a failed
  // build keeps holding its overlay, so the umount fails with "target is busy", the
  // wipe below then throws, and the node can NEVER build again â€” reporting
  //   EBUSY: resource busy or locked, rmdir '.../apkbuild/gc'
  // which names a directory rather than the cause. Measured 2026-08-25: a daemon from
  // a build that failed 90 minutes earlier still held an overlay whose lower layer had
  // already been unmounted from under it.
  //
  // So: stop the daemons first, then umount, then fall back to a LAZY umount, which
  // detaches the mount even while something holds it. An operator's node must not be
  // one crashed build away from a dead builder.
  // No gradle wrapper exists yet (the project has not been copied out of the snap), so
  // this is the scoped sweep only. Anything matching here is a leftover from a build that
  // already died, so there is nothing to flush gracefully.
  stopOurGradleDaemons([work, base, CANONICAL_BUILD_ROOT], null, process.env);
  // Clear stale mounts under BOTH roots, canonical first. A crashed build leaves its
  // overlays at CANONICAL_BUILD_ROOT/<d>, and those are distinct mount entries from
  // work/<d> even though the two directories are the same inode - so umounting only the
  // work path would leave the real mounts live and `rm -rf work` would then fail.
  // The canonical bind itself goes last, after the overlays inside it.
  for (const root of [CANONICAL_BUILD_ROOT, work]) {
    for (const d of ['fl', 'asdk', 'pc', 'gc']) {
      const mp = path.join(root, d);
      try { execFileSync('umount', [mp]); continue; } catch (_) { /* busy or not mounted */ }
      try { execFileSync('umount', ['-l', mp]); (global.sovLog || console).warn(`[AutoBuild] lazy-unmounted stale overlay ${mp}`); } catch (_) { /* not mounted */ }
    }
  }
  try { execFileSync('umount', ['-l', CANONICAL_BUILD_ROOT]); } catch (_) { /* not bound */ }
  try {
    fs.rmSync(work, { recursive: true, force: true });
  } catch (e) {
    // Say what is actually wrong, and what clears it, rather than leaving an EBUSY.
    throw new Error(`could not clear the previous build tree at ${work} (${e.code || e.message}). `
      + `Something still holds a mount there â€” check \`mount | grep apkbuild\` and \`fuser -vm ${work}\`.`);
  }
  for (const d of ['fl', 'fl_up', 'fl_wk', 'asdk', 'asdk_up', 'asdk_wk', 'pc', 'gc', 'proj', '.pub-cache', '.gradle']) {
    fs.mkdirSync(path.join(work, d), { recursive: true });
  }
  // Copy the small app project out of the read-only snap so flutter can write build/.
  fs.cpSync(flutterDir, path.join(work, 'proj'), { recursive: true });

  // BUILD AT ONE CANONICAL ABSOLUTE PATH, ON EVERY BUILDER.
  //
  // Proven 2026-08-26: the project's absolute path is baked into the Dart AOT snapshot,
  // through the plugin-registrant URI:
  //     file:///<projectDir>/.dart_tool/flutter_build/dart_plugin_registrant.dart
  // Two builds of identical source at different paths gave libapp.so files differing in
  // 18-32% of .text. That looks like non-determinism and is not: .rodata shifted by 64
  // bytes (the URI length delta, padded) and every PC-relative reference downstream moved
  // with it. Only FOUR strings actually differed. Rebuilt at a matching path, the two APKs
  // were 543/543 byte-identical - across different userlands (glibc 2.35 vs 2.43) and
  // different JDK point releases.
  //
  // So a canonical path is not tidiness, it is what makes k-of-n content agreement possible
  // at all: without it two HONEST builders produce different digests and quorum can never
  // be reached. `work` cannot serve as that path - it lives under SNAP_DATA, which is
  // revision-scoped (/var/snap/sov-relay/x2 vs .../x25), so two nodes on different snap
  // revisions would disagree for no reason.
  //
  // Bind-mounting keeps the bytes in SNAP_DATA (so disk accounting and the wipe above still
  // work) while presenting one stable path to the compiler.
  //
  // If the bind fails we still build - a node that cannot agree is better than a node that
  // cannot ship - but we say so plainly, because the artifact will not match other builders
  // and that must not be discovered later as a mystery digest mismatch.
  let buildRoot = work;
  try {
    fs.mkdirSync(CANONICAL_BUILD_ROOT, { recursive: true });
    try { execFileSync('umount', ['-l', CANONICAL_BUILD_ROOT]); } catch (_) { /* not mounted */ }
    execFileSync('mount', ['--bind', work, CANONICAL_BUILD_ROOT]);
    buildRoot = CANONICAL_BUILD_ROOT;
    // Say so POSITIVELY. Which path was used decides whether this artifact can take part
    // in content agreement, so an operator (and any test) must be able to confirm it from
    // the log rather than infer it from the absence of a warning - an absent warning is
    // equally consistent with the build never having got this far.
    (global.sovLog || console).info(`[AutoBuild] building at canonical path ${CANONICAL_BUILD_ROOT} (bound from ${work})`);
  } catch (e) {
    (global.sovLog || console).warn(
      `[AutoBuild] could not bind ${work} -> ${CANONICAL_BUILD_ROOT} (${e.message}). `
      + 'Building at the raw path instead: the APK will be functionally correct but its '
      + 'content digest will NOT match other builders, so it cannot take part in k-of-n '
      + 'content agreement.');
  }

  const mounts = [];
  const overlay = (lower, upper, wk, merged) => {
    execFileSync('mount', ['-t', 'overlay', 'overlay', '-o',
      `lowerdir=${lower},upperdir=${upper},workdir=${wk}`, merged]);
    mounts.push(merged);
  };
  let flutterRoot, androidRoot;
  try {
    overlay(flutterSdkSrc, path.join(buildRoot, 'fl_up'), path.join(buildRoot, 'fl_wk'), path.join(buildRoot, 'fl'));
    flutterRoot = path.join(buildRoot, 'fl');
    overlay(androidSdkSrc, path.join(buildRoot, 'asdk_up'), path.join(buildRoot, 'asdk_wk'), path.join(buildRoot, 'asdk'));
    androidRoot = path.join(buildRoot, 'asdk');
    // The bundled dart package cache, same copy-on-write treatment. Without this,
    // PUB_CACHE points at an empty dir and `flutter pub get` goes to pub.dev - which
    // is exactly what a node with no internet cannot do (measured on VPS4: 486 MB
    // fetched). pub must be able to WRITE (lockfiles, hashes), hence overlay rather
    // than pointing straight at the read-only $SNAP copy.
    // Cache uppers live in cacheDir (persistent) so a rebuild does not re-download;
    // the merged view is mounted under work/ and torn down with the rest.
    for (const c of [['pub', pubCacheSrc, 'pc'], ['gradle', gradleCacheSrc, 'gc']]) {
      const [name, src, mnt] = c;
      if (!fs.existsSync(src)) continue;
      const up = path.join(cacheDir, name + '_up');
      const wk = path.join(cacheDir, name + '_wk');
      fs.mkdirSync(up, { recursive: true }); fs.mkdirSync(wk, { recursive: true });
      overlay(src, up, wk, path.join(buildRoot, mnt));
      if (name === 'pub') pubCacheRoot = path.join(buildRoot, mnt);
      else gradleCacheRoot = path.join(buildRoot, mnt);
    }
    (global.sovLog || console).info('[AutoBuild] android: overlay-mounted read-only SDKs (copy-on-write)'
      + (pubCacheRoot    ? ' + bundled pub cache'    : ' â€” NO bundled pub cache, pub will need the network')
      + (gradleCacheRoot ? ' + bundled gradle cache' : ' â€” NO bundled gradle cache, gradle will need the network'));
  } catch (e) {
    // Overlay unavailable â€” fall back to a cached full copy (slow first time, reused after).
    (global.sovLog || console).warn(`[AutoBuild] overlay mount failed (${e.message}); falling back to cached SDK copy`);
    for (const m of mounts.splice(0)) { try { execFileSync('umount', [m]); } catch (_) {} }
    flutterRoot = path.join(base, 'flutter-sdk-rw');
    androidRoot = path.join(base, 'android-sdk-rw');
    if (!fs.existsSync(flutterRoot)) fs.cpSync(flutterSdkSrc, flutterRoot, { recursive: true });
    if (!fs.existsSync(androidRoot)) fs.cpSync(androidSdkSrc, androidRoot, { recursive: true });
    if (fs.existsSync(pubCacheSrc)) {
      pubCacheRoot = path.join(base, 'pub-cache-rw');
      if (!fs.existsSync(pubCacheRoot)) fs.cpSync(pubCacheSrc, pubCacheRoot, { recursive: true });
    }
    if (fs.existsSync(gradleCacheSrc)) {
      gradleCacheRoot = path.join(base, 'gradle-cache-rw');
      if (!fs.existsSync(gradleCacheRoot)) fs.cpSync(gradleCacheSrc, gradleCacheRoot, { recursive: true });
    }
  }

  // Canonical when the bind succeeded, the raw path when it did not. This is the value the
  // AOT snapshot records, so it is the one that decides whether this builder can agree.
  const projectDir = path.join(buildRoot, 'proj');
  // local.properties is excluded from the bundled source (machine-specific); seed it.
  fs.mkdirSync(path.join(projectDir, 'android'), { recursive: true });
  fs.writeFileSync(path.join(projectDir, 'android', 'local.properties'),
    `flutter.sdk=${flutterRoot}\nsdk.dir=${androidRoot}\n`);

  // MATERIALISE package_config.json FROM THE BUNDLED TEMPLATE.
  //
  // Why this exists: the project's package_config.json records an ABSOLUTE path for
  // every one of ~204 packages, so it cannot be shipped verbatim - the pub cache sits
  // at a different path on every node. The obvious alternative, running `flutter pub
  // get` on the node, does not work offline either: pub fetches a security-advisories
  // manifest from pub.dev even under --offline, and CRASHES when that fetch fails
  // (dart-lang/pub#4269, still open). Measured 2026-08-24:
  //   ClientException with SocketException: Failed host lookup: 'pub.dev'
  //   (uri=https://pub.dev/api/packages/archive/advisories) -> Failed to update packages.
  //
  // So the snap ships the file with the cache prefix replaced by a token, and we
  // substitute this node's real cache path here. pub then never runs at all (the build
  // uses --no-pub), which keeps both the network and that upstream bug out of the path.
  //
  // Substitution is anchored on the TOKEN, never on a path string: a cache path can be
  // a prefix of another path, and a naive path-for-path replace corrupts every entry.
  // TWO tokens, not one. Most packages live in the pub cache, but six (flutter,
  // flutter_driver, flutter_test, flutter_web_plugins, fuchsia_remote_debug_protocol,
  // sky_engine) live inside the Flutter SDK, which is overlay-mounted at a different
  // path again. Substituting only the pub cache leaves those six pointing at the snap
  // BUILD machine's directories.
  const PUB_CACHE_TOKEN = '__SOV_PUB_CACHE__';
  const FLUTTER_ROOT_TOKEN = '__SOV_FLUTTER_ROOT__';
  const tmpl = path.join(projectDir, '.dart_tool', 'package_config.template.json');
  const pkgCfg = path.join(projectDir, '.dart_tool', 'package_config.json');
  const effectivePubCache = pubCacheRoot || path.join(buildRoot, '.pub-cache');
  if (fs.existsSync(tmpl)) {
    const rendered = fs.readFileSync(tmpl, 'utf8')
      .split(PUB_CACHE_TOKEN).join(effectivePubCache)
      .split(FLUTTER_ROOT_TOKEN).join(flutterRoot);
    for (const t of [PUB_CACHE_TOKEN, FLUTTER_ROOT_TOKEN]) {
      if (rendered.includes(t)) throw new Error(`package_config template still holds unsubstituted ${t}`);
    }
    fs.writeFileSync(pkgCfg, rendered);
    (global.sovLog || console).info(`[AutoBuild] android: package_config materialised â€” pub cache ${effectivePubCache}, flutter ${flutterRoot}`);
  } else {
    // Not fatal on its own, but it means the build will fall back to `pub get` and
    // therefore needs the network. Say so plainly rather than failing obscurely later.
    (global.sovLog || console).warn('[AutoBuild] android: NO package_config template in the snap â€” '
      + 'the build will have to run `pub get`, which requires network access to pub.dev');
  }
  // TIER-3 ONLY: pin sqlite3 to the vendored amalgamation.
  //
  // The repo default deliberately leaves this OUT (see pubspec.yaml), because the
  // prebuilt library keeps tier-1/2 GitHub builds free of the Google Play Protect
  // warning that a freshly-compiled, zero-prevalence native library triggers. But a
  // NODE has no GitHub: sqlite3's build hook would try to download
  // libsqlite3.<abi>.android.so mid-compile and die. So the node â€” and only the node â€”
  // compiles it from third_party/sqlite3, which ships inside the snap.
  //
  // Injected into the COPIED project, never the source tree, so the repo default and
  // every non-node build path stay untouched. See docs/BUILD_TIERS_DESIGN.md.
  const pubspecPath = path.join(projectDir, 'pubspec.yaml');
  const amalgamation = path.join(projectDir, 'third_party', 'sqlite3', 'sqlite3.c');
  if (!fs.existsSync(amalgamation)) {
    throw new Error('tier-3 build needs third_party/sqlite3/sqlite3.c and it is not in the snap â€” '
      + 'without it sqlite3 downloads a prebuilt library from GitHub and an offline build cannot finish');
  }
  let pubspec = fs.readFileSync(pubspecPath, 'utf8');
  if (/^hooks:/m.test(pubspec)) {
    (global.sovLog || console).info('[AutoBuild] android: pubspec already pins sqlite3 â€” leaving it alone');
  } else {
    pubspec = pubspec.replace(/\s*$/, '\n')
      + '\n# INJECTED by autobuild.js for the tier-3 node self-build. Not in the repo default.\n'
      + 'hooks:\n'
      + '  user_defines:\n'
      + '    sqlite3:\n'
      + '      source: source\n'
      + '      path: third_party/sqlite3/sqlite3.c\n';
    fs.writeFileSync(pubspecPath, pubspec);
    if (!/^hooks:/m.test(fs.readFileSync(pubspecPath, 'utf8'))) {
      throw new Error('sqlite3 hooks injection did not take â€” refusing to start a build that will reach GitHub');
    }
    (global.sovLog || console).info('[AutoBuild] android: sqlite3 pinned to vendored source (tier-3 offline build)');
  }

  // .flutter-plugins-dependencies â€” how Gradle finds each plugin's ANDROID code.
  // Missing it does not fail loudly at resolution; it fails deep in javac with
  // "package <plugin> does not exist" for every plugin at once.
  const PROJECT_ROOT_TOKEN = '__SOV_PROJECT_ROOT__';
  const fpdTmpl = path.join(projectDir, '.flutter-plugins-dependencies.template');
  if (fs.existsSync(fpdTmpl)) {
    const fpd = fs.readFileSync(fpdTmpl, 'utf8')
      .split(PUB_CACHE_TOKEN).join(effectivePubCache)
      .split(FLUTTER_ROOT_TOKEN).join(flutterRoot)
      .split(PROJECT_ROOT_TOKEN).join(projectDir);
    for (const t of [PUB_CACHE_TOKEN, FLUTTER_ROOT_TOKEN, PROJECT_ROOT_TOKEN]) {
      if (fpd.includes(t)) throw new Error(`.flutter-plugins-dependencies still holds unsubstituted ${t}`);
    }
    fs.writeFileSync(path.join(projectDir, '.flutter-plugins-dependencies'), fpd);
    (global.sovLog || console).info('[AutoBuild] android: .flutter-plugins-dependencies materialised');
  } else {
    (global.sovLog || console).warn('[AutoBuild] android: NO .flutter-plugins-dependencies template â€” '
      + 'Gradle will not find the plugins and javac will fail on every plugin package');
  }

  // FLUTTER_TOOLS' OWN CONFIG. The flutter command bootstraps flutter_tools on every
  // invocation; with no resolved package_config of its own it runs pub, which reaches
  // pub.dev for the advisories manifest and dies offline. Materialising the APP's
  // config is NOT enough - measured in 1.4.50, where the app template was perfect and
  // the build still failed on flutter_tools' own resolution.
  const ftDir = path.join(flutterRoot, 'packages', 'flutter_tools', '.dart_tool');
  const ftTmpl = path.join(ftDir, 'package_config.template.json');
  const ftCfg = path.join(ftDir, 'package_config.json');
  if (fs.existsSync(ftTmpl)) {
    const ftRendered = fs.readFileSync(ftTmpl, 'utf8')
      .split(PUB_CACHE_TOKEN).join(effectivePubCache)
      .split(FLUTTER_ROOT_TOKEN).join(flutterRoot);
    for (const t of [PUB_CACHE_TOKEN, FLUTTER_ROOT_TOKEN]) {
      if (ftRendered.includes(t)) throw new Error(`flutter_tools template still holds unsubstituted ${t}`);
    }
    fs.writeFileSync(ftCfg, ftRendered);
    (global.sovLog || console).info('[AutoBuild] android: flutter_tools package_config materialised');
  } else {
    (global.sovLog || console).warn('[AutoBuild] android: NO flutter_tools package_config template â€” '
      + 'flutter will bootstrap itself via pub, which requires network access to pub.dev');
  }

  // hooks_runner caches absolute paths from whichever cache built it; stale entries
  // point into a directory that does not exist on this node.
  try { fs.rmSync(path.join(projectDir, '.dart_tool', 'hooks_runner'), { recursive: true, force: true }); } catch (_) {}

  const env = {
    HOME: work,
    PUB_CACHE: pubCacheRoot || path.join(buildRoot, '.pub-cache'),
    GRADLE_USER_HOME: gradleCacheRoot || path.join(buildRoot, '.gradle'),
    ANDROID_SDK_ROOT: androidRoot,
    ANDROID_HOME: androidRoot,
    JAVA_HOME: jdk,
    PATH: [path.join(flutterRoot, 'bin'), path.join(jdk, 'bin'),
           path.join(snap, 'usr', 'bin'), path.join(snap, 'bin'),
           process.env.PATH || ''].join(':'),
  };
  const flutterBin = path.join(flutterRoot, 'bin', 'flutter');
  // Unmount, then DELETE the ephemeral tree. Without the delete, every build leaves
  // its project copy, overlay uppers and build output on disk until the next build
  // wipes them - on a 29 GB node that is how the disk fills quietly. The persistent
  // cache deltas in cacheDir are deliberately NOT touched here; they are what make the
  // next build fast, and pruneBuildCaches() bounds them separately.
  const cleanup = () => {
    // Stop our daemons BEFORE unmounting. A Gradle daemon does not exit when the build
    // finishes - it idles, holding two things: ~3 GB of RSS (measured 2026-08-25: killing
    // it took RAM used from 3,953 MB to 902 MB) and the overlay mounts below, which makes
    // the umount fail and the rm leave the tree behind. The wedge-clearing at the top of
    // prepareAndroidBuildEnv already handles finding a daemon here on the NEXT build; this
    // closes the window in between, which is where an operator's machine sits idle with
    // 3 GB missing and no build running to explain it.
    stopOurGradleDaemons([work, base, CANONICAL_BUILD_ROOT], path.join(projectDir, 'android', 'gradlew'), env);
    // Same lazy fallback the wedge-clearing block uses. A --stopped daemon can still be
    // releasing its handles, and an overlay left mounted here is exactly what wedges the
    // NEXT build.
    for (const m of mounts.splice(0).reverse()) {
      try { execFileSync('umount', [m]); continue; } catch (_) { /* busy */ }
      try { execFileSync('umount', ['-l', m]); } catch (__) {}
    }
    // The canonical bind is the LAST mount to go: the overlays above sit inside it, and
    // unmounting the parent first would leave them orphaned and `work` undeletable.
    if (buildRoot === CANONICAL_BUILD_ROOT) {
      try { execFileSync('umount', [CANONICAL_BUILD_ROOT]); }
      catch (_) { try { execFileSync('umount', ['-l', CANONICAL_BUILD_ROOT]); } catch (__) {} }
    }
    try { fs.rmSync(work, { recursive: true, force: true }); } catch (_) {}
  };
  return { projectDir, env, flutterBin, cleanup };
}

/** Bytes free on the filesystem holding `p`. 0 if it cannot be determined. */
function freeBytes(p) {
  try { const s = fs.statfsSync(p); return s.bavail * s.bsize; } catch (_) { return 0; }
}
function dirBytes(p) {
  let t = 0;
  try {
    for (const e of fs.readdirSync(p, { withFileTypes: true })) {
      const f = path.join(p, e.name);
      if (e.isDirectory()) t += dirBytes(f);
      else { try { t += fs.statSync(f).size; } catch (_) {} }
    }
  } catch (_) {}
  return t;
}

/**
 * Bound the things a build leaves behind. Called before every android build.
 *
 * Three separate accumulations, and only one of them is expensive to lose:
 *   1. the persistent cache DELTAS (build-cache/*_up) - grow slowly, and are cheap to
 *      drop because the bundled cache in $SNAP is the baseline underneath them. Reset
 *      once past the cap; the next build re-overlays on the shipped copy, offline.
 *   2. old APKs in outDir - 158 MB each, unbounded. Keep the newest `keepArtifacts`.
 *   3. the *-rw fallback copies, only present where overlayfs is unavailable. Left
 *      alone: recreating them is a multi-GB local copy, and they do not grow.
 */
function pruneBuildCaches({ base, outDir, capBytes, keepArtifacts = 3 } = {}) {
  const log = global.sovLog || console;
  const cacheDir = path.join(base, 'build-cache');
  const cap = capBytes || 4 * 1024 * 1024 * 1024;   // 4 GB of delta is already generous
  try {
    const sz = dirBytes(cacheDir);
    if (sz > cap) {
      fs.rmSync(cacheDir, { recursive: true, force: true });
      fs.mkdirSync(cacheDir, { recursive: true });
      log.info(`[AutoBuild] build-cache was ${(sz / 1e9).toFixed(1)} GB (cap ${(cap / 1e9).toFixed(1)} GB) â€” reset; `
             + 'the bundled caches in $SNAP are the baseline, so this costs no downloads');
    }
  } catch (_) {}
  try {
    const apks = fs.readdirSync(outDir)
      .filter(f => f.endsWith('.apk'))
      .map(f => ({ f, t: fs.statSync(path.join(outDir, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t);
    for (const old of apks.slice(keepArtifacts)) {
      fs.rmSync(path.join(outDir, old.f), { force: true });
      log.info(`[AutoBuild] pruned old artifact ${old.f}`);
    }
  } catch (_) {}
}

async function buildAndroidApk({ flutterDir, outDir, flutterBin, env }) {
  fs.mkdirSync(outDir, { recursive: true });
  const base = process.env.SNAP_DATA || os.tmpdir();
  pruneBuildCaches({ base, outDir });
  // Refuse rather than fill the disk. A node that fills its filesystem mid-build
  // stops serving citizens too - the build is never worth that.
  const MIN_FREE = 6 * 1024 * 1024 * 1024;
  const free = freeBytes(base);
  if (free && free < MIN_FREE) {
    throw new Error(`refusing to build: only ${(free / 1e9).toFixed(1)} GB free on ${base}, `
                  + `need ${(MIN_FREE / 1e9).toFixed(0)} GB. Free space or prune build-cache.`);
  }
  // $SNAP is read-only; set up writable SDKs + project + caches (overlay copy-on-write).
  const prep = prepareAndroidBuildEnv({ flutterDir });
  try {
    const bin = prep.flutterBin || flutterBin || 'flutter';  // writable-overlay flutter, not the read-only $SNAP one
    // --no-pub: dependencies are already resolved (package_config.json is materialised
    // from the bundled template in prepareAndroidBuildEnv). Letting pub run here would
    // reach pub.dev for its advisories manifest and abort on an offline node â€” see the
    // note there. Everything pub would have fetched is already in the bundled cache.
    await run(bin, ['build', 'apk', '--release', '--no-pub'], { cwd: prep.projectDir, env: { ...process.env, ...prep.env, ...(env || {}) } });
    const built = path.join(prep.projectDir, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
    if (!fs.existsSync(built)) throw new Error('flutter build produced no app-release.apk');
    const outFile = path.join(outDir, 'SovWallet.apk');
    fs.copyFileSync(built, outFile);
    const a = { platform: 'android', file: 'SovWallet.apk', sha256: sha256File(outFile), size: fs.statSync(outFile).size };
    (global.sovLog || console).info(`[AutoBuild] built android: SovWallet.apk (${a.sha256.slice(0, 12)}â€¦)`);
    return a;
  } finally {
    prep.cleanup();
  }
}

/**
 * Assemble the Distribution Manifest (unsigned). The host base URLs are where the
 * artifacts get uploaded (third-party hosts) â€” NOT the node's own endpoint.
 */
function buildManifest({ version, artifacts, baseUrls }) {
  const platforms = {};
  for (const a of artifacts) {
    const base = (baseUrls && baseUrls[a.platform]) || '';
    platforms[a.platform] = { url: base + a.file, sha256: a.sha256, size: a.size };
  }
  return { kind: 'sov-distribution-manifest', version, built_at: Date.now(), platforms };
}

/**
 * Full launch-and-forget cycle. `signManifest` MUST be the witness-signer threshold
 * signer (PI-37); `publish` uploads artifacts + posts the signed manifest to the mesh.
 * Both are injected so this module stays free of protocol/transport coupling.
 */
async function runReleaseCycle({ version, entry, outDir, baseUrls, pkgBin,
                                 flutterDir, flutterBin, androidEnv,
                                 signManifest, publish }) {
  const log = global.sovLog || console;
  log.info(`[AutoBuild] release cycle v${version} â€” building all platformsâ€¦`);
  const artifacts = await crossCompileAll({ entry, outDir, pkgBin });  // win/mac/linux
  if (flutterDir) {  // android via the headless Flutter/Gradle toolchain
    artifacts.push(await buildAndroidApk({ flutterDir, outDir, flutterBin, env: androidEnv }));
  }
  const manifest = buildManifest({ version, artifacts, baseUrls });
  const signed = await signManifest(manifest);   // FROST threshold sig (>= threshold signers)
  await publish({ artifacts, outDir, manifest: signed });
  log.info(`[AutoBuild] v${version} published â€” ${artifacts.length} platforms, threshold-signed. No human in the loop.`);
  return signed;
}

module.exports = { TARGETS, crossCompileAll, prepareAndroidBuildEnv, buildAndroidApk, buildManifest, runReleaseCycle, sha256File, pruneBuildCaches, freeBytes };
