#!/usr/bin/env node
/**
 * Nightly attendance sync to IIMPresent — the sender side of docs/IIMPRESENT-SYNC.md (sections 1-6).
 *
 * Reads our attendance records, shapes them into enrolments / sessions / totals, splits them into pages
 * of at most 500 rows, signs each page with HMAC-SHA256 and posts them one after another.
 *
 * Nothing is written on the receiving end until you pass --live: by default every batch is sent with
 * dry_run: true, which the receiver validates and discards.
 *
 * Usage:
 *   node sync/send-attendance.mjs                 # dry run against the endpoint
 *   node sync/send-attendance.mjs --live          # the real thing
 *   node sync/send-attendance.mjs --out ./out     # build and check pages without posting anything
 *   node sync/send-attendance.mjs --as-of 2026-09-19 --page-size 200
 *
 * Settings come from the environment (see sync/.env.example). Node 18 or newer; no packages needed.
 */

import { createHmac, randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

/* ---------------- Settings ---------------- */

const args = process.argv.slice(2);
const flag = name => args.includes(`--${name}`);
const option = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};

const CFG = {
  supabaseUrl: (process.env.SUPABASE_URL || "").replace(/\/+$/, ""),
  serviceKey: process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  endpoint: process.env.IIMPRESENT_ENDPOINT || "",
  keyId: process.env.IIMPRESENT_KEY_ID || "k1",
  secret: process.env.IIMPRESENT_SECRET || "",
  term: process.env.TERM || "V",
  pageSize: Number(option("page-size", process.env.PAGE_SIZE || 500)),
  asOf: option("as-of", process.env.AS_OF || ""),
  outDir: option("out", process.env.OUT_DIR || ""),
  live: flag("live") || process.env.DRY_RUN === "false"
};

const CONTRACT = 1;
const READ_PAGE = 1000;                       // rows per read from our own database
const BACKOFF_MS = [2000, 4000, 8000, 16000, 30000];
const STATUSES = new Set(["present", "absent", "excused", "not_held", "unmarked"]);

const log = (...parts) => console.log(new Date().toISOString(), ...parts);

/** ISO 8601 in this machine's timezone, with the offset spelled out: 2026-09-20T03:10:00+05:30 */
function isoWithOffset(d = new Date()) {
  const pad = n => String(Math.floor(Math.abs(n))).padStart(2, "0");
  const offset = -d.getTimezoneOffset();
  const sign = offset < 0 ? "-" : "+";
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T` +
         `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
         `${sign}${pad(offset / 60)}:${pad(offset % 60)}`;
}
const fail = msg => { console.error(`\nSync stopped: ${msg}`); process.exit(1); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

/* ---------------- Read our own records ---------------- */

async function callFunction(name, body, { limit, offset } = {}) {
  const url = new URL(`${CFG.supabaseUrl}/rest/v1/rpc/${name}`);
  if (limit != null) { url.searchParams.set("limit", limit); url.searchParams.set("offset", offset); }
  const res = await fetch(url, {
    method: "POST",
    headers: {
      apikey: CFG.serviceKey,
      authorization: `Bearer ${CFG.serviceKey}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(body ?? {})
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${name} failed (HTTP ${res.status}): ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

/** Read every row of a table-valued function, a page at a time. */
async function readAll(name, body) {
  const rows = [];
  for (let offset = 0; ; offset += READ_PAGE) {
    const part = await callFunction(name, body, { limit: READ_PAGE, offset });
    rows.push(...part);
    if (part.length < READ_PAGE) return rows;
  }
}

/* ---------------- Check what we're about to send ---------------- */

const isEmail = v => typeof v === "string" && v === v.toLowerCase() && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v);

function checkRows(enrolments, sessions, totals) {
  const problems = [];
  const note = (kind, i, why, row) => problems.push(`${kind}[${i}] ${why}: ${JSON.stringify(row).slice(0, 160)}`);

  enrolments.forEach((r, i) => {
    if (!isEmail(r.student_email)) note("enrolments", i, "student_email is missing or not lowercase", r);
    if (!r.course_code) note("enrolments", i, "course_code is missing", r);
  });

  const enrolled = new Set(enrolments.map(r => `${r.student_email}|${r.course_code}`));
  const seen = new Set();
  sessions.forEach((r, i) => {
    if (!isEmail(r.student_email)) note("sessions", i, "student_email is missing or not lowercase", r);
    if (!STATUSES.has(r.status)) note("sessions", i, `status "${r.status}" is not one the contract allows`, r);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(r.class_date)) note("sessions", i, "class_date is not YYYY-MM-DD", r);
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(r.start_time)) note("sessions", i, "start_time is not HH:MM", r);
    if (!enrolled.has(`${r.student_email}|${r.course_code}`)) note("sessions", i, "no matching enrolment row", r);
    const key = `${r.student_email}|${r.course_code}|${r.class_date}|${r.start_time}`;
    if (seen.has(key)) note("sessions", i, "two rows for the same student, course, date and time", r);
    seen.add(key);
  });

  totals.forEach((r, i) => {
    if (!isEmail(r.student_email)) note("totals", i, "student_email is missing or not lowercase", r);
    if (r.attended > r.held) note("totals", i, "attended is greater than held", r);
    if (r.percent != null && (r.percent < 0 || r.percent > 100)) note("totals", i, "percent is outside 0-100", r);
    if (!enrolled.has(`${r.student_email}|${r.course_code}`)) note("totals", i, "no matching enrolment row", r);
  });

  return problems;
}

/* ---------------- Build the pages ---------------- */

function buildPages(batch, enrolments, sessions, totals) {
  // Enrolments first: a session or total that arrives before its enrolment gets quarantined.
  const queue = [
    ...enrolments.map(row => ["enrolments", row]),
    ...sessions.map(row => ["sessions", row]),
    ...totals.map(row => ["totals", row])
  ];
  const pages = [];
  for (let i = 0; i < queue.length; i += CFG.pageSize) {
    const page = { enrolments: [], sessions: [], totals: [] };
    for (const [kind, row] of queue.slice(i, i + CFG.pageSize)) page[kind].push(row);
    pages.push(page);
  }
  if (!pages.length) pages.push({ enrolments: [], sessions: [], totals: [] });

  return pages.map((arrays, index) => ({
    contract: CONTRACT,
    batch_id: batch.batchId,
    page: index + 1,
    pages: pages.length,
    generated_at: batch.generatedAt,
    as_of: batch.asOf,
    term: CFG.term,
    complete: true,               // we always send the whole term, never a delta
    dry_run: !CFG.live,
    ...arrays
  }));
}

/* ---------------- Send one page ---------------- */

function sign(bodyText) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = createHmac("sha256", CFG.secret).update(`${timestamp}.${bodyText}`).digest("hex");
  return { timestamp, signature };
}

async function postPage(envelope) {
  const bodyText = JSON.stringify(envelope);   // sign and send these exact bytes
  const rows = envelope.enrolments.length + envelope.sessions.length + envelope.totals.length;

  for (let attempt = 0; ; attempt++) {
    const { timestamp, signature } = sign(bodyText);
    let res, text;
    try {
      res = await fetch(CFG.endpoint, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-iimp-key-id": CFG.keyId,
          "x-iimp-timestamp": timestamp,
          "x-iimp-signature": signature
        },
        body: bodyText
      });
      text = await res.text();
    } catch (e) {
      if (attempt >= BACKOFF_MS.length) fail(`page ${envelope.page}: ${e.message}, and retries are exhausted`);
      log(`page ${envelope.page}: ${e.message}; retrying in ${BACKOFF_MS[attempt] / 1000}s`);
      await sleep(BACKOFF_MS[attempt]);
      continue;
    }

    if (res.status === 200) {
      let body = {};
      try { body = JSON.parse(text); } catch { /* a 200 without JSON still counts as applied */ }
      log(`page ${envelope.page}/${envelope.pages}: ${rows} rows, accepted ${body.accepted ?? "?"}, quarantined ${body.quarantined ?? 0}`);
      (body.errors || []).forEach(e => log(`  quarantined row ${e.row_index}: ${e.reason}`));
      return { rows, accepted: body.accepted ?? 0, quarantined: body.quarantined ?? 0, errors: body.errors || [] };
    }
    if (res.status >= 500) {
      if (attempt >= BACKOFF_MS.length) fail(`page ${envelope.page}: receiver still failing (HTTP ${res.status}) after ${BACKOFF_MS.length} retries`);
      log(`page ${envelope.page}: HTTP ${res.status}; retrying in ${BACKOFF_MS[attempt] / 1000}s`);
      await sleep(BACKOFF_MS[attempt]);
      continue;
    }

    // 400, 401, 409, 413: all mean stop and fix something.
    const advice = {
      400: "malformed body or unknown contract version — fix the sender, do not retry",
      401: "signature, timestamp or key id rejected — check the shared secret and this machine's clock",
      409: "same batch and page already arrived with a different body — the batch was rebuilt mid-send",
      413: "over the row limit — lower --page-size"
    }[res.status] || "unexpected response";
    fail(`page ${envelope.page}: HTTP ${res.status} (${advice}). Response: ${text.slice(0, 300)}`);
  }
}

/* ---------------- Run ---------------- */

async function main() {
  const started = Date.now();
  if (!CFG.supabaseUrl || !CFG.serviceKey) fail("set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (see sync/.env.example)");
  if (!Number.isInteger(CFG.pageSize) || CFG.pageSize < 1 || CFG.pageSize > 500) fail("--page-size must be between 1 and 500");

  const asOf = CFG.asOf || await callFunction("sync_as_of");
  if (!asOf) fail("no attendance has been saved yet, so there is nothing to send");
  log(`batch as_of ${asOf}, term ${CFG.term}, ${CFG.live ? "LIVE" : "dry run"}`);

  const [enrolments, sessions, totals, unmapped] = await Promise.all([
    readAll("sync_enrolments", { p_as_of: asOf }),
    readAll("sync_sessions", { p_as_of: asOf }),
    readAll("sync_totals", { p_as_of: asOf }),
    readAll("sync_unmapped_students")
  ]);
  log(`read ${enrolments.length} enrolments, ${sessions.length} sessions, ${totals.length} totals`);
  if (unmapped.length) {
    log(`WARNING: ${unmapped.length} students have no institute email and are not in this batch ` +
        `(e.g. ${unmapped.slice(0, 3).map(s => s.reg).join(", ")}). Link them on the portal's Access page.`);
  }

  const problems = checkRows(enrolments, sessions, totals);
  if (problems.length) {
    problems.slice(0, 10).forEach(p => console.error("  " + p));
    fail(`${problems.length} row(s) would be rejected by the receiver; nothing was sent`);
  }

  const batch = { batchId: randomUUID(), generatedAt: isoWithOffset(), asOf };
  const pages = buildPages(batch, enrolments, sessions, totals);
  log(`batch ${batch.batchId}: ${pages.length} page(s) of up to ${CFG.pageSize} rows`);

  if (CFG.outDir) {
    await mkdir(CFG.outDir, { recursive: true });
    for (const page of pages) {
      await writeFile(join(CFG.outDir, `page-${String(page.page).padStart(4, "0")}.json`), JSON.stringify(page, null, 2));
    }
    log(`wrote ${pages.length} page(s) to ${CFG.outDir} and posted nothing`);
    return;
  }

  if (!CFG.endpoint || !CFG.secret) fail("set IIMPRESENT_ENDPOINT and IIMPRESENT_SECRET, or use --out to inspect the pages instead");

  let accepted = 0, quarantined = 0;
  for (const page of pages) {                  // sequential, never parallel
    const result = await postPage(page);
    accepted += result.accepted;
    quarantined += result.quarantined;
  }

  log(`done in ${Math.round((Date.now() - started) / 1000)}s: ${pages.length} page(s), ` +
      `${accepted} rows accepted, ${quarantined} quarantined${CFG.live ? "" : " (dry run: the receiver discarded them)"}`);
}

main().catch(e => fail(e.stack || e.message));
