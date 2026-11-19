// ============================================================================
// Delivery board — PACE › Delivery (Migrations 029, 030, 032, 033)
// ============================================================================
// Clément, 11 Nov: an interface for the delivery team — which order is
// finished, which one is pushed back — very visual.
// 13 Nov (030): kg and accounting's invoice status on every order — taken off
// the board again on 17 Nov (invoicing is accounting's project, not live yet);
// the database still returns it.
// 17 Nov (033): the real flow — a confirmed working paper means the order is
// produced and done; it waits at the factory, the delivery team picks it up
// by truck, brings it to the dispatch center and delivers it to the client.
// 17 Nov: simpler screen, design "Option A" chosen by Clément on the design
// canvas, with order numbers 1, 2, 3… in both sections. 17 Nov 13:56: compact
// version ("Option A compact" on the canvas) — one-line day bar, the counters
// as chips on the Summary title line, ~36 px table rows, one-line delivery
// rows, and the table header row and the delivery bulk bar frozen at the top
// while scrolling (the side menu is frozen app-wide in styles.css):
//
//   1 · Summary — five counters (At factory, At dispatch, On the road,
//       Delivered, Problem), kg finished / papers confirmed / delivered, and ONE
//       table of every order due that day: #, client, PO, company, kg, working
//       paper status (17 Nov, in place of the invoice),
//       status — orders not finished yet and orders pushed to another day
//       included. This is what everyone sees; it is also what Print prints.
//   2 · Delivery (delivery team and admin only) — every finished order of the
//       day, numbered, with five status buttons: At factory · At dispatch ·
//       On the road · Delivered · Problem (a comment is required; admins get a
//       bell). Tick several orders and set them in one go. Finished orders of
//       OTHER days still waiting at the factory are listed as links to their
//       day (production often runs a day or two before delivery).
//
// 17 Nov (034): the working paper status on every order of the summary table
// is a button (📄); it opens the
// working paper — the photographed FM-SA-01 (confirmed papers; admin: all)
// and its lines, ordered vs actual kg, and who confirmed the weights.
//
// Labels are Thai and English together, so no language switch is needed.
// Reasons for postponements: admin, middle office, company director only (the
// database leaves them out for everyone else). Company director (032): his
// company only, no marks.
//
// Data: delivery_board(day), delivery_mark(paper, status, note),
// delivery_mark_many(papers, status). "At factory" = no mark (status null).
// Refreshes itself every 20 s and when the tab comes back; never while a
// problem comment is being written or something is saving.
//
// Uses weighing-common.js (weighBangkokToday, weighAddDays, weighTime,
// weighCompanyShort) and postponed.js (ppReasonLabel); app.js globals at run
// time (sb, myProfile, escapeHtml, escapeAttr, paceScope).
// ============================================================================

const dlSection = document.getElementById("delivery-section");
const DL_REFRESH_MS = window.__dlRefreshMs || 20000;

const DL = {
  day: null,          // ISO delivery date on screen
  data: null,         // last delivery_board() result
  sig: "",            // data signature, to redraw only on change
  company: "all",     // all | Prosun Farm | Prosun Food
  q: "",              // search
  sel: new Set(),     // ticked orders in section 2
  problemFor: null,   // paper id whose problem comment is open
  paper: null,        // open working paper: { id, no, url, error, loading, opener }
  busy: false,
  loading: false,
  timer: null,
  message: null,      // { kind: "ok" | "err", text }
};

// The steps, in order. key = what the screen calls it; mark = the value
// stored by delivery_mark (null = no mark: waiting at the factory).
const DL_STEPS = [
  { key: "factory",   mark: null,        th: "รอรับที่โรงงาน", en: "At factory",  sth: "รอรับ",     sen: "Factory",   icon: "🏭", cls: "dl-amber" },
  { key: "dispatch",  mark: "dispatch",  th: "ที่ศูนย์",        en: "At dispatch", sth: "ที่ศูนย์",   sen: "Dispatch",  icon: "🏬", cls: "dl-teal" },
  { key: "out",       mark: "out",       th: "ระหว่างส่ง",      en: "On the road", sth: "ระหว่างส่ง", sen: "On road",   icon: "🚚", cls: "dl-blue" },
  { key: "delivered", mark: "delivered", th: "ส่งถึงแล้ว",      en: "Delivered",   sth: "ส่งแล้ว",    sen: "Delivered", icon: "✔",  cls: "dl-done" },
  { key: "problem",   mark: "problem",   th: "มีปัญหา",         en: "Problem",     sth: "ปัญหา",      sen: "Problem",   icon: "⚠",  cls: "dl-red" },
];
const DL_STEP = Object.fromEntries(DL_STEPS.map(s => [s.key, s]));
const DL_ORDER = ["factory", "dispatch", "out", "problem", "delivered"];

const dlBi = (th, en) => `${th} · ${en}`;
const dlFmt = n => Number(n).toLocaleString("en-GB", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

// Where an order stands: a delivery step, "notready" or (pushed lists) "pushed".
function dlStateOf(p) {
  if (p.mark && DL_STEP[p.mark.status]) return p.mark.status;
  if (p.status === "confirmed") return "factory";
  return "notready";
}

function dlCanMark() { return !!(DL.data && DL.data.can_mark); }
function dlFinished(p) { return p.status === "confirmed"; }

// kg: the confirmed weights once finished, else what was ordered ("~").
function dlKg(p) {
  const lines = Array.isArray(p.lines) ? p.lines : [];
  if (p.status === "confirmed" || lines.some(l => l.actual_kg !== null && l.actual_kg !== undefined)) {
    const s = lines.reduce((t, l) => t + (Number(l.actual_kg) || 0), 0);
    if (s > 0) return { kg: s, approx: p.status !== "confirmed" };
  }
  const o = lines.reduce((t, l) =>
    t + (l.ordered_unit === "kg" ? Number(l.ordered_qty) || 0 : l.ordered_unit === "g" ? (Number(l.ordered_qty) || 0) / 1000 : 0), 0);
  return o > 0 ? { kg: o, approx: true } : null;
}
function dlKgText(k) { return k ? `${k.approx ? "~" : ""}${dlFmt(k.kg)}` : "—"; }

// "PO 12345", but not "PO PO-12345" when the number already says PO.
function dlPo(po, part) {
  // Part 2, 3 … of an order split in Confirmed weights (Migration 040)
  const tag = part > 1 ? ` <span class="dl-part">${dlBi("ส่วนที่ " + part, "Part " + part)}</span>` : "";
  if (!po) return "—" + tag;
  return (/^\s*(po|so)\b/i.test(po) ? escapeHtml(po) : `PO ${escapeHtml(po)}`) + tag;
}

// Dates in both languages: "พุธ 18 พ.ย. · Wed 18 Nov".
function dlDateBi(iso, long) {
  if (!iso) return "—";
  const d = new Date(iso + "T00:00:00");
  const th = d.toLocaleDateString("th-TH", { weekday: long ? "long" : "short", day: "numeric", month: "short" });
  const en = d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  return `${th} · ${en}`;
}

function dlDayLabel(iso) {
  const today = weighBangkokToday();
  if (iso === today) return dlBi("วันนี้", "Today");
  if (iso === weighAddDays(today, 1)) return dlBi("พรุ่งนี้", "Tomorrow");
  if (iso === weighAddDays(today, -1)) return dlBi("เมื่อวาน", "Yesterday");
  return "";
}


// ----------------------------------------------------------- open / close
async function openDelivery() {
  dlSection.classList.remove("hidden");
  if (!DL.day) DL.day = weighBangkokToday();
  DL.message = null;
  DL.problemFor = null;
  dlSection.innerHTML = `<p class="mg-muted">${dlBi("กำลังโหลด…", "Loading…")}</p>`;
  await dlLoad();
}

function closeDelivery() {
  clearTimeout(DL.timer);
  if (dlSection.classList.contains("hidden")) return;
  dlSection.classList.add("hidden");
  dlSection.innerHTML = "";
}

function dlIsOpen() { return !dlSection.classList.contains("hidden"); }

document.getElementById("switch-system-btn").addEventListener("click", closeDelivery);
document.getElementById("sign-out-btn").addEventListener("click", () => {
  closeDelivery();
  Object.assign(DL, { day: null, data: null, sig: "", company: "all", q: "", problemFor: null, paper: null, message: null });
  DL.sel.clear();
});


// ----------------------------------------------------------- data
// silent = the automatic refresh: no "Loading…", and the board is redrawn
// only if something changed. A failed silent refresh keeps what is on screen.
async function dlLoad(opts = {}) {
  const silent = !!opts.silent;
  DL.loading = true;
  const day = DL.day;
  const { data, error } = await sb.rpc("delivery_board", { p_date: day });
  DL.loading = false;
  if (day !== DL.day || !dlIsOpen()) return;          // the day changed meanwhile
  if (error) {
    if (silent && DL.data) { dlSchedule(); return; }
    const missing = /delivery_board|schema cache|does not exist|Could not find/i.test(error.message || "");
    DL.data = null;
    DL.sig = "";
    DL.message = { kind: "err", text: missing
      ? dlBi("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 033 ใน Supabase", "The database is not up to date: run Migration 033 in Supabase.")
      : dlBi("โหลดข้อมูลไม่สำเร็จ", "Could not load") + ": " + error.message };
    dlDraw();
    dlSchedule();
    return;
  }
  if (!Array.isArray(data.pickups)) {   // the front end arrived before Migration 033
    DL.message = { kind: "err", text: dlBi("กรุณารัน Migration 033 ใน Supabase", "Run Migration 033 in Supabase") };
    data.pickups = [];
  }
  const sig = JSON.stringify([data.papers, data.moved, data.register, data.pickups]);
  const changed = sig !== DL.sig;
  DL.data = data;
  DL.sig = sig;
  // Forget ticks on orders that are no longer in the delivery list.
  const ids = new Set((data.papers || []).map(p => p.id));
  [...DL.sel].forEach(id => { if (!ids.has(id)) DL.sel.delete(id); });
  if (!silent) dlDraw();
  else if (changed) dlDrawBoard();
  else dlStamp();
  dlSchedule();
}

function dlSchedule() {
  clearTimeout(DL.timer);
  if (!dlIsOpen()) return;
  DL.timer = setTimeout(async () => {
    if (!dlIsOpen()) return;
    if (document.hidden || DL.loading || DL.busy || DL.problemFor || DL.paper) { dlSchedule(); return; }
    await dlLoad({ silent: true });
  }, DL_REFRESH_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && dlIsOpen() && !DL.loading && !DL.busy && !DL.problemFor && !DL.paper) dlLoad({ silent: true });
});

async function dlSetDay(iso) {
  if (!iso || iso === DL.day) return;
  DL.day = iso;
  DL.problemFor = null;
  DL.paper = null;
  DL.message = null;
  DL.sel.clear();
  DL.data = null;
  DL.sig = "";
  dlDraw();
  await dlLoad();
}

// One order to a step (mark null = back to "at the factory").
async function dlMark(paperId, mark, note) {
  if (DL.busy) return;
  DL.busy = true;
  dlDrawBoard();
  const { error } = await sb.rpc("delivery_mark", { p_paper: paperId, p_status: mark, p_note: note || null });
  DL.busy = false;
  if (error) {
    DL.message = { kind: "err", text: dlBi("บันทึกไม่สำเร็จ", "Could not save") + ": " + error.message };
  } else {
    DL.message = null;
    DL.problemFor = null;
  }
  await dlLoad({ silent: true });
  dlDrawBoard();
}

// The ticked orders to one step, all or nothing. "At factory" (no mark) is
// sent order by order: delivery_mark_many takes dispatch / out / delivered.
async function dlMarkSelected(stepKey) {
  const ids = [...DL.sel];
  if (DL.busy || !ids.length) return;
  const step = DL_STEP[stepKey];
  DL.busy = true;
  dlDrawBoard();
  let error = null;
  if (step.mark) {
    ({ error } = await sb.rpc("delivery_mark_many", { p_papers: ids, p_status: step.mark }));
  } else {
    for (const id of ids) {
      ({ error } = await sb.rpc("delivery_mark", { p_paper: id, p_status: null, p_note: null }));
      if (error) break;
    }
  }
  DL.busy = false;
  DL.message = error
    ? { kind: "err", text: dlBi("บันทึกไม่สำเร็จ", "Could not save") + ": " + error.message }
    : { kind: "ok", text: `${ids.length} ${dlBi("ออเดอร์", ids.length === 1 ? "order" : "orders")} → ${dlBi(step.th, step.en)}` };
  if (!error) DL.sel.clear();
  await dlLoad({ silent: true });
  dlDrawBoard();
}


// ----------------------------------------------------------- items
function dlMatches(p) {
  if (DL.company !== "all" && p.company !== DL.company) return false;
  if (DL.q) {
    const lines = Array.isArray(p.lines) ? p.lines : [];   // pushed items carry a count, not lines
    const hay = [p.customer_name, p.po_number, p.product, ...lines.map(l => l.description)].join(" ").toLowerCase();
    if (!hay.includes(DL.q.toLowerCase())) return false;
  }
  return true;
}

// By client name (papers still being read, with no name yet, last), then PO.
const dlByName = (a, b) => (!a.p.customer_name - !b.p.customer_name)
  || String(a.p.customer_name || "").localeCompare(String(b.p.customer_name || ""), "th")
  || String(a.p.po_number || "").localeCompare(String(b.p.po_number || ""));

// The day: papers due (finished or not) and the ones pushed away.
function dlItems() {
  const d = DL.data;
  if (!d) return { due: [], pushed: [] };
  const due = (d.papers || []).filter(dlMatches).map(p => ({ kind: "paper", state: dlStateOf(p), p })).sort(dlByName);
  const pushed = (d.moved || []).map(m => ({ kind: "moved", state: "pushed", p: m }))
    .concat((d.register || []).map(r => ({ kind: "register", state: "pushed", p: r })))
    .filter(it => dlMatches(it.p)).sort(dlByName);
  return { due, pushed };
}


// ----------------------------------------------------------- draw
function dlDraw() {
  if (!dlIsOpen()) return;
  const today = weighBangkokToday();
  const rel = dlDayLabel(DL.day);
  const chip = (iso, label) =>
    `<button type="button" class="ws-chip ${DL.day === iso ? "on" : ""}" data-act="day" data-day="${iso}" aria-pressed="${DL.day === iso}">${label}</button>`;
  dlSection.innerHTML = `
    <div class="dl-top">
      <div class="dl-daynav" role="group" aria-label="วันส่ง · Delivery day">
        <button type="button" class="dl-arrow" data-act="prev" aria-label="วันก่อนหน้า · Previous day">‹</button>
        <strong class="dl-day-date">${escapeHtml(dlDateBi(DL.day))}</strong>
        <button type="button" class="dl-arrow" data-act="next" aria-label="วันถัดไป · Next day">›</button>
      </div>
      <div class="dl-top-right">
        ${chip(weighAddDays(today, -1), dlBi("เมื่อวาน", "Yesterday"))}
        ${chip(today, dlBi("วันนี้", "Today"))}
        ${chip(weighAddDays(today, 1), dlBi("พรุ่งนี้", "Tomorrow"))}
        <label class="dl-pick"><span class="sr-only">เลือกวัน · Pick a day</span>
          <input type="date" id="dl-date" value="${escapeAttr(DL.day)}"></label>
        <button type="button" class="ws-chip" data-act="print">🖨 ${dlBi("พิมพ์", "Print")}</button>
      </div>
    </div>
    <div id="dl-board-wrap"></div>
    <div id="dl-paper-root"></div>`;
  dlDrawBoard();
  dlDrawPaper();
}

function dlStamp() {
  const el = document.getElementById("dl-stamp");
  if (el && DL.data) el.textContent = `${dlBi("อัปเดต", "Updated")} ${weighTime(DL.data.loaded_at)} · ${dlBi("รีเฟรชอัตโนมัติ", "refreshes by itself")}`;
}

function dlCompanyChip(c) {
  if (!c) return "";
  return `<span class="dl-co ${c === "Prosun Farm" ? "dl-co-farm" : "dl-co-food"}">${escapeHtml(weighCompanyShort(c))}</span>`;
}

function dlMessageHtml() {
  return DL.message
    ? `<div class="${DL.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="dl-msg" role="status">${escapeHtml(DL.message.text)}</div>` : "";
}

function dlSectionHead(n, th, en, sub, extra) {
  return `<div class="dl-sec-head">
    <span class="dl-sec-n" aria-hidden="true">${n}</span>
    <h3 class="dl-sec-title" id="dl-sec-${n}">${th} · ${en}</h3>
    ${sub ? `<span class="dl-sec-sub">${sub}</span>` : ""}
    ${extra || ""}
  </div>`;
}

// Status label for the summary table.
function dlStatusPill(it) {
  const p = it.p;
  if (it.state === "pushed") {
    const to = p.new_date ? dlDateBi(p.new_date) : null;
    return `<span class="dl-pill dl-violet">↻ ${to ? `เลื่อนไป ${escapeHtml(to)}` : "เลื่อน · ยังไม่มีวันใหม่ · no new date"}</span>`;
  }
  if (it.state === "notready") {
    return `<span class="dl-pill dl-slate">⏳ ${escapeHtml(dlBi("ยังไม่พร้อมส่ง", "Not ready yet"))}</span>`;
  }
  const s = DL_STEP[it.state];
  const when = p.mark ? ` <span class="dl-pill-time">${escapeHtml(weighTime(p.mark.marked_at))}</span>` : "";
  return `<span class="dl-pill ${s.cls}">${s.icon} ${escapeHtml(dlBi(s.th, s.en))}${when}</span>`;
}

// Working paper status (17 Nov, in place of the invoice): where the paper
// stands at the factory — photographed, read, weights checked and confirmed.
function dlPaperStatus(status, p) {
  const at = p && p.confirmed_at ? ` <span class="dl-pill-time">${escapeHtml(weighTime(p.confirmed_at))}</span>` : "";
  if (status === "confirmed") return `<span class="dl-ps dl-ps-ok">✅ ${dlBi("ยืนยันแล้ว", "Confirmed")}${at}</span>`;
  if (status === "read" && p && p.reopened) return `<span class="dl-ps dl-ps-warn">✏️ ${dlBi("กำลังแก้น้ำหนัก", "Being corrected")}</span>`;
  if (status === "read") return `<span class="dl-ps dl-ps-warn">⚖️ ${dlBi("รอตรวจน้ำหนัก", "Weights to check")}</span>`;
  if (status === "failed") return `<span class="dl-ps dl-ps-bad">⚠ ${dlBi("อ่านไม่ได้ ต้องตรวจ", "Not read, to check")}</span>`;
  if (["uploading", "queued", "reading"].includes(status)) return `<span class="dl-ps dl-ps-wait">⏳ ${dlBi("กำลังอ่านใบงาน", "Being read")}</span>`;
  if (status === "postponed") return `<span class="dl-ps dl-ps-wait">↻ ${dlBi("ยังไม่ผลิต (เลื่อนมา)", "Not produced (postponed here)")}</span>`;
  return `<span class="dl-muted">—</span>`;
}

// In the table the status IS the button that opens the paper (photo + lines).
function dlPaperCell(it, no) {
  if (it.kind === "paper") {
    const p = it.p;
    return `<button type="button" class="dl-view" data-act="paper" data-id="${escapeAttr(p.id)}" data-no="${no}"
      aria-label="ดูใบงาน · Open the working paper: ${escapeAttr(p.customer_name || "")}">📄 ${dlPaperStatus(p.status, p)}</button>`;
  }
  if (it.kind === "moved" && it.p.paper_status) return dlPaperStatus(it.p.paper_status, null);
  return `<span class="dl-muted">—</span>`;
}

function dlSummaryHtml(due, pushed) {
  const fin = due.filter(it => it.state !== "notready");
  const n = k => fin.filter(it => it.state === k).length;
  const kg = fin.reduce((t, it) => t + ((dlKg(it.p) || {}).kg || 0), 0);
  const confirmed = due.filter(it => dlFinished(it.p)).length;
  const delivered = n("delivered");
  const chips = DL_STEPS.map(s => `<span class="dl-chip ${s.cls} ${n(s.key) ? "" : "zero"}"><strong>${n(s.key)}</strong> ${s.icon} ${s.sth} <small>${s.sen}</small></span>`).join("");

  const rows = due.concat(pushed);
  const body = rows.map((it, i) => {
    const p = it.p;
    const k = it.kind === "paper" ? dlKg(p)
      : it.kind === "moved" && p.kg_ordered ? { kg: Number(p.kg_ordered), approx: true }
      : it.kind === "register" && p.quantity_kg !== null && p.quantity_kg !== undefined ? { kg: Number(p.quantity_kg), approx: true } : null;
    const reason = it.state === "pushed" && DL.data.reasons_visible && p.reason
      ? `<div class="dl-sub">${escapeHtml(ppReasonLabel(p.reason))}${p.note ? " — " + escapeHtml(p.note) : ""}</div>` : "";
    const note = p.mark && p.mark.status === "problem" && p.mark.note ? `<div class="dl-sub dl-sub-red">“${escapeHtml(p.mark.note)}”</div>` : "";
    return `<tr class="dl-row-${it.state}" data-id="${escapeAttr(p.id || p.paper_id || "")}">
      <td class="dl-no">${i + 1}</td>
      <td class="dl-client"><strong>${escapeHtml(p.customer_name || dlBi("กำลังอ่านใบงาน…", "Paper being read…"))}</strong>${note}${reason}</td>
      <td class="dl-po">${dlPo(p.po_number, p.part)}</td>
      <td>${dlCompanyChip(p.company)}</td>
      <td class="dl-kg">${escapeHtml(dlKgText(k))}</td>
      <td>${dlPaperCell(it, i + 1)}</td>
      <td>${dlStatusPill(it)}</td>
    </tr>`;
  }).join("");

  const filters = paceScope()
    ? `<span class="mg-company-fixed" id="dl-company-fixed">${escapeHtml(paceScope())}</span>`   // company director: his company only (032)
    : ["all", "Prosun Farm", "Prosun Food"].map(v =>
        `<button type="button" class="ws-chip ${DL.company === v ? "on" : ""}" data-act="company" data-company="${escapeAttr(v)}" aria-pressed="${DL.company === v}">${v === "all" ? dlBi("ทุกบริษัท", "All") : v === "Prosun Farm" ? "PSFarm" : "PSFood"}</button>`).join("");

  return `<section class="dl-sec" aria-labelledby="dl-sec-1">
    ${dlSectionHead(1, "สรุป", "Summary", "", `<span class="dl-chips">${chips}</span>
      <span class="dl-totals">
        <span><strong>${dlFmt(kg)} kg</strong> ${dlBi("ผลิตเสร็จ", "finished")}</span>
        <span><strong>${confirmed} / ${due.length}</strong> ${dlBi("ใบงานยืนยัน", "confirmed")}</span>
        <span><strong>${delivered} / ${due.length}</strong> ${dlBi("ส่งแล้ว", "delivered")}</span>
      </span>`)}
    <div class="dl-filters">
      <div class="ws-presets">${filters}</div>
      <input type="search" id="dl-search" class="dl-search" placeholder="ค้นหาลูกค้า / PO · Search client / PO" value="${escapeAttr(DL.q)}" aria-label="ค้นหา · Search">
      <span class="dl-muted dl-stamp" id="dl-stamp"></span>
    </div>
    <div class="dl-table-box">
      <table class="dl-table">
        <thead><tr>
          <th class="dl-no">#</th><th>ลูกค้า · Client</th><th>PO</th><th>บริษัท</th>
          <th class="dl-kg">kg</th><th>สถานะใบงาน · Working paper</th><th>สถานะ · Status</th>
        </tr></thead>
        <tbody>${body || `<tr><td colspan="7" class="dl-empty">${dlBi("ยังไม่มีออเดอร์สำหรับวันนี้ — ออเดอร์จะขึ้นเมื่อฝ่ายผลิตถ่ายรูปใบงาน", "No orders for this day yet — they appear once production photographs the working paper")}</td></tr>`}</tbody>
      </table>
    </div>
  </section>`;
}

function dlProblemFormHtml(p) {
  const dis = DL.busy ? "disabled" : "";
  return `<form class="dl-problem-form" data-id="${escapeAttr(p.id)}">
    <label for="dl-problem-note">⚠ เกิดอะไรขึ้น? · What happened? *</label>
    <textarea id="dl-problem-note" rows="2" required placeholder="เช่น ลูกค้าปิดร้าน ของตีกลับ ส่งไม่ครบ · e.g. client closed, goods returned"></textarea>
    <div class="dl-problem-actions">
      <button type="submit" class="dl-btn dl-btn-red" ${dis}>${dlBi("บันทึกปัญหา", "Save problem")}</button>
      <button type="button" class="dl-btn" data-act="problem-cancel">${dlBi("ยกเลิก", "Cancel")}</button>
      <span class="dl-muted">${dlBi("ผู้บริหารจะได้รับแจ้ง", "Management is notified")}</span>
    </div>
  </form>`;
}

function dlDeliveryHtml(due) {
  const work = due.filter(it => it.state !== "notready");
  const dis = DL.busy ? "disabled" : "";
  const selCount = work.filter(it => DL.sel.has(it.p.id)).length;
  const allOn = work.length > 0 && selCount === work.length;

  // Finished orders of other days still at the factory: links to their day.
  const other = {};
  ((DL.data && DL.data.pickups) || []).filter(p => p.due_date !== DL.day && dlMatches(p))
    .forEach(p => { other[p.due_date] = (other[p.due_date] || 0) + 1; });
  const otherHtml = Object.keys(other).sort().map(d =>
    `<button type="button" class="dl-other ${d < weighBangkokToday() ? "dl-other-late" : ""}" data-act="day" data-day="${d}">🏭 ${escapeHtml(dlDateBi(d))}: ${other[d]}</button>`).join("");

  const bulk = DL_STEPS.filter(s => s.key !== "problem").map(s =>
    `<button type="button" class="dl-bulk ${s.cls}" data-act="bulk" data-step="${s.key}" ${selCount && !DL.busy ? "" : "disabled"}>${s.icon} ${s.sth} · ${s.sen}</button>`).join("");

  const rows = work.map((it, i) => {
    const p = it.p;
    const k = dlKg(p);
    const segs = DL_STEPS.map(s => {
      const on = it.state === s.key;
      return `<button type="button" class="dl-seg ${s.cls} ${on ? "on" : ""}" data-act="step" data-id="${escapeAttr(p.id)}" data-step="${s.key}" aria-pressed="${on}" ${dis}>
${s.sth} · ${s.sen}</button>`;
    }).join("");
    const tags = [
      p.moved_from && p.moved_from !== DL.day ? `<span class="dl-tag dl-tag-violet">↻ ${dlBi("เลื่อนมาจาก", "moved from")} ${escapeHtml(dlDateBi(p.moved_from))}</span>` : "",
      p.mark && p.mark.carried ? `<span class="dl-tag dl-tag-teal">🏬 ${dlBi("รับมาแล้ว แต่ถูกเลื่อนวันส่ง", "picked up, then postponed")}</span>` : "",
      p.reopened ? `<span class="dl-tag dl-tag-amber">${dlBi("โรงงานกำลังแก้น้ำหนัก", "weights being corrected")}</span>` : "",
    ].join("");
    const who = p.mark ? `<span class="dl-muted">${escapeHtml(weighTime(p.mark.marked_at))}${p.mark.by ? " · " + escapeHtml(p.mark.by) : ""}</span>` : "";
    const note = p.mark && p.mark.status === "problem" && p.mark.note ? `<div class="dl-sub dl-sub-red">⚠ “${escapeHtml(p.mark.note)}”</div>` : "";
    return `<div class="dl-work ${DL_STEP[it.state].cls}" data-id="${escapeAttr(p.id)}">
      <span class="dl-work-no">${i + 1}</span>
      <label class="dl-work-who">
        <input type="checkbox" data-act="tick" data-id="${escapeAttr(p.id)}" ${DL.sel.has(p.id) ? "checked" : ""} ${dis}>
        <span class="dl-work-text">
          <strong>${escapeHtml(p.customer_name || "—")}</strong>
          <span class="dl-work-meta">${dlPo(p.po_number, p.part)} · ${dlCompanyChip(p.company)} · <strong>${escapeHtml(dlKgText(k))} kg</strong></span>
          ${tags ? `<span class="dl-tags">${tags}</span>` : ""}
          ${note}${who}
        </span>
      </label>
      <div class="dl-segs" role="group" aria-label="สถานะ · Status">${segs}</div>
      ${DL.problemFor === p.id ? dlProblemFormHtml(p) : ""}
    </div>`;
  }).join("");

  return `<section class="dl-sec" aria-labelledby="dl-sec-2">
    ${dlSectionHead(2, "จัดการส่ง", "Delivery", dlBi("กดสถานะของแต่ละออเดอร์", "tap the status of each order"))}
    ${otherHtml ? `<div class="dl-others"><span class="dl-muted">${dlBi("ผลิตเสร็จแล้ว รอรับที่โรงงาน (วันส่งอื่น)", "Also finished, waiting at the factory (other delivery days)")}:</span> ${otherHtml}</div>` : ""}
    ${work.length ? `<div class="dl-bulkbar">
      <label class="dl-all"><input type="checkbox" data-act="tick-all" ${allOn ? "checked" : ""} ${dis}> ${dlBi("เลือกทั้งหมด", "Select all")}</label>
      <strong class="dl-selcount">${dlBi(`เลือกแล้ว ${selCount}`, `${selCount} selected`)} →</strong>
      ${bulk}
    </div>
    <div class="dl-worklist">${rows}</div>` : `<p class="dl-empty dl-card">${dlBi("ยังไม่มีออเดอร์ที่ผลิตเสร็จสำหรับวันนี้", "No finished orders for this day yet")}</p>`}
    <p class="dl-muted dl-foot">${dlBi("ออเดอร์ที่ยังผลิตไม่เสร็จ หรือถูกเลื่อน แสดงเฉพาะในตารางสรุป", "Orders not finished yet or pushed to another day appear only in the summary")}.</p>
  </section>`;
}

function dlDrawBoard() {
  const wrap = document.getElementById("dl-board-wrap");
  if (!wrap) return;
  if (!DL.data) {
    wrap.innerHTML = dlMessageHtml() || `<p class="mg-muted">${dlBi("กำลังโหลด…", "Loading…")}</p>`;
    return;
  }
  // Keep the search box (and the caret in it) when only the board changes.
  const search = document.getElementById("dl-search");
  const typing = search && document.activeElement === search;
  const caret = typing ? search.selectionStart : null;
  const note = document.getElementById("dl-problem-note");
  const noteText = note ? note.value : "";

  const { due, pushed } = dlItems();
  wrap.innerHTML = `${dlMessageHtml()}${dlSummaryHtml(due, pushed)}${dlCanMark() ? dlDeliveryHtml(due) : ""}`;
  dlStamp();

  if (typing) {
    const s = document.getElementById("dl-search");
    s.focus();
    try { s.setSelectionRange(caret, caret); } catch (e) { /* type=search */ }
  }
  if (DL.problemFor) {
    const t = document.getElementById("dl-problem-note");
    if (t) { t.value = noteText; if (document.activeElement !== t) t.focus(); }
  }
}


// ----------------------------------------------------------- the working paper
// Photo: only a confirmed paper's for everyone but admin (the storage rules,
// Migrations 018, 020, 022, 032, 034); kept 4 weeks.
function dlPaperPhotoState(p) {
  if (!p.photo_path) return "none";
  if (p.photo_deleted_at) return "deleted";
  if (p.status !== "confirmed" && !(myProfile && myProfile.role === "admin")) return "unconfirmed";
  return "ok";
}

async function dlOpenPaper(id, no, opener) {
  const p = ((DL.data && DL.data.papers) || []).find(x => x.id === id);
  if (!p) return;
  DL.paper = { id, no, url: null, error: null, loading: false, opener };
  if (dlPaperPhotoState(p) === "ok") {
    DL.paper.loading = true;
    dlDrawPaper();
    const { data, error } = await sb.storage.from(WEIGH_BUCKET).createSignedUrl(p.photo_path, 600);
    if (!DL.paper || DL.paper.id !== id) return;    // closed or another paper meanwhile
    DL.paper.loading = false;
    if (error || !data || !data.signedUrl) DL.paper.error = (error && error.message) || "photo not found";
    else DL.paper.url = data.signedUrl;
  }
  dlDrawPaper();
}

function dlClosePaper() {
  if (!DL.paper) return;
  const opener = DL.paper.opener;
  DL.paper = null;
  dlDrawPaper();
  // Back to the button that opened it (redrawn meanwhile: find it again).
  const again = opener && dlSection.querySelector(`.dl-view[data-id="${CSS.escape(opener)}"]`);
  if (again) again.focus();
  dlSchedule();
}

function dlDrawPaper() {
  const root = document.getElementById("dl-paper-root");
  if (!root) return;
  const st = DL.paper;
  const p = st && ((DL.data && DL.data.papers) || []).find(x => x.id === st.id);
  if (!st || !p) { root.innerHTML = ""; return; }
  const confirmed = dlFinished(p);
  const lines = Array.isArray(p.lines) ? p.lines : [];
  const kg = dlKg(p);
  const photoState = dlPaperPhotoState(p);
  const photo = photoState === "ok"
    ? (st.loading ? `<p class="dl-muted">${dlBi("กำลังโหลดรูป…", "Loading the photo…")}</p>`
      : st.error ? `<p class="mg-msg">${dlBi("เปิดรูปไม่ได้", "Could not open the photo")}: ${escapeHtml(st.error)}</p>`
      : `<a href="${escapeAttr(st.url)}" target="_blank" rel="noopener" class="dl-photo-link">
           <img src="${escapeAttr(st.url)}" alt="ใบงาน · Working paper ${escapeAttr(p.po_number || "")} ${escapeAttr(p.customer_name || "")}" class="dl-photo">
         </a>
         <a href="${escapeAttr(st.url)}" target="_blank" rel="noopener" class="dl-photo-full">↗ ${dlBi("เปิดรูปเต็ม", "Open full size")}</a>`)
    : `<div class="dl-photo-none">📄<p>${photoState === "deleted" ? dlBi("รูปถูกลบแล้ว (เก็บไว้ 4 สัปดาห์)", "Photo deleted (kept 4 weeks)")
        : photoState === "unconfirmed" ? dlBi("รูปจะเปิดได้เมื่อยืนยันน้ำหนักแล้ว", "The photo opens once the weights are confirmed")
        : dlBi("ไม่มีรูป", "No photo")}</p></div>`;
  const rows = lines.map(l => `<tr>
      <td class="dl-no">${escapeHtml(String(l.line_no || ""))}</td>
      <td>${escapeHtml(l.description || "—")}</td>
      <td class="dl-kg">${escapeHtml(l.ordered_text || (l.ordered_qty !== null && l.ordered_qty !== undefined ? `${l.ordered_qty} ${weighUnit(l.ordered_unit)}` : "—"))}</td>
      <td class="dl-kg">${l.actual_kg !== null && l.actual_kg !== undefined ? `${Number(l.actual_kg).toLocaleString("en-GB", { maximumFractionDigits: 2 })}${confirmed ? "" : "?"}` : "—"}</td>
    </tr>`).join("");
  root.innerHTML = `<div class="dl-modal-back" data-act="paper-close-back">
    <div class="dl-modal" role="dialog" aria-modal="true" aria-labelledby="dl-paper-title">
      <header class="dl-modal-head">
        <div>
          <h3 id="dl-paper-title" class="dl-modal-title">📄 ${st.no ? `<span class="dl-modal-no">#${escapeHtml(String(st.no))}</span> ` : ""}${escapeHtml(p.customer_name || dlBi("กำลังอ่านใบงาน…", "Paper being read…"))}</h3>
          <div class="dl-modal-meta">${dlPo(p.po_number, p.part)} · ${dlCompanyChip(p.company)} · ${dlBi("ส่ง", "Delivery")} ${escapeHtml(dlDateBi(p.due_date))} · ${dlStatusPill({ kind: "paper", state: dlStateOf(p), p })}</div>
        </div>
        <button type="button" class="dl-modal-close" data-act="paper-close" aria-label="ปิด · Close">✕</button>
      </header>
      <div class="dl-modal-body">
        <div class="dl-modal-photo">${photo}</div>
        <div class="dl-modal-lines">
          <table class="dl-table dl-lines-table">
            <thead><tr><th class="dl-no">#</th><th>สินค้า · Product</th><th class="dl-kg">สั่ง · Ordered</th><th class="dl-kg">${dlBi("ชั่งจริง", "Actual")} kg</th></tr></thead>
            <tbody>${rows || `<tr><td colspan="4" class="dl-empty">${dlBi("ยังไม่มีรายการ", "No lines yet")}</td></tr>`}</tbody>
            ${kg ? `<tfoot><tr><td></td><td><strong>${dlBi("รวม", "Total")}</strong></td><td></td><td class="dl-kg"><strong>${escapeHtml(dlKgText(kg))}</strong></td></tr></tfoot>` : ""}
          </table>
          <p class="dl-modal-who">${confirmed
            ? `✅ ${dlBi("ยืนยันน้ำหนักโดย", "Weights confirmed by")} <strong>${escapeHtml(p.confirmed_by_name || "—")}</strong>${p.confirmed_at ? " · " + escapeHtml(weighTime(p.confirmed_at)) : ""}`
            : `⏳ ${dlBi("ยังไม่ยืนยันน้ำหนัก — ตัวเลขอาจเปลี่ยน", "Weights not confirmed yet — figures may change")}`}</p>
        </div>
      </div>
    </div>
  </div>`;
  const close = root.querySelector(".dl-modal-close");
  if (close && !root.contains(document.activeElement)) close.focus();
}

document.addEventListener("keydown", e => {
  if (e.key === "Escape" && DL.paper && dlIsOpen()) { e.preventDefault(); dlClosePaper(); }
});


// ----------------------------------------------------------- events
dlSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "tick" || act === "tick-all") return;   // handled on change
  if (act === "day") await dlSetDay(b.dataset.day);
  else if (act === "prev") await dlSetDay(weighAddDays(DL.day, -1));
  else if (act === "next") await dlSetDay(weighAddDays(DL.day, 1));
  else if (act === "print") window.print();
  else if (act === "paper") await dlOpenPaper(b.dataset.id, b.dataset.no, b.dataset.id);
  else if (act === "paper-close") dlClosePaper();
  else if (act === "paper-close-back") { if (e.target === b) dlClosePaper(); }
  else if (act === "company") { DL.company = b.dataset.company; dlDrawBoard(); }
  else if (act === "step") {
    const id = b.dataset.id;
    const step = DL_STEP[b.dataset.step];
    const p = (DL.data.papers || []).find(x => x.id === id);
    if (!p || dlStateOf(p) === step.key) return;
    if (step.key === "problem") { DL.problemFor = id; DL.message = null; dlDrawBoard(); return; }
    await dlMark(id, step.mark);
  }
  else if (act === "bulk") {
    const step = DL_STEP[b.dataset.step];
    const n = DL.sel.size;
    if (!confirm(`${dlBi(`ยืนยัน: ${n} ออเดอร์`, `Confirm: ${n} order${n === 1 ? "" : "s"}`)} → ${dlBi(step.th, step.en)}?`)) return;
    await dlMarkSelected(step.key);
  }
  else if (act === "problem-cancel") { DL.problemFor = null; dlDrawBoard(); dlSchedule(); }
});

dlSection.addEventListener("submit", async e => {
  const f = e.target.closest(".dl-problem-form");
  if (!f) return;
  e.preventDefault();
  const note = document.getElementById("dl-problem-note").value.trim();
  if (!note) {
    DL.message = { kind: "err", text: dlBi("กรุณาเขียนว่าเกิดอะไรขึ้น", "Write what happened first") };
    dlDrawBoard();
    return;
  }
  await dlMark(f.dataset.id, "problem", note);
});

dlSection.addEventListener("input", e => {
  if (e.target.id === "dl-search") { DL.q = e.target.value.trim(); dlDrawBoard(); }
});

dlSection.addEventListener("change", async e => {
  const t = e.target;
  if (t.id === "dl-date" && t.value) { await dlSetDay(t.value); return; }
  if (t.dataset.act === "tick") {
    if (t.checked) DL.sel.add(t.dataset.id); else DL.sel.delete(t.dataset.id);
    dlDrawBoard();
  } else if (t.dataset.act === "tick-all") {
    const { due } = dlItems();
    const work = due.filter(it => it.state !== "notready");
    if (t.checked) work.forEach(it => DL.sel.add(it.p.id)); else work.forEach(it => DL.sel.delete(it.p.id));
    dlDrawBoard();
  }
});
