// 把 config/openclaw.patch.json 深合并进 ~/.openclaw/openclaw.json。
// 幂等：重复执行不会再写文件、不会再产生备份。
import { readFileSync, writeFileSync, renameSync, copyFileSync, existsSync, mkdtempSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { planPatch } from './lib/config-merge.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const patchPath = arg('patch', join(ROOT, 'config', 'openclaw.patch.json'));
const configPath = arg('config', join(homedir(), '.openclaw', 'openclaw.json'));

let patch;
try {
  patch = JSON.parse(readFileSync(patchPath, 'utf8'));
} catch (e) {
  console.error(`读不到补丁 ${patchPath}：${e.message}`);
  process.exit(2);
}

// workspace 由仓库位置决定，绝不写在 patch.json 里 —— 那样每台机器都得手改，
// 而且会把上一台机器的用户名带过来。
patch.agents = patch.agents || {};
patch.agents.defaults = patch.agents.defaults || {};
patch.agents.defaults.workspace = join(ROOT, 'workspace').replace(/\\/g, '/');

let baseText = null;
if (existsSync(configPath)) {
  baseText = readFileSync(configPath, 'utf8');
}

if (baseText === null || baseText.trim() === '') {
  // OpenClaw 还没写过配置（从没启动过）。这里不替它凭空造一个文件——
  // 那会绕过它自己的默认值。让调用方先跑一次 onboard/health。
  console.error(`配置文件不存在或为空：${configPath}`);
  console.error('请先运行 `openclaw onboard` 或 `openclaw health` 让它建立默认配置，再重跑本脚本。');
  process.exit(3);
}

let plan;
try {
  plan = planPatch(baseText, patch);
} catch (e) {
  if (/base is not strict JSON/.test(e.message)) {
    console.error(`配置文件含注释或尾逗号（JSON5），本脚本不敢自动改写：${configPath}`);
    console.error(`请把 ${patchPath} 里的键手工合并进去。`);
    process.exit(4);
  }
  throw e;
}

if (!plan.changed) {
  console.log('配置已是最新，未改动文件。');
  process.exit(0);
}

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const backup = `${configPath}.bak-${stamp}`;
copyFileSync(configPath, backup);

// 原子写：先写同目录临时文件再改名，避免半截文件（上次并发安装已经踩过一次）
const tmp = join(dirname(configPath), `.openclaw.json.writing-${stamp}`);
writeFileSync(tmp, plan.nextText, 'utf8');
renameSync(tmp, configPath);

console.log(`已更新 ${configPath}`);
console.log(`旧文件备份在 ${backup}`);
