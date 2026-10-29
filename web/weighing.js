// ============================================================================
// Weighing photo screen — PC side (Migration 018, 13 Oct 2026)
// ============================================================================
// Khun Muay (role factory_admin) photographs the filled FM-SA-01 working
// papers. The photos reach this screen live; the edge function `weighing`
// reads each one with an AI vision model; she checks every number against the
// photo and confirms. One table per day, exportable to Excel.
//
// Loaded after app.js and uses its globals (sb, myProfile, escapeHtml,
// escapeAttr, downloadXlsx, hideCrmSections, hidePaceSections, paceTabs).
// As everywhere in this app, the database decides who sees what: a sales rep
// or sale support calling these queries gets zero rows (Migration 018 RLS).
// Thai or English (switch at the top right of the screen, remembered per
// browser): Thai by default for the factory, English for admin.
// ============================================================================

const weighSection = document.getElementById("weighing-section");

const W = {
  date: null,          // work day on screen (ISO), Bangkok
  papers: [],          // weighing_papers rows with their weighing_lines
  link: null,          // { token, expires_at } — QR for today
  view: "day",         // "day" | "check"
  openId: null,        // paper open on the check screen
  filter: "all",
  names: {},           // profile id → name
  photoUrls: {},       // photo_path → { url, until }
  rotation: {},        // paper id → degrees
  zoom: false,
  uploads: [],         // PC uploads in progress: { name, state, error }
  message: null,       // { kind: "error" | "info", text }
  channel: null,
  refreshTimer: null,
  pendingRefresh: false,
  pollTimer: null,
  saving: 0,
  live: false,         // realtime connected
};

const WEIGH_TOLERANCE = 0.05;   // ±5% → orange in the "ต่าง" column

// Labels are getters so they follow the TH / EN switch (weighing-common.js).
const WEIGH_STATUS = {
  uploading: { get label() { return T("กำลังส่ง", "Sending"); }, cls: "w-pill-blue" },
  queued:    { get label() { return T("กำลังอ่าน", "Reading"); }, cls: "w-pill-blue" },
  reading:   { get label() { return T("กำลังอ่าน", "Reading"); }, cls: "w-pill-blue" },
  read:      { get label() { return T("รอตรวจ", "To check"); }, cls: "w-pill-amber" },
  failed:    { get label() { return T("อ่านไม่ได้", "Not readable"); }, cls: "w-pill-red" },
  confirmed: { get label() { return T("ยืนยันแล้ว", "Confirmed"); }, cls: "w-pill-green" },
};
const WEIGH_IN_PROGRESS = ["uploading", "queued", "reading"];
// A confirmed paper reopened for correction (Migration 021) shows as such
// until it is confirmed again.
const WEIGH_REOPENED = { get label() { return T("เปิดแก้ไข", "Reopened"); }, cls: "w-pill-amber" };
function weighStatusOf(p) {
  if (p.reopened_snapshot && (p.status === "read" || p.status === "failed")) return WEIGH_REOPENED;
  return WEIGH_STATUS[p.status] || WEIGH_STATUS.read;
}
const WEIGH_UNIT_TH = { kg: "kg", g: "g", pcs: "ตัว", pack: "แพค", jar: "ขวด", other: "หน่วย" };
const WEIGH_UNIT_EN = { kg: "kg", g: "g", pcs: "pc", pack: "pack", jar: "jar", other: "unit" };
function weighUnit(u) { return (WEIGH_LANG === "en" ? WEIGH_UNIT_EN : WEIGH_UNIT_TH)[u] || ""; }

function weighCompanyShort(c) {
  return c === "Prosun Farm" ? "PSFarm" : c === "Prosun Food" ? "PSFood" : "—";
}
function weighFmt(n, dp = 2) {
  return n === null || n === undefined || n === "" || isNaN(Number(n)) ? "" : Number(n).toFixed(dp);
}
function weighShortDate(iso) {
  if (!iso) return "";
  const [y, m, d] = iso.split("-");
  // Thai: Buddhist year as the team writes it (28/10/69); English: 28/10/26.
  return `${Number(d)}/${Number(m)}/${String(Number(y) + (WEIGH_LANG === "en" ? 0 : 543)).slice(2)}`;
}
function weighPaper(id) { return W.papers.find((p) => p.id === id); }
function weighLines(p) { return (p && p.weighing_lines) || []; }

// Actual vs ordered. Kilo lines: the gap in kg. Lines sold by the piece or
// pack: average kg per unit, to check against the size band instead.
function weighDiff(line) {
  const a = line.actual_kg === null || line.actual_kg === undefined ? null : Number(line.actual_kg);
  const q = line.ordered_qty === null || line.ordered_qty === undefined ? null : Number(line.ordered_qty);
  if (a === null || !q) return { text: "", warn: false, kg: null, perUnit: null };
  if (line.ordered_unit === "kg" || line.ordered_unit === "g") {
    const qk = line.ordered_unit === "g" ? q / 1000 : q;
    const d = a - qk;
    return {
      text: (d >= 0 ? "+" : "−") + Math.abs(d).toFixed(2),
      warn: Math.abs(d) / qk > WEIGH_TOLERANCE,
      kg: Math.round(d * 1000) / 1000, perUnit: null,
    };
  }
  if (["pcs", "pack", "jar"].includes(line.ordered_unit)) {
    const per = a / q;
    return { text: `${per.toFixed(2)}/${weighUnit(line.ordered_unit)}`, warn: false, kg: null, perUnit: Math.round(per * 1000) / 1000 };
  }
  return { text: "", warn: false, kg: null, perUnit: null };
}

function weighNeedsLook(line) { return !!line.flag_reason && !line.checked; }

// A wrong, blurred or duplicate photo can be deleted until it is confirmed.
// A confirmed paper may already be used for invoicing: the factory first sets
// it back with "แก้ไข / Edit" (logged), then deletes; admin can delete directly.
// The database enforces the same rule (Migration 018 RLS).
function weighCanDelete(p) {
  return !!p && (p.status !== "confirmed" || myProfile.role === "admin");
}

function weighLangHtml() {
  return `<div class="w-lang" role="group" aria-label="Language / ภาษา">
    <button type="button" data-act="lang" data-lang="th" class="${WEIGH_LANG === "en" ? "" : "on"}" aria-pressed="${WEIGH_LANG !== "en"}">ไทย</button>
    <button type="button" data-act="lang" data-lang="en" class="${WEIGH_LANG === "en" ? "on" : ""}" aria-pressed="${WEIGH_LANG === "en"}">EN</button>
  </div>`;
}

// Reasons and notes are written by the reading function in Thai. In English,
// the fixed phrases are translated here; a reason the AI wrote in its own
// words stays Thai inside the English sentence.
function weighServerText(s) {
  if (!s || WEIGH_LANG !== "en") return s || "";
  return String(s)
    .replace(/เขียนไว้ (\d+) ค่า \((.+?)\) รวมให้แล้ว/g, "$1 values written ($2), added up")
    .replace(/ไม่พบน้ำหนักในช่อง kg\./g, "No weight found in the kg. column")
    .replace(/ต่างจากที่สั่ง \((.+?) kg\) มากกว่า (\d+)%/g, "More than $2% off the order ($1 kg)")
    .replace(/รูปนี้ไม่ใช่ใบงาน FM-SA-01/g, "This photo is not an FM-SA-01 working paper")
    .replace(/ลายมืออื่น:/g, "Other handwriting:")
    .replace(/ทศนิยมไม่ชัด/g, "Unclear decimal")
    .replace(/มีขีดฆ่าแก้ตัวเลข/g, "Number crossed out and rewritten")
    .replace(/อ่านไม่ชัด/g, "Unclear reading")
    .replace(/ หรือ /g, " or ");
}

async function weighToken() {
  const { data } = await sb.auth.getSession();
  return data && data.session ? data.session.access_token : null;
}


// ----------------------------------------------------------- open / close
// Opened from the PROSUN PACE tab "งานชั่งน้ำหนัก" (switchPaceView in app.js),
// which sets the header, tabs and title. This only fills the section.
async function openWeighing() {
  // Language: the browser's last choice; otherwise Thai for the factory,
  // English for admin.
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  if (myProfile.role === "factory_admin") {
    document.getElementById("who-role").textContent = T("ผู้ดูแลโรงงาน", "Factory admin");
  }
  weighSection.classList.remove("hidden");
  // From a notification (notifications.js): that paper's day, opened on it.
  const pend = W.pendingOpen;
  W.pendingOpen = null;
  W.date = (pend && pend.date) || weighBangkokToday();
  W.view = "day";
  W.openId = null;
  weighSection.innerHTML = `<p class="w-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  await weighLoad();
  if (pend && pend.id && weighPaper(pend.id)) { W.view = "check"; W.openId = pend.id; weighRender(); }
  weighStartRealtime();
  weighCleanupOnce();
}

// Free-plan storage: photos older than 4 weeks are deleted by the edge
// function (weights are kept). Asked once per day per browser, in the
// background — the screen never waits for it.
async function weighCleanupOnce() {
  const key = "weigh-cleanup-" + weighBangkokToday();
  try { if (localStorage.getItem(key)) return; } catch (e) { /* private mode */ }
  try {
    await weighCallFn({ action: "cleanup" }, await weighToken());
    try { localStorage.setItem(key, "1"); } catch (e) { /* ignore */ }
  } catch (e) {
    console.warn("weighing photo clean-up skipped:", e.message);
  }
}

function closeWeighing() {
  if (weighSection.classList.contains("hidden")) return;
  weighSection.classList.add("hidden");
  weighSection.innerHTML = "";
  weighStopRealtime();
  clearTimeout(W.pollTimer);
}

document.getElementById("switch-system-btn").addEventListener("click", closeWeighing);
document.getElementById("sign-out-btn").addEventListener("click", closeWeighing);


// ------------------------------------------------------------------ data
async function weighLoad() {
  const { data, error } = await sb
    .from("weighing_papers")
    .select("*, weighing_lines(*)")
    .eq("work_date", W.date)
    .order("uploaded_at", { ascending: true });
  if (error) {
    W.papers = [];
    W.message = { kind: "error", text: T("โหลดข้อมูลไม่ได้: ", "Could not load: ") + error.message };
  } else {
    W.papers = (data || []).map((p) => Object.assign({}, p, {
      weighing_lines: (p.weighing_lines || []).slice().sort((a, b) => a.line_no - b.line_no),
    }));
  }
  await weighLoadNames();
  if (W.date === weighBangkokToday()) {
    if (!W.link || W.link.work_date !== W.date || new Date(W.link.expires_at) < new Date()) {
      await weighEnsureLink(false);
    }
  }
  if (W.view === "check" && !weighPaper(W.openId)) { W.view = "day"; W.openId = null; }
  await weighPreparePhotos();
  weighRender();
  weighSchedulePoll();
}

async function weighLoadNames() {
  const ids = new Set();
  W.papers.forEach((p) => { if (p.confirmed_by) ids.add(p.confirmed_by); if (p.uploaded_by) ids.add(p.uploaded_by); });
  const missing = [...ids].filter((id) => !(id in W.names));
  if (myProfile) W.names[myProfile.id] = myProfile.full_name;
  if (!missing.length) return;
  const { data } = await sb.from("profiles").select("id, full_name").in("id", missing);
  (data || []).forEach((r) => { W.names[r.id] = r.full_name; });
}

// The QR on screen. One per day per person, valid until midnight; "สร้างใหม่"
// revokes it (a photographed QR stops working) and makes another.
async function weighEnsureLink(forceNew) {
  if (!forceNew) {
    const { data } = await sb
      .from("weighing_capture_links")
      .select("token, work_date, expires_at")
      .eq("work_date", W.date)
      .eq("revoked", false)
      .eq("created_by", myProfile.id)
      .gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: false })
      .limit(1);
    if (data && data.length) { W.link = data[0]; return; }
  } else if (W.link) {
    await sb.from("weighing_capture_links").update({ revoked: true }).eq("token", W.link.token);
  }
  const { data, error } = await sb
    .from("weighing_capture_links")
    .insert({
      work_date: W.date,
      created_by: myProfile.id,
      expires_at: new Date(W.date + "T23:59:59+07:00").toISOString(),
    })
    .select("token, work_date, expires_at")
    .single();
  W.link = error ? null : data;
  if (error) W.message = { kind: "error", text: T("สร้าง QR ไม่ได้: ", "Could not create the QR code: ") + error.message };
}

async function weighPreparePhotos() {
  const now = Date.now();
  const need = W.papers
    .filter((p) => p.status !== "uploading" && !p.photo_deleted_at)
    .map((p) => p.photo_path)
    .filter((path) => !W.photoUrls[path] || W.photoUrls[path].until < now + 60000);
  if (!need.length) return;
  const { data } = await sb.storage.from(WEIGH_BUCKET).createSignedUrls(need, 3600);
  (data || []).forEach((r) => {
    if (r && r.signedUrl) W.photoUrls[r.path] = { url: r.signedUrl, until: now + 3500 * 1000 };
  });
}

function weighPhoto(p) {
  if (!p || p.photo_deleted_at) return "";
  const e = W.photoUrls[p.photo_path];
  return e ? e.url : "";
}


// ------------------------------------------------------ live + polling
function weighStartRealtime() {
  if (W.channel || typeof sb.channel !== "function") return;
  try {
    W.channel = sb.channel("weighing-day")
      .on("postgres_changes", { event: "*", schema: "public", table: "weighing_papers" }, weighOnRemote)
      .on("postgres_changes", { event: "*", schema: "public", table: "weighing_lines" }, weighOnRemote)
      .subscribe((status) => {
        // The client retries a failed connection every few seconds; only a
        // real change of state may reschedule the poll, or a retry loop
        // would keep pushing it back forever.
        const live = status === "SUBSCRIBED";
        if (live !== W.live) { W.live = live; weighSchedulePoll(); }
      });
  } catch (e) {
    W.channel = null;   // the poll below still keeps the screen current
  }
}

function weighStopRealtime() {
  if (W.channel) { try { sb.removeChannel(W.channel); } catch (e) { /* ignore */ } }
  W.channel = null;
  W.live = false;
}

function weighTyping() {
  const a = document.activeElement;
  return a && weighSection.contains(a) && (a.tagName === "INPUT" || a.tagName === "SELECT" || a.tagName === "TEXTAREA");
}

function weighOnRemote() {
  clearTimeout(W.refreshTimer);
  W.refreshTimer = setTimeout(() => {
    // Never reload under someone's cursor — wait until they leave the field.
    if (weighTyping() || W.saving) { W.pendingRefresh = true; return; }
    W.pendingRefresh = false;
    weighLoad();
  }, 700);
}

weighSection.addEventListener("focusout", () => {
  setTimeout(() => {
    if (W.pendingRefresh && !weighTyping() && !W.saving) { W.pendingRefresh = false; weighLoad(); }
  }, 50);
});

// Photos being read change status within seconds: poll every 5 s while any
// are. If live updates are not connected (some networks block websockets),
// also poll every 20 s so photos from the phone still appear by themselves.
function weighSchedulePoll() {
  clearTimeout(W.pollTimer);
  if (weighSection.classList.contains("hidden")) return;
  const busy = W.papers.some((p) => WEIGH_IN_PROGRESS.includes(p.status));
  const delay = busy ? 5000 : W.live ? 0 : 20000;
  if (!delay) return;
  W.pollTimer = setTimeout(() => {
    if (weighTyping() || W.saving) { weighSchedulePoll(); return; }
    weighLoad();
  }, delay);
}


// ------------------------------------------------------------- rendering
function weighRender() {
  if (W.view === "check" && weighPaper(W.openId)) weighRenderCheck();
  else weighRenderDay();
}

function weighCounts() {
  const c = { all: W.papers.length, wait: 0, busy: 0, done: 0 };
  W.papers.forEach((p) => {
    if (p.status === "confirmed") c.done++;
    else if (p.status === "read" || p.status === "failed") c.wait++;
    else c.busy++;
  });
  return c;
}

function weighMessageHtml() {
  if (!W.message) return "";
  return `<div class="w-msg w-msg-${W.message.kind}" role="status">${escapeHtml(W.message.text)}
    <button type="button" class="w-msg-close" data-act="dismiss" aria-label="${T("ปิด", "Close")}">×</button></div>`;
}

function weighQrHtml() {
  if (W.date !== weighBangkokToday()) {
    return `<p class="w-muted">${T("QR สำหรับมือถือใช้ได้เฉพาะวันนี้ — สำหรับวันอื่นใช้ปุ่มอัปโหลดด้านล่าง", "The phone QR code works for today only — for another day use the upload button below.")}</p>`;
  }
  if (!W.link) return `<p class="w-muted">${T("ยังไม่มี QR", "No QR code yet")}</p>`;
  const url = new URL("capture.html?t=" + W.link.token, location.href).href;
  let svg = "";
  if (typeof qrcode === "function") {
    const qr = qrcode(0, "M");
    qr.addData(url);
    qr.make();
    svg = qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true, alt: T("QR สำหรับเปิดหน้าถ่ายรูปบนมือถือ", "QR code to open the phone camera page") });
  } else {
    svg = `<a href="${escapeAttr(url)}" target="_blank" rel="noopener">${T("เปิดหน้าถ่ายรูป", "Open the camera page")}</a>`;
  }
  return `<div class="w-qr" data-qr-url="${escapeAttr(url)}">${svg}</div>
    <p class="w-small w-center">${T("ใช้ได้ถึง 23:59 วันนี้", "Valid until 23:59 today")} ·
      <button type="button" class="btn-link" data-act="new-link">${T("สร้างใหม่", "New code")}</button></p>`;
}

function weighUploadsHtml() {
  if (!W.uploads.length) return "";
  return `<ul class="w-uploads">${W.uploads.map((u) =>
    `<li><span>${escapeHtml(u.name)}</span><span class="w-pill ${u.state === "error" ? "w-pill-red" : u.state === "done" ? "w-pill-green" : "w-pill-blue"}">${
      u.state === "error" ? T("ส่งไม่สำเร็จ", "Failed") : u.state === "done" ? T("ส่งแล้ว", "Sent") : T("กำลังส่ง…", "Sending…")}</span>${
      u.error ? `<small class="w-err">${escapeHtml(u.error)}</small>` : ""}</li>`).join("")}</ul>`;
}

function weighPaperCardHtml(p) {
  const st = weighStatusOf(p);
  const n = weighLines(p).length;
  const img = weighPhoto(p);
  return `<button type="button" class="w-card" data-act="open" data-id="${p.id}">
    <span class="w-thumb">${img ? `<img src="${escapeAttr(img)}" alt="" loading="lazy">` : ""}</span>
    <span class="w-card-body">
      <span class="w-card-po">${escapeHtml(p.po_number || "—")}</span>
      <span class="w-card-cust">${escapeHtml(p.customer_name || (WEIGH_IN_PROGRESS.includes(p.status) ? T("กำลังอ่าน…", "Reading…") : T("ไม่ทราบลูกค้า", "Unknown customer")))}</span>
      <span class="w-card-meta">${escapeHtml(weighCompanyShort(p.company))}${n ? " · " + n + T(" รายการ", n === 1 ? " line" : " lines") : ""} · ${escapeHtml(weighTime(p.uploaded_at))}</span>
      <span class="w-pill ${st.cls}">${st.label}</span>
    </span>
  </button>`;
}

function weighTableRows() {
  const rows = [];
  W.papers.forEach((p) => {
    const lines = weighLines(p);
    const st = weighStatusOf(p);
    const by = p.confirmed_by ? `${W.names[p.confirmed_by] || "—"} ${weighTime(p.confirmed_at)}` : "—";
    if (!lines.length) {
      rows.push({ p, l: null, first: true, st, by });
      return;
    }
    lines.forEach((l, i) => rows.push({ p, l, first: i === 0, st, by }));
  });
  return rows.filter((r) => {
    if (W.filter === "wait") return r.p.status === "read" || r.p.status === "failed";
    if (W.filter === "done") return r.p.status === "confirmed";
    if (W.filter === "gap") return r.l && weighDiff(r.l).warn;
    return true;
  });
}

function weighRenderDay() {
  const c = weighCounts();
  const rows = weighTableRows();
  const lineCount = W.papers.reduce((n, p) => n + weighLines(p).length, 0);
  const isToday = W.date === weighBangkokToday();

  weighSection.innerHTML = `
  ${weighMessageHtml()}
  <div class="w-head">
    <div class="w-daynav">
      <button type="button" class="w-iconbtn" data-act="day" data-delta="-1" aria-label="${T("วันก่อนหน้า", "Previous day")}">‹</button>
      <div>
        <h2 class="w-day">${escapeHtml(weighThaiDate(W.date))}</h2>
        <div class="w-muted">${isToday ? T("ใบงานที่ถ่ายวันนี้", "Papers photographed today") : T("ใบงานที่ถ่ายวันนั้น", "Papers photographed that day")}${
          isToday ? "" : ` · <button type="button" class="btn-link" data-act="today">${T("กลับไปวันนี้", "Back to today")}</button>`}</div>
      </div>
      <button type="button" class="w-iconbtn" data-act="day" data-delta="1" aria-label="${T("วันถัดไป", "Next day")}">›</button>
    </div>
    <div class="w-head-right">
      ${weighLangHtml()}
      <div class="w-counters">
        <div class="w-counter"><span>${T("ใบงาน", "Papers")}</span><strong>${c.all}</strong></div>
        <div class="w-counter w-c-amber"><span>${T("รอตรวจ", "To check")}</span><strong>${c.wait}</strong></div>
        <div class="w-counter w-c-blue"><span>${T("กำลังอ่าน", "Reading")}</span><strong>${c.busy}</strong></div>
        <div class="w-counter w-c-green"><span>${T("ยืนยันแล้ว", "Confirmed")}</span><strong>${c.done}</strong></div>
      </div>
    </div>
  </div>

  <div class="w-row">
    <section class="w-panel w-capture">
      <h3>${T("ถ่ายรูปด้วยมือถือ", "Photograph with a phone")}</h3>
      <p class="w-small">${T("สแกน QR นี้ด้วยมือถือของโรงงาน รูปที่ถ่ายจะขึ้นในตารางนี้ทันที ไม่ต้องล็อกอินบนมือถือ", "Scan this QR code with the factory phone. Photos appear here straight away — no login on the phone.")}</p>
      ${weighQrHtml()}
      <div class="w-sep"></div>
      <p class="w-small w-muted">${T("ไม่มีมือถือ หรือใช้เครื่องสแกน", "No phone, or using a scanner")}</p>
      <label class="w-btn w-btn-outline w-upload-label">
        <input type="file" accept="image/*" multiple data-act="upload" class="w-file">
        ${T("อัปโหลดไฟล์รูป / สแกน", "Upload photos / scans")}
      </label>
      ${weighUploadsHtml()}
    </section>

    <section class="w-panel w-papers">
      <div class="w-panel-head"><h3>${isToday ? T("ใบงานวันนี้", "Today's papers") : T("ใบงาน", "Papers")}</h3><span class="w-small w-muted">${T("คลิกใบงานเพื่อตรวจตัวเลข", "Click a paper to check its numbers")}</span></div>
      ${W.papers.length
        ? `<div class="w-cards">${W.papers.map(weighPaperCardHtml).join("")}</div>`
        : `<p class="w-empty">${isToday ? T("ยังไม่มีรูปใบงานวันนี้ — สแกน QR แล้วถ่ายรูปได้เลย", "No papers yet today — scan the QR code and start photographing") : T("ยังไม่มีรูปใบงาน", "No papers")}</p>`}
    </section>
  </div>

  <section class="w-panel w-table-panel">
    <div class="w-panel-head">
      <div>
        <h3>${T("ตารางน้ำหนักจริง", "Actual weights")} — ${escapeHtml(weighThaiDate(W.date, { day: "numeric", month: "short", year: "numeric" }))}</h3>
        <div class="w-small w-muted">${T(
          `${lineCount} รายการจาก ${c.all} ใบงาน · ยืนยันแล้ว ${c.done} ใบ · รอตรวจ ${c.wait} ใบ${c.busy ? ` · กำลังอ่าน ${c.busy} ใบ` : ""}`,
          `${lineCount} lines from ${c.all} papers · ${c.done} confirmed · ${c.wait} to check${c.busy ? ` · ${c.busy} being read` : ""}`)}</div>
      </div>
      <div class="w-actions">
        <label class="w-inline">${T("แสดง", "Show")}
          <select data-act="filter">
            <option value="all"${W.filter === "all" ? " selected" : ""}>${T("ทุกรายการ", "All lines")}</option>
            <option value="wait"${W.filter === "wait" ? " selected" : ""}>${T("รอตรวจ", "To check")}</option>
            <option value="done"${W.filter === "done" ? " selected" : ""}>${T("ยืนยันแล้ว", "Confirmed")}</option>
            <option value="gap"${W.filter === "gap" ? " selected" : ""}>${T("ต่างเกิน ±5%", "Off by more than ±5%")}</option>
          </select>
        </label>
        <button type="button" class="w-btn" data-act="export"${W.papers.length ? "" : " disabled"}>${T("ส่งออก Excel", "Export to Excel")}</button>
      </div>
    </div>
    <div class="table-scroll w-scroll">
      <table class="w-table" id="weighing-table">
        <thead><tr><th>${T("วันที่ส่ง", "Delivery")}</th><th>${T("บริษัท", "Company")}</th><th>PO</th><th>${T("ลูกค้า", "Customer")}</th><th>${T("สินค้า", "Product")}</th>
          <th class="w-num">${T("สั่ง", "Ordered")}</th><th class="w-num">${T("ชั่งจริง (kg)", "Actual (kg)")}</th><th class="w-num">${T("ต่าง", "Difference")}</th>
          <th>${T("สถานะ", "Status")}</th><th>${T("ยืนยันโดย", "Confirmed by")}</th><th></th></tr></thead>
        <tbody>${rows.length ? rows.map((r) => {
          const d = r.l ? weighDiff(r.l) : { text: "", warn: false };
          return `<tr class="${r.first ? "w-first" : ""}">
            <td>${r.first ? escapeHtml(weighShortDate(r.p.delivery_date)) : ""}</td>
            <td>${r.first ? escapeHtml(weighCompanyShort(r.p.company)) : ""}</td>
            <td class="w-mono">${r.first ? escapeHtml(r.p.po_number || "") : ""}</td>
            <td>${r.first ? escapeHtml(r.p.customer_name || "") : ""}</td>
            <td class="w-wrap">${r.l ? escapeHtml(r.l.description) : `<span class="w-muted">${escapeHtml(r.p.status === "failed" ? T("อ่านไม่ได้ — เปิดเพื่ออ่านใหม่", "Not readable — open to read again") : WEIGH_IN_PROGRESS.includes(r.p.status) ? T("กำลังอ่าน…", "Reading…") : T("ไม่พบรายการ", "No lines found"))}</span>`}</td>
            <td class="w-num">${r.l ? escapeHtml(r.l.ordered_text || "") : ""}</td>
            <td class="w-num w-strong">${r.l ? (r.l.actual_kg === null ? `<span class="w-muted">—</span>` : weighFmt(r.l.actual_kg)) : ""}${r.l && weighNeedsLook(r.l) && r.p.status !== "confirmed" ? ` <span class="w-q" title="${T("ต้องตรวจกับรูป", "Check against the photo")}">?</span>` : ""}</td>
            <td class="w-num ${d.warn ? "w-warn" : ""}">${escapeHtml(d.text)}</td>
            <td>${r.first ? `<span class="w-pill ${r.st.cls}">${r.st.label}</span>` : ""}</td>
            <td>${r.first ? escapeHtml(r.by) : ""}</td>
            <td>${r.first ? `<span class="w-row-acts"><button type="button" class="btn-link" data-act="open" data-id="${r.p.id}">${T("ดูรูป", "View")}</button>${
              weighCanDelete(r.p) ? `<button type="button" class="w-del" data-act="delete-paper" data-id="${r.p.id}" title="${T("ลบใบงานนี้", "Delete this paper")}" aria-label="${T("ลบใบงาน", "Delete paper")} ${escapeAttr(r.p.po_number || "")}">${T("ลบ", "Delete")}</button>` : ""}</span>` : ""}</td>
          </tr>`;
        }).join("") : `<tr><td colspan="11" class="w-empty">${T("ไม่มีรายการ", "No lines")}</td></tr>`}</tbody>
      </table>
    </div>
    <p class="w-small w-muted w-foot">${T("สินค้าที่สั่งเป็นตัว / แพค แสดงน้ำหนักเฉลี่ยต่อหน่วยในช่อง “ต่าง” · สีส้ม = ต่างจากที่สั่งเกิน ±5%", "Lines ordered by the piece or pack show the average kg per unit under “Difference” · orange = more than ±5% off the order")} · <span class="w-q">?</span> = ${T("ยังไม่ได้ตรวจกับรูป", "not yet checked against the photo")}</p>
  </section>`;
}

function weighRenderCheck() {
  const p = weighPaper(W.openId);
  const idx = W.papers.indexOf(p);
  const lines = weighLines(p);
  const locked = p.status === "confirmed";
  const busy = WEIGH_IN_PROGRESS.includes(p.status);
  const editable = !locked && !busy;
  const st = weighStatusOf(p);
  const rot = W.rotation[p.id] || 0;
  const img = weighPhoto(p);
  const ro = editable ? "" : " disabled";

  const notes = [];
  if (busy) notes.push(`<div class="w-note w-note-blue">${T("กำลังอ่านรูปนี้ — ตัวเลขจะขึ้นเองในไม่กี่วินาที", "Reading this photo — the numbers appear by themselves in a few seconds")}</div>`);
  if (p.status === "failed") notes.push(`<div class="w-note w-note-red">${T("อ่านรูปนี้ไม่ได้", "This photo could not be read")}${p.read_error ? ": " + escapeHtml(p.read_error) : ""} — ${T("กด “อ่านใหม่” หรือถ่ายใหม่", "press “Read again” or take a new photo")}</div>`);
  if (p.note) notes.push(`<div class="w-note w-note-amber">${escapeHtml(weighServerText(p.note))}</div>`);
  if (p.reopened_snapshot && !locked) {
    const s = p.reopened_snapshot;
    const by = [s.confirmed_by_name, s.confirmed_at ? weighTime(s.confirmed_at) : ""].filter(Boolean).join(" ");
    notes.push(`<div class="w-note w-note-amber">${T(
      `ใบนี้เคยยืนยันแล้ว${by ? " (" + escapeHtml(by) + ")" : ""} และเปิดแก้ไข — ออกจากตารางของบัญชีจนกว่าจะยืนยันอีกครั้ง เมื่อยืนยัน ผู้บริหารจะได้รับแจ้งว่าน้ำหนักเปลี่ยนจากเท่าไรเป็นเท่าไร`,
      `This paper was confirmed${by ? " (" + escapeHtml(by) + ")" : ""} and reopened for correction — it is out of the accounting table until confirmed again. When it is confirmed, management is notified of every weight before → after.`)}</div>`);
  }
  const dup = p.po_number && W.papers.filter((o) => o.id !== p.id && o.po_number === p.po_number && o.company === p.company).length;
  if (dup) notes.push(`<div class="w-note w-note-amber">PO ${escapeHtml(p.po_number)} ${T("มีอีกรูปในวันนี้ — ถ่ายซ้ำหรือเปล่า?", "appears on another photo today — photographed twice?")}</div>`);

  weighSection.innerHTML = `
  ${weighMessageHtml()}
  <div class="w-check-top">
    <button type="button" class="btn-link w-back" data-act="back">‹ ${W.date === weighBangkokToday() ? T("กลับไปตารางวันนี้", "Back to today's table") : T("กลับไปตาราง", "Back to the table")}</button>
    <div class="w-stepper">
      <button type="button" class="w-btn w-btn-outline" data-act="step" data-delta="-1"${idx <= 0 ? " disabled" : ""}>‹ ${T("ใบก่อนหน้า", "Previous")}</button>
      <span class="w-mono">${idx + 1} / ${W.papers.length}</span>
      <button type="button" class="w-btn w-btn-outline" data-act="step" data-delta="1"${idx >= W.papers.length - 1 ? " disabled" : ""}>${T("ใบถัดไป", "Next")} ›</button>
      ${weighLangHtml()}
    </div>
  </div>

  <div class="w-check">
    <section class="w-photo" aria-label="${T("รูปใบงาน", "Paper photo")}">
      <div class="w-photo-bar">
        <span>${T("รูปส่งเมื่อ", "Sent at")} ${escapeHtml(weighTime(p.uploaded_at))}${p.uploaded_by ? " · " + escapeHtml(W.names[p.uploaded_by] || "") : " · " + T("มือถือ", "phone")}</span>
        <span class="w-photo-tools">
          <button type="button" class="w-tool" data-act="zoom">${W.zoom ? T("ย่อให้พอดี", "Fit") : T("ขยาย", "Zoom")}</button>
          <button type="button" class="w-tool" data-act="rotate">${T("หมุน", "Rotate")}</button>
          ${!locked && !p.photo_deleted_at ? `<button type="button" class="w-tool" data-act="reread"${busy ? " disabled" : ""}>${T("อ่านใหม่", "Read again")}</button>` : ""}
        </span>
      </div>
      <div class="w-photo-frame ${W.zoom ? "w-zoomed" : ""}">
        ${img ? `<img id="weigh-photo" src="${escapeAttr(img)}" alt="${T("รูปใบงาน", "Paper photo")} ${escapeAttr(p.po_number || "")}" style="transform: rotate(${rot}deg)">`
          : p.photo_deleted_at ? `<p class="w-photo-gone">${T("รูปนี้ถูกลบอัตโนมัติ (เก็บรูปไว้ 4 สัปดาห์) — ตัวเลขยังอยู่ครบ", "This photo was deleted automatically (photos are kept 4 weeks) — the numbers are all kept")}</p>`
          : `<p class="w-photo-gone">${T("ไม่มีรูป", "No photo")}</p>`}
      </div>
    </section>

    <section class="w-side">
      <div class="w-panel">
        <div class="w-panel-head">
          <h3 class="w-cust">${escapeHtml(p.customer_name || T("ไม่ทราบลูกค้า", "Unknown customer"))}</h3>
          <span class="w-pill ${st.cls}">${st.label}</span>
        </div>
        <div class="w-fields">
          <label>${T("บริษัท", "Company")}
            <select data-paper-field="company"${ro}>
              <option value="">—</option>
              <option value="Prosun Farm"${p.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
              <option value="Prosun Food"${p.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option>
            </select></label>
          <label>PO
            <input type="text" data-paper-field="po_number" value="${escapeAttr(p.po_number || "")}"${ro}></label>
          <label>${T("ลูกค้า", "Customer")}
            <input type="text" data-paper-field="customer_name" value="${escapeAttr(p.customer_name || "")}"${ro}></label>
          <label>${T("วันส่ง", "Delivery date")}
            <input type="date" data-paper-field="delivery_date" value="${escapeAttr(p.delivery_date || "")}"${ro}></label>
        </div>
        ${notes.join("")}
      </div>

      <div class="w-panel w-lines-panel">
        <table class="w-lines">
          <thead><tr><th>${T("สินค้า", "Product")}</th><th class="w-num">${T("สั่ง", "Ordered")}</th><th class="w-num">${T("ที่เขียน", "Written")}</th><th class="w-num">${T("ชั่งจริง (kg)", "Actual (kg)")}</th><th class="w-num">${T("ต่าง", "Difference")}</th><th></th></tr></thead>
          <tbody>
          ${lines.length ? lines.map((l) => weighLineRowHtml(l, editable)).join("") : `<tr><td colspan="6" class="w-empty">${busy ? T("กำลังอ่าน…", "Reading…") : T("ไม่พบรายการในรูปนี้", "No lines found on this photo")}</td></tr>`}
          </tbody>
        </table>
        ${editable ? `<button type="button" class="btn-link w-add" data-act="add-line">+ ${T("เพิ่มรายการ", "Add a line")}</button>` : ""}
        <p class="w-small w-muted w-pad">${T("แก้ตัวเลขได้ทุกช่อง บันทึกให้อัตโนมัติ · สีส้มในช่อง “ต่าง” = ต่างจากที่สั่งเกิน ±5%", "Every number can be corrected and saves automatically · orange under “Difference” = more than ±5% off the order")}</p>
      </div>

      ${locked ? `
      <div class="w-panel w-confirmed">
        <strong>✓ ${T("ยืนยันแล้ว", "Confirmed")} · ${escapeHtml(W.names[p.confirmed_by] || "")} ${escapeHtml(weighTime(p.confirmed_at))}</strong>
        <span class="w-actions">
          ${myProfile.role === "admin" ? `<button type="button" class="w-btn w-btn-danger-outline" data-act="delete">${T("ลบใบงาน", "Delete paper")}</button>` : ""}
          <button type="button" class="w-btn w-btn-outline" data-act="unconfirm">${T("แก้ไข", "Edit")}</button>
          ${idx < W.papers.length - 1 ? `<button type="button" class="w-btn" data-act="step" data-delta="1">${T("ใบถัดไป", "Next paper")} ›</button>` : `<button type="button" class="w-btn" data-act="back">${T("กลับไปตาราง", "Back to the table")}</button>`}
        </span>
      </div>` : `
      <div class="w-panel w-confirm-bar">
        <span class="w-small" id="weigh-helper"></span>
        <span class="w-actions">
          <button type="button" class="w-btn w-btn-danger-outline" data-act="delete">${T("ลบรูปนี้", "Delete photo")}</button>
          <button type="button" class="w-btn w-btn-big" id="weigh-confirm" data-act="confirm">${T("ยืนยันน้ำหนัก", "Confirm weights")}</button>
        </span>
      </div>`}
    </section>
  </div>`;
  weighRefreshCheckDerived();
}

function weighLineRowHtml(l, editable) {
  const d = weighDiff(l);
  const look = weighNeedsLook(l);
  const ro = editable ? "" : " disabled";
  const manual = !l.ordered_text && l.edited && !(l.weights && l.weights.length);
  return `<tr class="w-line ${look ? "w-look" : ""}" data-line-id="${l.id}">
    <td>${manual && editable
      ? `<input type="text" class="w-desc" data-line-field="description" value="${escapeAttr(l.description)}" placeholder="${T("ชื่อสินค้า", "Product name")}" aria-label="${T("ชื่อสินค้า", "Product name")}">`
      : escapeHtml(l.description || "—")}</td>
    <td class="w-num">${escapeHtml(l.ordered_text || "")}</td>
    <td class="w-num w-hand">${escapeHtml(l.handwritten_text || "")}</td>
    <td class="w-num"><input type="text" inputmode="decimal" class="w-kg" data-line-field="actual_kg"
        value="${escapeAttr(l.actual_kg === null || l.actual_kg === undefined ? "" : String(Number(l.actual_kg)))}"
        aria-label="${T("น้ำหนักจริง", "Actual weight")} ${escapeAttr(l.description)}"${ro}></td>
    <td class="w-num w-diff ${d.warn ? "w-warn" : ""}">${escapeHtml(d.text)}</td>
    <td>${editable ? `<button type="button" class="w-x" data-act="remove-line" aria-label="${T("ลบรายการ", "Remove line")} ${escapeAttr(l.description)}">×</button>` : ""}</td>
  </tr>
  ${l.flag_reason ? `<tr class="w-flag-row ${look ? "w-look" : ""}" data-flag-for="${l.id}">
    <td colspan="6"><div class="w-flag">
      <span class="w-flag-text">⚠ ${escapeHtml(weighServerText(l.flag_reason))}</span>
      <label class="w-check-label"><input type="checkbox" data-line-check="${l.id}"${l.checked ? " checked" : ""}${ro}> ${T("ตรวจกับรูปแล้ว", "Checked against photo")}</label>
    </div></td></tr>` : ""}`;
}

// After a save, update what depends on it without redrawing the form (a
// redraw would steal the cursor from the next field).
function weighRefreshCheckDerived() {
  const p = weighPaper(W.openId);
  if (!p || W.view !== "check") return;
  weighLines(p).forEach((l) => {
    const row = weighSection.querySelector(`tr[data-line-id="${l.id}"]`);
    if (!row) return;
    const d = weighDiff(l);
    const cell = row.querySelector(".w-diff");
    cell.textContent = d.text;
    cell.classList.toggle("w-warn", d.warn);
    const look = weighNeedsLook(l);
    row.classList.toggle("w-look", look);
    const fr = weighSection.querySelector(`tr[data-flag-for="${l.id}"]`);
    if (fr) {
      fr.classList.toggle("w-look", look);
      const cb = fr.querySelector("input[type=checkbox]");
      if (cb) cb.checked = !!l.checked;
    }
  });
  const btn = document.getElementById("weigh-confirm");
  const helper = document.getElementById("weigh-helper");
  if (!btn || !helper) return;
  const lines = weighLines(p);
  const open = lines.filter(weighNeedsLook).length;
  const bad = lines.filter((l) => l._invalid).length;
  let msg, ready = false;
  if (WEIGH_IN_PROGRESS.includes(p.status)) msg = T("รอให้อ่านรูปเสร็จก่อน", "Wait until the photo has been read");
  else if (p.status === "failed" && !lines.length) msg = T("อ่านไม่ได้ — กด “อ่านใหม่” หรือเพิ่มรายการเอง", "Not readable — press “Read again” or add the lines yourself");
  else if (!lines.length) msg = T("ไม่มีรายการให้ยืนยัน — เพิ่มรายการ หรือลบรูปนี้", "Nothing to confirm — add a line or delete this photo");
  else if (bad) msg = T("มีช่องน้ำหนักที่ไม่ใช่ตัวเลข", "A weight box contains something that is not a number");
  else if (open) msg = T(`ยังเหลือ ${open} รายการที่ต้องตรวจกับรูปก่อนยืนยัน`, `${open} line${open === 1 ? "" : "s"} still to check against the photo before confirming`);
  else if (W.saving) msg = T("กำลังบันทึก…", "Saving…");
  else { msg = T("ตัวเลขครบแล้ว กดยืนยันเพื่อบันทึกลงตารางวันนี้", "All numbers checked — confirm to record them in today's table"); ready = true; }
  helper.textContent = msg;
  btn.disabled = !ready;
}


// --------------------------------------------------------------- actions
weighSection.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-act]");
  if (!el || !weighSection.contains(el)) return;
  const act = el.dataset.act;
  if (act === "upload" || act === "filter") return;   // handled on change
  if (act === "dismiss") { W.message = null; weighRender(); return; }
  if (act === "lang") { weighSetLang(el.dataset.lang); weighRender(); return; }
  if (act === "day") {
    const d = new Date(W.date + "T00:00:00Z");
    d.setUTCDate(d.getUTCDate() + Number(el.dataset.delta));
    W.date = d.toISOString().slice(0, 10);
    W.view = "day";
    await weighLoad();
    return;
  }
  if (act === "today") { W.date = weighBangkokToday(); W.view = "day"; await weighLoad(); return; }
  if (act === "new-link") { await weighEnsureLink(true); weighRender(); return; }
  if (act === "open") { W.openId = el.dataset.id; W.view = "check"; W.zoom = false; weighRender(); window.scrollTo(0, 0); return; }
  if (act === "back") { W.view = "day"; W.openId = null; weighRender(); return; }
  if (act === "step") {
    const i = W.papers.findIndex((p) => p.id === W.openId) + Number(el.dataset.delta);
    if (W.papers[i]) { W.openId = W.papers[i].id; W.zoom = false; weighRender(); window.scrollTo(0, 0); }
    return;
  }
  if (act === "zoom") { W.zoom = !W.zoom; weighRender(); return; }
  if (act === "rotate") {
    W.rotation[W.openId] = ((W.rotation[W.openId] || 0) + 90) % 360;
    const img = document.getElementById("weigh-photo");
    if (img) img.style.transform = `rotate(${W.rotation[W.openId]}deg)`;
    return;
  }
  if (act === "export") { weighExport(); return; }
  if (act === "confirm") { await weighSetStatus("confirmed"); return; }
  if (act === "unconfirm") {
    if (!confirm(T("เปิดใบงานที่ยืนยันแล้วเพื่อแก้ไข? ใบนี้จะออกจากตารางของบัญชีจนกว่าจะยืนยันอีกครั้ง และผู้บริหารจะได้รับแจ้ง",
                   "Reopen this confirmed paper for correction? It leaves the accounting table until it is confirmed again, and management is notified."))) return;
    await weighSetStatus("read");
    return;
  }
  if (act === "reread") { await weighReread(); return; }
  if (act === "delete") { await weighDeletePaper(W.openId); return; }
  if (act === "delete-paper") { await weighDeletePaper(el.dataset.id); return; }
  if (act === "add-line") { await weighAddLine(); return; }
  if (act === "remove-line") {
    const id = el.closest("tr").dataset.lineId;
    await weighRemoveLine(id);
  }
});

weighSection.addEventListener("change", async (e) => {
  const t = e.target;
  if (t.dataset.act === "filter") { W.filter = t.value; weighRender(); return; }
  if (t.dataset.act === "upload") { const files = [...t.files]; t.value = ""; await weighUploadFiles(files); return; }
  if (t.dataset.paperField) { await weighSavePaperField(t.dataset.paperField, t.value); return; }
  if (t.dataset.lineCheck) { await weighSaveLine(t.dataset.lineCheck, { checked: t.checked }); return; }
  if (t.dataset.lineField) {
    const id = t.closest("tr").dataset.lineId;
    if (t.dataset.lineField === "actual_kg") {
      const raw = t.value.trim().replace(",", ".");
      const line = weighLines(weighPaper(W.openId)).find((l) => l.id === id);
      if (raw !== "" && !/^\d+(\.\d+)?$/.test(raw)) {
        line._invalid = true;
        t.classList.add("w-input-bad");
        weighRefreshCheckDerived();
        return;
      }
      line._invalid = false;
      t.classList.remove("w-input-bad");
      const payload = { actual_kg: raw === "" ? null : Number(raw), edited: true };
      // Typing the number yourself is looking at it: it counts as checked.
      if (line.flag_reason) payload.checked = true;
      await weighSaveLine(id, payload);
    } else {
      await weighSaveLine(id, { description: t.value.trim() });
    }
  }
});

async function weighSaving(fn) {
  W.saving++;
  weighRefreshCheckDerived();
  try { return await fn(); }
  finally { W.saving--; weighRefreshCheckDerived(); weighSchedulePoll(); }
}

async function weighSaveLine(id, payload) {
  const p = weighPaper(W.openId);
  const line = weighLines(p).find((l) => l.id === id);
  if (!line) return;
  // Applied on screen first so the form never flickers back; undone if the
  // database refuses.
  const before = {};
  Object.keys(payload).forEach((k) => { before[k] = line[k]; });
  Object.assign(line, payload);
  await weighSaving(async () => {
    const { error } = await sb.from("weighing_lines").update(payload).eq("id", id);
    if (error) {
      Object.assign(line, before);
      W.message = { kind: "error", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message };
      weighRender();
    }
  });
}

async function weighSavePaperField(field, value) {
  const p = weighPaper(W.openId);
  const payload = { [field]: value === "" ? null : value };
  const before = p[field];
  p[field] = payload[field];
  await weighSaving(async () => {
    const { error } = await sb.from("weighing_papers").update(payload).eq("id", p.id);
    if (error) { p[field] = before; W.message = { kind: "error", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message }; weighRender(); return; }
    if (field === "customer_name") {
      const h = weighSection.querySelector(".w-cust");
      if (h) h.textContent = value || T("ไม่ทราบลูกค้า", "Unknown customer");
    }
  });
}

async function weighSetStatus(status) {
  const p = weighPaper(W.openId);
  await weighSaving(async () => {
    const { data, error } = await sb.from("weighing_papers").update({ status }).eq("id", p.id)
      .select("status, confirmed_by, confirmed_at").single();
    if (error) { W.message = { kind: "error", text: T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message }; return; }
    Object.assign(p, data);
    W.message = null;
  });
  weighRender();
}

async function weighReread() {
  const p = weighPaper(W.openId);
  if (weighLines(p).some((l) => l.edited) &&
      !confirm(T("อ่านใหม่จะแทนตัวเลขทั้งหมดในใบนี้ รวมถึงที่แก้ไว้ ต้องการอ่านใหม่?", "Reading again replaces every number on this paper, including your corrections. Read again?"))) return;
  try {
    await weighCallFn({ action: "read", paper_id: p.id }, await weighToken());
    p.status = "queued";
    W.message = null;
  } catch (err) {
    W.message = { kind: "error", text: T("อ่านใหม่ไม่ได้: ", "Could not read again: ") + err.message };
  }
  weighRender();
  weighSchedulePoll();
}

async function weighDeletePaper(id) {
  const p = weighPaper(id);
  if (!weighCanDelete(p)) return;
  const label = [p.po_number, p.customer_name].filter(Boolean).join(" · ");
  const question = p.status === "confirmed"
    ? T(`ใบงานนี้ยืนยันแล้ว${label ? " (" + label + ")" : ""} — ลบรูปและน้ำหนักทั้งหมด? บัญชีจะไม่เห็นใบนี้อีก และผู้บริหารจะได้รับแจ้ง`,
        `This paper is confirmed${label ? " (" + label + ")" : ""} — delete the photo and all its weights? Accounting will no longer see it; management is notified.`)
    : T(`ลบรูปใบงานนี้${label ? " (" + label + ")" : ""} และตัวเลขที่อ่านได้? ผู้บริหารจะได้รับแจ้ง`,
        `Delete this photo${label ? " (" + label + ")" : ""} and the numbers read from it? Management is notified.`);
  if (!confirm(question)) return;
  // .select() returns what was really deleted: the database refuses silently
  // (zero rows) if the paper was confirmed meanwhile on another screen — then
  // the photo must stay too.
  const { data, error } = await sb.from("weighing_papers").delete().eq("id", p.id).select("id");
  if (error || !data || !data.length) {
    W.message = { kind: "error", text: error
      ? T("ลบไม่สำเร็จ: ", "Could not delete: ") + error.message
      : T("ลบไม่ได้ — ใบงานนี้อาจถูกยืนยันไปแล้ว กด “แก้ไข” ก่อน", "Could not delete — this paper may have been confirmed meanwhile; press “Edit” first") };
    await weighLoad();
    return;
  }
  await sb.storage.from(WEIGH_BUCKET).remove([p.photo_path]);
  W.papers = W.papers.filter((x) => x.id !== p.id);
  if (W.openId === p.id) { W.view = "day"; W.openId = null; }
  W.message = { kind: "info", text: T("ลบใบงานแล้ว", "Paper deleted") };
  weighRender();
}

async function weighAddLine() {
  const p = weighPaper(W.openId);
  const next = weighLines(p).reduce((m, l) => Math.max(m, l.line_no), 0) + 1;
  const { data, error } = await sb.from("weighing_lines").insert({
    paper_id: p.id, line_no: next, description: "", weights: [], confidence: "high",
    edited: true, checked: true,
  }).select("*").single();
  if (error) { W.message = { kind: "error", text: T("เพิ่มรายการไม่ได้: ", "Could not add a line: ") + error.message }; weighRender(); return; }
  p.weighing_lines = weighLines(p).concat([data]);
  weighRender();
  const input = weighSection.querySelector(`tr[data-line-id="${data.id}"] .w-desc`);
  if (input) input.focus();
}

async function weighRemoveLine(id) {
  const p = weighPaper(W.openId);
  const line = weighLines(p).find((l) => l.id === id);
  if (!line || !confirm(T(`ลบรายการ “${line.description || "ไม่มีชื่อ"}”?`, `Remove the line “${line.description || "no name"}”?`))) return;
  const { error } = await sb.from("weighing_lines").delete().eq("id", id);
  if (error) { W.message = { kind: "error", text: T("ลบไม่สำเร็จ: ", "Could not delete: ") + error.message }; weighRender(); return; }
  p.weighing_lines = weighLines(p).filter((l) => l.id !== id);
  weighRender();
}

async function weighUploadFiles(files) {
  if (!files.length) return;
  const token = await weighToken();
  const items = files.map((f) => ({ name: f.name, state: "busy", error: null }));
  W.uploads = items;
  weighRender();
  for (let i = 0; i < files.length; i++) {
    try {
      const blob = await weighResizePhoto(files[i]);
      await weighUploadPhoto(sb, blob, { work_date: W.date }, token);
      items[i].state = "done";
    } catch (err) {
      items[i].state = "error";
      items[i].error = err.message;
    }
    if (W.view === "day") weighRender();
  }
  await weighLoad();
  setTimeout(() => {
    if (W.uploads === items && items.every((x) => x.state === "done")) { W.uploads = []; if (W.view === "day") weighRender(); }
  }, 4000);
}


// ------------------------------------------------------------ Excel export
function weighExport() {
  const header = WEIGH_LANG === "en"
    ? ["Weighing day", "Delivery", "Company", "PO", "Customer", "Line", "Product", "Ordered",
       "Ordered qty", "Unit", "Actual (kg)", "Written", "Difference (kg)", "kg per unit",
       "Status", "Confirmed by", "Confirmed at", "Note"]
    : ["วันที่ชั่ง", "วันที่ส่ง", "บริษัท", "PO", "ลูกค้า", "ลำดับ", "สินค้า", "สั่ง",
       "จำนวนสั่ง", "หน่วย", "น้ำหนักจริง (kg)", "ค่าที่เขียน", "ต่าง (kg)", "kg ต่อหน่วย",
       "สถานะ", "ยืนยันโดย", "เวลายืนยัน", "หมายเหตุ"];
  const rows = [header];
  W.papers.forEach((p) => {
    const lines = weighLines(p);
    const st = (weighStatusOf(p)).label;
    const base = [p.work_date, p.delivery_date || "", p.company || "", p.po_number || "", p.customer_name || ""];
    const tail = [st, p.confirmed_by ? (W.names[p.confirmed_by] || "") : "", p.confirmed_at ? weighTime(p.confirmed_at) : "", weighServerText(p.note || "")];
    if (!lines.length) { rows.push([...base, "", "", "", "", "", "", "", "", "", ...tail]); return; }
    lines.forEach((l) => {
      const d = weighDiff(l);
      rows.push([
        ...base, l.line_no, l.description || "", l.ordered_text || "",
        l.ordered_qty === null || l.ordered_qty === undefined ? "" : Number(l.ordered_qty),
        weighUnit(l.ordered_unit),
        l.actual_kg === null || l.actual_kg === undefined ? "" : Number(l.actual_kg),
        l.handwritten_text || "",
        d.kg === null ? "" : d.kg,
        d.perUnit === null ? "" : d.perUnit,
        ...tail,
      ]);
    });
  });
  // ASCII file name: some browsers drop a Thai download name entirely.
  downloadXlsx(`Weighing ${W.date}.xlsx`, T("น้ำหนักจริง ", "Actual weights ") + W.date, rows,
    [11, 11, 12, 13, 26, 6, 40, 12, 9, 7, 13, 14, 9, 10, 11, 14, 10, 30]);
}
