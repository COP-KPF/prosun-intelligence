// ============================================================================
// Session security (25 Nov 2026)
// ============================================================================
// Clément: "once the staff has logged in, even if we close the page, the
// account is still logged in." Before this, supabase-js kept the login in
// localStorage, which survives closing the browser, and renewed it forever.
//
//   1. The login lives in sessionStorage (app.js createClient uses
//      secAuthOptions()): closing the tab, the browser or the phone app ends it.
//      Old logins left in localStorage are revoked once and removed.
//   2. Idle timeout by role (SEC_IDLE_MIN). A 60-second warning first, then the
//      session is revoked on Supabase and the page reloads, so nothing stays in
//      memory.
//   3. Six hours at most after the password was typed, whatever the activity
//      (SEC_MAX_HOURS). Warning 10 minutes before.
//   4. Checked again when the page opens, so a browser that restores its tabs
//      ("Continue where you left off") cannot bring back an expired login.
//   5. Watermark: the user's name, email, date and time, faint, over every
//      screen once signed in. Screenshots and photos show who took them.
//      (25 Nov: "PROSUN · CONFIDENTIAL" line removed at Clément's request.)
//   6. Printing is blocked on the sensitive screens (Management, Payables,
//      Purchases, Sales, the CRM). Working screens still print.
//
// Loaded before app.js; uses app.js's `sb` and `myProfile` at run time only.
// None of this is a database rule: the database still decides what each
// account may read. This limits what an unattended or shared device exposes.
// ============================================================================

const SEC_MAX_HOURS = 6;
const SEC_WARN_IDLE_S = 60;          // warning shown this long before an idle sign-out
const SEC_WARN_MAX_MIN = 10;         // banner this long before the 6-hour sign-out
const SEC_IDLE_MIN = {               // minutes without a click, key or touch
  admin: 15, accounting: 15, company_director: 15,
  sale_support: 60, purchasing: 60, sales: 60, director: 60,
  production: 240, factory_admin: 240, delivery: 240,
};
const SEC_IDLE_DEFAULT = 15;
const SEC_STORAGE_KEY = "pace-session";
const SEC_K = { last: "pace-sec-last", idle: "pace-sec-idle", loginAt: "pace-sec-login-at", reason: "pace-sec-reason" };

// Screens that never print (also the CRM and the system chooser, i.e. any
// signed-in screen outside PACE).
const SEC_NOPRINT_VIEWS = ["overview", "management", "mgsummary", "mgorders", "mg-sales-kpis", "mg-purchases",
  "payables", "purchases", "sales-day", "sales-clients", "sales-deliveries", "sales-kpis"];

const SEC = { started: false, last: Date.now(), idleMin: SEC_IDLE_DEFAULT, loginAt: null, timer: null,
  wmTimer: null, wmText: "", signingOut: false, lastSaved: 0 };

function secGet(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
function secSet(k, v) { try { sessionStorage.setItem(k, String(v)); } catch (e) { /* storage off */ } }
function secDel(k) { try { sessionStorage.removeItem(k); } catch (e) { /* storage off */ } }

// Options for app.js's createClient.
function secAuthOptions() {
  let storage;
  try { sessionStorage.setItem("pace-sec-test", "1"); sessionStorage.removeItem("pace-sec-test"); storage = window.sessionStorage; }
  catch (e) { storage = undefined; }   // storage blocked: supabase-js keeps the login in memory only
  return { auth: { storage, storageKey: SEC_STORAGE_KEY, persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } };
}

// One time per browser: logins kept in localStorage before this change are
// revoked on Supabase (this session only) and removed.
(function secRetireOldLogins() {
  let keys = [];
  try { keys = Object.keys(localStorage).filter(k => /^sb-.*-auth-token/.test(k)); } catch (e) { return; }
  if (!keys.length || !window.supabase) return;
  const drop = () => keys.forEach(k => { try { localStorage.removeItem(k); } catch (e) { /* ignore */ } });
  try {
    const old = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY,
      { auth: { autoRefreshToken: false, persistSession: true, detectSessionInUrl: false } });
    Promise.resolve(old.auth.signOut({ scope: "local" })).catch(() => {}).finally(drop);
    setTimeout(drop, 5000);
  } catch (e) { drop(); }
})();

// Time the password (or code) was typed, from the token's own record (amr);
// survives page reloads and token refreshes.
function secLoginTime(session) {
  try {
    const p = session.access_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(decodeURIComponent(escape(atob(p))));
    const ts = (claims.amr || []).map(a => Number(a.timestamp)).filter(Boolean);
    if (ts.length) return Math.min(...ts) * 1000;
  } catch (e) { /* fall back below */ }
  const saved = Number(secGet(SEC_K.loginAt));
  return saved || null;
}

// Called by app.js init() when a stored session exists, before using it.
// Returns false (and signs out) when it is too old or idle for too long.
async function secCheckOnStart(session) {
  const now = Date.now();
  const last = Number(secGet(SEC_K.last));
  const idleMin = Number(secGet(SEC_K.idle)) || SEC_IDLE_DEFAULT;
  const loginAt = secLoginTime(session);
  if (!last || now - last > idleMin * 60000) { await secSignOut("idle"); return false; }
  if (!loginAt || now - loginAt > SEC_MAX_HOURS * 3600000) { await secSignOut("max"); return false; }
  return true;
}

// Called by app.js right after the password (and 2FA code) succeeded.
function secMarkLogin() {
  const now = Date.now();
  secSet(SEC_K.loginAt, now);
  secSet(SEC_K.last, now);
  SEC.last = now;
}

// Called by app.js onSignedIn() once the profile is loaded.
async function secStart() {
  const role = typeof myProfile !== "undefined" && myProfile ? myProfile.role : null;
  SEC.idleMin = SEC_IDLE_MIN[role] || SEC_IDLE_DEFAULT;
  secSet(SEC_K.idle, SEC.idleMin);
  let session = null, email = "";
  try { ({ data: { session } } = await sb.auth.getSession()); } catch (e) { /* ignore */ }
  if (session && session.user) email = session.user.email || "";
  SEC.loginAt = (session && secLoginTime(session)) || Number(secGet(SEC_K.loginAt)) || Date.now();
  if (!secGet(SEC_K.loginAt)) secSet(SEC_K.loginAt, SEC.loginAt);
  SEC.last = Number(secGet(SEC_K.last)) || Date.now();
  secTouch(true);
  if (!SEC.started) {
    SEC.started = true;
    ["pointerdown", "keydown", "wheel", "touchstart", "scroll"].forEach(ev =>
      document.addEventListener(ev, () => secTouch(false), { capture: true, passive: true }));
    let lastMove = 0;
    document.addEventListener("mousemove", () => {
      const t = Date.now(); if (t - lastMove > 5000) { lastMove = t; secTouch(false); }
    }, { capture: true, passive: true });
    document.addEventListener("visibilitychange", () => { if (!document.hidden) secTick(); });
    window.addEventListener("focus", secTick);
    window.addEventListener("beforeprint", secBeforePrint);
    window.addEventListener("afterprint", () => document.body.classList.remove("sec-noprint"));
  }
  clearInterval(SEC.timer);
  SEC.timer = setInterval(secTick, 10000);
  secWatermark(myProfile ? myProfile.full_name : "", email);
}

function secTouch(force) {
  if (SEC.signingOut) return;
  const warn = document.getElementById("sec-idle-warn");
  // While the warning shows, only its button (or a key) keeps the session.
  if (!force && warn && !warn.classList.contains("hidden")) return;
  SEC.last = Date.now();
  if (force || SEC.last - SEC.lastSaved > 5000) { secSet(SEC_K.last, SEC.last); SEC.lastSaved = SEC.last; }
}

function secTick() {
  if (!SEC.started || SEC.signingOut || typeof myProfile === "undefined" || !myProfile) return;
  const now = Date.now();
  const idleLeft = SEC.idleMin * 60000 - (now - SEC.last);
  const maxLeft = SEC_MAX_HOURS * 3600000 - (now - SEC.loginAt);
  if (maxLeft <= 0) { secSignOut("max"); return; }
  if (idleLeft <= 0) { secSignOut("idle"); return; }
  secShowIdleWarning(idleLeft <= SEC_WARN_IDLE_S * 1000 ? Math.ceil(idleLeft / 1000) : 0);
  secShowMaxBanner(maxLeft <= SEC_WARN_MAX_MIN * 60000 ? Math.ceil(maxLeft / 60000) : 0);
}

function secShowIdleWarning(seconds) {
  let el = document.getElementById("sec-idle-warn");
  if (!seconds) { if (el) el.classList.add("hidden"); clearInterval(SEC.countdown); return; }
  if (!el) {
    el = document.createElement("div");
    el.id = "sec-idle-warn";
    el.className = "sec-overlay hidden";
    el.setAttribute("role", "alertdialog");
    el.setAttribute("aria-live", "assertive");
    el.innerHTML = '<div class="sec-card">'
      + '<div class="sec-title">ไม่มีการใช้งาน · No activity</div>'
      + '<p>ระบบจะออกจากระบบใน <b class="sec-count"></b> วินาที<br>'
      + 'You will be signed out in <b class="sec-count"></b> seconds.</p>'
      + '<button type="button" class="btn-primary" id="sec-stay">ใช้งานต่อ · Stay signed in</button></div>';
    document.body.appendChild(el);
    el.querySelector("#sec-stay").addEventListener("click", () => {
      el.classList.add("hidden"); clearInterval(SEC.countdown); secTouch(true);
    });
    el.addEventListener("keydown", e => { if (e.key === "Escape" || e.key === "Enter") el.querySelector("#sec-stay").click(); });
  }
  const wasHidden = el.classList.contains("hidden");
  el.classList.remove("hidden");
  const paint = () => {
    const left = Math.max(0, Math.ceil((SEC.idleMin * 60000 - (Date.now() - SEC.last)) / 1000));
    el.querySelectorAll(".sec-count").forEach(c => { c.textContent = left; });
    if (left <= 0) secTick();
  };
  paint();
  if (wasHidden) {
    clearInterval(SEC.countdown);
    SEC.countdown = setInterval(paint, 1000);
    el.querySelector("#sec-stay").focus();
  }
}

function secShowMaxBanner(minutes) {
  let el = document.getElementById("sec-max-banner");
  if (!minutes) { if (el) el.classList.add("hidden"); return; }
  if (!el) {
    el = document.createElement("div");
    el.id = "sec-max-banner";
    el.className = "sec-banner";
    el.setAttribute("role", "status");
    document.body.appendChild(el);
  }
  const at = new Date(SEC.loginAt + SEC_MAX_HOURS * 3600000)
    .toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  el.textContent = `ครบ ${SEC_MAX_HOURS} ชั่วโมง: ระบบจะออกจากระบบเวลา ${at} (อีก ${minutes} นาที) กรุณาบันทึกงาน · `
    + `${SEC_MAX_HOURS}-hour limit: you will be signed out at ${at} (in ${minutes} min). Save your work.`;
  el.classList.remove("hidden");
}

// Revokes this session on Supabase, clears what is stored in the tab, and
// reloads so no data stays in memory. reason: idle | max | manual.
async function secSignOut(reason, scope) {
  if (SEC.signingOut) return;
  SEC.signingOut = true;
  clearInterval(SEC.timer);
  try { await Promise.race([sb.auth.signOut({ scope: scope || "local" }), new Promise(r => setTimeout(r, 4000))]); }
  catch (e) { /* offline: the stored login is removed below anyway */ }
  try { Object.keys(sessionStorage).filter(k => k.startsWith(SEC_STORAGE_KEY)).forEach(k => sessionStorage.removeItem(k)); }
  catch (e) { /* ignore */ }
  [SEC_K.last, SEC_K.loginAt, SEC_K.idle].forEach(secDel);
  if (reason && reason !== "manual") secSet(SEC_K.reason, reason);
  location.reload();
}

// Login screen: why the last session ended.
(function secLoginNote() {
  const reason = secGet(SEC_K.reason);
  if (!reason) return;
  secDel(SEC_K.reason);
  const form = document.getElementById("login-form");
  if (!form) return;
  const note = document.createElement("div");
  note.className = "sec-login-note";
  note.id = "sec-login-note";
  note.textContent = reason === "max"
    ? `ออกจากระบบอัตโนมัติหลังใช้งานครบ ${SEC_MAX_HOURS} ชั่วโมง กรุณาเข้าสู่ระบบอีกครั้ง · Signed out automatically after ${SEC_MAX_HOURS} hours. Please sign in again.`
    : "ออกจากระบบอัตโนมัติเนื่องจากไม่มีการใช้งาน กรุณาเข้าสู่ระบบอีกครั้ง · Signed out automatically after a period without activity. Please sign in again.";
  form.insertBefore(note, form.querySelector("label"));
})();

// ------------------------------------------------------------------ watermark
function secWatermark(name, email) {
  let el = document.getElementById("sec-watermark");
  const paint = () => {
    const d = new Date();
    const stamp = d.toLocaleDateString("en-GB") + " " + d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
    const text = [name, email, stamp].filter(Boolean).join(" · ");
    // Put it back if it was removed or hidden in the browser's tools.
    if (!document.getElementById("sec-watermark")) { el = null; }
    if (!el) {
      el = document.createElement("div");
      el.id = "sec-watermark";
      el.setAttribute("aria-hidden", "true");
      document.body.appendChild(el);
      SEC.wmText = "";
    }
    if (text !== SEC.wmText) {
      SEC.wmText = text;
      const esc = s => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]));
      const t = esc(text);
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="460" height="260">'
        + '<g transform="rotate(-24 230 130)" font-family="Sarabun, Tahoma, Arial, sans-serif" font-size="14" fill="#1d1d1f" fill-opacity="0.085">'
        + `<text x="230" y="135" text-anchor="middle">${t}</text></g></svg>`;
      SEC.wmUrl = `url("data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}")`;
    }
    // Reset anything changed in the browser's tools (hidden, moved, emptied).
    el.className = "sec-watermark";
    el.style.cssText = "";
    el.style.backgroundImage = SEC.wmUrl;
  };
  paint();
  clearInterval(SEC.wmTimer);
  SEC.wmTimer = setInterval(paint, 30000);
}

// ------------------------------------------------------------------ printing
function secBeforePrint() {
  const signedIn = typeof myProfile !== "undefined" && !!myProfile;
  if (!signedIn) return;
  const inPace = document.body.classList.contains("pace-mode") || (typeof PACE_ROLES !== "undefined" && PACE_ROLES.includes(myProfile.role))
    || myProfile.role === "factory_admin";
  const view = typeof paceView !== "undefined" ? paceView : "";
  const block = !inPace || SEC_NOPRINT_VIEWS.includes(view);
  document.body.classList.toggle("sec-noprint", block);
}
