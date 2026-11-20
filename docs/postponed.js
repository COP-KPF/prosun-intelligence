// ============================================================================
// Postponed orders — PACE › Middle office (Migrations 027, 028, 035)
// ============================================================================
// One line per postponed ORDER, followed until it is delivered (17 Nov 2026,
// Clément: "when an order is postponed, how can I track it — how do I know it
// is produced, finished and no longer postponed?").
//
// Where each order is now comes from the database (postponed_orders_tracker,
// Migration 035): waiting for production, weights being checked, produced and
// waiting at the factory, picked up (dispatch center), on the road, delivered.
// "Late again" = still open and its new delivery date has passed. An order
// moved twice is one line, "2×". A middle office register record follows the
// working paper with the same PO on the new date.
//
// Compact list (design agreed 17 Nov): small type, one line per order, the
// counters are the filters, late orders first; every label in Thai and
// English (ไทย / EN switch); a status never covers other text — pills are cut
// with "…" inside their column and "Late again" wraps below.
//
// Click an order: its timeline (postponed → photographed → weights confirmed
// → picked up → on the road → delivered), and for the middle office "Delivered
// — close" by hand (until the delivery team uses the board) and the register
// record's correction.
//
// Loaded after weighing.js (reuses T, PP_REASONS, ppReasonLabel, ppSyncForm,
// ppNoteLabel, weighLangHtml, weighSetLang, weighDayShort) and before
// management.js; uses app.js globals at run time (sb, myProfile, escapeHtml,
// escapeAttr, paceReadOnly).
// ============================================================================

const ppSection = document.getElementById("postponed-section");

const PP = {
  data: null,        // postponed_orders_tracker()
  register: [],      // order_postponements rows (the correction form)
  customers: [],
  filter: "open",    // open | waiting | produced | late | closed | all
  source: "all",     // all | production | middle | register
  q: "",
  expanded: null,    // key of the order whose timeline is open
  timelines: {},     // key → { loading } | { error } | timeline
  closing: null,     // key of the order with the "close by hand" box open
  formOpen: false,
  editing: null,     // the register row being corrected
  message: null,     // { kind: "ok" | "err", text }
  missing: false,    // Migration 035 not run yet
};
const PP_CLOSED_DAYS = 30;

function ppDate(iso) {
  if (!iso) return "—";
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { day: "numeric", month: "short", year: "2-digit", timeZone: "UTC" });
}
function ppWhen(ts) {
  if (!ts) return "";
  return new Date(ts).toLocaleString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
}
function ppTime(ts) {
  return ts ? new Date(ts).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" }) : "";
}
function ppKg(n) {
  return n === null || n === undefined ? "" : Number(n).toLocaleString("en-GB", { maximumFractionDigits: 1 });
}

// ----------------------------------------------------------- wording
const PP_STATE = {
  waiting:   { cls: "pp-s-violet", get label() { return T("รอผลิต", "Waiting production"); } },
  checking:  { cls: "pp-s-amber",  get label() { return T("กำลังตรวจน้ำหนัก", "Weights being checked"); } },
  no_paper:  { cls: "pp-s-grey",   get label() { return T("รอใบงาน", "Waiting for paper"); } },
  no_date:   { cls: "pp-s-grey",   get label() { return T("ยังไม่มีวันส่งใหม่", "No new date"); } },
  factory:   { cls: "pp-s-green",  get label() { return T("ผลิตแล้ว · ที่โรงงาน", "Produced · factory"); } },
  dispatch:  { cls: "pp-s-blue",   get label() { return T("ที่ศูนย์จัดส่ง", "At dispatch"); } },
  out:       { cls: "pp-s-blue",   get label() { return T("กำลังส่ง", "On the road"); } },
  problem:   { cls: "pp-s-red",    get label() { return T("ปัญหาการส่ง", "Delivery problem"); } },
  delivered: { cls: "pp-s-done",   get label() { return T("ส่งแล้ว", "Delivered"); } },
  closed:    { cls: "pp-s-done",   get label() { return T("ปิดแล้ว", "Closed"); } },
  untracked: { cls: "pp-s-grey",   get label() { return T("ก่อนมีกระดานจัดส่ง", "Before the board"); } },
  deleted:   { cls: "pp-s-grey",   get label() { return T("ใบงานถูกลบ", "Paper deleted"); } },
};
const PP_STEPS = [
  { states: ["factory", "dispatch", "out", "problem", "delivered", "closed", "untracked"], label: () => T("ผลิตแล้ว", "Produced") },
  { states: ["dispatch", "out", "problem", "delivered", "closed"], label: () => T("รับสินค้า", "Picked up") },
  { states: ["out", "problem", "delivered", "closed"], label: () => T("กำลังส่ง", "On the road") },
  { states: ["delivered", "closed"], label: () => T("ส่งแล้ว", "Delivered") },
];
function ppSourceLabel(s) {
  return s === "production" ? T("ฝ่ายผลิต", "Production")
    : s === "middle" ? T("มิดเดิลออฟฟิศ", "Middle office")
    : T("บันทึกเลื่อน", "Register");
}
function ppCompanyTag(c) {
  return c === "Prosun Farm" ? "Farm" : c === "Prosun Food" ? "Food" : "—";
}

const PP_FILTERS = {
  open:     o => o.open,
  waiting:  o => o.open && ["waiting", "checking", "no_paper", "no_date"].includes(o.state),
  produced: o => o.open && ["factory", "dispatch", "out", "problem"].includes(o.state),
  late:     o => o.late,
  closed:   o => !o.open,
  all:      () => true,
};
function ppFilterLabel(k) {
  return {
    open: T("ยังไม่ปิด", "Still open"),
    waiting: T("รอผลิต", "Waiting production"),
    produced: T("ผลิตแล้ว ยังไม่ส่ง", "Produced, not delivered"),
    late: T("เลยกำหนดอีกครั้ง", "Late again"),
    closed: T(`ปิดแล้ว ${PP_CLOSED_DAYS} วัน`, `Closed, ${PP_CLOSED_DAYS} days`),
    all: T("ทั้งหมด", "All"),
  }[k];
}

// What happened last, in one short line.
// "Breast 10 Kg of 25 Kg, Thigh 5 Kg" — products moved to a part (Migration 040).
function ppMovedLines(lines) {
  const unit = u => (typeof weighUnit === "function" && weighUnit(u)) || u || "";
  const q = (n, u) => `${Number(n).toLocaleString("en-GB", { maximumFractionDigits: 3 })} ${unit(u)}`.trim();
  return (lines || []).map(l => `${l.description} ${l.whole ? q(l.qty, l.unit) : q(l.qty, l.unit) + T(" จาก ", " of ") + q(l.of_qty, l.unit)}`).join(", ");
}

function ppLastUpdate(o) {
  let s;
  switch (o.state) {
    case "waiting":  s = T(`วันผลิต ${weighDayShort(o.work_date)}`, `Production day ${weighDayShort(o.work_date)}`); break;
    case "checking": s = T(`ถ่ายรูปใบงาน ${ppWhen(o.uploaded_at)} · กำลังตรวจน้ำหนัก`, `Paper photographed ${ppWhen(o.uploaded_at)} · weights being checked`); break;
    case "no_paper": s = o.po_number
      ? T(`ยังไม่มีใบงาน PO ${o.po_number} สำหรับ ${weighDayShort(o.due_date)}`, `No working paper with PO ${o.po_number} for ${weighDayShort(o.due_date)} yet`)
      : T("ใส่เลข PO เพื่อให้ติดตามได้", "Add the PO number so it can be followed"); break;
    case "no_date":  s = T("ยังไม่ได้ตกลงวันส่งใหม่", "No new delivery date agreed yet"); break;
    case "factory":  s = T(`ยืนยันน้ำหนัก ${ppWhen(o.confirmed_at)}${o.kg_actual ? ` · ${ppKg(o.kg_actual)} กก.` : ""} · รอรับสินค้า`,
                           `Weights confirmed ${ppWhen(o.confirmed_at)}${o.kg_actual ? ` · ${ppKg(o.kg_actual)} kg` : ""} · waiting for pick-up`); break;
    case "dispatch": s = T(`รับสินค้าแล้ว ${ppWhen(o.mark_at)}`, `Picked up ${ppWhen(o.mark_at)}`); break;
    case "out":      s = T(`ออกส่ง ${ppWhen(o.mark_at)}`, `Out for delivery ${ppWhen(o.mark_at)}`); break;
    case "problem":  s = T("มีปัญหา", "Problem") + (o.mark_note ? ": " + o.mark_note : ""); break;
    case "delivered": s = T(`ส่งแล้ว ${ppWhen(o.mark_at)}`, `Delivered ${ppWhen(o.mark_at)}`); break;
    case "closed":   s = T(`ปิดโดย ${o.closed_by || "มิดเดิลออฟฟิศ"} ${ppWhen(o.closed_at)}`, `Closed by ${o.closed_by || "the middle office"} ${ppWhen(o.closed_at)}`)
                         + (o.close_note ? " · " + o.close_note : ""); break;
    case "untracked": s = T("ผลิตก่อนเริ่มใช้กระดานจัดส่ง ไม่ได้ติดตามการส่ง", "Produced before the delivery board started — delivery not tracked"); break;
    case "deleted":  s = T("ใบงานถูกลบ", "The working paper was deleted"); break;
    default: s = "";
  }
  if (o.late) s += T(` · เลยวันส่งใหม่ ${o.days_late} วัน`, ` · ${o.days_late} day${o.days_late === 1 ? "" : "s"} past the new date`);
  // A product postponed from Confirmed weights (Migration 040): what moved
  if (o.lines_moved && o.lines_moved.length) s = ppMovedLines(o.lines_moved) + " · " + s;
  return s;
}


// ----------------------------------------------------------- open / close
async function openPostponed() {
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  ppSection.classList.remove("hidden");
  paceLiveStart();   // live updates (041)
  ppSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  PP.message = null;
  PP.editing = null;
  PP.formOpen = false;
  PP.closing = null;
  if (!PP.customers.length && !paceReadOnly()) {   // the form's client list; a company director has no form (Migration 032)
    const { data } = await sb.from("pace_customers").select("name").eq("active", true).order("name");
    PP.customers = [...new Set((data || []).map(c => c.name))];
  }
  ppLateCheck(true);
  await ppLoad();
}

function closePostponed() {
  if (ppSection.classList.contains("hidden")) return;
  ppSection.classList.add("hidden");
  ppSection.innerHTML = "";
}

document.getElementById("switch-system-btn").addEventListener("click", closePostponed);
document.getElementById("sign-out-btn").addEventListener("click", closePostponed);

async function ppLoad() {
  const canEdit = !paceReadOnly();
  const [tr, reg] = await Promise.all([
    sb.rpc("postponed_orders_tracker", { p_closed_days: PP_CLOSED_DAYS }),
    canEdit ? sb.from("order_postponements").select("*").order("created_at", { ascending: false }).limit(500)
            : Promise.resolve({ data: [] }),
  ]);
  const err = tr.error;
  PP.missing = !!err && /postponed_orders_tracker|schema cache|does not exist|Could not find/i.test(err.message || "");
  if (err) {
    PP.data = null;
    PP.message = { kind: "err", text: PP.missing
      ? T("ยังไม่พร้อม: กรุณารัน Migration 035 ใน Supabase", "Not ready: run Migration 035 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load: ") + err.message };
  } else {
    PP.data = tr.data;
    // A timeline already open is reloaded with the list.
    if (PP.expanded) { delete PP.timelines[PP.expanded]; ppLoadTimeline(PP.expanded); }
  }
  PP.register = reg.error ? [] : reg.data || [];
  ppSetBadge();
  ppDraw();
}

// "Late again" bell for the admins (Migration 035): checked when the middle
// office or an admin opens PACE or this list, at most every 30 minutes.
let ppLateCheckedAt = 0;
function ppLateCheck(force) {
  if (!myProfile || !["admin", "sale_support"].includes(myProfile.role)) return;
  if (!force && Date.now() - ppLateCheckedAt < 30 * 60 * 1000) return;
  ppLateCheckedAt = Date.now();
  sb.rpc("postponed_late_check").then(({ error }) => {
    if (error && !/postponed_late_check|schema cache|Could not find/i.test(error.message || "")) console.warn("Late check:", error.message);
  });
}

// Count of open postponed orders on the menu item (red when some are late).
async function ppRefreshBadge() {
  if (!myProfile || !["admin", "sale_support", "company_director"].includes(myProfile.role)) return;
  paceLiveStart();   // live updates (041)
  ppLateCheck(false);
  const { data, error } = await sb.rpc("postponed_orders_tracker", { p_closed_days: 0 });
  if (error) return;
  PP.badge = data;
  ppSetBadge(data);
}
function ppSetBadge(d) {
  d = d || PP.data;
  const tab = document.getElementById("tab-postponed");
  if (!tab || !d) return;
  const orders = d.orders || [];
  const open = orders.filter(o => o.open).length;
  const late = orders.filter(o => o.late).length;
  let b = tab.querySelector(".pp-badge");
  if (!open) { if (b) b.remove(); return; }
  if (!b) {
    b = document.createElement("span");
    b.className = "pp-badge";
    tab.insertBefore(b, tab.firstChild.nextSibling);
  }
  b.textContent = String(open);
  b.classList.toggle("pp-badge-late", late > 0);
  b.title = late ? `${open} open · ${late} late again` : `${open} open`;
}


// ----------------------------------------------------------- draw
function ppVisible() {
  const orders = (PP.data && PP.data.orders) || [];
  const q = PP.q.trim().toLowerCase();
  return orders.filter(PP_FILTERS[PP.filter] || PP_FILTERS.open)
    .filter(o => PP.source === "all" || o.last_source === PP.source || (o.sources || []).includes(PP.source))
    .filter(o => !q || `${o.customer_name || ""} ${o.po_number || ""}`.toLowerCase().includes(q));
}

function ppStepsHtml(o) {
  const done = PP_STEPS.filter(s => s.states.includes(o.state)).map(s => s.label());
  const label = done.length ? T("เสร็จแล้ว: ", "Done: ") + done.join(", ") : T("ยังไม่ผลิต", "Not produced yet");
  return `<span class="pp-steps" role="img" aria-label="${escapeAttr(label)}" title="${escapeAttr(label)}">${
    PP_STEPS.map(s => `<i class="${s.states.includes(o.state) ? "on" : ""}"></i>`).join("")}</span>`;
}

function ppRowHtml(o) {
  const st = PP_STATE[o.state] || PP_STATE.checking;
  const open = PP.expanded === o.key;
  const reason = o.reason ? ppReasonLabel(o.reason) : "";
  const by = ppSourceLabel(o.last_source);
  const part = o.part > 1 ? T(`ส่วนที่ ${o.part}`, `Part ${o.part}`) : "";
  const name = `${o.customer_name || "—"}${o.po_number ? " · " + o.po_number : ""}${part ? " · " + part : ""}`;
  const update = ppLastUpdate(o);
  const delay = o.delay_days === null || o.delay_days === undefined ? "—" : `+${o.delay_days}${T(" วัน", " d")}`;
  return `<tr class="pp-row${o.late ? " pp-late" : ""}${o.open ? "" : " pp-closed"}${open ? " pp-open" : ""}" data-key="${escapeAttr(o.key)}">
    <td class="pp-c-client"><button type="button" class="pp-name" data-act="toggle" data-key="${escapeAttr(o.key)}" aria-expanded="${open}" title="${escapeAttr(name)}">
      <strong>${escapeHtml(o.customer_name || "—")}</strong>${o.po_number ? ` <span class="pp-po">${escapeHtml(o.po_number)}</span>` : ""}${part ? ` <span class="pp-part">${escapeHtml(part)}</span>` : ""}</button></td>
    <td class="pp-c-co"><span class="pp-co pp-co-${ppCompanyTag(o.company).toLowerCase()}">${ppCompanyTag(o.company)}</span></td>
    <td class="pp-c-by" title="${escapeAttr(by + (reason ? " · " + reason : "") + (o.note ? " — " + o.note : ""))}"><span class="pp-cut">
      <span class="pp-by">${escapeHtml(by)}</span>${o.times > 1 ? `<span class="pp-times" title="${escapeAttr(T(`เลื่อน ${o.times} ครั้ง`, `Postponed ${o.times} times`))}">${o.times}×</span>` : ""}${reason ? `<span class="pp-reason"> · ${escapeHtml(reason)}</span>` : ""}</span></td>
    <td class="pp-c-when"><span class="pp-cut"><s>${escapeHtml(weighDayShort(o.original_date))}</s> → <strong>${o.due_date ? escapeHtml(weighDayShort(o.due_date)) : "?"}</strong></span></td>
    <td class="pp-c-now"><span class="pp-pill ${st.cls}" title="${escapeAttr(st.label)}">${escapeHtml(st.label)}</span>${
      o.late ? `<span class="pp-pill pp-s-late">${T("เลยกำหนดอีกครั้ง", "Late again")}</span>` : ""}</td>
    <td class="pp-c-steps">${ppStepsHtml(o)}</td>
    <td class="pp-c-delay">${escapeHtml(delay)}</td>
    <td class="pp-c-note" title="${escapeAttr(update)}"><span class="pp-cut">${escapeHtml(update)}</span></td>
    <td class="pp-c-go"><button type="button" class="pp-go" data-act="toggle" data-key="${escapeAttr(o.key)}" aria-expanded="${open}" aria-label="${escapeAttr(T("ไทม์ไลน์ ", "Timeline ") + name)}">${open ? "▾" : "›"}</button></td>
  </tr>${open ? `<tr class="pp-detail-row"><td colspan="9">${ppDetailHtml(o)}</td></tr>` : ""}`;
}

function ppEventHtml(e) {
  const by = e.by ? ` · ${escapeHtml(e.by)}` : "";
  const why = e.reason ? `<div class="pp-ev-sub">${escapeHtml(ppReasonLabel(e.reason))}${e.note ? " — " + escapeHtml(e.note) : ""}</div>` : "";
  let cls = "", text = "";
  const d = iso => escapeHtml(weighDayShort(iso));
  switch (e.kind) {
    case "moved":
      cls = "pp-ev-moved";
      if (e.split_mode) {      // Migrations 040, 041: products moved to part 2, 3 …
        const prod = e.by_dept === "production";
        text = T(`${prod ? "ฝ่ายผลิต" : "มิดเดิลออฟฟิศ"}เลื่อนสินค้า: ${escapeHtml(ppMovedLines(e.lines))} · ส่ง ${d(e.from_date)} → ${d(e.to_date)} · `,
                 `Products postponed by ${prod ? "production" : "the middle office"}: ${escapeHtml(ppMovedLines(e.lines))} · delivery ${d(e.from_date)} → ${d(e.to_date)} · `)
          + (e.split_mode === "production"
            ? T(`ยังไม่ได้ผลิต — กลับไปผลิต ${d(e.to_work_date)}`, `not produced — back to production on ${d(e.to_work_date)}`)
            : T("ผลิตแล้ว — ส่งทีหลัง", "produced — delivered later"));
        break;
      }
      text = e.stage === "delivery"
        ? T(`มิดเดิลออฟฟิศเลื่อนวันส่ง ${d(e.from_date)} → ${d(e.to_date)}`, `Delivery postponed by the middle office: ${d(e.from_date)} → ${d(e.to_date)}`)
        : T(`ฝ่ายผลิตเลื่อน · ผลิต ${d(e.from_work_date)} → ${d(e.to_work_date)} · ส่ง ${d(e.from_date)} → ${d(e.to_date)}`,
            `Postponed by production · production ${d(e.from_work_date)} → ${d(e.to_work_date)} · delivery ${d(e.from_date)} → ${d(e.to_date)}`);
      break;
    case "register":
      cls = "pp-ev-moved";
      text = T(`บันทึกการเลื่อน: ส่ง ${d(e.from_date)} → ${e.to_date ? d(e.to_date) : "ยังไม่มีวันใหม่"}`,
               `Recorded in the register: delivery ${d(e.from_date)} → ${e.to_date ? d(e.to_date) : "no new date yet"}`);
      break;
    case "photographed": text = T("ถ่ายรูปใบงาน", "Working paper photographed"); break;
    case "confirmed": cls = "pp-ev-good"; text = T("ยืนยันน้ำหนัก — ผลิตเสร็จ", "Weights confirmed — produced"); break;
    case "reopened": text = T("เปิดแก้ไขน้ำหนัก", "Reopened for correction"); break;
    case "mark":
      if (e.status === "dispatch") text = T("รับสินค้าจากโรงงาน → ศูนย์จัดส่ง", "Picked up at the factory → dispatch center");
      else if (e.status === "out") text = T("ออกส่ง", "Out for delivery");
      else if (e.status === "problem") { cls = "pp-ev-bad"; text = T("ปัญหาการส่ง", "Delivery problem") + (e.note ? ": " + escapeHtml(e.note) : ""); }
      else if (e.status === "delivered") { cls = "pp-ev-done"; text = T("ส่งถึงลูกค้าแล้ว — ปิด", "Delivered — closed"); }
      break;
    case "mark_cleared": text = T("ยกเลิกสถานะการส่ง", "Delivery mark cleared"); break;
    case "closed": cls = "pp-ev-done"; text = T("ปิดโดยมิดเดิลออฟฟิศ", "Closed by hand by the middle office") + (e.note ? " — " + escapeHtml(e.note) : ""); break;
    case "late": cls = "pp-ev-bad"; text = T(`เลยวันส่งใหม่ (${d(e.due_date)}) — เลยกำหนดอีกครั้ง`, `New delivery date (${d(e.due_date)}) passed — late again`); break;
    default: text = escapeHtml(e.kind);
  }
  return `<li class="${cls}"><span class="pp-ev-at">${escapeHtml(ppWhen(e.at))}</span><span class="pp-ev-dot" aria-hidden="true"></span>
    <div class="pp-ev-body"><div>${text}${e.kind === "late" ? "" : by}</div>${why}</div></li>`;
}

function ppDetailHtml(o) {
  const tl = PP.timelines[o.key];
  const canEdit = PP.data && PP.data.can_edit && !paceReadOnly();
  const isAdmin = PP.data && PP.data.can_delete;
  let events;
  if (!tl || tl.loading) events = `<p class="mg-small mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  else if (tl.error) events = `<div class="mg-msg">${escapeHtml(tl.error)}</div>`;
  else events = `<ol class="pp-timeline">${tl.events.map(ppEventHtml).join("")}</ol>`;

  const facts = [
    [T("ลูกค้า", "Client"), `${escapeHtml(o.customer_name || "—")}${o.po_number ? " · PO " + escapeHtml(o.po_number) : ""} · ${escapeHtml(o.company || "—")}`],
    [T("วันส่ง", "Delivery"), `${escapeHtml(ppDate(o.original_date))} → <strong>${o.due_date ? escapeHtml(ppDate(o.due_date)) : T("ยังไม่มีวันใหม่", "no new date yet")}</strong>`
      + (o.times > 1 ? ` · ${T(`เลื่อน ${o.times} ครั้ง`, `postponed ${o.times} times`)}` : "")],
    [T("สาเหตุล่าสุด", "Latest reason"), o.reason ? escapeHtml(ppReasonLabel(o.reason)) + (o.note ? " — " + escapeHtml(o.note) : "") : "—"],
    [T("น้ำหนัก", "Weight"), [o.kg_ordered ? T(`สั่ง ${ppKg(o.kg_ordered)} กก.`, `ordered ${ppKg(o.kg_ordered)} kg`) : "",
      o.kg_actual && o.confirmed_at ? T(`จริง ${ppKg(o.kg_actual)} กก.`, `actual ${ppKg(o.kg_actual)} kg`) : ""].filter(Boolean).join(" · ") || "—"],
  ].map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("");

  let actions = "";
  if (canEdit) {
    if (PP.closing === o.key) {
      actions += `<form class="pp-close-form" data-key="${escapeAttr(o.key)}">
        <label for="pp-close-note">${T("หมายเหตุ (ไม่บังคับ)", "Comment (optional)")}</label>
        <input id="pp-close-note" autocomplete="off" placeholder="${escapeAttr(T("เช่น ส่งแล้วตามใบส่งของ", "e.g. delivered with the delivery note"))}">
        <button type="submit" class="ws-chip on">${T("ยืนยัน: ส่งแล้ว — ปิด", "Confirm: delivered — close")}</button>
        <button type="button" class="ws-chip" data-act="close-cancel">${T("ยกเลิก", "Cancel")}</button>
      </form>`;
    } else if (o.open) {
      actions += `<button type="button" class="ws-chip" data-act="close-ask" data-key="${escapeAttr(o.key)}">✓ ${T("ส่งแล้ว — ปิดรายการ", "Delivered — close")}</button>`;
    } else if (o.state === "closed") {
      actions += `<button type="button" class="ws-chip" data-act="reopen" data-key="${escapeAttr(o.key)}">${T("เปิดรายการอีกครั้ง", "Reopen")}</button>`;
    }
    (o.register_ids || []).forEach(id => {
      actions += `<button type="button" class="ws-chip" data-act="edit" data-id="${escapeAttr(id)}">${T("แก้ไขรายการที่บันทึก", "Correct the register record")}</button>`;
      if (isAdmin) actions += `<button type="button" class="ws-chip pp-danger" data-act="delete" data-id="${escapeAttr(id)}">${T("ลบรายการที่บันทึก", "Delete the register record")}</button>`;
    });
  }
  const hint = canEdit && o.open && ["factory", "dispatch", "out"].includes(o.state)
    ? `<p class="mg-small mg-muted">${T("ปิดเองได้ถ้าส่งแล้วแต่ยังไม่ได้กดในกระดานจัดส่ง", "Close it by hand if it was delivered but not marked on the delivery board.")}</p>` : "";
  return `<div class="pp-detail">
    <div class="pp-detail-main"><h4>${T("ไทม์ไลน์", "Timeline")}</h4>${events}</div>
    <div class="pp-detail-side"><dl class="pp-facts">${facts}</dl>${actions ? `<div class="pp-actions">${actions}</div>` : ""}${hint}</div>
  </div>`;
}

function ppFormHtml() {
  const e = PP.editing || {};
  const v = k => escapeAttr(e[k] === null || e[k] === undefined ? "" : String(e[k]));
  const reasons = PP_REASONS.map(([k, label]) =>
    `<option value="${k}" ${e.reason === k ? "selected" : ""}>${escapeHtml(label())}</option>`).join("");
  return `<form class="mg-card pp-form" id="pp-form" novalidate>
    <h3>${PP.editing ? T("แก้ไขรายการ", "Correct this record") : T("บันทึกออเดอร์ที่ถูกเลื่อน (นอกฝ่ายผลิต)", "Record a postponed order (outside production)")}</h3>
    <p class="mg-small mg-muted">${T(
      "ฝ่ายผลิตเลื่อนในหน้าชั่งน้ำหนัก รายการนั้นขึ้นที่นี่เอง ใช้แบบฟอร์มนี้สำหรับกรณีอื่น เช่น ลูกค้าขอเลื่อน หรือเลื่อนก่อนใบงานถึงฝ่ายผลิต ใส่เลข PO เพื่อให้ระบบติดตามใบงานในวันส่งใหม่ได้",
      "Postponements made by production on the weighing screen appear here by themselves. Use this form for the others — a client asking to move a delivery, or an order moved before its paper reached production. With the PO number, the order is followed to its working paper on the new date.")}</p>
    <div class="pp-fields">
      <label class="pp-wide">${T("ลูกค้า", "Client")} *
        <input id="pp-customer" list="pp-customers" required value="${v("customer_name")}" autocomplete="off">
        <datalist id="pp-customers">${PP.customers.map(c => `<option value="${escapeAttr(c)}"></option>`).join("")}</datalist>
      </label>
      <label>${T("เลขที่ PO", "PO number")}<input id="pp-po" value="${v("po_number")}"></label>
      <label>${T("บริษัท", "Company")}
        <select id="pp-company">
          <option value="">—</option>
          <option value="Prosun Farm" ${e.company === "Prosun Farm" ? "selected" : ""}>Prosun Farm</option>
          <option value="Prosun Food" ${e.company === "Prosun Food" ? "selected" : ""}>Prosun Food</option>
        </select>
      </label>
      <label class="pp-wide">${T("สินค้า", "Product")}<input id="pp-product" value="${v("product")}"></label>
      <label>${T("น้ำหนัก (กก.)", "Quantity (kg)")}<input id="pp-kg" type="number" min="0" step="0.01" inputmode="decimal" value="${v("quantity_kg")}"></label>
      <label>${T("วันส่งเดิม", "Original delivery date")} *<input id="pp-original" type="date" required value="${v("original_date")}"></label>
      <label>${T("วันส่งใหม่", "New delivery date")}<input id="pp-new" type="date" value="${v("new_date")}"></label>
      <label class="pp-wide">${T("สาเหตุ", "Reason")} *
        <select id="pp-reason" data-pp="reason" required><option value="">${T("เลือกสาเหตุ", "Choose a reason")}</option>${reasons}</select>
      </label>
      <label class="pp-full">${ppNoteLabel()}<input id="pp-note" data-pp="note" value="${v("note")}"></label>
    </div>
    <div class="pp-form-actions">
      <button type="submit" class="ws-chip on" id="pp-save" data-pp="save">${PP.editing ? T("บันทึกการแก้ไข", "Save correction") : T("บันทึก", "Save")}</button>
      <span class="mg-small pp-hint" data-pp="hint" role="status"></span>
      <button type="button" class="ws-chip" data-act="cancel">${T("ยกเลิก", "Cancel")}</button>
      <span class="mg-small mg-muted">${T("ผู้บริหารจะได้รับแจ้งทุกครั้งที่บันทึก หรือแก้วันที่และสาเหตุ", "Management is notified of each new record and of any change to its dates or reason.")}</span>
    </div>
  </form>`;
}

function ppListHtml() {
  const rows = ppVisible();
  if (!rows.length) {
    return `<div class="mg-card mg-small mg-muted" id="pp-empty">${PP.q || PP.source !== "all"
      ? T("ไม่พบรายการที่ตรงกับตัวกรอง", "No order matches these filters.")
      : T("ไม่มีออเดอร์ในกลุ่มนี้", "No order in this group.")}</div>`;
  }
  return `<div class="pp-table-wrap"><table class="pp-table" id="pp-table">
    <colgroup><col class="pp-w-client"><col class="pp-w-co"><col class="pp-w-by"><col class="pp-w-when"><col class="pp-w-now">
      <col class="pp-w-steps"><col class="pp-w-delay"><col class="pp-w-note"><col class="pp-w-go"></colgroup>
    <thead><tr>
      <th scope="col">${T("ลูกค้า · PO", "Client · PO")}</th><th scope="col">${T("บริษัท", "Co.")}</th>
      <th scope="col">${T("โดย · สาเหตุ", "By · reason")}</th><th scope="col">${T("วันส่ง", "Delivery")}</th>
      <th scope="col">${T("สถานะ", "Now")}</th><th scope="col">${T("ขั้นตอน", "Steps")}</th>
      <th scope="col">${T("เลื่อนไป", "Delay")}</th><th scope="col">${T("อัปเดตล่าสุด", "Last update")}</th>
      <th scope="col"><span class="pp-sr">${T("ไทม์ไลน์", "Timeline")}</span></th>
    </tr></thead>
    <tbody>${rows.map(ppRowHtml).join("")}</tbody></table></div>`;
}

function ppDraw() {
  if (ppSection.classList.contains("hidden")) return;
  const orders = (PP.data && PP.data.orders) || [];
  const canEdit = PP.data ? PP.data.can_edit && !paceReadOnly() : !paceReadOnly();
  const msg = PP.message
    ? `<div class="${PP.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="pp-msg" role="status">${escapeHtml(PP.message.text)}</div>` : "";
  const counters = ["open", "waiting", "produced", "late", "closed", "all"].map(k => {
    const n = orders.filter(PP_FILTERS[k]).length;
    return `<button type="button" class="pp-count pp-count-${k}${PP.filter === k ? " on" : ""}" data-act="filter" data-filter="${k}" aria-pressed="${PP.filter === k}">
      <b>${n}</b><span>${escapeHtml(ppFilterLabel(k))}</span></button>`;
  }).join("");
  const sources = [["all", T("ทั้งหมด", "All")], ["production", ppSourceLabel("production")], ["middle", ppSourceLabel("middle")], ["register", ppSourceLabel("register")]]
    .map(([k, l]) => `<option value="${k}" ${PP.source === k ? "selected" : ""}>${escapeHtml(l)}</option>`).join("");
  const showForm = canEdit && !PP.missing && (PP.formOpen || PP.editing);
  ppSection.innerHTML = `
    <div class="pp-bar">
      <p class="mg-small mg-muted">${T(
        "ทุกออเดอร์ที่ถูกเลื่อน ติดตามจนส่งถึงลูกค้า: รอผลิต → ผลิตแล้ว → รับสินค้า → กำลังส่ง → ส่งแล้ว",
        "Every postponed order, followed until it is delivered: waiting → produced → picked up → on the road → delivered.")}</p>
      <div class="pp-bar-right">
        ${canEdit && !PP.missing ? `<button type="button" class="ws-chip" data-act="new" aria-expanded="${!!showForm}">+ ${T("บันทึกการเลื่อน", "Register a postponement")}</button>` : ""}
        ${weighLangHtml()}
      </div>
    </div>
    ${msg}
    ${PP.data ? `
    <div class="pp-tools">
      <div class="pp-counts" role="group" aria-label="${escapeAttr(T("ตัวกรอง", "Filters"))}">${counters}</div>
      <div class="pp-search">
        <label for="pp-src">${T("เลื่อนโดย", "Postponed by")}</label>
        <select id="pp-src" data-act="source">${sources}</select>
        <label for="pp-q" class="pp-sr">${T("ค้นหาลูกค้าหรือ PO", "Search client or PO")}</label>
        <input id="pp-q" type="search" autocomplete="off" value="${escapeAttr(PP.q)}" placeholder="${escapeAttr(T("ลูกค้าหรือ PO", "Client or PO"))}">
      </div>
    </div>
    <div id="pp-list">${ppListHtml()}</div>
    <p class="mg-small mg-muted pp-legend"><span class="pp-steps" aria-hidden="true"><i class="on"></i></span> ${T(
      "ขั้นตอน: ผลิตแล้ว → รับสินค้า → กำลังส่ง → ส่งแล้ว · เลยกำหนดอีกครั้ง = เลยวันส่งใหม่แล้วแต่ยังไม่ส่ง · กดที่ชื่อลูกค้าเพื่อดูไทม์ไลน์",
      "Steps: produced → picked up → on the road → delivered · Late again = the new delivery date has passed and it is not delivered · Click a client for the timeline")}</p>` : ""}
    ${showForm ? ppFormHtml() : ""}`;
  ppSyncForm(document.getElementById("pp-form"));
}

// Search and source redraw only the list, so the search box keeps its focus.
function ppDrawList() {
  const el = document.getElementById("pp-list");
  if (el) el.innerHTML = ppListHtml();
}

async function ppLoadTimeline(key) {
  const o = ((PP.data && PP.data.orders) || []).find(x => x.key === key);
  if (!o) return;
  PP.timelines[key] = { loading: true };
  const { data, error } = await sb.rpc("postponed_order_timeline",
    o.paper_id ? { p_paper: o.paper_id, p_register: null } : { p_paper: null, p_register: (o.register_ids || [])[0] || null });
  PP.timelines[key] = error ? { error: T("โหลดไทม์ไลน์ไม่สำเร็จ: ", "Could not load the timeline: ") + error.message } : data;
  if (PP.expanded === key) ppDrawList();
}

ppSection.addEventListener("input", e => {
  if (e.target.dataset.pp) ppSyncForm(e.target.form);
  if (e.target.id === "pp-q") { PP.q = e.target.value; ppDrawList(); }
});
ppSection.addEventListener("change", e => {
  if (e.target.dataset.pp) ppSyncForm(e.target.form);
  if (e.target.id === "pp-src") { PP.source = e.target.value; ppDrawList(); }
});


// ----------------------------------------------------------- events
function ppFormError(text) {
  let m = document.getElementById("pp-form-error");
  if (!m) {
    m = document.createElement("div");
    m.id = "pp-form-error";
    m.className = "mg-msg";
    m.setAttribute("role", "alert");
    document.getElementById("pp-form").prepend(m);
  }
  m.textContent = text;
}

function ppOrder(key) { return ((PP.data && PP.data.orders) || []).find(x => x.key === key); }

async function ppClose(key, close, note) {
  const o = ppOrder(key);
  if (!o) return;
  const { error } = await sb.rpc("postponement_close", {
    p_paper: o.paper_id || null,
    p_register: o.paper_id ? null : (o.register_ids || [])[0] || null,
    p_close: close, p_note: note || null });
  PP.closing = null;
  PP.message = error
    ? { kind: "err", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message }
    : { kind: "ok", text: close ? T("ปิดรายการแล้ว", "Closed.") : T("เปิดรายการอีกครั้งแล้ว", "Reopened.") };
  await ppLoad();
}

ppSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) {
    // a click anywhere on an order's line opens its timeline
    const row = e.target.closest("tr.pp-row");
    if (row && !e.target.closest("a, button, input, select")) row.querySelector(".pp-name").click();
    return;
  }
  const act = b.dataset.act;
  if (act === "lang") { weighSetLang(b.dataset.lang); ppDraw(); }
  else if (act === "filter") { PP.filter = b.dataset.filter; ppDraw(); }
  else if (act === "toggle") {
    const key = b.dataset.key;
    PP.expanded = PP.expanded === key ? null : key;
    PP.closing = null;
    ppDrawList();
    if (PP.expanded && !PP.timelines[key]) ppLoadTimeline(key);
    const btn = ppSection.querySelector(`tr.pp-row[data-key="${CSS.escape(key)}"] .pp-name`);
    if (btn) btn.focus();
  }
  else if (act === "close-ask") {
    PP.closing = b.dataset.key;
    ppDrawList();
    const n = document.getElementById("pp-close-note");
    if (n) n.focus();
  }
  else if (act === "close-cancel") { PP.closing = null; ppDrawList(); }
  else if (act === "reopen") { await ppClose(b.dataset.key, false); }
  else if (act === "new") {
    PP.formOpen = !(PP.formOpen || PP.editing);
    PP.editing = null;
    PP.message = null;
    ppDraw();
    const f = document.getElementById("pp-form");
    if (f) { f.scrollIntoView({ block: "start" }); document.getElementById("pp-customer").focus(); }
  }
  else if (act === "cancel") { PP.editing = null; PP.formOpen = false; PP.message = null; ppDraw(); }
  else if (act === "edit") {
    PP.editing = PP.register.find(r => r.id === b.dataset.id) || null;
    PP.formOpen = false;
    PP.message = null;
    ppDraw();
    const f = document.getElementById("pp-form");
    if (f) f.scrollIntoView({ block: "start" });
  } else if (act === "delete") {
    if (!confirm(T("ลบรายการที่บันทึกนี้? การลบจะถูกบันทึกไว้ และผู้บริหารจะได้รับแจ้ง", "Delete this register record? The deletion is kept in the activity log and management is notified."))) return;
    const { data, error } = await sb.from("order_postponements").delete().eq("id", b.dataset.id).select("id");
    PP.message = error || !data || !data.length
      ? { kind: "err", text: T("ลบไม่สำเร็จ", "Could not delete") + (error ? ": " + error.message : "") }
      : { kind: "ok", text: T("ลบแล้ว", "Deleted.") };
    PP.expanded = null;
    await ppLoad();
  }
});

ppSection.addEventListener("submit", async e => {
  e.preventDefault();
  if (paceReadOnly()) return;
  if (e.target.classList.contains("pp-close-form")) {
    const btn = e.target.querySelector("button[type=submit]");
    btn.disabled = true;
    await ppClose(e.target.dataset.key, true, document.getElementById("pp-close-note").value.trim());
    return;
  }
  const val = id => document.getElementById(id).value.trim();
  const row = {
    customer_name: val("pp-customer"),
    po_number: val("pp-po") || null,
    company: val("pp-company") || null,
    product: val("pp-product") || null,
    quantity_kg: val("pp-kg") === "" ? null : Number(val("pp-kg")),
    original_date: val("pp-original"),
    new_date: val("pp-new") || null,
    reason: val("pp-reason"),
    note: val("pp-note") || null,
  };
  let problem = null;
  if (!row.customer_name) problem = T("กรุณาระบุลูกค้า", "Enter the client.");
  else if (!row.original_date) problem = T("กรุณาระบุวันส่งเดิม", "Enter the original delivery date.");
  else if (!row.reason) problem = T("กรุณาเลือกสาเหตุ", "Choose a reason.");
  else if (row.new_date && row.new_date <= row.original_date) problem = T("วันส่งใหม่ต้องหลังวันส่งเดิม", "The new date must be after the original date.");
  else if (row.reason === "other" && !row.note) problem = T("สาเหตุ “อื่น ๆ” ต้องมีหมายเหตุ", "Add a comment when the reason is Other.");
  if (problem) { ppFormError(problem); return; }
  const saveBtn = document.getElementById("pp-save");
  saveBtn.disabled = true;
  const q = PP.editing
    ? sb.from("order_postponements").update(row).eq("id", PP.editing.id)
    : sb.from("order_postponements").insert(row);
  const { error } = await q;
  if (error) {
    saveBtn.disabled = false;
    ppFormError(T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message);
    return;
  }
  PP.message = { kind: "ok", text: PP.editing ? T("แก้ไขแล้ว", "Correction saved.") : T("บันทึกแล้ว", "Recorded.") };
  PP.editing = null;
  PP.formOpen = false;
  PP.timelines = {};
  await ppLoad();
});


// Live (Migration 041): production's and the middle office's changes show at
// once — the list (unless someone is typing in its forms) and the menu count.
paceLiveOn(() => {
  if (!myProfile || !["admin", "sale_support", "company_director"].includes(myProfile.role)) return;
  const open = !ppSection.classList.contains("hidden");
  const typing = document.activeElement && ppSection.contains(document.activeElement)
    && /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName) && document.activeElement.id !== "pp-q";
  if (open && !PP.formOpen && !PP.editing && !PP.closing && !typing) ppLoad();
  else if (!open) ppRefreshBadge();
});
