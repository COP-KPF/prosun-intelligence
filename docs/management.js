// ============================================================================
// Management dashboard — PROSUN PACE › Management (Migration 024, 2 Nov 2026)
// ============================================================================
// Clément: a dashboard to follow the activity and pilot the company. Admin
// only, read-only. All numbers come from one database function,
// management_dashboard(from, to, company), which also holds the definitions
// (see the migration's header); nothing is calculated from raw rows here.
//
// Refreshes every 60 seconds while open and in front, and when the browser tab
// comes back. Redraws only if the numbers changed.
//
// Loaded after weights-summary.js (reuses wsPresetRange, wsAddDays) and
// weighing.js (weighLangHtml); uses app.js globals at run time (sb, myProfile,
// escapeHtml, switchPaceView, paceWeightsDept).
// ============================================================================

const mgSection = document.getElementById("management-section");

const MG = {
  preset: "today",
  company: "all",
  data: null,
  error: null,
  saving: false,
  showAllClients: false,
  timer: null,
  sig: "",
  updatedAt: null,
};

const MG_REFRESH_MS = window.__mgRefreshMs || 60000;

const MG_PRESETS = [
  ["today",     () => T("วันนี้", "Today")],
  ["yesterday", () => T("เมื่อวาน", "Yesterday")],
  ["week",      () => T("สัปดาห์นี้", "This week")],
  ["lastweek",  () => T("สัปดาห์ที่แล้ว", "Last week")],
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
];


// ----------------------------------------------------------- open / close
async function openManagement() {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  mgSection.classList.remove("hidden");
  if (!MG.data) mgSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  MG.sig = "";
  await mgLoad();
}

function closeManagement() {
  clearTimeout(MG.timer);
  if (mgSection.classList.contains("hidden")) return;
  mgSection.classList.add("hidden");
  mgSection.innerHTML = "";
}

function mgOpen() { return !mgSection.classList.contains("hidden"); }

function mgSchedule() {
  clearTimeout(MG.timer);
  if (!mgOpen()) return;
  MG.timer = setTimeout(async () => {
    if (mgOpen() && !document.hidden) await mgLoad();
    else mgSchedule();
  }, MG_REFRESH_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && mgOpen()) mgLoad();
});

// A period never runs past today: "this week" would otherwise chart empty future days.
function mgRange() {
  const today = weighBangkokToday();
  const [from, to] = wsPresetRange(MG.preset);
  return [from, to > today ? today : to];
}

async function mgLoad() {
  clearTimeout(MG.timer);
  const preset = MG.preset, company = MG.company;
  const [from, to] = mgRange();
  const { data, error } = await sb.rpc("management_dashboard", { p_from: from, p_to: to, p_company: company });
  if (!mgOpen() || preset !== MG.preset || company !== MG.company) return;   // closed, or a newer filter is loading
  if (error) {
    const missing = /management_dashboard|schema cache|does not exist/i.test(error.message || "");
    MG.error = missing
      ? T("ยังไม่พบข้อมูลแดชบอร์ด: กรุณารัน Migration 024 ใน Supabase", "The dashboard's database function is missing: run Migration 024 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load the dashboard: ") + error.message;
    MG.data = null;
    MG.sig = "";
    mgDraw();
  } else {
    MG.error = null;
    MG.data = data;
    MG.updatedAt = new Date();
    const sig = JSON.stringify(data);
    const typing = mgSection.contains(document.activeElement) && document.activeElement.tagName === "INPUT";
    if (sig !== MG.sig && !typing) { MG.sig = sig; mgDraw(); }
    else mgDrawUpdated();
  }
  mgSchedule();
}


// ----------------------------------------------------------- formatting
function mgN(n, dp = 0) {
  return Number(n || 0).toLocaleString("en-GB", { minimumFractionDigits: dp, maximumFractionDigits: dp });
}
function mgKg(n) { return mgN(n, Math.abs(Number(n)) >= 100 ? 0 : 1); }
function mgSigned(n, dp = 1) {
  const v = Number(n || 0);
  if (Math.abs(v) < 0.05) return "0";
  return (v > 0 ? "+" : "−") + mgN(Math.abs(v), dp);
}
function mgDayShort(iso) {
  const [, m, d] = String(iso).split("-");
  return `${Number(d)}/${Number(m)}`;
}
function mgDayLong(iso) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}
function mgDuration(hours) {
  if (hours === null || hours === undefined) return "—";
  const h = Number(hours);
  if (h < 1) return `${Math.max(1, Math.round(h * 60))} ${T("นาที", "min")}`;
  if (h < 48) return `${mgN(h, 1)} ${T("ชม.", "h")}`;
  return `${mgN(h / 24, 1)} ${T("วัน", "days")}`;
}
function mgAge(ts) {
  return ts ? mgDuration((Date.now() - new Date(ts).getTime()) / 3600000) : "—";
}
function mgStatusLabel(p) {
  if (p.status === "failed") return T("อ่านไม่สำเร็จ", "Reading failed");
  if (p.status === "read") return p.reopened_at ? T("เปิดแก้ไข", "Reopened") : T("รอตรวจ", "To check");
  return T("กำลังอ่าน", "Being read");
}


// ----------------------------------------------------------- chart
function mgNiceMax(max, integer) {
  if (max <= 0) return integer ? 2 : 10;
  const pow = Math.pow(10, Math.floor(Math.log10(max)));
  for (const k of [1, 2, 2.5, 5, 10]) {
    const m = k * pow;
    if (m >= max && (!integer || (m >= 2 && Number.isInteger(m / 2)))) return m;
  }
  return 10 * pow;
}

// Thin stacked columns on a recessive grid. series: [{ key, cls, label }].
// The latest day and the highest day carry a number; every day has a tooltip;
// the table underneath gives all the figures.
function mgBars(days, series, opts) {
  const totals = days.map(d => series.reduce((a, s) => a + Number(d[s.key] || 0), 0));
  const peak = Math.max(0, ...totals);
  const top = mgNiceMax(peak, !!opts.integer);
  const peakAt = totals.indexOf(peak);
  const every = Math.ceil(days.length / 14);
  const cols = days.map((d, i) => {
    const segs = [...series].reverse().map(s => {
      const v = Number(d[s.key] || 0);
      return v > 0 ? `<div class="mg-seg ${s.cls}" style="height:${(v / top) * 100}%"></div>` : "";
    }).join("");
    const labelled = totals[i] > 0 && (i === days.length - 1 || i === peakAt);
    const tip = [`<strong>${escapeHtml(mgDayLong(d.day))}</strong>`]
      .concat(series.map(s => `${escapeHtml(s.label)}: ${opts.fmt(d[s.key])}`)).join("<br>");
    const aria = `${mgDayLong(d.day)}: ` + series.map(s => `${s.label} ${opts.fmt(d[s.key])}`).join(", ");
    const showX = (days.length - 1 - i) % every === 0;
    return `<div class="mg-col" tabindex="0" aria-label="${escapeHtml(aria)}">
      ${labelled ? `<div class="mg-val">${opts.fmt(totals[i])}</div>` : ""}
      ${segs}
      ${showX ? `<span class="mg-x">${mgDayShort(d.day)}</span>` : ""}
      <div class="mg-tip">${tip}</div>
    </div>`;
  }).join("");
  const grid = [0, 0.5, 1].map(f =>
    `<div class="mg-grid" style="bottom:${f * 100}%"><span>${f === 0 ? 0 : mgN(top * f, top * f < 10 && !Number.isInteger(top * f) ? 1 : 0)}</span></div>`).join("");
  return `<div class="mg-plot">${grid}<div class="mg-cols">${cols}</div></div>`;
}


// ----------------------------------------------------------- pieces
function mgTile(o) {
  return `<div class="mg-card mg-tile ${o.state ? "mg-" + o.state : ""}" ${o.id ? `id="${o.id}"` : ""}>
    <span class="mg-tile-k">${o.label}</span>
    <span class="mg-tile-v">${o.value}${o.unit ? `<small>${o.unit}</small>` : ""}</span>
    ${o.stateText ? `<span class="mg-state">${o.stateText}</span>` : ""}
    ${o.sub ? `<span class="mg-tile-s">${o.sub}</span>` : ""}
    ${o.go ? `<button type="button" class="mg-go" data-act="go" data-view="${o.go}">${T("เปิด ›", "Open ›")}</button>` : ""}
  </div>`;
}

function mgTilesHtml(d) {
  const p = d.papers, l = d.lines, o = d.open, a = d.accounting;
  const openInPeriod = Number(p.to_check) + Number(p.processing) + Number(p.failed);
  const off = Number(l.under) + Number(l.over);
  return `<div class="mg-tiles" id="mg-tiles">
    ${mgTile({
      id: "mg-t-papers", label: T("ใบงานที่ถ่ายรูป", "Papers photographed"), value: mgN(p.total),
      sub: T(`ยืนยันแล้ว ${mgN(p.confirmed)} · ยังไม่ยืนยัน ${mgN(openInPeriod)}`, `${mgN(p.confirmed)} confirmed · ${mgN(openInPeriod)} not yet`),
    })}
    ${mgTile({
      id: "mg-t-kg", label: T("น้ำหนักที่ยืนยันแล้ว", "Kg confirmed"), value: mgKg(l.kg), unit: "kg",
      sub: T(`${mgN(l.total)} รายการ`, `${mgN(l.total)} product lines`),
    })}
    ${mgTile({
      id: "mg-t-off", label: T("รายการที่ต่างเกิน ±5%", "Lines off by more than ±5%"), value: mgN(off),
      sub: T(`ขาด ${mgN(l.under)} · เกิน ${mgN(l.over)} · จาก ${mgN(l.compared)} รายการที่เทียบได้`, `${mgN(l.under)} under · ${mgN(l.over)} over · of ${mgN(l.compared)} comparable`),
    })}
    ${mgTile({
      id: "mg-t-backlog", label: T("ค้างยืนยันจากวันก่อน", "Unconfirmed from earlier days"), value: mgN(o.earlier),
      state: Number(o.earlier) > 0 ? "alert" : "good",
      stateText: Number(o.earlier) > 0 ? T("⚠ ต้องติดตาม", "⚠ Needs follow-up") : T("✓ ไม่มีค้าง", "✓ None"),
      sub: T(`วันนี้ยังไม่ยืนยัน ${mgN(o.today)}`, `Today, not yet confirmed: ${mgN(o.today)}`),
      go: Number(o.earlier) > 0 ? "weighing" : "",
    })}
    ${mgTile({
      id: "mg-t-waiting", label: T("รอบัญชีตรวจ", "Waiting for accounting check"), value: mgN(a.waiting),
      sub: Number(a.waiting) > 0 ? T(`นานสุด ${mgAge(a.oldest)}`, `Oldest: ${mgAge(a.oldest)}`) : T("ไม่มีค้าง", "None waiting"),
      go: Number(a.waiting) > 0 ? "weights" : "",
    })}
    ${mgTile({
      id: "mg-t-speed", label: T("เวลาตรวจของบัญชี (ค่ากลาง)", "Time to accounting check (median)"), value: mgDuration(a.median_hours),
      sub: p.median_confirm_minutes === null ? T("รูปถึงยืนยัน: —", "Photo to confirmation: —")
        : T(`รูปถึงยืนยัน: ${mgDuration(Number(p.median_confirm_minutes) / 60)}`, `Photo to confirmation: ${mgDuration(Number(p.median_confirm_minutes) / 60)}`),
    })}
  </div>`;
}

function mgChartsHtml(d) {
  const done = T("ยืนยันแล้ว", "Confirmed"), open = T("ยังไม่ยืนยัน", "Not yet confirmed");
  const rows = d.trend.map(t => `<tr><td>${escapeHtml(mgDayLong(t.day))}</td><td class="mg-n">${mgN(t.confirmed)}</td><td class="mg-n">${mgN(t.open)}</td><td class="mg-n">${mgKg(t.kg)}</td></tr>`).join("");
  return `<div class="mg-charts">
    <div class="mg-card" id="mg-chart-papers">
      <div class="mg-card-head"><h3>${T("ใบงานต่อวัน", "Papers per day")}</h3>
        <div class="mg-legend"><span><i style="background:var(--mg-done)"></i>${done}</span><span><i style="background:var(--mg-open)"></i>${open}</span></div></div>
      ${mgBars(d.trend, [{ key: "confirmed", cls: "mg-seg-done", label: done }, { key: "open", cls: "mg-seg-open", label: open }], { integer: true, fmt: v => mgN(v) })}
    </div>
    <div class="mg-card" id="mg-chart-kg">
      <div class="mg-card-head"><h3>${T("น้ำหนักที่ยืนยันต่อวัน (กก.)", "Kg confirmed per day")}</h3></div>
      ${mgBars(d.trend, [{ key: "kg", cls: "mg-seg-done", label: T("กก.", "kg") }], { fmt: v => mgKg(v) })}
    </div>
  </div>
  <details class="mg-details"><summary>${T("ดูตัวเลขรายวัน", "See the daily figures")}</summary>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("วัน", "Day")}</th><th class="mg-n">${done}</th><th class="mg-n">${open}</th><th class="mg-n">kg</th></tr></thead><tbody>${rows}</tbody></table></div>
  </details>`;
}

function mgClientsHtml(d) {
  const l = d.lines;
  const notCompared = Number(l.total) - Number(l.compared);
  const list = MG.showAllClients ? d.clients : d.clients.slice(0, 10);
  const body = list.map(c => `<tr>
      <td>${escapeHtml(c.client)}</td>
      <td class="mg-n">${mgN(c.under_lines)}</td><td class="mg-n">${mgSigned(c.under_kg)}</td>
      <td class="mg-n">${mgN(c.over_lines)}</td><td class="mg-n">${mgSigned(c.over_kg)}</td>
      <td class="mg-n mg-strong">${mgSigned(c.net_kg)}</td><td class="mg-n">${mgN(c.compared)}</td>
    </tr>`).join("");
  return `<div class="mg-card" id="mg-clients">
    <div class="mg-card-head"><h3>${T("ส่งขาด / เกินจากที่สั่ง ตามลูกค้า", "Under and over the ordered quantity, by client")}</h3>
      <span class="mg-small mg-muted">${T(`รวมขาด ${mgSigned(l.under_kg)} กก. · รวมเกิน ${mgSigned(l.over_kg)} กก.`, `Total under ${mgSigned(l.under_kg)} kg · total over ${mgSigned(l.over_kg)} kg`)}</span></div>
    ${list.length ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th>${T("ลูกค้า", "Client")}</th>
        <th class="mg-n">${T("รายการขาด", "Lines under")}</th><th class="mg-n">${T("ขาด (กก.)", "Kg under")}</th>
        <th class="mg-n">${T("รายการเกิน", "Lines over")}</th><th class="mg-n">${T("เกิน (กก.)", "Kg over")}</th>
        <th class="mg-n">${T("สุทธิทุกรายการ (กก.)", "Net, all lines (kg)")}</th><th class="mg-n">${T("รายการที่เทียบได้", "Comparable lines")}</th>
      </tr></thead><tbody>${body}</tbody></table></div>`
      : `<p class="mg-small mg-muted">${T("ไม่มีรายการที่ต่างเกิน ±5% ในช่วงนี้", "No line off by more than ±5% in this period.")}</p>`}
    ${d.clients.length > 10 ? `<button type="button" class="ws-chip mg-more" data-act="more">${MG.showAllClients ? T("แสดง 10 รายแรก", "Show the first 10") : T(`แสดงทั้งหมด ${d.clients.length} ราย`, `Show all ${d.clients.length} clients`)}</button>` : ""}
    <p class="mg-small mg-muted" style="margin-top:10px">${T(
      `ลูกค้าที่อยู่ในเกณฑ์ทั้งหมด: ${mgN(d.clients_within)} ราย เทียบได้เฉพาะรายการที่สั่งเป็น กก. หรือ กรัม: ไม่รวม ${mgN(notCompared)} รายการที่สั่งเป็นชิ้น แพ็ค หรือขวด`,
      `Clients fully within ±5%: ${mgN(d.clients_within)}. Only lines ordered in kg or g can be compared; ${mgN(notCompared)} lines ordered in pieces, packs or jars are left out.`)}</p>
  </div>`;
}

function mgOpenHtml(d) {
  const o = d.open;
  if (!Number(o.earlier)) return "";
  const rows = o.list.map(p => `<tr><td>${escapeHtml(mgDayLong(p.work_date))}</td><td>${escapeHtml(mgStatusLabel(p))}</td><td>${escapeHtml(p.customer_name || "—")}</td><td>${escapeHtml(p.po_number || "—")}</td><td>${escapeHtml(p.company || "—")}</td></tr>`).join("");
  return `<div class="mg-card" id="mg-open-list">
    <div class="mg-card-head"><h3>${T("ใบงานค้างยืนยันจากวันก่อน", "Papers still unconfirmed from earlier days")}</h3>
      ${Number(o.earlier) > o.list.length ? `<span class="mg-small mg-muted">${T(`แสดง ${o.list.length} ใบแรกจาก ${mgN(o.earlier)}`, `Oldest ${o.list.length} of ${mgN(o.earlier)}`)}</span>` : ""}</div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("วันที่ถ่าย", "Photographed")}</th><th>${T("สถานะ", "Status")}</th><th>${T("ลูกค้า", "Client")}</th><th>PO</th><th>${T("บริษัท", "Company")}</th></tr></thead><tbody>${rows}</tbody></table></div>
  </div>`;
}

function mgSalesHtml(d) {
  const reps = d.sales.reps, un = d.sales.unassigned;
  const keys = ["clients", "active", "at_risk", "dormant", "pipeline", "lost"];
  const total = {};
  keys.forEach(k => { total[k] = reps.reduce((a, r) => a + Number(r[k] || 0), Number(un[k] || 0)); });
  const cells = r => keys.map(k => `<td class="mg-n${k === "at_risk" && Number(r[k]) > 0 ? " mg-strong" : ""}">${mgN(r[k])}</td>`).join("");
  const body = reps.map(r => `<tr><td>${escapeHtml(r.name)}</td>${cells(r)}</tr>`).join("");
  return `<div class="mg-card" id="mg-sales">
    <div class="mg-card-head"><h3>${T("ลูกค้าตามพนักงานขาย", "Clients per salesperson")}</h3>
      <span class="mg-small mg-muted">${T(`เสี่ยง ${mgN(total.at_risk)} · ไม่มีพนักงานขาย ${mgN(un.clients)}`, `${mgN(total.at_risk)} at risk · ${mgN(un.clients)} with no salesperson`)}</span></div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("พนักงานขาย", "Salesperson")}</th><th class="mg-n">${T("ลูกค้า", "Clients")}</th><th class="mg-n">${T("ใช้งาน", "Active")}</th>
      <th class="mg-n">${T("เสี่ยง", "At risk")}</th><th class="mg-n">${T("หยุดซื้อ", "Dormant")}</th><th class="mg-n">${T("ลูกค้าใหม่", "Pipeline")}</th><th class="mg-n">${T("เสียไป", "Lost")}</th>
    </tr></thead><tbody>${body}
      <tr class="mg-flag" id="mg-unassigned"><td>${T("ไม่มีพนักงานขาย", "No salesperson")}</td>${cells(un)}</tr>
      <tr class="mg-total"><td>${T("รวม", "Total")}</td>${cells(total)}</tr>
    </tbody></table></div>
    <p class="mg-small mg-muted" style="margin-top:10px">${T(
      "สถานะตามที่บันทึกใน CRM ณ ตอนนี้ ไม่ใช่ข้อมูลคำสั่งซื้อจริง และไม่ขึ้นกับช่วงเวลาหรือบริษัทที่เลือก",
      "Stages are as recorded in the CRM today, not live orders, and do not follow the period or company filters.")}</p>
  </div>`;
}

function mgNoteHtml(d) {
  return `<div class="mg-card mg-small" id="mg-note">
    <div class="mg-note">
      <label for="mg-count-from" class="mg-strong">${T("เริ่มนับตั้งแต่วันที่", "Count papers from")}</label>
      <input type="date" id="mg-count-from" value="${escapeHtml(d.count_from)}" max="${escapeHtml(d.today)}">
      <button type="button" class="ws-chip" data-act="save-start" ${MG.saving ? "disabled" : ""}>${T("บันทึก", "Save")}</button>
      <span class="mg-muted">${T("ใบงานก่อนวันนี้ (ช่วงทดสอบ) ไม่นับในตัวเลขการชั่ง", "Papers before this date (team testing) are left out of all weighing figures.")}</span>
    </div>
    <p class="mg-muted" style="margin-top:8px">${T(
      "ใบงานนับตามวันที่ถ่ายรูป น้ำหนักนับเฉพาะใบที่ยืนยันแล้ว “รอบัญชีตรวจ” มาจากเครื่องหมายตรวจในหน้าน้ำหนักที่ยืนยันแล้ว ไม่ได้ยืนยันว่าออกใบแจ้งหนี้ใน Odoo แล้ว ยังไม่มีรายได้ เพราะรายการยังไม่มีราคา",
      "Papers count on the day they were photographed; weights count on confirmed papers only. “Waiting for accounting check” comes from the check mark on Confirmed weights and does not prove an Odoo invoice exists. Revenue is not shown yet because the lines carry no prices.")}</p>
  </div>`;
}


// ----------------------------------------------------------- draw
function mgFiltersHtml() {
  const chips = MG_PRESETS.map(([k, label]) =>
    `<button type="button" class="ws-chip ${MG.preset === k ? "on" : ""}" data-act="preset" data-preset="${k}" aria-pressed="${MG.preset === k}">${label()}</button>`).join("");
  return `<div class="mg-bar">
    <div class="ws-presets">${chips}</div>
    <div class="mg-bar-right">
      <select id="mg-company" aria-label="${T("บริษัท", "Company")}">
        <option value="all" ${MG.company === "all" ? "selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
        <option value="Prosun Farm" ${MG.company === "Prosun Farm" ? "selected" : ""}>Prosun Farm</option>
        <option value="Prosun Food" ${MG.company === "Prosun Food" ? "selected" : ""}>Prosun Food</option>
      </select>
      ${weighLangHtml()}
    </div>
  </div>`;
}

function mgDrawUpdated() {
  const el = document.getElementById("mg-updated");
  if (el && MG.updatedAt) el.textContent = T("อัปเดต ", "Updated ") + weighTimeFmt(MG.updatedAt);
}

function weighTimeFmt(date) {
  return date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
}

function mgDraw() {
  if (!mgOpen()) return;
  const d = MG.data;
  if (MG.error || !d) {
    mgSection.innerHTML = mgFiltersHtml() + `<div class="mg-msg" id="mg-error">${escapeHtml(MG.error || "")}</div>`;
    return;
  }
  const clipped = d.from !== mgRange()[0];
  const openDetails = mgSection.querySelector("details.mg-details[open]") !== null;
  mgSection.innerHTML = `
    ${mgFiltersHtml()}
    <p class="mg-small mg-muted"><span id="mg-range">${escapeHtml(mgDayLong(d.from))}${d.from !== d.to ? " – " + escapeHtml(mgDayLong(d.to)) : ""}</span>${clipped ? T(" (นับตั้งแต่วันเริ่มนับ)", " (counting starts on this date)") : ""} · <span id="mg-updated"></span></p>
    ${mgTilesHtml(d)}
    ${mgChartsHtml(d)}
    ${mgOpenHtml(d)}
    ${mgClientsHtml(d)}
    ${mgSalesHtml(d)}
    ${mgNoteHtml(d)}`;
  if (openDetails) mgSection.querySelector("details.mg-details").open = true;
  mgDrawUpdated();
}


// ----------------------------------------------------------- events
mgSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "preset") {
    MG.preset = b.dataset.preset;
    MG.sig = "";
    mgDraw();
    await mgLoad();
  } else if (act === "lang") {
    weighSetLang(b.dataset.lang);
    mgDraw();
  } else if (act === "more") {
    MG.showAllClients = !MG.showAllClients;
    mgDraw();
  } else if (act === "go") {
    if (b.dataset.view === "weights") paceWeightsDept = "Accounting";
    await switchPaceView(b.dataset.view);
  } else if (act === "save-start") {
    const v = document.getElementById("mg-count-from").value;
    if (!v) return;
    MG.saving = true;
    const { error } = await sb.rpc("management_set_count_from", { p_date: v });
    MG.saving = false;
    document.activeElement && document.activeElement.blur();
    if (error) { MG.error = T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message; MG.data = null; mgDraw(); return; }
    MG.sig = "";
    await mgLoad();
  }
});

mgSection.addEventListener("change", async e => {
  if (e.target.id === "mg-company") {
    MG.company = e.target.value;
    MG.sig = "";
    await mgLoad();
  }
});
