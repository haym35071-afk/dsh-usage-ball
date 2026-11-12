// DSH 用量采集器：扫描 ~/.dsh/sessions 下的会话日志，按天 / 按模型 / 峰谷时段聚合 token 与费用。
// 输出 state.json 给悬浮窗读取；价格与官方价目表一致（人民币 / 百万 tokens）。
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import os from 'node:os';

const HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const SESSIONS_ROOT = path.join(HOME, 'sessions');
const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const STATE_PATH = path.join(HERE, 'state.json');
const CACHE_PATH = path.join(HERE, '.cache.json');

const MTOK = 1e6;
const PRICES = {
  'deepseek-flash': { peak: { hit: 0.04, miss: 2, out: 8 }, off: { hit: 0.02, miss: 1, out: 4 } },
  'deepseek-v4-pro': { peak: { hit: 0.3, miss: 9, out: 27 }, off: { hit: 0.15, miss: 4.5, out: 13.5 } },
};
const ALIASES = {
  'deepseek-v4-flash': 'deepseek-flash',
  'deepseek-v4-flash-vision-exp': 'deepseek-flash',
  'deepseek-chat': 'deepseek-flash',
  'deepseek-reasoner': 'deepseek-v4-pro',
};
// 2026-2027 中国法定节假日（只用于判断峰谷；缺的日期按普通工作日算）
const HOLIDAYS = new Set([
  '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05', '2026-10-06', '2026-10-07',
  '2026-10-08', '2026-10-09', '2026-10-10',
  '2027-01-01', '2027-01-02', '2027-01-03',
]);
const PEAK_WINDOWS = [[9, 12], [14, 18]];

function beijingParts(ms) {
  const d = new Date(ms + 8 * 3600 * 1000);
  return {
    y: d.getUTCFullYear(),
    m: String(d.getUTCMonth() + 1).padStart(2, '0'),
    d: String(d.getUTCDate()).padStart(2, '0'),
    h: d.getUTCHours(),
    weekday: d.getUTCDay(),
  };
}
function dayKey(ms) {
  const p = beijingParts(ms);
  return `${p.y}-${p.m}-${p.d}`;
}
function isPeak(ms) {
  const p = beijingParts(ms);
  const key = `${p.y}-${p.m}-${p.d}`;
  if (HOLIDAYS.has(key)) return false;
  if (p.weekday === 0 || p.weekday === 6) return false;
  return PEAK_WINDOWS.some(([a, b]) => p.h >= a && p.h < b);
}

const empty = () => ({ hit: 0, miss: 0, write: 0, out: 0, calls: 0 });
function add(a, b) {
  a.hit += b.hit; a.miss += b.miss; a.write += b.write; a.out += b.out; a.calls += b.calls;
  return a;
}
function bucketOf(usage) {
  return {
    hit: usage.cacheReadTokens || 0,
    miss: usage.inputTokens || usage.uncachedInputTokens || 0,
    write: usage.cacheWriteTokens || 0,
    out: usage.outputTokens || 0,
    calls: 1,
  };
}
function priceOf(model) {
  const id = String(model || '').split('/').pop();
  const canonical = ALIASES[id] || id;
  return PRICES[canonical] ? { canonical, ...PRICES[canonical] } : null;
}
function costOf(bucket, tier) {
  return (bucket.miss * tier.miss + (bucket.hit + bucket.write) * tier.hit + bucket.out * tier.out) / MTOK;
}

function frames(buf) {
  const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
  const starts = [];
  let i = 0;
  for (;;) {
    const idx = buf.indexOf(magic, i);
    if (idx < 0) break;
    starts.push(idx);
    i = idx + 4;
  }
  const out = [];
  for (let n = 0; n < starts.length; n++) {
    const slice = buf.subarray(starts[n], starts[n + 1] ?? buf.length);
    try { out.push(zlib.zstdDecompressSync(slice).toString('utf8')); } catch { /* skip damaged frame */ }
  }
  return out.join('');
}

function scanSession(file) {
  const text = frames(fs.readFileSync(file));
  const samples = new Map(); // turn/step -> last usage sample
  let headerModel = null;
  for (const line of text.split('\n')) {
    if (!line) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    if (ev.type === 'request/header') {
      const c = ev.data && ev.data.header && ev.data.header.config;
      if (c && c.provider && c.model) headerModel = `${c.provider}/${c.model}`;
      continue;
    }
    let usage = null;
    if (ev.type === 'assistant/message' && ev.data && ev.data.usage) usage = ev.data.usage;
    else if (ev.type === 'assistant/chunk' && ev.data && ev.data.chunk && ev.data.chunk.type === 'usage' && ev.data.chunk.usage) usage = ev.data.chunk.usage;
    if (!usage) continue;
    const src = ev.data.message && ev.data.message.source;
    const model = src && src.kind === 'model' && src.provider ? `${src.provider}/${src.model}` : headerModel;
    const key = `${ev.data.turn}/${ev.data.step}`;
    samples.set(key, { usage, time: ev.time, model });
  }
  return samples;
}

function aggregate(samples) {
  const days = new Map(); // date -> { models: { model: {peak: bucket, off: bucket} } }
  const models = new Map();
  for (const { usage, time, model } of samples.values()) {
    const date = dayKey(time);
    const tier = isPeak(time) ? 'peak' : 'off';
    if (!days.has(date)) days.set(date, { models: {} });
    const day = days.get(date);
    const key = model || 'unknown';
    day.models[key] ??= { peak: empty(), off: empty() };
    add(day.models[key][tier], bucketOf(usage));
    if (!models.has(key)) models.set(key, { peak: empty(), off: empty() });
    add(models.get(key)[tier], bucketOf(usage));
  }
  return { days, models };
}

function mergeInto(target, source) {
  for (const [date, d] of source.days) {
    if (!target.days.has(date)) target.days.set(date, { models: {} });
    const td = target.days.get(date);
    for (const [model, tiers] of Object.entries(d.models)) {
      td.models[model] ??= { peak: empty(), off: empty() };
      add(td.models[model].peak, tiers.peak);
      add(td.models[model].off, tiers.off);
    }
  }
  for (const [model, tiers] of source.models) {
    if (!target.models.has(model)) target.models.set(model, { peak: empty(), off: empty() });
    add(target.models.get(model).peak, tiers.peak);
    add(target.models.get(model).off, tiers.off);
  }
}

function listFiles(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) stack.push(p);
      else if (e.name.endsWith('.jsonl.zstd')) out.push(p);
    }
  }
  return out;
}

function main() {
  const files = listFiles(SESSIONS_ROOT);
  let cache = {};
  try { cache = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8')); } catch { cache = {}; }
  const nextCache = {};
  const total = { days: new Map(), models: new Map() };
  let reused = 0;
  for (const file of files) {
    const stat = fs.statSync(file);
    const cached = cache[file];
    if (cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs && cached.days) {
      reused++;
      const days = new Map(Object.entries(cached.days));
      const models = new Map(Object.entries(cached.models));
      mergeInto(total, { days, models });
      nextCache[file] = cached;
      continue;
    }
    const agg = aggregate(scanSession(file));
    mergeInto(total, agg);
    nextCache[file] = {
      size: stat.size,
      mtimeMs: stat.mtimeMs,
      days: Object.fromEntries(agg.days),
      models: Object.fromEntries(agg.models),
    };
  }

  const today = dayKey(Date.now());
  const month = today.slice(0, 7);
  const dayStats = [];
  let todayCost = 0, todayTokens = 0, todayCalls = 0;
  let monthCost = 0, monthTokens = 0, monthCalls = 0;
  let allCost = 0, allTokens = 0, allCalls = 0;
  let unknownModels = new Set();
  for (const [date, d] of [...total.days.entries()].sort()) {
    let cost = 0, tokens = 0, calls = 0;
    for (const [model, tiers] of Object.entries(d.models)) {
      const p = priceOf(model);
      if (!p) { unknownModels.add(model); continue; }
      cost += costOf(tiers.peak, p.peak) + costOf(tiers.off, p.off);
      for (const t of [tiers.peak, tiers.off]) { tokens += t.hit + t.miss + t.write + t.out; calls += t.calls; }
    }
    dayStats.push({ date, cost: +cost.toFixed(6), tokens, calls });
    allCost += cost; allTokens += tokens; allCalls += calls;
    if (date === today) { todayCost = cost; todayTokens = tokens; todayCalls = calls; }
    if (date.startsWith(month)) { monthCost += cost; monthTokens += tokens; monthCalls += calls; }
  }

  const models = [];
  for (const [model, tiers] of total.models) {
    const p = priceOf(model);
    const tokens = tiers.peak.hit + tiers.peak.miss + tiers.peak.write + tiers.peak.out + tiers.off.hit + tiers.off.miss + tiers.off.write + tiers.off.out;
    const calls = tiers.peak.calls + tiers.off.calls;
    const cost = p ? costOf(tiers.peak, p.peak) + costOf(tiers.off, p.off) : 0;
    models.push({ model, tokens, calls, cost: +cost.toFixed(6), priced: !!p });
  }
  models.sort((a, b) => b.cost - a.cost || b.tokens - a.tokens);

  const state = {
    generatedAt: Date.now(),
    today: { date: today, cost: +todayCost.toFixed(6), tokens: todayTokens, calls: todayCalls },
    month: { key: month, cost: +monthCost.toFixed(6), tokens: monthTokens, calls: monthCalls },
    all: { cost: +allCost.toFixed(6), tokens: allTokens, calls: allCalls },
    days: dayStats.slice(-45),
    models: models.slice(0, 6),
    unpriced: [...unknownModels],
    files: files.length,
    reused,
    price: { currency: 'CNY', table: PRICES, peakHours: '周一至周五 09:00-12:00 / 14:00-18:00（北京时间）' },
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 1), 'utf8');
  fs.writeFileSync(CACHE_PATH, JSON.stringify(nextCache), 'utf8');

  console.log(`sessions=${files.length} reused=${reused} days=${dayStats.length}`);
  console.log(`today ${today}: ¥${todayCost.toFixed(4)} / ${todayTokens} tok / ${todayCalls} calls`);
  console.log(`month ${month}: ¥${monthCost.toFixed(4)} / ${monthTokens} tok`);
  console.log(`all: ¥${allCost.toFixed(4)} / ${allTokens} tok`);
  if (unknownModels.size) console.log('unpriced models:', [...unknownModels].join(', '));
  console.log('state ->', STATE_PATH);
}

main();
