// 用 Node 内置测试运行器（Node 24 自带），不引入任何依赖。
// 运行：node --test tests
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deepMerge, planPatch } from '../scripts/lib/config-merge.mjs';

test('objects merge recursively and never mutate the base', () => {
  const base = { agents: { defaults: { workspace: '/old', model: { primary: 'x' } } }, keep: 1 };
  const patch = { agents: { defaults: { model: { primary: 'myprovider/deepseek-v4.1-flash' } } } };
  const out = deepMerge(base, patch);
  assert.equal(out.agents.defaults.model.primary, 'myprovider/deepseek-v4.1-flash');
  assert.equal(out.agents.defaults.workspace, '/old', 'sibling keys survive');
  assert.equal(out.keep, 1, 'untouched top-level survives');
  assert.equal(base.agents.defaults.model.primary, 'x', 'base must not be mutated');
});

test('arrays replace instead of merging element-wise', () => {
  // allowFrom 这类白名单必须是「替换」语义。逐元素合并会让旧条目赖着不走，
  // 那是个安全缺陷而不是便利。
  const out = deepMerge({ channels: { wx: { allowFrom: ['old1', 'old2', 'old3'] } } },
                        { channels: { wx: { allowFrom: ['me'] } } });
  assert.deepEqual(out.channels.wx.allowFrom, ['me']);
});

test('null in the patch deletes the key', () => {
  const out = deepMerge({ a: 1, b: 2 }, { b: null });
  assert.equal('b' in out, false);
  assert.equal(out.a, 1);
});

test('scalars overwrite scalars', () => {
  assert.equal(deepMerge({ a: 1 }, { a: 2 }).a, 2);
});

test('type change (object -> array) replaces rather than blending', () => {
  const out = deepMerge({ x: { keep: true } }, { x: [1, 2] });
  assert.deepEqual(out.x, [1, 2]);
});

test('planPatch reports no change when the patch is already applied', () => {
  // 幂等性的核心：install.ps1 会被反复重跑，不该每次都改文件时间戳
  const text = JSON.stringify({ agents: { defaults: { model: { primary: 'p/m' } } }, other: 7 }, null, 2);
  const patch = { agents: { defaults: { model: { primary: 'p/m' } } } };
  const r = planPatch(text, patch);
  assert.equal(r.changed, false, 're-applying an identical patch must be a no-op');
  assert.equal(r.nextText, text);
});

test('planPatch changes only when it really should', () => {
  const text = JSON.stringify({ a: { b: 1 } }, null, 2);
  const r = planPatch(text, { a: { b: 2 } });
  assert.equal(r.changed, true);
  assert.equal(JSON.parse(r.nextText).a.b, 2);
});

test('idempotency is semantic, not textual', () => {
  // 回归用：openclaw.json 由 OpenClaw 自己写，排版和键序都不由我们决定。
  // 若按文本比较判幂等，重跑 install 会误判有改动、白刷备份并碰用户文件。
  const disk = JSON.stringify({ other: 7, agents: { defaults: { model: { primary: 'p/m' } } } }, null, 4) + '\n\n';
  const r = planPatch(disk, { agents: { defaults: { model: { primary: 'p/m' } } } });
  assert.equal(r.changed, false, 'same semantics under different formatting must be a no-op');
  assert.equal(r.nextText, disk, 'no-op returns the original text untouched so the caller skips writing');
});

test('non-object patch values are rejected instead of silently accepted', () => {
  assert.throws(() => deepMerge({ a: 1 }, 'oops'), /patch must be an object/);
});

test('unparseable base text throws a named error the caller can turn into guidance', () => {
  // openclaw.json 是 JSON5（可含注释/尾逗号）。我们的合并只吃严格 JSON，
  // 解析不了就必须明确失败，让调用方去提示手工粘贴，而不是猜。
  assert.throws(() => planPatch('{ not json // comment }', { a: 1 }), /base is not strict JSON/);
});
