// ============================================================================
// Management › Weekly report — PROSUN PACE (Migration 051, 27 Nov 2026)
// ============================================================================
// Clément: "a weekly report with graphs" for him and Khun Jum, ready on Monday
// at 06:00. Admin only. Every number comes from weekly_report(week); the rules
// are in the migration's header.
//
//   - A finished week is the report saved on Monday 06:00 (or built the first
//     time it is opened). It does not move afterwards; "Rebuild with today's
//     data" recomputes it on purpose (the comment stays).
//   - The week in progress is computed live and not saved.
//   - Charts: Chart.js (index.html). Without it the page still shows every
//     figure in the tables.
//   - "Download PDF": jsPDF with the Sarabun fonts of app.js, charts as images.
//
// Loaded after management.js (mgN, mgKg, mgTile), weighing-common.js / weighing.js
// (T, WEIGH_LANG, weighLangHtml, weighSetLang). Uses app.js globals at run time
// (sb, escapeHtml, switchPaceView, SARABUN_*_BASE64, LOGO_BASE64).
// ============================================================================

const wrSection = document.getElementById("weekly-section");

const WR = {
  week: null,            // Monday (ISO date) asked for; null = last finished week
  data: null,            // weekly_report() result
  error: null,
  msg: null,             // { kind: "ok" | "err", text }
  busy: false,
  confirmRebuild: false,
  charts: [],
  sig: "",
};

// Brand colours (Klong Phai Farm) and two quiet greys.
const WR_C = { green: "#1f3d2a", gold: "#b59767", brown: "#241905", red: "#a8262c", amber: "#c9892b", grey: "#b4b2a9", grid: "#e8e1d2", tick: "#7a7468" };


// ----------------------------------------------------------- open / close
async function openWeekly(week) {
  if (!WEIGH_LANG) WEIGH_LANG = "en";
  if (week) WR.week = week;
  wrSection.classList.remove("hidden");
  if (!WR.data) wrSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  WR.sig = "";
  await wrLoad();
}

function closeWeekly() {
  if (wrSection.classList.contains("hidden")) return;
  wrDestroyCharts();
  wrSection.classList.add("hidden");
  wrSection.innerHTML = "";
  WR.msg = null;
  WR.confirmRebuild = false;
}

function wrOpen() { return !wrSection.classList.contains("hidden"); }

async function wrLoad() {
  const asked = WR.week;
  const { data, error } = await sb.rpc("weekly_report", { p_week: asked });
  if (!wrOpen() || asked !== WR.week) return;
  if (error) {
    const missing = /weekly_report|schema cache|does not exist/i.test(error.message || "");
    WR.error = missing
      ? T("ยังไม่พบรายงานประจำสัปดาห์: กรุณารัน Migration 051 ใน Supabase", "The Weekly report's database function is missing: run Migration 051 in Supabase.")
      : T("โหลดรายงานไม่สำเร็จ: ", "Could not load the Weekly report: ") + error.message;
    WR.data = null; WR.sig = "";
    wrDraw();
    return;
  }
  WR.error = null;
  WR.data = data;
  const sig = JSON.stringify(data) + WEIGH_LANG;
  if (sig !== WR.sig) { WR.sig = sig; wrDraw(); }
}


// ----------------------------------------------------------- formatting
function wrBaht(n) { return mgN(Math.round(Number(n || 0))); }
function wrK(n) { const v = Number(n || 0); return Math.abs(v) >= 1e6 ? mgN(v / 1e6, 2) + "M" : mgN(v / 1e3, 0) + "k"; }
function wrPct(a, b) { const d = Number(b || 0); return d > 0 ? Math.round(Number(a || 0) / d * 100) : null; }
function wrDelta(a, b) {
  const d = Number(b || 0);
  if (!d) return null;
  return (Number(a || 0) / d - 1) * 100;
}
function wrSigned(p) { return p === null ? "—" : (p >= 0 ? "▲ " : "▼ ") + Math.abs(Math.round(p)) + "%"; }
function wrDate(iso, opts) {
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    Object.assign({ timeZone: "UTC" }, opts || { day: "numeric", month: "short" }));
}
function wrStamp(ts) {
  return new Date(ts).toLocaleString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
}
function wrAddDays(iso, n) { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
function wrWeekLabel(ws, iso) {
  return `${T("สัปดาห์", "Week")} ${iso} · ${wrDate(ws)} – ${wrDate(wrAddDays(ws, 5), { day: "numeric", month: "short", year: "numeric" })}`;
}
function wrIsoWeek(iso) {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 3 - ((d.getUTCDay() + 6) % 7));
  const y = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  return 1 + Math.round(((d - y) / 86400000 - 3 + ((y.getUTCDay() + 6) % 7)) / 7);
}
function wrReason(code) {
  if (typeof ppReasonLabel === "function") return ppReasonLabel(code);
  return ({ production: T("ผลิตไม่ทัน", "Lack from production"), raw_material: T("สินค้าไม่พอ", "Not enough product"),
            delivery: T("ส่งไม่ทันเวลา", "Missed the delivery time"), client: T("ลูกค้าขอเลื่อน", "Client request") })[code] || T("อื่นๆ", "Other");
}
function wrRatio(r) { return r && r.d > 0 && r.pct !== null && r.pct !== undefined ? `${mgN(r.pct, 0)}%` : "—"; }
function wrRatioTitle(r) { return r && r.d > 0 ? `${mgN(r.n)} / ${mgN(r.d)}` : ""; }


// ----------------------------------------------------------- pieces
function wrHeaderHtml(r) {
  const weeks = (r && r.weeks) || [];
  const ws = r ? r.week_start : null;
  const idx = weeks.findIndex(w => w.week_start === ws);
  const newer = idx > 0 ? weeks[idx - 1].week_start : null;
  const older = idx >= 0 && idx < weeks.length - 1 ? weeks[idx + 1].week_start : null;
  const options = weeks.map(w => `<option value="${w.week_start}" ${w.week_start === ws ? "selected" : ""}>${escapeHtml(
    wrWeekLabel(w.week_start, wrIsoWeek(w.week_start)))}${w.week_start === r.current_week ? T(" (กำลังดำเนินการ)", " (in progress)") : ""}</option>`).join("");
  return `<div class="mg-bar">
    <div class="ws-presets wr-nav">
      <button type="button" class="ws-chip" data-act="week" data-week="${older || ""}" ${older ? "" : "disabled"} aria-label="${T("สัปดาห์ก่อน", "Previous week")}">‹</button>
      <select id="wr-week" class="wr-select" aria-label="${T("เลือกสัปดาห์", "Choose a week")}">${options}</select>
      <button type="button" class="ws-chip" data-act="week" data-week="${newer || ""}" ${newer ? "" : "disabled"} aria-label="${T("สัปดาห์ถัดไป", "Next week")}">›</button>
    </div>
    <div class="mg-bar-right">
      ${r && !r.live ? `<button type="button" class="ws-chip ${WR.confirmRebuild ? "wr-confirm" : ""}" data-act="rebuild" ${WR.busy ? "disabled" : ""}>${
        WR.busy ? T("กำลังคำนวณ…", "Rebuilding…") : WR.confirmRebuild ? T("ยืนยัน: คำนวณใหม่ด้วยข้อมูลวันนี้", "Confirm: rebuild with today's data") : T("คำนวณใหม่ด้วยข้อมูลวันนี้", "Rebuild with today's data")}</button>` : ""}
      ${r ? `<button type="button" class="ws-chip" data-act="pdf" id="wr-pdf">${T("ดาวน์โหลด PDF", "Download PDF")}</button>` : ""}
      ${weighLangHtml()}
    </div>
  </div>`;
}

function wrStatusHtml(r) {
  const d = r.data;
  let s;
  if (r.live) s = T("สัปดาห์ที่กำลังดำเนินการ — ตัวเลขสด ยังไม่บันทึก รายงานจะบันทึกวันจันทร์ 06:00",
                    "Week in progress — live figures, not saved. The report is saved on Monday at 06:00.");
  else if (r.built_by) s = T(`คำนวณใหม่โดย ${escapeHtml(r.built_by)} · ${wrStamp(r.built_at)}`, `Rebuilt by ${escapeHtml(r.built_by)} · ${wrStamp(r.built_at)}`);
  else s = T(`บันทึกอัตโนมัติ · ${wrStamp(r.built_at)}`, `Saved automatically · ${wrStamp(r.built_at)}`);
  const sched = r.schedule === "on" ? "" :
    `<div class="wr-note-warn" id="wr-schedule">${T(
      "ยังไม่ได้ตั้งเวลาวันจันทร์ 06:00: เปิด pg_cron ใน Supabase (Database › Extensions) แล้วรัน Migration 051 อีกครั้ง ระหว่างนี้รายงานจะสร้างเมื่อเปิดหน้านี้",
      "The Monday 06:00 schedule is not active: enable pg_cron in Supabase (Database › Extensions) and run Migration 051 again. Until then a week's report is built when this page opens it.")}</div>`;
  return `<p class="mg-small mg-muted" id="wr-status"><strong class="ov-month">${escapeHtml(wrWeekLabel(d.week_start, d.iso_week))}</strong> · ${s}</p>
    ${sched}
    ${WR.msg ? `<div class="${WR.msg.kind === "ok" ? "ov-ok" : "mg-msg"}" id="wr-msg" role="status">${escapeHtml(WR.msg.text)}</div>` : ""}`;
}

function wrPointsHtml(d) {
  const pts = d.points || [];
  const icon = { warn: "⚠", info: "ℹ", good: "✓" };
  const items = pts.map(p => `<li class="wr-pt wr-pt-${p.level}"><span class="wr-pt-i" aria-hidden="true">${icon[p.level] || "•"}</span>${escapeHtml(WEIGH_LANG === "en" ? p.en : p.th)}</li>`).join("");
  return `<section class="mg-card" id="wr-points">
    <div class="mg-card-head"><h3>${T("สิ่งที่ต้องดูสัปดาห์นี้", "To look at this week")}</h3></div>
    ${items ? `<ul class="wr-pts">${items}</ul>` : `<p class="mg-small mg-muted">${T("ไม่มีประเด็นจากกฎที่ตั้งไว้", "Nothing flagged by the rules this week.")}</p>`}
  </section>`;
}

function wrTilesHtml(d) {
  const t = d.top, m = d.mtd || {}, e = d.execution, p = d.purchasing;
  const vsBudget = wrPct(t.value, t.budget);
  const vsPrev = wrDelta(t.value, t.prev_value);
  const t1 = mgTile({ id: "wr-t-value", label: T("มูลค่าสัปดาห์ (ประมาณ ราคาตามลิสต์)", "Week value (estimate, list prices)"),
    value: wrBaht(t.value), unit: "THB",
    state: vsBudget === null ? "" : vsBudget >= 100 ? "good" : vsBudget < 90 ? "alert" : "",
    stateText: vsBudget === null ? "" : T(`${vsBudget}% ของงบสัปดาห์ (${wrBaht(t.budget)})`, `${vsBudget}% of the weekly budget pace (${wrBaht(t.budget)})`),
    sub: T(`${mgN(t.papers)} ใบงานยืนยัน · ${mgKg(t.kg)} กก. · Farm ${wrK(t.farm_value)} · Food ${wrK(t.food_value)}`,
           `${mgN(t.papers)} confirmed papers · ${mgKg(t.kg)} kg · Farm ${wrK(t.farm_value)} · Food ${wrK(t.food_value)}`) });
  const t2 = mgTile({ id: "wr-t-prev", label: T("เทียบสัปดาห์ก่อน", "Against last week"),
    value: wrSigned(vsPrev), state: vsPrev === null ? "" : vsPrev >= 0 ? "good" : "alert",
    sub: T(`สัปดาห์ก่อน ${wrBaht(t.prev_value)} บาท`, `Last week ${wrBaht(t.prev_value)} THB`)
      + (t.avg4_value !== null && t.avg4_value !== undefined ? T(` · เฉลี่ย 4 สัปดาห์ ${wrBaht(t.avg4_value)}`, ` · 4-week average ${wrBaht(t.avg4_value)}`) : "") });
  const reached = wrPct(m.actual, m.budget_to_date);
  const t3 = m.days
    ? mgTile({ id: "wr-t-mtd", label: T("ยอดขายเดือนนี้ (Daily Sales Reporting)", "Month to date (Daily Sales Reporting)"),
        value: wrBaht(m.actual), unit: "THB",
        state: reached === null ? "" : reached >= 100 ? "good" : reached < 95 ? "alert" : "",
        stateText: reached === null ? "" : T(`${reached}% ของงบถึง ${wrDate(m.as_of)}`, `${reached}% of budget to ${wrDate(m.as_of)}`),
        sub: T(`คาดการณ์สิ้นเดือน ${wrBaht(m.projection)} จากงบ ${wrBaht(m.budget_month)}`, `Month-end projection ${wrBaht(m.projection)} of ${wrBaht(m.budget_month)} budget`) })
    : mgTile({ id: "wr-t-mtd", label: T("ยอดขายเดือนนี้ (Daily Sales Reporting)", "Month to date (Daily Sales Reporting)"), value: "—",
        sub: T("ยังไม่ได้อัปโหลดไฟล์ของเดือนนี้ (หน้า Overview)", "This month's workbook is not uploaded yet (Overview page)") });
  const t4 = mgTile({ id: "wr-t-postponed", label: T("ออเดอร์ที่เลื่อน", "Orders postponed"),
    value: mgN(e.postponed), unit: T(`/ ${mgN(e.orders)}`, `of ${mgN(e.orders)}`),
    state: Number(e.internal) > 0 ? "alert" : "good",
    stateText: T(`จากภายใน ${mgN(e.internal)} · ลูกค้าขอ ${mgN(e.client)}`, `${mgN(e.internal)} internal · ${mgN(e.client)} client request`),
    sub: T(`ปัญหาการจัดส่ง ${mgN(e.problems)} · ยังไม่ยืนยัน ${mgN(e.not_confirmed)} ใบ`,
           `${mgN(e.problems)} delivery problem${Number(e.problems) === 1 ? "" : "s"} · ${mgN(e.not_confirmed)} paper${Number(e.not_confirmed) === 1 ? "" : "s"} not confirmed`) });
  const t5 = mgTile({ id: "wr-t-ratio", label: T("ต้นทุนซื้อ ÷ มูลค่าขาย", "Purchase cost ÷ week value"),
    value: p.ratio === null || p.ratio === undefined ? "—" : mgN(p.ratio, 1) + "%",
    state: p.ratio !== null && p.prev_ratio !== null && p.ratio !== undefined && p.prev_ratio !== undefined ? (p.ratio - p.prev_ratio >= 3 ? "alert" : "") : "",
    stateText: p.prev_ratio !== null && p.prev_ratio !== undefined ? T(`สัปดาห์ก่อน ${mgN(p.prev_ratio, 1)}%`, `Last week ${mgN(p.prev_ratio, 1)}%`) : "",
    sub: T(`ซื้อ ${wrBaht(p.cost)} บาท · นกสั่ง ${mgN(p.birds_ordered)} รับ ${mgN(p.birds_received)}${p.estimate ? " · มีประมาณการ" : ""}`,
           `Bought ${wrBaht(p.cost)} THB · birds ordered ${mgN(p.birds_ordered)}, received ${mgN(p.birds_received)}${p.estimate ? " · includes estimates" : ""}`) });
  return `<div class="mg-tiles ov-grid" id="wr-tiles">${t1}${t2}${t3}${t4}${t5}</div>`;
}

function wrChartCard(id, title, legend, height, extra) {
  return `<section class="mg-card" id="${id}-card">
    <div class="mg-card-head"><h3>${title}</h3>${legend ? `<div class="mg-legend">${legend}</div>` : ""}</div>
    <div class="wr-chart" style="height:${height}px"><canvas id="${id}" role="img" aria-label="${escapeHtml(title)}"></canvas></div>
    ${extra || ""}
  </section>`;
}
function wrKey(color, label, dashed) {
  return `<span><i style="background:${dashed ? "transparent" : color};${dashed ? `border-top:2px dashed ${color};height:0;margin-bottom:3px` : ""}"></i>${label}</span>`;
}

function wrChartsHtml(d) {
  const reps = (d.sales.reps || []).filter(r => !r.director);
  return `<div class="mg-charts sm-pair">
      ${wrChartCard("wr-c-days", T("มูลค่าต่อวัน (ประมาณ)", "Value per day (estimate)"),
        wrKey(WR_C.green, T("สัปดาห์นี้", "This week")) + wrKey(WR_C.gold, T("สัปดาห์ก่อน", "Last week"), true), 230)}
      ${wrChartCard("wr-c-trend", T("แนวโน้มรายสัปดาห์เทียบงบ", "Week by week vs budget pace"),
        wrKey(WR_C.green, T("มูลค่าสัปดาห์ (ประมาณ)", "Week value (estimate)")) + wrKey(WR_C.brown, T("งบ conservative", "Conservative budget"), true), 230,
        d.top.trend.length < 4 ? `<p class="mg-small mg-muted">${T(`เริ่มนับตั้งแต่ ${wrDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })} — กราฟจะยาวขึ้นทุกสัปดาห์ (สูงสุด 12 สัปดาห์)`, `PACE counts from ${wrDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })} — the line grows every week (up to 12 weeks).`)}</p>` : "")}
    </div>
    <div class="mg-charts sm-pair">
      ${wrChartCard("wr-c-team", T("ทีมขาย: มูลค่าลูกค้าเทียบเป้าสัปดาห์", "Sales team: clients' value vs weekly target"),
        wrKey(WR_C.green, T("มูลค่าสัปดาห์ (ประมาณ)", "Week value (estimate)")) + wrKey(WR_C.gold, T("เป้าสัปดาห์", "Weekly target")), Math.max(160, reps.length * 46 + 50))}
      ${wrChartCard("wr-c-postp", T("ออเดอร์ที่เลื่อนต่อสัปดาห์", "Postponed orders per week"),
        wrKey(WR_C.red, T("จากภายใน", "Internal")) + wrKey(WR_C.grey, T("ลูกค้าขอ", "Client request")), 230)}
    </div>`;
}

function wrTeamHtml(d) {
  const s = d.sales || {};
  if (s.error) return `<section class="mg-card"><div class="mg-msg">${escapeHtml(T("โหลด KPI ทีมขายไม่สำเร็จ: ", "Sales KPIs could not be read: ") + s.error)}</div></section>`;
  const rows = (s.reps || []).map(r => {
    const pct = wrPct(r.value, r.target_week);
    return `<tr>
      <td><strong>${escapeHtml(r.name)}</strong> <small class="mg-muted">${escapeHtml(r.code)}${r.director ? T(" · ผอ.ฝ่ายขาย", " · director") : ""}</small></td>
      <td class="mg-n mg-strong">${wrBaht(r.value)}</td>
      <td class="mg-n">${r.target_week === null || r.target_week === undefined ? "—" : wrBaht(r.target_week)}</td>
      <td class="mg-n ${pct !== null && pct < 80 ? "ov-warn" : ""}">${pct === null ? "—" : pct + "%"}</td>
      <td class="mg-n ${!r.director && Number(r.calls || 0) === 0 ? "ov-warn" : ""}">${mgN(r.calls)}</td>
      <td class="mg-n" title="${wrRatioTitle(r.coverage)}">${wrRatio(r.coverage)}</td>
      <td class="mg-n" title="${wrRatioTitle(r.call_to_order)}">${wrRatio(r.call_to_order)}</td>
      <td class="mg-n">${mgN(r.reactivated)}</td>
      <td class="mg-n" title="${wrRatioTitle(r.active30)}">${wrRatio(r.active30)}</td>
      <td class="mg-n" title="${wrRatioTitle(r.call_now)}">${r.call_now ? mgN(r.call_now.n) : "—"}</td>
      <td class="mg-n" title="${wrRatioTitle(r.at_risk)}">${r.at_risk ? mgN(r.at_risk.n) : "—"}</td>
      <td class="mg-n" title="${wrRatioTitle(r.lost)}">${r.lost ? mgN(r.lost.n) : "—"}</td>
      <td class="mg-n" title="${wrRatioTitle(r.target_ytd)}">${wrRatio(r.target_ytd)}</td>
    </tr>`;
  }).join("");
  const other = Number(s.house_value || 0) + Number(s.unlinked_value || 0);
  return `<section class="mg-card" id="wr-team">
    <div class="mg-card-head"><h3>${T("ทีมขาย — สัปดาห์นี้", "Sales team — this week")}</h3>
      <button type="button" class="mg-go" data-act="go" data-view="mg-sales-kpis">${T("เปิด Sales KPIs ›", "Open Sales KPIs ›")}</button></div>
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("พนักงานขาย", "Salesperson")}</th>
      <th class="mg-n">${T("มูลค่าสัปดาห์", "Week value")}</th>
      <th class="mg-n">${T("เป้าสัปดาห์", "Weekly target")}</th>
      <th class="mg-n">%</th>
      <th class="mg-n">${T("โทร", "Calls")}</th>
      <th class="mg-n" title="${T("ลูกค้าโทรเลย ที่โทรใน 7 วัน", "Call-now clients called within 7 days")}">${T("โทรเลย ที่โทรแล้ว", "Call-now called")}</th>
      <th class="mg-n" title="${T("การโทรที่ตามด้วยออเดอร์ใน 7 วัน", "Calls followed by an order within 7 days")}">${T("โทร → ออเดอร์", "Call → order")}</th>
      <th class="mg-n">${T("กลับมาสั่ง", "Reactivated")}</th>
      <th class="mg-n">${T("Active 30 วัน", "Active 30 d")}</th>
      <th class="mg-n">${T("โทรเลย", "Call now")}</th>
      <th class="mg-n">${T("เสี่ยง", "At risk")}</th>
      <th class="mg-n">${T("หาย", "Lost")}</th>
      <th class="mg-n">${T("เป้าสะสม", "Target YTD")}</th>
    </tr></thead><tbody>${rows}
      <tr class="mg-flag"><td>${T("House / ไม่ได้เชื่อม", "House / not linked")}</td><td class="mg-n mg-strong">${wrBaht(other)}</td>
        <td class="mg-n" colspan="11"><small class="mg-muted">${T(`ไม่ได้เชื่อมกับรหัสลูกค้า ${mgN(s.unlinked_papers)} ใบงาน (${wrBaht(s.unlinked_value)} บาท)`, `${mgN(s.unlinked_papers)} papers not linked to a client code (${wrBaht(s.unlinked_value)} THB)`)}</small></td></tr>
    </tbody></table></div>
    <p class="mg-small mg-muted" style="margin-top:10px">${T(
      "มูลค่าสัปดาห์ = ใบงานยืนยันของลูกค้าแต่ละคน × ราคาลิสต์ (ประมาณ) · เป้าสัปดาห์ = เป้ารายไตรมาส แบ่งตามงบ Prosun Farm ÷ วันทำงาน × 6 · สถานะลูกค้าและเป้าสะสมจาก Sales KPIs ณ วันที่บันทึกรายงาน",
      "Week value = the client's confirmed papers × list price (estimate) · Weekly target = quarterly target split by the Prosun Farm budget ÷ working days × 6 · Client status and target year to date from Sales KPIs on the day the report was saved.")}</p>
  </section>`;
}

function wrClientsHtml(d) {
  const c = d.clients || {};
  const top = (c.top || []).map(x => {
    const delta = x.usual ? wrDelta(x.value, x.usual) : null;
    return `<tr><td>${escapeHtml(x.name)}</td><td class="mg-n mg-strong">${wrBaht(x.value)}</td>
      <td class="mg-n">${x.usual === null || x.usual === undefined ? "—" : wrBaht(x.usual)}</td>
      <td class="mg-n ${delta !== null && delta < -20 ? "ov-warn" : delta !== null && delta > 20 ? "ov-good" : ""}">${delta === null ? "—" : wrSigned(delta)}</td></tr>`;
  }).join("");
  const silent = (c.silent_list || []).map(s => `<tr><td>${escapeHtml(s.name)}</td><td class="mg-n">${T(`${s.days_silent} วัน`, `${s.days_silent} days`)}</td><td class="mg-n">${mgN(s.papers_60)}</td></tr>`).join("");
  const drops = (c.drops || []).map(x => `<tr><td>${escapeHtml(x.name)}</td><td class="mg-n">${wrBaht(x.value)}</td><td class="mg-n">${wrBaht(x.usual)}</td></tr>`).join("");
  const counts = T(
    `สั่งสัปดาห์นี้ <strong>${mgN(c.ordering)}</strong> ราย (สัปดาห์ก่อน ${mgN(c.prev_ordering)})` + (c.new !== null && c.new !== undefined ? ` · ใหม่ <strong>${mgN(c.new)}</strong> · กลับมา ${mgN(c.back)}` : "") + ` · เงียบ 14–90 วัน <strong>${mgN(c.silent)}</strong>`,
    `<strong>${mgN(c.ordering)}</strong> clients ordered (last week ${mgN(c.prev_ordering)})` + (c.new !== null && c.new !== undefined ? ` · <strong>${mgN(c.new)}</strong> new · ${mgN(c.back)} back after 4+ weeks` : "") + ` · <strong>${mgN(c.silent)}</strong> silent 14–90 days`);
  return `<div class="mg-charts sm-pair">
    <section class="mg-card" id="wr-clients">
      <div class="mg-card-head"><h3>${T("ลูกค้าหลักของสัปดาห์", "Biggest clients this week")}</h3></div>
      <p class="mg-small">${counts}</p>
      ${top ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th class="mg-n">${T("สัปดาห์นี้", "This week")}</th>
        <th class="mg-n">${T("ปกติ (เฉลี่ย 4 สัปดาห์)", "Usual (4-week avg)")}</th><th class="mg-n">${T("ต่าง", "Change")}</th></tr></thead><tbody>${top}</tbody></table></div>`
        : `<p class="mg-small mg-muted">${T("ไม่มีใบงานยืนยัน", "No confirmed paper this week.")}</p>`}
      ${c.new_list && c.new_list.length ? `<p class="mg-small" style="margin-top:8px"><strong>${T("ลูกค้าใหม่", "New clients")}:</strong> ${c.new_list.map(escapeHtml).join(", ")}</p>` : ""}
    </section>
    <section class="mg-card" id="wr-watch">
      <div class="mg-card-head"><h3>${T("ต้องติดตาม", "To follow up")}</h3>
        <button type="button" class="mg-go" data-act="go" data-view="sales-clients">${T("เปิดลูกค้า ›", "Open Clients ›")}</button></div>
      ${drops ? `<p class="mg-small"><strong>${T("สั่งน้อยกว่าครึ่งของปกติ", "Under half their usual week")}</strong></p>
        <div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th class="mg-n">${T("สัปดาห์นี้", "This week")}</th><th class="mg-n">${T("ปกติ", "Usual")}</th></tr></thead><tbody>${drops}</tbody></table></div>`
        : c.drops === null || c.drops === undefined ? `<p class="mg-small mg-muted">${T("การเทียบกับสัปดาห์ปกติเริ่มเมื่อมีข้อมูลครบ 4 สัปดาห์", "Comparison with the usual week starts once PACE has 4 weeks of history.")}</p>` : ""}
      <p class="mg-small" style="margin-top:8px"><strong>${T("เงียบ 14–90 วัน", "Silent 14–90 days")}</strong></p>
      ${silent ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr><th>${T("ลูกค้า", "Client")}</th><th class="mg-n">${T("สั่งล่าสุด", "Last order")}</th><th class="mg-n">${T("ออเดอร์ 60 วัน", "Orders, 60 d")}</th></tr></thead><tbody>${silent}</tbody></table></div>`
        : `<p class="mg-small mg-muted">${T("ไม่มี", "None.")}</p>`}
    </section>
  </div>`;
}

function wrExecutionHtml(d) {
  const e = d.execution || {};
  const rs = e.reasons || [];
  const max = Math.max(1, ...rs.map(r => Number(r.n)));
  const bars = rs.map(r => `<span>${escapeHtml(wrReason(r.reason))}</span>
      <span class="ov-hbar"><span style="width:${(Number(r.n) / max) * 100}%"></span></span><span class="mg-n mg-strong">${mgN(r.n)}</span>`).join("");
  const probs = (e.problem_notes || []).map(p => `<li><strong>${escapeHtml(p.client)}</strong> · ${escapeHtml(wrDate(p.delivery_date))} — ${escapeHtml(p.note || "")}</li>`).join("");
  const okPct = wrPct(e.lines_ok, e.lines);
  return `<div class="mg-charts sm-pair">
    <section class="mg-card" id="wr-exec">
      <div class="mg-card-head"><h3>${T("การส่งมอบ", "Execution")}</h3>
        <button type="button" class="mg-go" data-act="go" data-view="postponed">${T("ออเดอร์ที่เลื่อน ›", "Postponed orders ›")}</button></div>
      ${bars ? `<div class="ov-hbars">${bars}</div>` : `<p class="mg-small mg-muted">${T("ไม่มีการเลื่อนสัปดาห์นี้", "No postponement this week.")}</p>`}
      ${probs ? `<p class="mg-small" style="margin-top:10px"><strong>${T("ปัญหาการจัดส่ง", "Delivery problems")}</strong></p><ul class="wr-list mg-small">${probs}</ul>` : ""}
      <p class="mg-small" style="margin-top:10px">${T(
        `น้ำหนักภายใน ±5%: <strong>${okPct === null ? "—" : okPct + "%"}</strong> ของ ${mgN(e.lines)} รายการ · ให้เกิน +5%: <strong>${mgKg(e.give_kg)} กก.</strong> (≈ ${wrBaht(e.give_value)} บาท)`,
        `Weight within ±5%: <strong>${okPct === null ? "—" : okPct + "%"}</strong> of ${mgN(e.lines)} lines · given over +5%: <strong>${mgKg(e.give_kg)} kg</strong> (≈ ${wrBaht(e.give_value)} THB)`)}</p>
    </section>
    <section class="mg-card" id="wr-comment-card">
      <div class="mg-card-head"><h3>${T("ความเห็นของผู้บริหาร", "Management comment")}</h3>
        ${WR.data.comment_at ? `<span class="mg-small mg-muted">${escapeHtml(WR.data.comment_by || "")} · ${wrStamp(WR.data.comment_at)}</span>` : ""}</div>
      ${WR.data.live
        ? `<p class="mg-small mg-muted">${T("เขียนความเห็นได้เมื่อรายงานของสัปดาห์นี้บันทึกแล้ว (วันจันทร์)", "A comment can be written once this week's report is saved (Monday).")}</p>`
        : `<textarea id="wr-comment" class="wr-comment" maxlength="4000" rows="6" placeholder="${T("สรุป การตัดสินใจ สิ่งที่ต้องทำสัปดาห์หน้า…", "Summary, decisions, actions for next week…")}">${escapeHtml(WR.data.comment || "")}</textarea>
           <div class="wr-row"><button type="button" class="btn-primary" data-act="comment" ${WR.busy ? "disabled" : ""}>${T("บันทึกความเห็น", "Save comment")}</button></div>`}
    </section>
  </div>`;
}

function wrNoteHtml(d) {
  return `<details class="mg-card mg-small mg-muted" id="wr-note"><summary>${T("ตัวเลขมาจากไหน", "Where the figures come from")}</summary>${T(
    `<p>มูลค่าสัปดาห์ = ใบงานที่ยืนยันน้ำหนักแล้ว × ราคาลิสต์ (โรงแรม/ร้านอาหาร และ Under Roof) ตามวันผลิต เป็นค่าประมาณ ไม่หักส่วนลด และสินค้าแปรรูปของ Prosun Food ยังไม่มีราคา จึงเทียบระหว่างสัปดาห์ได้ดีกว่าเทียบกับงบ</p>
     <p>งบสัปดาห์ = งบ conservative ของเดือน ÷ วันทำงานของเดือน × วันจันทร์–เสาร์ ยอดขายเดือนนี้มาจากไฟล์ Daily Sales Reporting ที่อัปโหลดล่าสุดในหน้า Overview (ยอดจริง)</p>
     <p>การเลื่อนนับตามวันส่งที่พลาด ต้นทุนซื้อ = สินค้า + ค่าขนส่งของนกที่มาถึงในสัปดาห์ ข้อมูลนับตั้งแต่ ${wrDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })} ออเดอร์ที่ยังไม่ถึงฝ่ายผลิตจะเห็นเมื่อสมุดออเดอร์ย้ายมา PACE</p>`,
    `<p>Week value = confirmed working papers × list price (hotel / restaurant, Under Roof), on the production day. An estimate: discounts are not taken off and Prosun Food's prepared products have no price yet, so it compares weeks better than it compares with the budget.</p>
     <p>Weekly budget pace = the month's conservative budget ÷ its working days × the Monday–Saturday days. Month to date is the exact figure from the Daily Sales Reporting last uploaded on the Overview page.</p>
     <p>Postponements are counted on the delivery date missed. Purchase cost = goods + freight of the birds arriving in the week. PACE counts from ${wrDate(d.count_from, { day: "numeric", month: "short", year: "numeric" })}; orders that never reached production appear once the order book is in PACE.</p>`)}</details>`;
}


// ----------------------------------------------------------- charts
function wrDestroyCharts() {
  WR.charts.forEach(c => { try { c.destroy(); } catch (e) { /* already gone */ } });
  WR.charts = [];
}

function wrDrawCharts(d) {
  wrDestroyCharts();
  if (typeof Chart === "undefined") {
    wrSection.querySelectorAll(".wr-chart").forEach(el => {
      el.innerHTML = `<p class="mg-small mg-muted">${T("โหลดกราฟไม่ได้ (ไม่มีอินเทอร์เน็ต?) ตัวเลขทั้งหมดอยู่ในตาราง", "Charts could not load (offline?). Every figure is in the tables.")}</p>`;
      el.style.height = "auto";
    });
    return;
  }
  const font = { family: getComputedStyle(document.body).fontFamily, size: 11 };
  const axis = (fmt, stacked) => ({
    stacked: !!stacked, beginAtZero: true, grid: { color: WR_C.grid }, border: { display: false },
    ticks: { color: WR_C.tick, font, callback: fmt, maxTicksLimit: 5 } });
  const xAxis = stacked => ({ stacked: !!stacked, grid: { display: false }, ticks: { color: WR_C.tick, font, autoSkip: false, maxRotation: 0 } });
  const base = { responsive: true, maintainAspectRatio: false, animation: false, plugins: { legend: { display: false },
    tooltip: { callbacks: { label: c => `${c.dataset.label}: ${mgN(Math.round(c.parsed.y ?? c.parsed.x))}` } } } };
  const money = v => wrK(v);

  // 1. Value per day
  const days = d.top.days || [];
  const c1 = document.getElementById("wr-c-days");
  if (c1) WR.charts.push(new Chart(c1, {
    data: {
      labels: days.map(x => wrDate(x.day, { weekday: "short", day: "numeric" })),
      datasets: [
        { type: "bar", label: T("สัปดาห์นี้", "This week"), data: days.map(x => Math.round(x.value)), backgroundColor: WR_C.green, borderRadius: 4, maxBarThickness: 26, order: 2 },
        { type: "line", label: T("สัปดาห์ก่อน", "Last week"), data: days.map(x => Math.round(x.prev_value)), borderColor: WR_C.gold, borderDash: [5, 4], borderWidth: 2, pointRadius: 3, pointBackgroundColor: WR_C.gold, order: 1 },
      ] },
    options: { ...base, scales: { x: xAxis(), y: axis(money) } } }));

  // 2. Trend vs budget
  const tr = d.top.trend || [];
  const c2 = document.getElementById("wr-c-trend");
  if (c2) WR.charts.push(new Chart(c2, {
    type: "line",
    data: {
      labels: tr.map(x => T("ส.", "W") + wrIsoWeek(x.week)),
      datasets: [
        { label: T("มูลค่าสัปดาห์", "Week value"), data: tr.map(x => Math.round(x.value)), borderColor: WR_C.green, backgroundColor: "rgba(31,61,42,0.08)", fill: true, borderWidth: 2, pointRadius: 3, pointBackgroundColor: WR_C.green, tension: 0.25 },
        { label: T("งบ", "Budget"), data: tr.map(x => Math.round(x.budget)), borderColor: WR_C.brown, borderDash: [5, 4], borderWidth: 2, pointRadius: 0, stepped: "middle" },
      ] },
    options: { ...base, scales: { x: xAxis(), y: axis(money) } } }));

  // 3. Sales team vs weekly target (horizontal)
  const reps = (d.sales.reps || []).filter(r => !r.director);
  const c3 = document.getElementById("wr-c-team");
  if (c3) WR.charts.push(new Chart(c3, {
    type: "bar",
    data: {
      labels: reps.map(r => r.name),
      datasets: [
        { label: T("มูลค่าสัปดาห์", "Week value"), data: reps.map(r => Math.round(r.value)), backgroundColor: WR_C.green, borderRadius: 4, maxBarThickness: 16 },
        { label: T("เป้าสัปดาห์", "Weekly target"), data: reps.map(r => Math.round(r.target_week || 0)), backgroundColor: WR_C.gold, borderRadius: 4, maxBarThickness: 16 },
      ] },
    options: { ...base, indexAxis: "y",
      plugins: { ...base.plugins, tooltip: { callbacks: { label: c => `${c.dataset.label}: ${mgN(Math.round(c.parsed.x))}` } } },
      scales: { y: { grid: { display: false }, ticks: { color: WR_C.tick, font } }, x: axis(money) } } }));

  // 4. Postponements per week (stacked)
  const se = (d.execution && d.execution.series) || [];
  const c4 = document.getElementById("wr-c-postp");
  if (c4) WR.charts.push(new Chart(c4, {
    type: "bar",
    data: {
      labels: se.map(x => T("ส.", "W") + wrIsoWeek(x.week)),
      datasets: [
        { label: T("จากภายใน", "Internal"), data: se.map(x => x.internal), backgroundColor: WR_C.red, maxBarThickness: 26 },
        { label: T("ลูกค้าขอ", "Client request"), data: se.map(x => x.client), backgroundColor: WR_C.grey, borderRadius: 4, maxBarThickness: 26 },
      ] },
    options: { ...base, plugins: { ...base.plugins, tooltip: { callbacks: {
        label: c => `${c.dataset.label}: ${c.parsed.y}`,
        footer: items => { const x = se[items[0].dataIndex]; return x ? T(`ออเดอร์ ${x.orders}`, `${x.orders} orders`) : ""; } } } },
      scales: { x: xAxis(true), y: axis(v => Number.isInteger(v) ? v : null, true) } } }));
}


// ----------------------------------------------------------- draw
function wrDraw() {
  if (!wrOpen()) return;
  const r = WR.data;
  if (WR.error || !r) {
    wrDestroyCharts();
    wrSection.innerHTML = (r ? wrHeaderHtml(r) : `<div class="mg-bar"><div class="mg-bar-right">${weighLangHtml()}</div></div>`)
      + (WR.error ? `<div class="mg-msg" id="wr-error">${escapeHtml(WR.error)}</div>` : "");
    return;
  }
  const d = r.data;
  wrSection.innerHTML = `
    ${wrHeaderHtml(r)}
    ${wrStatusHtml(r)}
    ${wrPointsHtml(d)}
    ${wrTilesHtml(d)}
    ${wrChartsHtml(d)}
    ${wrTeamHtml(d)}
    ${wrClientsHtml(d)}
    ${wrExecutionHtml(d)}
    ${wrNoteHtml(d)}`;
  wrDrawCharts(d);
}


// ----------------------------------------------------------- actions
async function wrRebuild() {
  if (!WR.data || WR.data.live) return;
  if (!WR.confirmRebuild) {
    WR.confirmRebuild = true; wrDraw();
    setTimeout(() => { if (WR.confirmRebuild && !WR.busy) { WR.confirmRebuild = false; wrDraw(); } }, 6000);
    return;
  }
  WR.busy = true; WR.confirmRebuild = false; wrDraw();
  const { data, error } = await sb.rpc("weekly_report_rebuild", { p_week: WR.data.week_start });
  WR.busy = false;
  if (error) WR.msg = { kind: "err", text: T("คำนวณใหม่ไม่สำเร็จ: ", "Could not rebuild: ") + error.message };
  else { WR.data = data; WR.msg = { kind: "ok", text: T("คำนวณใหม่และบันทึกแล้ว ความเห็นยังอยู่", "Rebuilt and saved with today's data. The comment is kept.") }; }
  WR.sig = "";
  wrDraw();
}

async function wrSaveComment() {
  const ta = document.getElementById("wr-comment");
  if (!ta || !WR.data) return;
  WR.busy = true;
  const { data, error } = await sb.rpc("weekly_report_comment", { p_week: WR.data.week_start, p_comment: ta.value });
  WR.busy = false;
  if (error) WR.msg = { kind: "err", text: T("บันทึกความเห็นไม่สำเร็จ: ", "Could not save the comment: ") + error.message };
  else {
    Object.assign(WR.data, data);
    WR.msg = { kind: "ok", text: T("บันทึกความเห็นแล้ว", "Comment saved.") };
  }
  wrDraw();
}

// PDF: the same figures, charts as images. Thai needs the Sarabun fonts (app.js).
function wrPdf() {
  const r = WR.data;
  if (!r || !window.jspdf) { WR.msg = { kind: "err", text: T("สร้าง PDF ไม่ได้ (โหลด jsPDF ไม่สำเร็จ)", "The PDF could not be made (jsPDF did not load).") }; wrDraw(); return; }
  const d = r.data, t = d.top, m = d.mtd || {}, e = d.execution, p = d.purchasing;
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  let font = "helvetica";
  try {
    doc.addFileToVFS("Sarabun-Regular.ttf", SARABUN_REGULAR_BASE64); doc.addFont("Sarabun-Regular.ttf", "Sarabun", "normal");
    doc.addFileToVFS("Sarabun-Bold.ttf", SARABUN_BOLD_BASE64); doc.addFont("Sarabun-Bold.ttf", "Sarabun", "bold");
    font = "Sarabun";
  } catch (err) { /* fonts missing: English only renders */ }
  const W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight(), M = 40;
  let y = M;
  const need = h => { if (y + h > H - M) { doc.addPage(); y = M; } };
  const text = (s, size, bold, color) => {
    doc.setFont(font, bold ? "bold" : "normal"); doc.setFontSize(size); doc.setTextColor(color || "#241905");
    const lines = doc.splitTextToSize(String(s), W - 2 * M);
    need(lines.length * size * 1.3);
    doc.text(lines, M, y + size); y += lines.length * size * 1.3;
  };
  try { if (typeof LOGO_BASE64 !== "undefined") doc.addImage(LOGO_BASE64, "PNG", W - M - 46, M - 6, 46, 46); } catch (err) { /* no logo */ }
  text("PROSUN PACE — " + T("รายงานประจำสัปดาห์", "Weekly report"), 16, true, "#1f3d2a");
  text(wrWeekLabel(d.week_start, d.iso_week), 11, false);
  text(r.live ? T("สัปดาห์ที่กำลังดำเนินการ — ยังไม่บันทึก", "Week in progress — not saved")
              : (r.built_by ? T(`คำนวณใหม่โดย ${r.built_by} · `, `Rebuilt by ${r.built_by} · `) : T("บันทึกอัตโนมัติ · ", "Saved automatically · ")) + wrStamp(r.built_at), 9, false, "#7a7468");
  y += 8;
  const vsB = wrPct(t.value, t.budget), vsP = wrDelta(t.value, t.prev_value), reached = wrPct(m.actual, m.budget_to_date);
  const rows = [
    [T("มูลค่าสัปดาห์ (ประมาณ)", "Week value (estimate)"), `${wrBaht(t.value)} THB`, vsB === null ? "" : T(`${vsB}% ของงบสัปดาห์`, `${vsB}% of weekly budget pace`)],
    [T("เทียบสัปดาห์ก่อน", "Against last week"), wrSigned(vsP), `${wrBaht(t.prev_value)} THB`],
    [T("ยอดขายเดือนนี้ (Daily Sales)", "Month to date (Daily Sales)"), m.days ? `${wrBaht(m.actual)} THB` : "—",
      m.days ? T(`${reached}% ของงบ · คาดการณ์ ${wrBaht(m.projection)}`, `${reached}% of budget · projection ${wrBaht(m.projection)}`) : ""],
    [T("ออเดอร์ที่เลื่อน", "Orders postponed"), `${mgN(e.postponed)} / ${mgN(e.orders)}`, T(`ภายใน ${e.internal} · ลูกค้า ${e.client} · ปัญหาส่ง ${e.problems}`, `${e.internal} internal · ${e.client} client · ${e.problems} delivery problems`)],
    [T("ต้นทุนซื้อ ÷ มูลค่า", "Purchase cost ÷ value"), p.ratio === null || p.ratio === undefined ? "—" : `${mgN(p.ratio, 1)}%`, p.prev_ratio === null || p.prev_ratio === undefined ? "" : T(`สัปดาห์ก่อน ${mgN(p.prev_ratio, 1)}%`, `last week ${mgN(p.prev_ratio, 1)}%`)],
  ];
  const tableStyle = { font, fontSize: 9, cellPadding: 4, textColor: "#241905" };
  const headStyle = { fillColor: [31, 61, 42], textColor: 255, font, fontStyle: "bold" };
  if (doc.autoTable) {
    doc.autoTable({ startY: y, head: [[T("ตัวชี้วัด", "Figure"), T("ค่า", "Value"), ""]], body: rows, margin: { left: M, right: M }, styles: tableStyle, headStyles: headStyle });
    y = doc.lastAutoTable.finalY + 14;
  }
  text(T("สิ่งที่ต้องดูสัปดาห์นี้", "To look at this week"), 12, true, "#1f3d2a");
  (d.points || []).forEach(pt => text(`${pt.level === "warn" ? "!" : pt.level === "good" ? "+" : "i"}  ${WEIGH_LANG === "en" ? pt.en : pt.th}`, 9.5, false));
  y += 8;
  const charts = [["wr-c-days", T("มูลค่าต่อวัน", "Value per day")], ["wr-c-trend", T("แนวโน้มรายสัปดาห์เทียบงบ", "Week by week vs budget")],
                  ["wr-c-team", T("ทีมขายเทียบเป้า", "Sales team vs target")], ["wr-c-postp", T("ออเดอร์ที่เลื่อนต่อสัปดาห์", "Postponed orders per week")]];
  const cw = (W - 2 * M - 16) / 2;
  for (let i = 0; i < charts.length; i += 2) {
    need(cw * 0.62 + 20);
    charts.slice(i, i + 2).forEach(([id, title], j) => {
      const cv = document.getElementById(id);
      const x = M + j * (cw + 16);
      doc.setFont(font, "bold"); doc.setFontSize(9.5); doc.setTextColor("#241905"); doc.text(title, x, y + 10);
      if (cv && cv.width) {
        const h = Math.min(cw * 0.6, cw * cv.height / cv.width);
        try { doc.addImage(cv.toDataURL("image/png"), "PNG", x, y + 16, cw, h); } catch (err) { /* chart missing */ }
      }
    });
    y += cw * 0.62 + 24;
  }
  if (doc.autoTable) {
    need(80);
    text(T("ทีมขาย — สัปดาห์นี้", "Sales team — this week"), 12, true, "#1f3d2a");
    doc.autoTable({ startY: y,
      head: [[T("พนักงานขาย", "Salesperson"), T("มูลค่า", "Value"), T("เป้า", "Target"), "%", T("โทร", "Calls"), T("โทรเลย โทรแล้ว", "Call-now called"), T("โทร→ออเดอร์", "Call→order"), T("กลับมาสั่ง", "Reactivated"), T("เป้าสะสม", "Target YTD")]],
      body: (d.sales.reps || []).map(rp => [rp.name, wrBaht(rp.value), rp.target_week ? wrBaht(rp.target_week) : "—",
        wrPct(rp.value, rp.target_week) === null ? "—" : wrPct(rp.value, rp.target_week) + "%", mgN(rp.calls), wrRatio(rp.coverage), wrRatio(rp.call_to_order), mgN(rp.reactivated), wrRatio(rp.target_ytd)]),
      margin: { left: M, right: M }, styles: tableStyle, headStyles: headStyle });
    y = doc.lastAutoTable.finalY + 14;
    const top = (d.clients.top || []).slice(0, 10);
    if (top.length) {
      need(80);
      text(T("ลูกค้าหลักของสัปดาห์", "Biggest clients this week"), 12, true, "#1f3d2a");
      doc.autoTable({ startY: y, head: [[T("ลูกค้า", "Client"), T("สัปดาห์นี้", "This week"), T("ปกติ", "Usual")]],
        body: top.map(c => [c.name, wrBaht(c.value), c.usual === null || c.usual === undefined ? "—" : wrBaht(c.usual)]),
        margin: { left: M, right: M }, styles: tableStyle, headStyles: headStyle });
      y = doc.lastAutoTable.finalY + 14;
    }
  }
  if (r.comment) {
    text(T("ความเห็นของผู้บริหาร", "Management comment"), 12, true, "#1f3d2a");
    text(r.comment, 10, false);
    if (r.comment_by) text(`— ${r.comment_by}`, 9, false, "#7a7468");
  }
  const pages = doc.getNumberOfPages();
  for (let i = 1; i <= pages; i++) {
    doc.setPage(i); doc.setFont(font, "normal"); doc.setFontSize(8); doc.setTextColor("#7a7468");
    doc.text(T("ลับ — สำหรับผู้บริหาร Prosun", "Confidential — Prosun management") + `   ${i} / ${pages}`, M, H - 20);
  }
  doc.save(`PACE-weekly-report-${d.week_start}.pdf`);
}


// ----------------------------------------------------------- events
wrSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b || b.disabled) return;
  const act = b.dataset.act;
  if (act === "week" && b.dataset.week) {
    WR.week = b.dataset.week; WR.msg = null; WR.confirmRebuild = false; WR.sig = "";
    await wrLoad();
  } else if (act === "lang") {
    weighSetLang(b.dataset.lang);
    WR.sig = ""; wrDraw();
  } else if (act === "rebuild") {
    await wrRebuild();
  } else if (act === "comment") {
    await wrSaveComment();
  } else if (act === "pdf") {
    wrPdf();
  } else if (act === "go") {
    await switchPaceView(b.dataset.view);
  }
});

wrSection.addEventListener("change", async e => {
  if (e.target.id === "wr-week" && e.target.value) {
    WR.week = e.target.value; WR.msg = null; WR.confirmRebuild = false; WR.sig = "";
    await wrLoad();
  }
});
