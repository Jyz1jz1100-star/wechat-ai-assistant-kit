// 配置合并：把本项目负责的键深合并进 OpenClaw 的 openclaw.json。
//
// 为什么不直接用 `openclaw config set`：PowerShell 5.1 把含双引号的 JSON 作为参数
// 交给原生程序时引号会被改写，且我们无法在事后确认它真的写对了。这里改成
// 「读文件 → 深合并 → 写回 + 备份」，逻辑全部可单元测试。

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

export function deepMerge(base, patch) {
  if (!isPlainObject(patch)) {
    throw new TypeError('patch must be an object');
  }
  const out = isPlainObject(base) ? structuredClone(base) : {};
  for (const [key, value] of Object.entries(structuredClone(patch))) {
    if (value === null) {
      delete out[key];               // null = 删除该键
      continue;
    }
    if (isPlainObject(value) && isPlainObject(out[key])) {
      out[key] = deepMerge(out[key], value);
    } else {
      // 数组与非对象一律替换：白名单之类必须是「整个换掉」语义，
      // 逐元素合并会让旧条目赖着不走，那是安全缺陷。
      out[key] = value;
    }
  }
  return out;
}

function stableStringify(v) {
  // 语义比较用：键排序后序列化，这样缩进与键顺序的差异不算「有变化」。
  // 早先用文本等值判幂等是错的 —— openclaw.json 的排版和这里生成的不一致，
  // 会导致每次重跑 install 都误判为有改动，白刷一堆 .bak 并触碰用户文件时间戳。
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  if (isPlainObject(v)) {
    return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + stableStringify(v[k])).join(',') + '}';
  }
  return JSON.stringify(v) ?? 'null';
}

export function planPatch(baseText, patch) {
  let base;
  try {
    base = JSON.parse(baseText);
  } catch {
    // openclaw.json 名义上是 JSON5，可以带注释和尾逗号。我们的合并不试图当
    // JSON5 解析器 —— 解析不了就必须显式失败，让调用方去提示人工粘贴。
    throw new Error('base is not strict JSON');
  }
  const merged = deepMerge(base, patch);
  if (stableStringify(base) === stableStringify(merged)) {
    return { changed: false, nextText: baseText };   // 原样回传，调用方据此跳过写盘
  }
  return { changed: true, nextText: JSON.stringify(merged, null, 2) + '\n' };
}
