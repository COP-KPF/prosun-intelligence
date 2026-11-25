// ============================================================================
// Two-step verification (authenticator app) — Migration 050, 25 Nov 2026
// ============================================================================
// After the password, people whose role is in public.mfa_policy (admin,
// accounting, company director) must type the 6-digit code from an
// authenticator app (Google Authenticator, Microsoft Authenticator …).
//   - First time: a QR code to scan, then the code.
//   - Next times: the code.
//   - Anyone who set up the app (whatever their role) is asked for the code.
// The database enforces all of this (Migration 050); this file is the screens.
// Loaded before app.js; uses app.js's `sb` at run time.
// ============================================================================

const MFA_ROLES_FALLBACK = ["admin", "accounting", "company_director"];   // until 050 runs

function mfaEsc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function mfaRequired(profile) {
  try {
    const { data, error } = await sb.rpc("my_mfa_required");
    if (!error && data && typeof data.required === "boolean") return data.required;
  } catch (e) { /* function not there yet */ }
  return MFA_ROLES_FALLBACK.includes(profile.role);
}

// Called by app.js onSignedIn() once the profile is read. Resolves true when
// the session may continue (code passed, or not needed); stays on the code
// screen until then. Signing out reloads the page.
async function mfaGate(profile) {
  let aal = null;
  try { ({ data: aal } = await sb.auth.mfa.getAuthenticatorAssuranceLevel()); } catch (e) { /* ignore */ }
  if (aal && aal.currentLevel === "aal2") return true;
  let factors = { totp: [], all: [] };
  try { const r = await sb.auth.mfa.listFactors(); if (!r.error && r.data) factors = r.data; } catch (e) { /* ignore */ }
  const verified = (factors.totp || []).filter((f) => f.status === "verified");
  if (verified.length) return mfaCodeScreen(verified[0]);
  if (await mfaRequired(profile)) return mfaEnrollScreen(factors.all || []);
  return true;
}

function mfaCard() {
  const form = document.getElementById("login-form");
  if (form) form.classList.add("hidden");
  let card = document.getElementById("mfa-card");
  if (!card) {
    card = document.createElement("div");
    card.id = "mfa-card";
    card.className = "login-card mfa-card";
    document.getElementById("login-screen").appendChild(card);
  }
  document.getElementById("login-screen").classList.remove("hidden");
  document.getElementById("app-screen").classList.add("hidden");
  return card;
}

function mfaCodeInput() {
  return '<label for="mfa-input">รหัส 6 หลัก · 6-digit code</label>'
    + '<input type="text" id="mfa-input" class="mfa-input" inputmode="numeric" pattern="[0-9]*" maxlength="6" '
    + 'autocomplete="one-time-code" autocapitalize="off" spellcheck="false" />';
}

function mfaFooter() {
  return '<div class="error-text" id="mfa-error" role="alert"></div>'
    + '<button type="button" class="mfa-link" id="mfa-signout">ออกจากระบบ · Sign out</button>';
}

function mfaWrongCode(err) {
  const m = String((err && err.message) || "");
  if (/invalid|incorrect|expired|totp/i.test(m)) {
    return "รหัสไม่ถูกต้อง ลองอีกครั้ง (รหัสเปลี่ยนทุก 30 วินาที) · Wrong code — try again (the code changes every 30 seconds).";
  }
  return m || "เกิดข้อผิดพลาด ลองอีกครั้ง · Something went wrong — try again.";
}

// Wires the input and button; onCode(code) returns an error or null.
function mfaWire(card, onCode) {
  return new Promise((resolve) => {
    const input = card.querySelector("#mfa-input");
    const btn = card.querySelector("#mfa-confirm");
    const errEl = card.querySelector("#mfa-error");
    const go = async () => {
      const code = input.value.replace(/\D/g, "");
      if (code.length !== 6) { errEl.textContent = "กรุณาใส่รหัส 6 หลัก · Please type the 6 digits."; input.focus(); return; }
      btn.disabled = true; errEl.textContent = "";
      const err = await onCode(code);
      btn.disabled = false;
      if (err) { errEl.textContent = mfaWrongCode(err); input.value = ""; input.focus(); return; }
      card.remove();
      document.getElementById("login-form").classList.remove("hidden");
      resolve(true);
    };
    btn.addEventListener("click", go);
    input.addEventListener("input", () => {
      input.value = input.value.replace(/\D/g, "").slice(0, 6);
      if (input.value.length === 6) go();
    });
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
    card.querySelector("#mfa-signout").addEventListener("click", () => secSignOut("manual", "local"));
    setTimeout(() => input.focus(), 50);
  });
}

function mfaCodeScreen(factor) {
  const card = mfaCard();
  card.innerHTML = '<img src="logo.png" class="login-logo" alt="" width="120" height="90" />'
    + '<h1>รหัสยืนยัน · Verification code</h1>'
    + '<p class="subtitle">เปิดแอป Authenticator บนโทรศัพท์ แล้วพิมพ์รหัส 6 หลักของ PROSUN PACE<br>'
    + 'Open the authenticator app on your phone and type the 6-digit PROSUN PACE code.</p>'
    + mfaCodeInput()
    + '<button type="button" class="btn-primary" id="mfa-confirm">ยืนยัน · Confirm</button>'
    + '<p class="mfa-help">ทำโทรศัพท์หาย? แจ้งผู้ดูแลระบบให้รีเซ็ต · Lost your phone? Ask an admin to reset your two-step verification.</p>'
    + mfaFooter();
  return mfaWire(card, async (code) => {
    const { error } = await sb.auth.mfa.challengeAndVerify({ factorId: factor.id, code });
    return error || null;
  });
}

async function mfaEnrollScreen(allFactors) {
  const card = mfaCard();
  card.innerHTML = '<h1>ตั้งค่าการยืนยัน 2 ขั้นตอน · Set up two-step verification</h1>'
    + '<p class="subtitle">กำลังเตรียม… · Preparing…</p>' + mfaFooter();
  card.querySelector("#mfa-signout").addEventListener("click", () => secSignOut("manual", "local"));
  // Leftovers from an earlier, unfinished setup.
  for (const f of allFactors.filter((x) => x.status !== "verified")) {
    try { await sb.auth.mfa.unenroll({ factorId: f.id }); } catch (e) { /* ignore */ }
  }
  const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
  const { data, error } = await sb.auth.mfa.enroll({ factorType: "totp", issuer: "PROSUN PACE", friendlyName: "PACE " + stamp });
  if (error || !data) {
    card.querySelector("#mfa-error").textContent = (error && error.message) || "Could not start the setup — sign out and try again.";
    return new Promise(() => {});   // stays here; Sign out reloads
  }
  const secret = (data.totp.secret || "").replace(/(.{4})/g, "$1 ").trim();
  // supabase-js prefixes the raw SVG without encoding it; a "#" in a colour
  // would cut the image. Re-encode it.
  let qr = String(data.totp.qr_code || "");
  const prefix = qr.match(/^data:image\/svg\+xml;(utf-8|charset=utf-8),/i);
  const raw = prefix ? qr.slice(prefix[0].length) : qr;
  if (raw.trim().startsWith("<")) qr = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(raw);
  card.innerHTML = '<h1>ตั้งค่าการยืนยัน 2 ขั้นตอน · Set up two-step verification</h1>'
    + '<p class="subtitle">บัญชีของคุณต้องใช้รหัสจากโทรศัพท์ทุกครั้งที่เข้าสู่ระบบ ทำครั้งเดียว ใช้เวลา 2 นาที<br>'
    + 'Your account needs a code from your phone at each sign-in. One-time setup, about 2 minutes.</p>'
    + '<ol class="mfa-steps">'
    + '<li>ติดตั้งแอป <b>Google Authenticator</b> หรือ <b>Microsoft Authenticator</b> (ฟรี) · Install <b>Google Authenticator</b> or <b>Microsoft Authenticator</b> (free).</li>'
    + '<li>ในแอป กด <b>+</b> แล้วสแกน QR code นี้ · In the app, tap <b>+</b> and scan this QR code.</li>'
    + '<li>พิมพ์รหัส 6 หลักที่แอปแสดง · Type the 6-digit code the app shows.</li></ol>'
    + `<div class="mfa-qr"><img src="${mfaEsc(qr)}" alt="QR code" width="190" height="190" /></div>`
    + '<details class="mfa-manual"><summary>สแกนไม่ได้? · Can\'t scan?</summary>'
    + `<p>ใส่คีย์นี้ในแอป · Enter this key in the app:</p><code class="mfa-secret">${mfaEsc(secret)}</code></details>`
    + mfaCodeInput()
    + '<button type="button" class="btn-primary" id="mfa-confirm">ยืนยัน · Confirm</button>'
    + mfaFooter();
  return mfaWire(card, async (code) => {
    const { error: e2 } = await sb.auth.mfa.challengeAndVerify({ factorId: data.id, code });
    return e2 || null;
  });
}
