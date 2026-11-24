// ============================================================================
// Purchasing › Purchases — bird orders, arrivals and the cost ratio (Migration 046)
// ============================================================================
// Clément, 24 Nov 2026: "follow the purchase ratio versus the revenue" and
// "follow the purchased products I order every Monday, Wednesday and Saturday,
// which come to the factory on Wednesday, Friday and Monday."
//
// Two tabs on one page:
//   Orders & arrivals — the week's three order cycles (Mon → Wed, Wed → Fri,
//     Sat → Mon). Each order: supplier, lines (item, size band, quantity, kg,
//     price), then what arrived (received, kg, rejected, final price, freight).
//   Cost ratio — purchase cost (goods + freight, by arrival day) against the
//     approximate revenue of the confirmed working papers (Summary's rules, by
//     production day), per arrival cycle, week or month; plus invoiced revenue
//     per month when it is loaded (sales_actuals).
//
// Only the accounts in purchase_access get data; anyone else sees a short
// note. Since Migration 047 (24 Nov 2026, Clément): the full cost ratio
// (revenue, cost, cost per kg sold, invoiced) is for the accounts with
// sees_revenue (Clément, Khun Jum) and lives in Management › KPI › Purchases;
// the purchasing manager's Cost ratio tab shows the ratio as a percentage only
// — the database sends her no revenue figure. Every write is one database call
// (purchase_save_order, purchase_record_arrival, purchase_cancel_order,
// purchase_save_item).
//
// Loaded after management.js (mgN, mgKg, mgTile, mgNiceMax),
// management-summary.js (smBaht, smBahtShort, smDayLabel, smMonthStart) and
// weights-summary.js (wsAddDays); uses app.js globals at run time (sb,
// escapeHtml, escapeAttr).
// ============================================================================

const puSection = document.getElementById("purchases-section");

const PU = {
  ctx: "purchasing",      // "purchasing": Purchasing › Purchases · "mgmt": Management › KPI › Purchases (Migration 047)
  tab: (() => { try { return localStorage.getItem("pu-tab") === "ratio" ? "ratio" : "orders"; } catch (e) { return "orders"; } })(),
  week: null,            // Monday shown on Orders & arrivals
  board: null,           // purchase_board answer
  items: {},             // id → item
  err: null,             // { kind: "access" | "missing" | "other", text }
  mode: null,            // { kind: "order" | "arrival" | "cancel", o, … }
  msg: null,             // { ok, text }
  saving: false,
  ratio: { preset: "month", from: null, to: null, company: "Prosun Farm", group: "cycle", data: null, err: null, sig: "" },
};

// Targets (process notes, 4 Sep 2026): Prosun Farm 55–60 %, Prosun Food below 50 %.
const PU_TARGETS = {
  "Prosun Farm": { good: 55, max: 60 },
  "Prosun Food": { good: 50, max: 50 },
};
const PU_SIZES = ["1.2-1.4", "1.4-1.6", "1.6-1.8"];


// ----------------------------------------------------------- dates
function puDow(iso) { return new Date(iso + "T00:00:00Z").getUTCDay(); }          // 0 Sunday … 6 Saturday
function puMonday(iso) { return wsAddDays(iso, -((puDow(iso) + 6) % 7)); }
function puToday() { return weighBangkokToday(); }
function puDay(iso, long) {
  return iso ? new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    long ? { weekday: "long", day: "numeric", month: "short", timeZone: "UTC" } : { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }) : "";
}
function puWeekday(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { weekday: "long", timeZone: "UTC" });
}

// The week's three cycles: order day → arrival day.
function puCycles(monday) {
  return [
    { key: "mon", order: monday,               arrival: wsAddDays(monday, 2) },
    { key: "wed", order: wsAddDays(monday, 2), arrival: wsAddDays(monday, 4) },
    { key: "sat", order: wsAddDays(monday, 5), arrival: wsAddDays(monday, 7) },
  ];
}
// Which cycle an order belongs to, from its order day: Mon–Tue → Monday's,
// Wed–Fri → Wednesday's, Sat–Sun → Saturday's.
function puCycleKey(orderDate) {
  const d = puDow(orderDate);
  return d === 1 || d === 2 ? "mon" : d >= 3 && d <= 5 ? "wed" : "sat";
}
// Production days fed by one arrival: Mon arrival → Mon–Tue, Wed → Wed–Thu,
// Fri → Fri–Sun. The anchor of a day is the arrival day of its cycle.
function puAnchor(iso) {
  const back = { 0: 2, 1: 0, 2: 1, 3: 0, 4: 1, 5: 0, 6: 1 }[puDow(iso)];
  return wsAddDays(iso, -back);
}
function puAnchorEnd(anchor) { return wsAddDays(anchor, puDow(anchor) === 5 ? 2 : 1); }


// ----------------------------------------------------------- figures
function puItem(id) { return PU.items[id] || { name: "?", unit: "bird" }; }
function puItemName(it) { return WEIGH_LANG === "en" ? it.name : (it.name_th || it.name); }
function puUnit(u, n) {
  if (u === "kg") return T("กก.", "kg");
  if (u === "pcs") return T("ชิ้น", "pcs");
  return T("ตัว", Number(n) === 1 ? "bird" : "birds");
}
function puNum(v, dp) {
  if (v === null || v === undefined || v === "") return "";
  const n = Number(v);
  return mgN(n, dp !== undefined ? dp : (n % 1 ? 2 : 0));
}
function puBaht(v) { return v === null || v === undefined ? "—" : smBaht(v); }

// One order's totals.
function puOrderSum(o) {
  const s = { goods: 0, noPrice: 0, birdsOrd: 0, birdsRec: 0, short: 0, kg: 0, kgCost: 0, rejected: 0 };
  const rec = o.status === "received";
  for (const l of o.lines || []) {
    const it = puItem(l.item_id);
    if (l.cost === null || l.cost === undefined) s.noPrice++;
    else s.goods += Number(l.cost);
    if (it.unit === "bird") {
      s.birdsOrd += Number(l.ordered_qty || 0);
      if (rec) {
        s.birdsRec += Number(l.received_qty || 0);
        s.short += Math.max(0, Number(l.ordered_qty || 0) - Number(l.received_qty || 0));
      }
    }
    if (rec) {
      s.rejected += Number(l.rejected_qty || 0);
      const kg = l.received_kg !== null && l.received_kg !== undefined ? Number(l.received_kg) : (it.unit === "kg" ? Number(l.received_qty || 0) : 0);
      if (kg > 0 && l.cost !== null) { s.kg += kg; s.kgCost += Number(l.cost); }
    }
  }
  s.freight = Number(o.freight_thb || 0);
  s.total = s.goods + s.freight;
  return s;
}

// ordered | today | late | received | short | cancelled
function puState(o) {
  if (o.status === "cancelled") return "cancelled";
  if (o.status === "received") return puOrderSum(o).short > 0 ? "short" : "received";
  const t = puToday();
  if (o.arrival_date < t) return "late";
  if (o.arrival_date === t) return "today";
  return "ordered";
}
function puStateChip(o) {
  const st = puState(o);
  const s = puOrderSum(o);
  const text = {
    ordered:   T("สั่งแล้ว · รอรับ", "Ordered · to arrive"),
    today:     T("มาถึงวันนี้ · รอบันทึก", "Arriving today · to record"),
    late:      T(`ยังไม่บันทึกการรับ (กำหนด ${puDay(o.arrival_date)})`, `Arrival not recorded (due ${puDay(o.arrival_date)})`),
    received:  T("รับครบแล้ว", "Arrived in full"),
    short:     T(`รับขาด ${mgN(s.short)} ตัว`, `Arrived short: ${mgN(s.short)} birds`),
    cancelled: T("ยกเลิก", "Cancelled"),
  }[st];
  return `<span class="pu-chip pu-chip-${st}">${escapeHtml(text)}</span>`;
}

function puCan() { return !PU.err || PU.err.kind === "other"; }


// ----------------------------------------------------------- open / close / load
async function puOpen(ctx) {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  const next = ctx === "mgmt" ? "mgmt" : "purchasing";
  if (next !== PU.ctx) { PU.mode = null; PU.msg = null; PU.err = null; }
  PU.ctx = next;
  PU.ratio.sig = "";                 // the section was emptied on close: always draw again
  puSection.classList.remove("hidden");
  if (!PU.week) PU.week = puMonday(puToday());
  if (!PU.board && !PU.ratio.data) puSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  await puLoad();
}

function puClose() {
  if (!puSection || puSection.classList.contains("hidden")) return;
  puSection.classList.add("hidden");
  puSection.innerHTML = "";
  PU.mode = null;
  PU.msg = null;
}
function puIsOpen() { return puSection && !puSection.classList.contains("hidden"); }

function puError(error) {
  const m = (error && error.message) || "";
  if (error && (error.code === "42501" || /not allowed for this account/.test(m))) {
    return { kind: "access", text: T("บัญชีนี้ยังไม่มีสิทธิ์ดูการสั่งซื้อและต้นทุน — ต้นทุนการซื้อเปิดให้เฉพาะบัญชีที่คุณเคลมองต์กำหนด ขอสิทธิ์ได้จากคุณเคลมองต์",
                                     "This account cannot see purchases and costs: purchase costs are open only to the accounts Clément has named. Ask Clément for access.") };
  }
  if (/purchase_board|purchase_ratio|schema cache|does not exist|Could not find/i.test(m)) {
    return { kind: "missing", text: T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 046 และ 047 ใน Supabase", "The database is not up to date: run Migrations 046 and 047 in Supabase.") };
  }
  return { kind: "other", text: puServerText(m) };
}
// The functions answer "purchases: …" in English; keep the sentence, drop the prefix.
function puServerText(m) { return String(m || "").replace(/^purchases:\s*/, ""); }

function puTabNow() { return PU.ctx === "mgmt" ? "ratio" : PU.tab; }

async function puLoad() {
  if (!puIsOpen()) return;
  if (puTabNow() === "ratio") return puLoadRatio();
  puReadForms();                     // a half-filled form survives Refresh
  const from = wsAddDays(PU.week, -7), to = wsAddDays(PU.week, 13);
  const week = PU.week;
  const { data, error } = await sb.rpc("purchase_board", { p_from: from, p_to: to });
  if (!puIsOpen() || puTabNow() !== "orders" || week !== PU.week) return;
  if (error) { PU.err = puError(error); PU.board = null; puDraw(); return; }
  PU.err = null;
  PU.board = data;
  PU.items = {};
  (data.items || []).forEach(i => { PU.items[i.id] = i; });
  puDraw();
}


// ----------------------------------------------------------- draw
function puDraw() {
  if (!puIsOpen()) return;
  const tabs = `<div class="kpi-tabs pu-tabs" role="tablist" aria-label="${escapeAttr(T("การสั่งซื้อ", "Purchases"))}">
    <button type="button" class="kpi-tab${PU.tab === "orders" ? " active" : ""}" role="tab" data-act="tab" data-tab="orders" aria-selected="${PU.tab === "orders"}">${T("สั่งซื้อและรับสินค้า", "Orders & arrivals")}<small>Mon → Wed · Wed → Fri · Sat → Mon</small></button>
    <button type="button" class="kpi-tab${PU.tab === "ratio" ? " active" : ""}" role="tab" data-act="tab" data-tab="ratio" aria-selected="${PU.tab === "ratio"}">${T("สัดส่วนต้นทุนต่อรายได้", "Cost ratio")}<small>${T("ต้นทุนซื้อ ÷ รายได้", "Purchases ÷ revenue")}</small></button>
  </div>`;
  const msg = PU.msg ? `<div class="${PU.msg.ok ? "pp-ok" : "mg-msg"}" id="pu-msg" role="status">${escapeHtml(PU.msg.text)}</div>` : "";
  if (PU.ctx === "mgmt") {
    // Management › KPI › Purchases: the KPI tabs are in the toolbar; no inner tabs.
    if (PU.err && PU.err.kind !== "other") { puSection.innerHTML = `<div class="mg-card pu-locked" id="pu-locked"><p>${escapeHtml(PU.err.text)}</p></div>`; return; }
    puSection.innerHTML = `<div id="pu-body" class="pu-body-mgmt">${puRatioHtml()}</div>`;
    return;
  }
  if (PU.err && PU.err.kind !== "other") {
    puSection.innerHTML = tabs + `<div class="mg-card pu-locked" id="pu-locked"><p>${escapeHtml(PU.err.text)}</p></div>`;
    return;
  }
  puSection.innerHTML = tabs + msg + `<div id="pu-body"></div>`;
  const body = document.getElementById("pu-body");
  body.innerHTML = puTabNow() === "ratio" ? puRatioHtml() : puOrdersHtml();
  if (PU.mode && PU.mode.kind === "order") puFormRefresh();
}


// ----------------------------------------------------------- Orders & arrivals
function puOrdersHtml() {
  if (PU.err) return `<div class="mg-msg" id="pu-error">${escapeHtml(PU.err.text)}</div>`;
  if (!PU.board) return `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  if (PU.mode && PU.mode.kind === "order") return puOrderFormHtml(PU.mode);
  if (PU.mode && PU.mode.kind === "arrival") return puArrivalFormHtml(PU.mode);

  const cycles = puCycles(PU.week);
  const weekEnd = wsAddDays(PU.week, 6);
  const orders = (PU.board.orders || []);
  const inWeek = orders.filter(o => o.order_date >= PU.week && o.order_date <= weekEnd);
  const prevWeek = orders.filter(o => o.order_date >= wsAddDays(PU.week, -7) && o.order_date < PU.week && o.status !== "cancelled");
  const thisWeek = PU.week === puMonday(puToday());

  const bar = `<div class="mg-bar pu-bar">
    <div class="pu-weeknav">
      <button type="button" class="ws-chip" data-act="week" data-step="-7" aria-label="${escapeAttr(T("สัปดาห์ก่อน", "Previous week"))}">‹</button>
      <strong id="pu-week-label">${escapeHtml(T("สัปดาห์", "Week of"))} ${escapeHtml(puDay(PU.week))} – ${escapeHtml(puDay(weekEnd))}</strong>
      <button type="button" class="ws-chip" data-act="week" data-step="7" aria-label="${escapeAttr(T("สัปดาห์ถัดไป", "Next week"))}">›</button>
      ${thisWeek ? "" : `<button type="button" class="ws-chip" data-act="thisweek">${T("สัปดาห์นี้", "This week")}</button>`}
    </div>
    <div class="mg-bar-right">
      <button type="button" class="ws-chip" data-act="csv-week" id="pu-csv-week">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
      ${weighLangHtml()}
    </div>
  </div>`;

  const cards = cycles.map(c => {
    const list = inWeek.filter(o => puCycleKey(o.order_date) === c.key);
    const prev = prevWeek.filter(o => puCycleKey(o.order_date) === c.key);
    const head = `<div class="pu-cycle-head">
      <h3>${escapeHtml(T(`สั่ง${puWeekday(c.order)}`, `${puWeekday(c.order)} order`))}
        <span class="pu-cycle-dates">${escapeHtml(puDay(c.order))} → ${escapeHtml(T("ถึงโรงงาน", "at the factory"))} ${escapeHtml(puDay(c.arrival))}</span></h3>
      <button type="button" class="ws-chip pu-new" data-act="new" data-order="${c.order}" data-arrival="${c.arrival}">+ ${T("สั่งซื้อใหม่", "New order")}</button>
    </div>`;
    const empty = !list.length ? `<div class="pu-empty">
        <p class="mg-muted mg-small">${T("ยังไม่มีการสั่งซื้อในรอบนี้", "No order recorded for this cycle yet.")}</p>
        ${prev.map(o => `<button type="button" class="ws-chip" data-act="repeat" data-from="${o.id}" data-order="${c.order}" data-arrival="${c.arrival}">${escapeHtml(T(`สั่งเหมือนสัปดาห์ก่อน: ${o.supplier}`, `Repeat last week's order: ${o.supplier}`))}</button>`).join("")}
      </div>` : "";
    return `<section class="mg-card pu-cycle" data-cycle="${c.key}">${head}${empty}${list.map(puOrderHtml).join("")}</section>`;
  }).join("");

  return bar + puWeekTilesHtml(inWeek) + `<div class="pu-cycles">${cards}</div>` + puOrdersNoteHtml();
}

function puWeekTilesHtml(list) {
  const live = list.filter(o => o.status !== "cancelled");
  const t = { birdsOrd: 0, birdsOrdRec: 0, birdsRec: 0, short: 0, total: 0, est: 0, kg: 0, kgCost: 0, toRecord: 0, noPrice: 0 };
  const today = puToday();
  for (const o of live) {
    const s = puOrderSum(o);
    t.birdsOrd += s.birdsOrd;
    if (o.status === "received") { t.birdsOrdRec += s.birdsOrd; t.birdsRec += s.birdsRec; t.short += s.short; }
    else if (o.arrival_date <= today) t.toRecord++;
    t.total += s.total;
    if (o.status !== "received") t.est += s.total;
    t.kg += s.kg; t.kgCost += s.kgCost; t.noPrice += s.noPrice;
  }
  const fill = t.birdsOrdRec > 0 ? Math.round((t.birdsRec / t.birdsOrdRec) * 1000) / 10 : null;
  return `<div class="mg-tiles pu-tiles" id="pu-week-tiles">
    ${mgTile({ id: "pu-t-ordered", label: T("สัตว์ปีกที่สั่ง (สัปดาห์นี้)", "Birds ordered this week"), value: mgN(t.birdsOrd), unit: T("ตัว", "birds"),
      sub: T(`${mgN(live.length)} ใบสั่งซื้อ`, `${mgN(live.length)} order${live.length === 1 ? "" : "s"}`) })}
    ${mgTile({ id: "pu-t-fill", label: T("ได้รับจริงเทียบกับที่สั่ง", "Received vs ordered"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: fill === null ? T("ยังไม่มีการรับสินค้าที่บันทึก", "No arrival recorded yet")
        : T(`รับ ${mgN(t.birdsRec)} จาก ${mgN(t.birdsOrdRec)} ตัว · ขาด ${mgN(t.short)} ตัว`, `${mgN(t.birdsRec)} of ${mgN(t.birdsOrdRec)} birds · ${mgN(t.short)} short`) })}
    ${mgTile({ id: "pu-t-cost", label: T("ต้นทุนการซื้อ (รวมค่าขนส่ง)", "Purchase cost (with freight)"), value: smBaht(t.total), unit: "THB",
      sub: (t.est > 0 ? T(`ประมาณการ ${smBaht(t.est)} บาท (ยังไม่รับ)`, `${smBaht(t.est)} THB still estimated (not arrived)`) : T("ทั้งหมดตามที่รับจริง", "All from recorded arrivals"))
        + (t.noPrice ? T(` · ${t.noPrice} รายการไม่มีราคา`, ` · ${t.noPrice} line${t.noPrice === 1 ? "" : "s"} without a price`) : "") })}
    ${mgTile({ id: "pu-t-kg", label: T("ราคาเฉลี่ยต่อกก. (น้ำหนักที่รับ)", "Average cost per kg received"), value: t.kg > 0 ? mgN(t.kgCost / t.kg, 2) : "—", unit: t.kg > 0 ? T("บาท/กก.", "THB/kg") : "",
      sub: t.kg > 0 ? T(`${mgKg(t.kg)} กก. ที่รับและมีราคา`, `${mgKg(t.kg)} kg received with a price`) : "" })}
    ${mgTile({ id: "pu-t-record", label: T("รอบันทึกการรับ", "Arrivals to record"), value: mgN(t.toRecord),
      state: t.toRecord > 0 ? "alert" : "good",
      sub: T("ถึงกำหนดแล้วแต่ยังไม่บันทึก", "Due today or earlier, not recorded yet") })}
  </div>`;
}

function puOrderHtml(o) {
  const s = puOrderSum(o);
  const rec = o.status === "received";
  const cancelled = o.status === "cancelled";
  const lines = (o.lines || []).map(l => {
    const it = puItem(l.item_id);
    const diff = rec && it.unit !== "kg" ? Number(l.received_qty || 0) - Number(l.ordered_qty || 0) : null;
    return `<tr>
      <td>${escapeHtml(puItemName(it))}${l.size_band ? ` <span class="pu-size">${escapeHtml(l.size_band)}</span>` : ""}${l.note ? `<div class="mg-small mg-muted">${escapeHtml(l.note)}</div>` : ""}</td>
      <td class="mg-n">${puNum(l.ordered_qty)} <span class="mg-muted">${escapeHtml(puUnit(it.unit, l.ordered_qty))}</span>${l.ordered_kg && it.unit !== "kg" ? `<div class="mg-small mg-muted">≈ ${puNum(l.ordered_kg)} kg</div>` : ""}</td>
      <td class="mg-n">${rec ? `${puNum(l.received_qty)}${l.rejected_qty ? `<div class="mg-small pu-bad">${T("ไม่รับ", "rejected")} ${puNum(l.rejected_qty)}</div>` : ""}` : `<span class="mg-muted">—</span>`}</td>
      <td class="mg-n ${diff !== null && diff < 0 ? "pu-bad" : ""}">${diff === null ? "" : diff === 0 ? "0" : (diff > 0 ? "+" : "−") + mgN(Math.abs(diff))}</td>
      <td class="mg-n">${rec ? (l.received_kg !== null && l.received_kg !== undefined ? puNum(l.received_kg, 1) : "—") : (l.ordered_kg ? `<span class="mg-muted">≈ ${puNum(l.ordered_kg, 0)}</span>` : "—")}</td>
      <td class="mg-n">${l.price === null || l.price === undefined ? `<span class="pu-bad">${T("ไม่มีราคา", "no price")}</span>` : `${puNum(l.price)}<span class="mg-muted">/${l.price_per === "unit" ? escapeHtml(puUnit(it.unit, 1)) : "kg"}</span>`}</td>
      <td class="mg-n mg-strong">${l.cost === null || l.cost === undefined ? "—" : (rec ? "" : "≈ ") + smBaht(l.cost)}</td>
    </tr>`;
  }).join("");
  const acts = cancelled ? "" : `<div class="pu-acts">
      ${PU.mode && PU.mode.kind === "cancel" && PU.mode.o.id === o.id ? `
        <input type="text" id="pu-cancel-reason" class="pu-cancel-reason" placeholder="${escapeAttr(T("เหตุผลที่ยกเลิก", "Why is it cancelled?"))}" aria-label="${escapeAttr(T("เหตุผลที่ยกเลิก", "Why is it cancelled?"))}">
        <button type="button" class="ws-chip pu-danger" data-act="cancel-yes" data-id="${o.id}"${PU.saving ? " disabled" : ""}>${T("ยืนยันยกเลิก", "Cancel this order")}</button>
        <button type="button" class="ws-chip" data-act="cancel-no">${T("ไม่ยกเลิก", "Keep it")}</button>`
      : `<button type="button" class="ws-chip pu-primary" data-act="arrival" data-id="${o.id}">${rec ? T("แก้ไขการรับสินค้า", "Edit arrival") : T("บันทึกการรับสินค้า", "Record arrival")}</button>
        <button type="button" class="ws-chip" data-act="edit" data-id="${o.id}">${T("แก้ไขใบสั่งซื้อ", "Edit order")}</button>
        ${rec ? "" : `<button type="button" class="ws-chip" data-act="cancel" data-id="${o.id}">${T("ยกเลิก", "Cancel")}</button>`}`}
    </div>`;
  return `<article class="pu-order${cancelled ? " pu-cancelled" : ""}" data-id="${o.id}" data-state="${puState(o)}">
    <div class="pu-order-head">
      <div><strong class="pu-supplier">${escapeHtml(o.supplier)}</strong>
        <span class="mg-muted mg-small">${escapeHtml(typeof weighCompanyShort === "function" ? weighCompanyShort(o.company) : o.company)}${o.ref ? " · " + escapeHtml(o.ref) : ""}
        · ${escapeHtml(T("สั่ง", "ordered"))} ${escapeHtml(puDay(o.order_date))} · ${escapeHtml(rec ? T("รับ", "arrived") : T("ถึง", "due"))} ${escapeHtml(puDay(rec ? o.arrived_on : o.arrival_date))}</span></div>
      ${puStateChip(o)}
    </div>
    ${cancelled ? `<p class="mg-small mg-muted">${escapeHtml(T("เหตุผล: ", "Reason: "))}${escapeHtml(o.cancel_reason || "")}</p>` : `
    <div class="mg-table-wrap"><table class="mg-table pu-lines-table">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th class="mg-n">${T("สั่ง", "Ordered")}</th><th class="mg-n">${T("รับจริง", "Received")}</th>
        <th class="mg-n">${T("ส่วนต่าง", "Diff.")}</th><th class="mg-n">kg</th><th class="mg-n">${T("ราคา", "Price")}</th><th class="mg-n">${T("ต้นทุน (บาท)", "Cost (THB)")}</th></tr></thead>
      <tbody>${lines}
        ${s.freight ? `<tr><td colspan="6">${T("ค่าขนส่ง", "Freight")}</td><td class="mg-n">${smBaht(s.freight)}</td></tr>` : ""}
        <tr class="mg-total"><td colspan="6">${T("รวม", "Total")}${rec ? "" : ` <span class="mg-muted mg-small">${T("(ประมาณการจากที่สั่ง)", "(estimate from the order)")}</span>`}${s.kg > 0 ? ` <span class="mg-muted mg-small">· ${mgN(s.kgCost / s.kg, 2)} ${T("บาท/กก.", "THB/kg")}</span>` : ""}</td><td class="mg-n">${smBaht(s.total)}</td></tr>
      </tbody></table></div>`}
    ${o.note ? `<p class="mg-small"><strong>${T("หมายเหตุ", "Note")}:</strong> ${escapeHtml(o.note)}</p>` : ""}
    ${rec && o.arrival_note ? `<p class="mg-small"><strong>${T("หมายเหตุการรับ", "Arrival note")}:</strong> ${escapeHtml(o.arrival_note)}</p>` : ""}
    <p class="mg-small mg-muted pu-who">${escapeHtml(T("บันทึกโดย", "Entered by"))} ${escapeHtml(o.created_by || "—")}${rec ? ` · ${escapeHtml(T("รับโดย", "arrival by"))} ${escapeHtml(o.received_by || "—")}` : ""}</p>
    ${acts}
  </article>`;
}

function puOrdersNoteHtml() {
  return `<div class="mg-card mg-small mg-muted" id="pu-orders-note">${T(
    "รอบสั่งซื้อ: สั่งวันจันทร์ ถึงโรงงานวันพุธ · สั่งวันพุธ ถึงวันศุกร์ · สั่งวันเสาร์ ถึงวันจันทร์ ต้นทุน = กก. × ราคาต่อกก. หรือ จำนวน × ราคาต่อตัว ก่อนรับสินค้าเป็นประมาณการจากที่สั่ง หลังรับใช้จำนวน/น้ำหนักที่รับจริง ตัวที่ไม่รับ (ตาย/ไม่ผ่าน) ไม่คิดเงิน หน้านี้เปิดเฉพาะบัญชีที่คุณเคลมองต์กำหนด",
    "Cycles: ordered Monday, at the factory Wednesday · ordered Wednesday, Friday · ordered Saturday, Monday. Cost = kg × price per kg, or quantity × price per bird. Before the arrival it is an estimate from the order; after, the received quantity and kg are used. Rejected birds (dead or refused) are not paid. Only the accounts Clément has named see this page.")}</div>`;
}


// ----------------------------------------------------------- order form
function puNewOrder(orderDate, arrival, copyFrom) {
  const lines = copyFrom
    ? copyFrom.lines.map(l => ({ item_id: l.item_id, size_band: l.size_band, ordered_qty: l.ordered_qty, ordered_kg: l.ordered_kg, price: l.price, price_per: l.price_per, note: l.note }))
    : [{ item_id: (PU.board.items.find(i => i.active) || {}).id, price_per: "kg" }];
  return { kind: "order", o: {
    id: null, order_date: orderDate, arrival_date: arrival, arrivalTouched: false,
    company: copyFrom ? copyFrom.company : "Prosun Farm", supplier: copyFrom ? copyFrom.supplier : "",
    ref: "", note: "", lines, updated_at: null } };
}

function puOrderFormHtml(m) {
  const o = m.o;
  const items = (PU.board.items || []).filter(i => i.active || o.lines.some(l => l.item_id === i.id));
  const itemOpts = sel => items.map(i => `<option value="${i.id}"${i.id === sel ? " selected" : ""}>${escapeHtml(puItemName(i))} (${escapeHtml(puUnit(i.unit, 2))})</option>`).join("");
  const rows = o.lines.map((l, i) => `<tr data-i="${i}" data-id="${l.id || ""}">
      <td><select class="pu-l-item" aria-label="${escapeAttr(T("สินค้า", "Item"))}">${itemOpts(l.item_id)}</select></td>
      <td><input class="pu-l-size" list="pu-sizes" value="${escapeAttr(l.size_band || "")}" placeholder="1.4-1.6" aria-label="${escapeAttr(T("ขนาด", "Size band"))}"></td>
      <td><input class="pu-l-qty pu-num" type="number" min="0" step="any" value="${escapeAttr(l.ordered_qty ?? "")}" aria-label="${escapeAttr(T("จำนวนที่สั่ง", "Quantity ordered"))}"> <span class="pu-l-unit mg-muted"></span></td>
      <td><input class="pu-l-kg pu-num" type="number" min="0" step="any" value="${escapeAttr(l.ordered_kg ?? "")}" placeholder="≈" aria-label="${escapeAttr(T("น้ำหนักโดยประมาณ (กก.)", "Estimated kg"))}"></td>
      <td><input class="pu-l-price pu-num" type="number" min="0" step="any" value="${escapeAttr(l.price ?? "")}" aria-label="${escapeAttr(T("ราคา", "Price"))}"></td>
      <td><select class="pu-l-per" aria-label="${escapeAttr(T("ราคาต่อ", "Price per"))}">
        <option value="kg"${l.price_per !== "unit" ? " selected" : ""}>${T("ต่อ กก.", "per kg")}</option>
        <option value="unit"${l.price_per === "unit" ? " selected" : ""}>${T("ต่อตัว/ชิ้น", "per bird / piece")}</option></select></td>
      <td class="mg-n pu-l-cost"></td>
      <td><button type="button" class="pu-x" data-act="line-del" data-i="${i}" aria-label="${escapeAttr(T("ลบรายการ", "Remove line"))}"${o.lines.length === 1 ? " disabled" : ""}>×</button></td>
    </tr>`).join("");
  const sup = (PU.board.suppliers || []).map(s => `<option value="${escapeAttr(s)}"></option>`).join("");
  return `<form class="mg-card pu-form" id="pu-form" novalidate>
    <h3>${o.id ? T("แก้ไขใบสั่งซื้อ", "Edit order") : T("สั่งซื้อใหม่", "New order")}</h3>
    <div class="pu-grid">
      <label>${T("วันที่สั่ง", "Order date")}<input type="date" id="pu-f-order" value="${escapeAttr(o.order_date)}" required></label>
      <label>${T("วันที่ถึงโรงงาน (กำหนด)", "Arrival at the factory (planned)")}<input type="date" id="pu-f-arrival" value="${escapeAttr(o.arrival_date)}" required></label>
      <label>${T("บริษัท", "Company")}<select id="pu-f-company">
        <option${o.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
        <option${o.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option></select></label>
      <label>${T("ผู้ขาย / ฟาร์ม", "Supplier / farm")}<input id="pu-f-supplier" list="pu-suppliers" value="${escapeAttr(o.supplier)}" autocomplete="off" required></label>
      <label>${T("เลขที่อ้างอิง", "Reference")}<input id="pu-f-ref" value="${escapeAttr(o.ref || "")}" placeholder="${escapeAttr(T("เลขใบสั่งซื้อ / ใบส่งของ", "PO / delivery note no."))}"></label>
    </div>
    <datalist id="pu-suppliers">${sup}</datalist>
    <datalist id="pu-sizes">${PU_SIZES.map(s => `<option value="${s}"></option>`).join("")}</datalist>
    <div class="mg-table-wrap"><table class="mg-table pu-form-lines">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th>${T("ขนาด (กก./ตัว)", "Size (kg/bird)")}</th><th>${T("จำนวนที่สั่ง", "Quantity")}</th>
        <th>${T("น้ำหนักโดยประมาณ (กก.)", "Est. kg")}</th><th>${T("ราคา (บาท)", "Price (THB)")}</th><th>${T("ต่อ", "Per")}</th>
        <th class="mg-n">${T("ต้นทุนโดยประมาณ", "Est. cost")}</th><th></th></tr></thead>
      <tbody id="pu-f-lines">${rows}</tbody>
      <tfoot><tr><td colspan="6"><button type="button" class="ws-chip" data-act="line-add">+ ${T("เพิ่มรายการ", "Add a line")}</button></td>
        <td class="mg-n mg-strong" id="pu-f-total"></td><td></td></tr></tfoot>
    </table></div>
    <p class="mg-small mg-muted">${T("ราคาต่อ กก. ต้องใส่น้ำหนักโดยประมาณเพื่อคำนวณต้นทุนก่อนรับสินค้า", "With a price per kg, write the estimated kg so the cost can be estimated before the arrival.")}</p>
    <details class="pu-newitem"${m.itemOpen ? " open" : ""}><summary>${T("ไม่มีสินค้าในรายการ? เพิ่มสินค้าใหม่", "Item not in the list? Add one")}</summary>
      <div class="pu-grid">
        <label>${T("ชื่อ (อังกฤษ)", "Name (English)")}<input id="pu-i-name"></label>
        <label>${T("ชื่อ (ไทย)", "Name (Thai)")}<input id="pu-i-th"></label>
        <label>${T("นับเป็น", "Counted in")}<select id="pu-i-unit"><option value="bird">${T("ตัว", "birds")}</option><option value="pcs">${T("ชิ้น", "pieces")}</option><option value="kg">kg</option></select></label>
        <div class="pu-grid-btn"><button type="button" class="ws-chip" data-act="item-add"${PU.saving ? " disabled" : ""}>${T("เพิ่มสินค้า", "Add item")}</button></div>
      </div>
    </details>
    <label class="pu-wide">${T("หมายเหตุ", "Note")}<textarea id="pu-f-note" rows="2">${escapeHtml(o.note || "")}</textarea></label>
    ${o.status === "received" ? `<p class="mg-small pu-warn">${T("ใบสั่งซื้อนี้รับสินค้าแล้ว: รายการที่เพิ่มใหม่ต้องบันทึกการรับอีกครั้ง", "This order has arrived: a line you add will need its arrival recorded again.")}</p>` : ""}
    <div class="pu-form-acts">
      <button type="submit" class="btn-primary" id="pu-f-save"${PU.saving ? " disabled" : ""}>${PU.saving ? T("กำลังบันทึก…", "Saving…") : T("บันทึก", "Save")}</button>
      <button type="button" class="btn-secondary" data-act="close-form">${T("ยกเลิก", "Cancel")}</button>
    </div>
  </form>`;
}

// Read the form back into PU.mode.o (so a redraw keeps what was typed).
function puReadForm() {
  const f = document.getElementById("pu-form");
  if (!f || !PU.mode || PU.mode.kind !== "order") return;
  const o = PU.mode.o;
  o.order_date = f.querySelector("#pu-f-order").value;
  o.arrival_date = f.querySelector("#pu-f-arrival").value;
  o.company = f.querySelector("#pu-f-company").value;
  o.supplier = f.querySelector("#pu-f-supplier").value;
  o.ref = f.querySelector("#pu-f-ref").value;
  o.note = f.querySelector("#pu-f-note").value;
  o.lines = [...f.querySelectorAll("#pu-f-lines tr")].map((tr, i) => {
    const prev = o.lines[Number(tr.dataset.i)] || {};
    const num = sel => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
    return Object.assign({}, prev, {
      id: tr.dataset.id || null,
      item_id: tr.querySelector(".pu-l-item").value,
      size_band: tr.querySelector(".pu-l-size").value.trim(),
      ordered_qty: num(".pu-l-qty"), ordered_kg: num(".pu-l-kg"), price: num(".pu-l-price"),
      price_per: tr.querySelector(".pu-l-per").value,
    });
  });
  PU.mode.itemOpen = !!f.querySelector(".pu-newitem[open]");
}

// The arrival form's figures back into PU.mode.o.
function puReadArrival() {
  const f = document.getElementById("pu-arrival");
  if (!f || !PU.mode || PU.mode.kind !== "arrival") return;
  const o = PU.mode.o;
  const val = (tr, sel) => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
  f.querySelectorAll("tbody tr").forEach(tr => {
    const l = o.lines.find(y => y.id === tr.dataset.id);
    if (l) Object.assign(l, { received_qty: val(tr, ".pu-a-qty"), received_kg: val(tr, ".pu-a-kg"), rejected_qty: val(tr, ".pu-a-rej"), price: val(tr, ".pu-a-price") });
  });
  o.arrived_on = f.querySelector("#pu-a-day").value;
  o.freight_thb = f.querySelector("#pu-a-freight").value === "" ? null : Number(f.querySelector("#pu-a-freight").value);
  o.arrival_note = f.querySelector("#pu-a-note").value;
}
function puReadForms() { puReadForm(); puReadArrival(); }

// Live parts of the form: unit labels, kg box for kg items, costs.
function puFormRefresh() {
  const f = document.getElementById("pu-form");
  if (!f) return;
  let total = 0, missing = 0;
  f.querySelectorAll("#pu-f-lines tr").forEach(tr => {
    const it = puItem(tr.querySelector(".pu-l-item").value);
    const qty = Number(tr.querySelector(".pu-l-qty").value || 0);
    const kgIn = tr.querySelector(".pu-l-kg");
    kgIn.disabled = it.unit === "kg";
    if (it.unit === "kg") kgIn.value = "";
    tr.querySelector(".pu-l-unit").textContent = puUnit(it.unit, qty);
    const price = tr.querySelector(".pu-l-price").value;
    const per = tr.querySelector(".pu-l-per").value;
    const kg = it.unit === "kg" ? qty : Number(kgIn.value || 0);
    let cost = null;
    if (price !== "") cost = per === "unit" ? qty * Number(price) : (kg > 0 ? kg * Number(price) : null);
    tr.querySelector(".pu-l-cost").textContent = cost === null ? "—" : smBaht(cost);
    if (cost === null) missing++; else total += cost;
  });
  const t = document.getElementById("pu-f-total");
  if (t) t.innerHTML = `≈ ${smBaht(total)} THB${missing ? `<div class="mg-small pu-bad">${missing} ${T("รายการยังคำนวณไม่ได้", missing === 1 ? "line not costed" : "lines not costed")}</div>` : ""}`;
}

async function puSaveOrder() {
  puReadForm();
  const o = PU.mode.o;
  const lines = o.lines.filter(l => l.ordered_qty || l.price !== null || l.size_band);
  const p = {
    id: o.id, order_date: o.order_date, arrival_date: o.arrival_date, company: o.company,
    supplier: o.supplier, ref: o.ref, note: o.note, updated_at: o.updated_at,
    lines: lines.map(l => ({ id: l.id, item_id: l.item_id, size_band: l.size_band, ordered_qty: l.ordered_qty,
                             ordered_kg: puItem(l.item_id).unit === "kg" ? null : l.ordered_kg,
                             price: l.price, price_per: l.price_per, note: l.note || null })),
  };
  PU.saving = true; PU.msg = null; puDraw();
  const { error } = await sb.rpc("purchase_save_order", { p });
  PU.saving = false;
  if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
  PU.mode = null;
  PU.msg = { ok: true, text: T("บันทึกใบสั่งซื้อแล้ว", "Order saved.") };
  PU.week = puMonday(o.order_date);
  await puLoad();
}


// ----------------------------------------------------------- arrival form
function puArrivalFormHtml(m) {
  const o = m.o;
  const rows = o.lines.map((l, i) => {
    const it = puItem(l.item_id);
    return `<tr data-id="${l.id}">
      <td>${escapeHtml(puItemName(it))}${l.size_band ? ` <span class="pu-size">${escapeHtml(l.size_band)}</span>` : ""}</td>
      <td class="mg-n">${puNum(l.ordered_qty)} <span class="mg-muted">${escapeHtml(puUnit(it.unit, l.ordered_qty))}</span></td>
      <td><input class="pu-a-qty pu-num" type="number" min="0" step="any" value="${escapeAttr(l.received_qty ?? "")}" aria-label="${escapeAttr(T("จำนวนที่รับ", "Received"))}"></td>
      <td><input class="pu-a-kg pu-num" type="number" min="0" step="any" value="${escapeAttr(l.received_kg ?? "")}"${it.unit === "kg" ? " disabled" : ""} aria-label="${escapeAttr(T("น้ำหนักที่รับ (กก.)", "Received kg"))}"></td>
      <td><input class="pu-a-rej pu-num" type="number" min="0" step="any" value="${escapeAttr(l.rejected_qty ?? "")}" aria-label="${escapeAttr(T("ไม่รับ (ตาย/ไม่ผ่าน)", "Rejected (dead / refused)"))}"></td>
      <td><input class="pu-a-price pu-num" type="number" min="0" step="any" value="${escapeAttr(l.price ?? "")}" aria-label="${escapeAttr(T("ราคา", "Price"))}">
        <span class="mg-muted mg-small">/${l.price_per === "unit" ? escapeHtml(puUnit(it.unit, 1)) : "kg"}</span></td>
    </tr>`;
  }).join("");
  const def = o.arrived_on || (o.arrival_date <= puToday() ? o.arrival_date : puToday());
  return `<form class="mg-card pu-form" id="pu-arrival" novalidate>
    <h3>${T("บันทึกการรับสินค้า", "Record the arrival")} — ${escapeHtml(o.supplier)}</h3>
    <p class="mg-small mg-muted">${escapeHtml(T("สั่ง", "Ordered"))} ${escapeHtml(puDay(o.order_date))} · ${escapeHtml(T("กำหนดถึง", "due"))} ${escapeHtml(puDay(o.arrival_date))} · ${escapeHtml(o.company)}${o.ref ? " · " + escapeHtml(o.ref) : ""}</p>
    <div class="pu-grid">
      <label>${T("วันที่มาถึงจริง", "Day it arrived")}<input type="date" id="pu-a-day" value="${escapeAttr(def)}" required></label>
      <label>${T("ค่าขนส่ง (บาท)", "Freight (THB)")}<input type="number" min="0" step="any" id="pu-a-freight" class="pu-num" value="${escapeAttr(o.freight_thb ?? "")}"></label>
      <div class="pu-grid-btn"><button type="button" class="ws-chip" data-act="same-as-ordered">${T("รับครบตามที่สั่ง", "Same quantities as ordered")}</button></div>
    </div>
    <div class="mg-table-wrap"><table class="mg-table pu-form-lines">
      <thead><tr><th>${T("สินค้า", "Item")}</th><th class="mg-n">${T("สั่ง", "Ordered")}</th><th>${T("รับจริง", "Received")}</th>
        <th>${T("น้ำหนักที่รับ (กก.)", "Received kg")}</th><th>${T("ไม่รับ", "Rejected")}</th><th>${T("ราคาสุดท้าย", "Final price")}</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
    <p class="mg-small mg-muted">${T("ใส่ 0 ถ้าไม่ได้รับสินค้ารายการนั้น ตัวที่ไม่รับไม่คิดเงิน", "Write 0 when nothing of a line came. Rejected birds are not paid.")}</p>
    <label class="pu-wide">${T("หมายเหตุการรับ", "Arrival note")}<textarea id="pu-a-note" rows="2">${escapeHtml(o.arrival_note || "")}</textarea></label>
    <div class="pu-form-acts">
      <button type="submit" class="btn-primary" id="pu-a-save"${PU.saving ? " disabled" : ""}>${PU.saving ? T("กำลังบันทึก…", "Saving…") : T("บันทึกการรับ", "Save the arrival")}</button>
      <button type="button" class="btn-secondary" data-act="close-form">${T("ยกเลิก", "Cancel")}</button>
    </div>
  </form>`;
}

async function puSaveArrival() {
  const f = document.getElementById("pu-arrival");
  const o = PU.mode.o;
  const val = (tr, sel) => { const v = tr.querySelector(sel).value; return v === "" ? null : Number(v); };
  const p = {
    id: o.id, arrived_on: f.querySelector("#pu-a-day").value, updated_at: o.updated_at,
    freight_thb: f.querySelector("#pu-a-freight").value === "" ? null : Number(f.querySelector("#pu-a-freight").value),
    arrival_note: f.querySelector("#pu-a-note").value,
    lines: [...f.querySelectorAll("tbody tr")].map(tr => ({
      id: tr.dataset.id, received_qty: val(tr, ".pu-a-qty"), received_kg: val(tr, ".pu-a-kg"),
      rejected_qty: val(tr, ".pu-a-rej"), price: val(tr, ".pu-a-price") })),
  };
  // Keep what was typed if the save is refused.
  p.lines.forEach(x => { const l = o.lines.find(y => y.id === x.id); if (l) Object.assign(l, { received_qty: x.received_qty, received_kg: x.received_kg, rejected_qty: x.rejected_qty, price: x.price }); });
  o.arrived_on = p.arrived_on; o.freight_thb = p.freight_thb; o.arrival_note = p.arrival_note;
  PU.saving = true; PU.msg = null; puDraw();
  const { error } = await sb.rpc("purchase_record_arrival", { p });
  PU.saving = false;
  if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); return; }
  PU.mode = null;
  PU.msg = { ok: true, text: T("บันทึกการรับสินค้าแล้ว", "Arrival saved.") };
  await puLoad();
}


// ----------------------------------------------------------- Cost ratio
const PU_PRESETS = [
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
  ["3months",   () => T("3 เดือนล่าสุด", "Last 3 months")],
  ["year",      () => T("ปีนี้", "This year")],
];

function puRatioRange() {
  const r = PU.ratio, today = puToday();
  switch (r.preset) {
    case "lastmonth": return [smMonthStart(today, 1), wsAddDays(smMonthStart(today, 0), -1)];
    case "3months":   return [smMonthStart(today, 2), today];
    case "year":      return [today.slice(0, 4) + "-01-01", today];
    case "custom":    return [r.from, r.to];
    default:          return [smMonthStart(today, 0), today];
  }
}

async function puLoadRatio() {
  const r = PU.ratio;
  const [from, to] = puRatioRange();
  const key = JSON.stringify([from, to, r.company, r.group, PU.ctx]);
  if (!from || !to || to < from) { r.err = T("เลือกวันเริ่มต้นและวันสิ้นสุด", "Choose a start and an end date."); r.data = null; puDraw(); return; }
  // The group matters only to the ratio-only answer (computed by the database);
  // the full answer is grouped here.
  const { data, error } = await sb.rpc("purchase_ratio", { p_from: from, p_to: to, p_company: r.company, p_group: r.group });
  const [f2, t2] = puRatioRange();
  if (!puIsOpen() || puTabNow() !== "ratio" || key !== JSON.stringify([f2, t2, r.company, r.group, PU.ctx])) return;
  if (error) {
    const e = puError(error);
    if (e.kind !== "other") { PU.err = e; r.data = null; puDraw(); return; }
    r.err = e.text; r.data = null; puDraw(); return;
  }
  PU.err = null; r.err = null;
  const sig = JSON.stringify(data);
  if (sig === r.sig && r.data) return;
  r.sig = sig;
  r.data = data;
  puDraw();
}

function puCompleteText(cut) {
  return cut ? T(`รอบที่ผลิตเสร็จถึง ${puDay(wsAddDays(cut, -1))}`, `completed cycles to ${puDay(wsAddDays(cut, -1))}`) : "";
}
function puTarget() { return PU_TARGETS[PU.ratio.company] || null; }
function puRatioState(pct) {
  const t = puTarget();
  if (pct === null || !t) return "";
  if (pct <= t.good && !(t.good === t.max && pct >= t.max)) return "good";
  if (pct <= t.max && t.good !== t.max) return "watch";
  return "alert";
}
function puTargetText() {
  const c = PU.ratio.company;
  if (c === "Prosun Farm") return T("เป้าหมาย 55–60%", "Target 55–60%");
  if (c === "Prosun Food") return T("เป้าหมายต่ำกว่า 50%", "Target below 50%");
  return T("ไม่มีเป้าหมายรวม (เลือกบริษัท)", "No combined target (choose a company)");
}

// Rows per arrival cycle, week or month.
function puRatioRows(d) {
  const g = PU.ratio.group;
  const keyOf = day => g === "month" ? day.slice(0, 7) + "-01" : g === "week" ? puMonday(day) : puAnchor(day);
  const m = new Map();
  const row = k => {
    if (!m.has(k)) m.set(k, { key: k, rev: 0, kg: 0, kgPriced: 0, papers: 0, cost: 0, freight: 0, est: false, bo: 0, br: 0, noPrice: 0, orders: 0 });
    return m.get(k);
  };
  for (const [day, , rev, kg, kgp, papers] of d.revenue) {
    const r = row(keyOf(day)); r.rev += Number(rev); r.kg += Number(kg); r.kgPriced += Number(kgp); r.papers += Number(papers);
  }
  for (const [day, , cost, freight, est, bo, br, , noPrice, orders] of d.purchases) {
    const r = row(keyOf(day)); r.cost += Number(cost); r.freight += Number(freight); r.est = r.est || !!est;
    r.bo += Number(bo); r.br += Number(br); r.noPrice += Number(noPrice); r.orders += Number(orders);
  }
  const rows = [...m.values()].sort((a, b) => a.key < b.key ? -1 : 1);
  rows.forEach(r => { r.total = r.cost + r.freight; r.pct = r.rev > 0 ? (r.total / r.rev) * 100 : null; });
  return rows;
}
function puRowLabel(k) {
  const g = PU.ratio.group;
  const prog = ` <span class="pu-chip pu-chip-today">${escapeHtml(T("ยังไม่ครบ", "in progress"))}</span>`;
  if (g === "month") return smMonthLabel(k, true) + (wsAddDays(smMonthStart(wsAddDays(k, 40), 0), -1) >= puToday() ? prog : "");
  if (g === "week") return T("สัปดาห์ ", "Week of ") + puDay(k) + (wsAddDays(k, 6) >= puToday() ? prog : "");
  const end = puAnchorEnd(k);
  const open = end >= puToday();
  return `${puDay(k)} <span class="mg-muted mg-small">${escapeHtml(T("ผลิต", "produced"))} ${escapeHtml(puDay(k).split(" ")[0])}–${escapeHtml(puDay(end).split(" ")[0])}</span>`
    + (open ? ` <span class="pu-chip pu-chip-today">${escapeHtml(T("ยังไม่ครบรอบ", "in progress"))}</span>` : "");
}

function puRatioHtml() {
  const r = PU.ratio;
  const [from, to] = puRatioRange();
  const chips = PU_PRESETS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${r.preset === k ? "on" : ""}" data-act="rpreset" data-preset="${k}" aria-pressed="${r.preset === k}">${label()}</button>`).join("");
  const bar = `<div class="mg-bar">
    <div class="ws-presets">${chips}
      <span class="mo-dates">
        <input type="date" id="pu-r-from" value="${escapeAttr(from || "")}" aria-label="${escapeAttr(T("ตั้งแต่", "From"))}">
        <span aria-hidden="true">–</span>
        <input type="date" id="pu-r-to" value="${escapeAttr(to || "")}" aria-label="${escapeAttr(T("ถึง", "To"))}">
      </span>
    </div>
    <div class="mg-bar-right">
      <select id="pu-r-company" aria-label="${escapeAttr(T("บริษัท", "Company"))}">
        <option value="Prosun Farm"${r.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
        <option value="Prosun Food"${r.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option>
        <option value="all"${r.company === "all" ? " selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
      </select>
      ${weighLangHtml()}
    </div>
  </div>`;
  if (r.err) return bar + `<div class="mg-msg" id="pu-r-error">${escapeHtml(r.err)}</div>`;
  const d = r.data;
  if (!d) return bar + `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  if (!d.first_purchase) {
    return bar + `<div class="mg-card" id="pu-r-empty"><p>${T(
      "ยังไม่มีการสั่งซื้อที่บันทึกใน PACE — สัดส่วนจะเริ่มคำนวณตั้งแต่การรับสินค้าครั้งแรกที่บันทึกในแท็บ “สั่งซื้อและรับสินค้า”",
      "No purchase recorded in PACE yet. The ratio starts with the first arrival entered on the “Orders & arrivals” tab.")}</p></div>` + puRatioNoteHtml(d);
  }
  if (d.full === false) return bar + puRatioLimitedHtml(d);
  const rows = puRatioRows(d);
  // Totals: completed arrival cycles only — the cycle in production has its
  // purchases but not yet its revenue, and would swing the figure every day.
  const cut = d.complete_before || puAnchor(puToday());
  const tot = puRatioRows({ revenue: d.revenue.filter(x => x[0] < cut), purchases: d.purchases.filter(x => x[0] < cut) }).reduce((a, x) => { for (const k of ["rev", "kg", "kgPriced", "cost", "freight", "bo", "br", "noPrice", "orders", "total"]) a[k] += x[k]; a.est = a.est || x.est; return a; },
    { rev: 0, kg: 0, kgPriced: 0, cost: 0, freight: 0, bo: 0, br: 0, noPrice: 0, orders: 0, total: 0, est: false });
  tot.pct = tot.rev > 0 ? (tot.total / tot.rev) * 100 : null;
  const started = d.from_effective > d.from
    ? `<p class="mg-small pu-warn" id="pu-r-start">${escapeHtml(T(
        `นับตั้งแต่ ${smDayLabel(d.from_effective)} — วันแรกที่มีทั้งใบงานที่นับและการสั่งซื้อที่บันทึกใน PACE`,
        `Counted from ${smDayLabel(d.from_effective)}: the first day with both counted working papers and purchases entered in PACE.`))}</p>` : "";
  tot.cut = cut;
  return bar + started + puRatioTilesHtml(tot, d) + puRatioChartHtml(rows) + puRatioTableHtml(rows, tot) + puInvoicedHtml(d) + puRatioNoteHtml(d);
}

// Ratio only (purchasing manager, Migration 047): percentages, birds, orders.
// No revenue, no cost total, no kg sold — the database does not send them.
function puRatioLimitedHtml(d) {
  const rows = (d.groups || []).map(g => ({ key: g[0], pct: g[1] === null ? null : Number(g[1]), est: !!g[2], bo: Number(g[3]), br: Number(g[4]), orders: Number(g[5]) }));
  const [tp, test, tbo, tbr, tord] = d.total || [null, false, 0, 0, 0];
  const pct = tp === null ? null : Number(tp);
  const st = puRatioState(pct);
  const fill = Number(tbo) > 0 ? Math.round((Number(tbr) / Number(tbo)) * 1000) / 10 : null;
  const started = d.from_effective > d.from
    ? `<p class="mg-small pu-warn" id="pu-r-start">${escapeHtml(T(
        `นับตั้งแต่ ${smDayLabel(d.from_effective)} — วันแรกที่มีทั้งใบงานที่นับและการสั่งซื้อที่บันทึกใน PACE`,
        `Counted from ${smDayLabel(d.from_effective)}: the first day with both counted working papers and purchases entered in PACE.`))}</p>` : "";
  const tiles = `<div class="mg-tiles pu-tiles pu-tiles-3" id="pu-r-tiles">
    ${mgTile({ id: "pu-r-ratio", label: T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue"),
      value: pct === null ? "—" : mgN(pct, 1) + "%", state: st === "watch" ? "alert" : st,
      stateText: st === "good" ? T("อยู่ในเป้า", "Within target") : st === "watch" ? T("ใกล้เพดาน", "Near the ceiling") : st === "alert" ? T("เกินเป้า", "Above target") : "",
      sub: puTargetText() + " · " + puCompleteText(d.complete_before) + (test ? T(" · รวมประมาณการของที่ยังไม่รับ", " · includes estimates for orders not arrived") : "") })}
    ${mgTile({ id: "pu-r-fill", label: T("สัตว์ปีกที่ได้รับ", "Birds received"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: T(`${mgN(tbr)} จาก ${mgN(tbo)} ตัวที่สั่ง`, `${mgN(tbr)} of ${mgN(tbo)} birds ordered`) })}
    ${mgTile({ id: "pu-r-orders", label: T("ใบสั่งซื้อ", "Orders"), value: mgN(tord), sub: T("ที่มาถึงในช่วงนี้", "Arriving in the period") })}
  </div>`;
  const g = PU.ratio.group;
  const head = g === "cycle" ? T("รอบรับสินค้า (วันที่ถึง)", "Arrival cycle (day it came)") : g === "week" ? T("สัปดาห์", "Week") : T("เดือน", "Month");
  const table = `<div class="mg-card" id="pu-r-table-card">
    <div class="mg-card-head"><h3>${T("รายละเอียด", "Detail")}</h3>
      <div class="ws-presets pu-groups" role="group" aria-label="${escapeAttr(T("แสดงตาม", "Show by"))}">
        ${[["cycle", T("ตามรอบรับสินค้า", "By arrival cycle")], ["week", T("รายสัปดาห์", "By week")], ["month", T("รายเดือน", "By month")]]
          .map(([k, label]) => `<button type="button" class="ws-chip ${g === k ? "on" : ""}" data-act="rgroup" data-group="${k}" aria-pressed="${g === k}">${label}</button>`).join("")}
      </div></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-table">
      <thead><tr><th>${head}</th><th class="mg-n">${T("ใบสั่งซื้อ", "Orders")}</th><th class="mg-n">${T("ตัว รับ/สั่ง", "Birds rec./ord.")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th></tr></thead>
      <tbody>${rows.map(r => { const s2 = puRatioState(r.pct); return `<tr><td>${puRowLabel(r.key)}</td><td class="mg-n">${mgN(r.orders)}</td>
        <td class="mg-n">${r.bo ? `${mgN(r.br)} / ${mgN(r.bo)}` : "—"}</td>
        <td class="mg-n mg-strong ${s2 ? "pu-st-" + s2 : ""}">${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}${r.est ? ` <span class="pu-est" title="${escapeAttr(T("มีประมาณการของที่ยังไม่รับ", "Includes orders not arrived yet (estimate)"))}">≈</span>` : ""}</td></tr>`; }).join("")}</tbody>
    </table></div>
  </div>`;
  const note = `<div class="mg-card mg-small mg-muted" id="pu-r-note">${T(
    "สัดส่วน = (ต้นทุนสินค้าที่ซื้อ + ค่าขนส่ง) ÷ รายได้ของใบงานที่ยืนยันแล้ว ต้นทุนนับตามวันที่สินค้ามาถึง ใบสั่งซื้อที่ยังไม่รับนับเป็นประมาณการ (≈) ตัวเลขรายได้เห็นเฉพาะผู้บริหาร",
    "Ratio = (goods bought + freight) ÷ revenue of the confirmed working papers. Purchases count on the day they arrived; an order not arrived yet counts as an estimate (≈). Revenue figures are visible to management only.")}</div>`;
  return started + tiles + puRatioChartHtml(rows) + table + note;
}

function puRatioTilesHtml(t, d) {
  const st = puRatioState(t.pct);
  const share = t.kg > 0 ? Math.round((t.kgPriced / t.kg) * 100) : 0;
  const fill = t.bo > 0 ? Math.round((t.br / t.bo) * 1000) / 10 : null;
  return `<div class="mg-tiles pu-tiles" id="pu-r-tiles">
    ${mgTile({ id: "pu-r-ratio", label: T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue"),
      value: t.pct === null ? "—" : mgN(t.pct, 1) + "%", state: st === "watch" ? "alert" : st,
      stateText: st === "good" ? T("อยู่ในเป้า", "Within target") : st === "watch" ? T("ใกล้เพดาน", "Near the ceiling") : st === "alert" ? T("เกินเป้า", "Above target") : "",
      sub: puTargetText() + " · " + puCompleteText(t.cut) + (t.est ? T(" · รวมประมาณการของที่ยังไม่รับ", " · includes estimates for orders not arrived") : "") })}
    ${mgTile({ id: "pu-r-cost", label: T("ต้นทุนการซื้อ", "Purchase cost"), value: smBaht(t.total), unit: "THB",
      sub: T(`สินค้า ${smBaht(t.cost)} · ค่าขนส่ง ${smBaht(t.freight)}`, `Goods ${smBaht(t.cost)} · freight ${smBaht(t.freight)}`)
        + (t.noPrice ? T(` · ${t.noPrice} รายการไม่มีราคา`, ` · ${t.noPrice} line${t.noPrice === 1 ? "" : "s"} without a price`) : "") })}
    ${mgTile({ id: "pu-r-rev", label: T("รายได้โดยประมาณ", "Approx. revenue"), value: smBaht(t.rev), unit: "THB",
      state: t.kg > 0 && share < 70 ? "alert" : "",
      sub: T(`คิดราคาได้ ${share}% ของน้ำหนัก · ราคาตามใบราคา ไม่หักส่วนลด`, `${share}% of the kg priced · list prices, no discounts`) })}
    ${mgTile({ id: "pu-r-perkg", label: T("ต้นทุนซื้อต่อกก. ที่ขาย", "Purchase cost per kg sold"), value: t.kg > 0 ? mgN(t.total / t.kg, 2) : "—", unit: t.kg > 0 ? T("บาท/กก.", "THB/kg") : "",
      sub: T(`${mgKg(t.kg)} กก. ในใบงานที่ยืนยัน`, `${mgKg(t.kg)} kg on confirmed papers`) })}
    ${mgTile({ id: "pu-r-fill", label: T("สัตว์ปีกที่ได้รับ", "Birds received"), value: fill === null ? "—" : mgN(fill, 1) + "%",
      state: fill === null ? "" : fill < 98 ? "alert" : "good",
      sub: T(`${mgN(t.br)} จาก ${mgN(t.bo)} ตัวที่สั่ง`, `${mgN(t.br)} of ${mgN(t.bo)} birds ordered`) })}
  </div>`;
}

function puRatioChartHtml(rows) {
  const vals = rows.map(r => r.pct === null ? 0 : r.pct);
  if (rows.length < 2) return "";
  const t = puTarget();
  const peak = Math.max(t ? t.max * 1.2 : 0, ...vals);
  const top = mgNiceMax(peak, false);
  const cols = rows.map((r, i) => {
    const st = puRatioState(r.pct) || "none";
    const label = PU.ratio.group === "month" ? smMonthLabel(r.key) : mgDayShort(r.key);
    const tip = `<strong>${puRowLabel(r.key).replace(/<[^>]+>/g, "")}</strong><br>${T("สัดส่วน", "Ratio")}: ${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}`
      + (r.rev !== undefined ? `<br>${T("ต้นทุน", "Cost")}: ${smBaht(r.total)} THB<br>${T("รายได้", "Revenue")}: ${smBaht(r.rev)} THB` : "");
    return `<div class="mg-col" tabindex="0" aria-label="${escapeAttr(label + ": " + (r.pct === null ? "—" : mgN(r.pct, 1) + "%"))}">
      ${r.pct !== null ? `<div class="mg-val">${mgN(r.pct, 0)}%</div>` : ""}
      ${r.pct ? `<div class="mg-seg pu-seg-${st}" style="height:${Math.min(100, (r.pct / top) * 100)}%"></div>` : ""}
      <span class="mg-x">${escapeHtml(label)}</span>
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const lines = t ? [...new Set([t.good, t.max])].map(v =>
    `<div class="pu-target" style="bottom:${(v / top) * 100}%"><span>${v}%</span></div>`).join("") : "";
  const grid = [0, 0.5, 1].map(f => `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : mgN(top * f, 0) + "%"}</span></div>`).join("");
  return `<div class="mg-card" id="pu-r-chart">
    <div class="mg-card-head"><h3>${T("ต้นทุนซื้อ ÷ รายได้", "Purchase cost ÷ revenue")}</h3><span class="mg-small mg-muted">${escapeHtml(puTargetText())}</span></div>
    <div class="mg-plot sm-plot">${grid}${lines}<div class="mg-cols">${cols}</div></div>
  </div>`;
}

function puRatioTableHtml(rows, tot) {
  const g = PU.ratio.group;
  const head = g === "cycle" ? T("รอบรับสินค้า (วันที่ถึง)", "Arrival cycle (day it came)") : g === "week" ? T("สัปดาห์", "Week") : T("เดือน", "Month");
  const tr = (r, label, cls) => {
    const st = puRatioState(r.pct);
    return `<tr class="${cls || ""}">
      <td>${label}</td>
      <td class="mg-n">${mgN(r.orders)}</td>
      <td class="mg-n">${r.bo ? `${mgN(r.br)} / ${mgN(r.bo)}` : "—"}</td>
      <td class="mg-n">${smBaht(r.cost)}${r.est ? ` <span class="pu-est" title="${escapeAttr(T("มีประมาณการของที่ยังไม่รับ", "Includes orders not arrived yet (estimate)"))}">≈</span>` : ""}${r.noPrice ? ` <span class="pu-bad mg-small">${r.noPrice}✕</span>` : ""}</td>
      <td class="mg-n">${smBaht(r.freight)}</td>
      <td class="mg-n">${smBaht(r.rev)}</td>
      <td class="mg-n mg-strong ${st ? "pu-st-" + st : ""}">${r.pct === null ? "—" : mgN(r.pct, 1) + "%"}</td>
      <td class="mg-n">${mgKg(r.kg)}</td>
      <td class="mg-n">${r.kg > 0 ? mgN(r.total / r.kg, 2) : "—"}</td>
    </tr>`;
  };
  return `<div class="mg-card" id="pu-r-table-card">
    <div class="mg-card-head"><h3>${T("รายละเอียด", "Detail")}</h3>
      <div class="ws-presets pu-groups" role="group" aria-label="${escapeAttr(T("แสดงตาม", "Show by"))}">
        ${[["cycle", T("ตามรอบรับสินค้า", "By arrival cycle")], ["week", T("รายสัปดาห์", "By week")], ["month", T("รายเดือน", "By month")]]
          .map(([k, label]) => `<button type="button" class="ws-chip ${g === k ? "on" : ""}" data-act="rgroup" data-group="${k}" aria-pressed="${g === k}">${label}</button>`).join("")}
        <button type="button" class="ws-chip" data-act="csv-ratio" id="pu-csv-ratio">${T("ดาวน์โหลด CSV (Excel)", "Download CSV (Excel)")}</button>
      </div></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-table">
      <thead><tr><th>${head}</th><th class="mg-n">${T("ใบสั่งซื้อ", "Orders")}</th><th class="mg-n">${T("ตัว รับ/สั่ง", "Birds rec./ord.")}</th>
        <th class="mg-n">${T("ต้นทุนสินค้า", "Goods cost")}</th><th class="mg-n">${T("ค่าขนส่ง", "Freight")}</th>
        <th class="mg-n">${T("รายได้โดยประมาณ", "Approx. revenue")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th>
        <th class="mg-n">${T("กก. ที่ขาย", "Kg sold")}</th><th class="mg-n">${T("ต้นทุน/กก. ที่ขาย", "Cost per kg sold")}</th></tr></thead>
      <tbody>${rows.map(r => tr(r, puRowLabel(r.key))).join("")}${rows.length > 1 ? tr(tot, T("รวม (รอบที่เสร็จแล้ว)", "Total (completed cycles)"), "mg-total") : ""}</tbody>
    </table></div>
    ${g === "cycle" ? `<p class="mg-small mg-muted">${T(
      "รอบที่ “ยังไม่ครบรอบ” ยังผลิตไม่เสร็จ สัดส่วนจะสูงจนกว่าใบงานจะยืนยันครบ แต่ละรอบ: ต้นทุนของสินค้าที่มาถึงวันนั้น เทียบกับรายได้ของใบงานที่ผลิตจนถึงรอบถัดไป (ถึงวันจันทร์ → ผลิตจันทร์–อังคาร · พุธ → พุธ–พฤหัส · ศุกร์ → ศุกร์–อาทิตย์) รายสัปดาห์และรายเดือนนิ่งกว่า",
      "A cycle “in progress” is still being produced: its ratio stays high until its papers are confirmed. Each cycle: the cost of what arrived that day against the revenue of the papers produced until the next arrival (Monday arrival → produced Mon–Tue · Wednesday → Wed–Thu · Friday → Fri–Sun). Weeks and months are steadier.")}</p>` : ""}
  </div>`;
}

// Invoiced revenue per month (Odoo, loaded in Management › Overview).
function puInvoicedHtml(d) {
  if (!d.invoiced || !d.invoiced.length) return "";
  const months = new Map();
  for (const [month, , amount, days] of d.invoiced) {
    const m = months.get(month) || { month, amount: 0, days: 0 };
    m.amount += Number(amount); m.days = Math.max(m.days, Number(days || 0));
    months.set(month, m);
  }
  const rows = [...months.values()].sort((a, b) => a.month < b.month ? -1 : 1).map(m => {
    const end = wsAddDays(smMonthStart(wsAddDays(m.month, 40), 0), -1);
    const cost = d.purchases.filter(p => p[0] >= m.month && p[0] <= end).reduce((a, p) => a + Number(p[2]) + Number(p[3]), 0);
    const partial = m.month < d.from_effective;
    const pct = !partial && m.amount > 0 ? (cost / m.amount) * 100 : null;
    const st = puRatioState(pct);
    return `<tr><td>${escapeHtml(smMonthLabel(m.month, true))}</td>
      <td class="mg-n">${smBaht(m.amount)}${m.days ? ` <span class="mg-muted mg-small">${escapeHtml(T(`ถึงวันที่ ${m.days}`, `to day ${m.days}`))}</span>` : ""}</td>
      <td class="mg-n">${smBaht(cost)}</td>
      <td class="mg-n mg-strong ${st ? "pu-st-" + st : ""}">${pct === null ? `<span class="mg-muted mg-small">${escapeHtml(T("บางส่วน — การสั่งซื้อเริ่มบันทึก " + smDayLabel(d.from_effective), "partial: purchases entered from " + smDayLabel(d.from_effective)))}</span>` : mgN(pct, 1) + "%"}</td></tr>`;
  }).join("");
  return `<div class="mg-card" id="pu-r-invoiced">
    <div class="mg-card-head"><h3>${T("เทียบกับยอดใบแจ้งหนี้ (Odoo)", "Against invoiced revenue (Odoo)")}</h3>
      <span class="mg-small mg-muted">${T("ยอดขายรายเดือนที่โหลดในหน้า ภาพรวม", "Monthly sales loaded in Management › Overview")}</span></div>
    <div class="mg-table-wrap"><table class="mg-table" id="pu-r-inv-table">
      <thead><tr><th>${T("เดือน", "Month")}</th><th class="mg-n">${T("ยอดใบแจ้งหนี้", "Invoiced")}</th><th class="mg-n">${T("ต้นทุนการซื้อ", "Purchase cost")}</th><th class="mg-n">${T("สัดส่วน", "Ratio")}</th></tr></thead>
      <tbody>${rows}</tbody></table></div>
  </div>`;
}

function puRatioNoteHtml(d) {
  return `<div class="mg-card mg-small mg-muted" id="pu-r-note">${T(
    `สัดส่วน = (ต้นทุนสินค้าที่ซื้อ + ค่าขนส่ง) ÷ รายได้ ต้นทุนนับตามวันที่สินค้ามาถึง ใบสั่งซื้อที่ยังไม่รับนับเป็นประมาณการ (≈) รายได้โดยประมาณมาจากใบงานที่ยืนยันน้ำหนักแล้ว ตามวันผลิต ใช้หลักเดียวกับหน้าสรุป: น้ำหนักจริง × ราคาในใบราคา ไม่หักส่วนลด จึงอาจสูงกว่ารายได้จริง (สัดส่วนจะดูดีกว่าความจริง) ส่วนสินค้าที่ไม่มีในใบราคาไม่ถูกนับรายได้ (สัดส่วนจะดูแย่กว่าความจริง) ยอดใบแจ้งหนี้ใน Odoo คือรายได้จริง ยอดขายของ Prosun Food ที่ซื้อจาก Prosun Farm นับเป็นรายได้ของ Farm`,
    `Ratio = (goods bought + freight) ÷ revenue. Purchases count on the day they arrived; an order not arrived yet counts as an estimate (≈). Approx. revenue comes from the confirmed working papers, by production day, with the Summary rules: actual kg × the list price, no discounts — so it can be above the real revenue (the ratio then looks better than it is), while products not on the price list bring no revenue (the ratio then looks worse). Odoo invoices are the real revenue. Prosun Food's purchases from Prosun Farm are Farm revenue.`)}</div>`;
}


// ----------------------------------------------------------- exports
function puDownload(name, rows) {
  const esc = v => { const s = String(v ?? ""); return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const blob = new Blob(["﻿" + rows.map(r => r.map(esc).join(",")).join("\r\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function puCsvWeek() {
  const weekEnd = wsAddDays(PU.week, 6);
  const out = [["Order date", "Arrival planned", "Arrived on", "Company", "Supplier", "Reference", "Status", "Item", "Size", "Ordered", "Unit", "Est. kg", "Received", "Received kg", "Rejected", "Price", "Per", "Cost THB", "Freight THB (order)"]];
  for (const o of (PU.board.orders || []).filter(o => o.order_date >= PU.week && o.order_date <= weekEnd)) {
    (o.lines || []).forEach((l, i) => {
      const it = puItem(l.item_id);
      out.push([o.order_date, o.arrival_date, o.arrived_on || "", o.company, o.supplier, o.ref || "", o.status, it.name, l.size_band || "",
        l.ordered_qty, it.unit, l.ordered_kg ?? "", l.received_qty ?? "", l.received_kg ?? "", l.rejected_qty ?? "", l.price ?? "", l.price_per,
        l.cost ?? "", i === 0 ? (o.freight_thb ?? "") : ""]);
    });
  }
  puDownload(`prosun-purchases-${PU.week}.csv`, out);
}

function puCsvRatio() {
  const d = PU.ratio.data;
  if (!d) return;
  const rows = puRatioRows(d);
  const out = [["Period", "Orders", "Birds ordered", "Birds received", "Goods cost THB", "Freight THB", "Estimate", "Approx revenue THB", "Ratio %", "Kg sold", "Cost per kg sold"]];
  for (const r of rows) out.push([r.key, r.orders, r.bo, r.br, r.cost.toFixed(2), r.freight.toFixed(2), r.est ? "yes" : "", r.rev.toFixed(2),
    r.pct === null ? "" : r.pct.toFixed(1), r.kg.toFixed(2), r.kg > 0 ? (r.total / r.kg).toFixed(2) : ""]);
  const [from, to] = puRatioRange();
  puDownload(`prosun-purchase-ratio-${PU.ratio.company.replace(/\s+/g, "-")}-${PU.ratio.group}-${from}_${to}.csv`, out);
}


// ----------------------------------------------------------- events
function puFind(id) { return ((PU.board && PU.board.orders) || []).find(o => o.id === id); }
function puClone(o) { return JSON.parse(JSON.stringify(o)); }

puSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "lang") {
    puReadForms();
    weighSetLang(b.dataset.lang);
    puDraw();
  } else if (act === "tab") {
    if (PU.tab === b.dataset.tab) return;
    PU.tab = b.dataset.tab; PU.mode = null; PU.msg = null;
    try { localStorage.setItem("pu-tab", PU.tab); } catch (err) { /* private mode */ }
    puDraw();
    await puLoad();
  } else if (act === "week") {
    PU.week = wsAddDays(PU.week, Number(b.dataset.step)); PU.msg = null; PU.board = PU.board && Object.assign({}, PU.board, { orders: [] });
    puDraw(); await puLoad();
  } else if (act === "thisweek") {
    PU.week = puMonday(puToday()); PU.msg = null; await puLoad();
  } else if (act === "new") {
    PU.msg = null; PU.mode = puNewOrder(b.dataset.order, b.dataset.arrival); puDraw();
  } else if (act === "repeat") {
    const from = puFind(b.dataset.from); if (!from) return;
    PU.msg = null; PU.mode = puNewOrder(b.dataset.order, b.dataset.arrival, from); puDraw();
  } else if (act === "edit") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "order", o: Object.assign(puClone(o), { arrivalTouched: true }) }; puDraw();
  } else if (act === "arrival") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "arrival", o: puClone(o) }; puDraw();
  } else if (act === "cancel") {
    const o = puFind(b.dataset.id); if (!o) return;
    PU.msg = null; PU.mode = { kind: "cancel", o }; puDraw();
    const i = document.getElementById("pu-cancel-reason"); if (i) i.focus();
  } else if (act === "cancel-no") {
    PU.mode = null; puDraw();
  } else if (act === "cancel-yes") {
    const reason = (document.getElementById("pu-cancel-reason") || {}).value || "";
    PU.saving = true; puDraw();
    const { error } = await sb.rpc("purchase_cancel_order", { p_id: b.dataset.id, p_reason: reason });
    PU.saving = false;
    if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; puDraw(); const i = document.getElementById("pu-cancel-reason"); if (i) i.value = reason; return; }
    PU.mode = null; PU.msg = { ok: true, text: T("ยกเลิกใบสั่งซื้อแล้ว", "Order cancelled.") };
    await puLoad();
  } else if (act === "close-form") {
    PU.mode = null; PU.msg = null; puDraw();
  } else if (act === "line-add") {
    puReadForm();
    const last = PU.mode.o.lines[PU.mode.o.lines.length - 1] || {};
    PU.mode.o.lines.push({ item_id: last.item_id, price_per: last.price_per || "kg" });
    puDraw();
    const rows = puSection.querySelectorAll("#pu-f-lines tr");
    const q = rows[rows.length - 1] && rows[rows.length - 1].querySelector(".pu-l-qty"); if (q) q.focus();
  } else if (act === "line-del") {
    puReadForm();
    PU.mode.o.lines.splice(Number(b.dataset.i), 1);
    puDraw();
  } else if (act === "item-add") {
    puReadForm();
    const name = document.getElementById("pu-i-name").value.trim();
    const p = { name, name_th: document.getElementById("pu-i-th").value.trim(), unit: document.getElementById("pu-i-unit").value };
    PU.saving = true;
    const { data, error } = await sb.rpc("purchase_save_item", { p });
    PU.saving = false;
    if (error) { PU.msg = { ok: false, text: puServerText(error.message) }; PU.mode.itemOpen = true; puDraw(); return; }
    const item = { id: data, name, name_th: p.name_th || null, unit: p.unit, active: true };
    PU.board.items.push(item); PU.items[data] = item;
    const blank = PU.mode.o.lines.find(l => !l.ordered_qty);
    if (blank) blank.item_id = data; else PU.mode.o.lines.push({ item_id: data, price_per: p.unit === "kg" ? "kg" : "unit" });
    PU.mode.itemOpen = false;
    PU.msg = { ok: true, text: T(`เพิ่มสินค้า “${name}” แล้ว`, `Item “${name}” added.`) };
    puDraw();
  } else if (act === "same-as-ordered") {
    puSection.querySelectorAll("#pu-arrival tbody tr").forEach(tr => {
      const l = PU.mode.o.lines.find(x => x.id === tr.dataset.id);
      const q = tr.querySelector(".pu-a-qty");
      if (l && q.value === "") q.value = l.ordered_qty;
    });
  } else if (act === "csv-week") {
    puCsvWeek();
  } else if (act === "rpreset") {
    PU.ratio.preset = b.dataset.preset; PU.ratio.data = null; puDraw(); await puLoadRatio();
  } else if (act === "rgroup") {
    PU.ratio.group = b.dataset.group;
    if (PU.ratio.data && PU.ratio.data.full === false) { PU.ratio.data = null; puDraw(); await puLoadRatio(); }
    else puDraw();
  } else if (act === "csv-ratio") {
    puCsvRatio();
  }
});

puSection.addEventListener("submit", async e => {
  e.preventDefault();
  if (PU.saving) return;
  if (e.target.id === "pu-form") await puSaveOrder();
  else if (e.target.id === "pu-arrival") await puSaveArrival();
});

puSection.addEventListener("input", e => {
  if (e.target.closest("#pu-f-lines")) puFormRefresh();
});

puSection.addEventListener("change", async e => {
  const id = e.target.id;
  if (e.target.closest("#pu-f-lines")) { puFormRefresh(); return; }
  if (id === "pu-f-order" && PU.mode && PU.mode.kind === "order" && !PU.mode.o.arrivalTouched && e.target.value) {
    document.getElementById("pu-f-arrival").value = wsAddDays(e.target.value, 2);   // Mon → Wed, Wed → Fri, Sat → Mon
  } else if (id === "pu-f-arrival" && PU.mode) {
    PU.mode.o.arrivalTouched = true;
  } else if (id === "pu-r-company") {
    PU.ratio.company = e.target.value; PU.ratio.data = null; puDraw(); await puLoadRatio();
  } else if (id === "pu-r-from" || id === "pu-r-to") {
    const f = document.getElementById("pu-r-from").value, t = document.getElementById("pu-r-to").value;
    if (!f || !t) return;
    Object.assign(PU.ratio, { preset: "custom", from: f, to: t, data: null });
    puDraw(); await puLoadRatio();
  }
});

if (document.getElementById("switch-system-btn")) document.getElementById("switch-system-btn").addEventListener("click", puClose);
if (document.getElementById("sign-out-btn")) {
  document.getElementById("sign-out-btn").addEventListener("click", () => {
    puClose();
    Object.assign(PU, { board: null, items: {}, err: null, mode: null, msg: null });
    Object.assign(PU.ratio, { data: null, err: null, sig: "" });
  });
}
