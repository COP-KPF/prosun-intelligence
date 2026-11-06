// ============================================================================
// Payables — helpers shared by the PC screen (payables.js) and the phone camera
// page (ap-capture.js). Migration 025 + edge function `payables`.
// Loaded after weighing-common.js (T, weighResizePhoto).
// ============================================================================

const PAY_BUCKET = "payable-documents";
const PAY_FUNCTION = "payables";
const PAY_MAX_PDF = 15 * 1024 * 1024;

async function payCallFn(body, accessToken) {
  let res;
  try {
    res = await fetch(SUPABASE_URL + "/functions/v1/" + PAY_FUNCTION, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: "Bearer " + (accessToken || SUPABASE_ANON_KEY),
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    const err = new Error(T("ไม่มีสัญญาณอินเทอร์เน็ต", "No internet connection"));
    err.code = "offline";
    throw err;
  }
  let data = null;
  try { data = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) {
    const err = new Error((data && data.error) || (T("ข้อผิดพลาด ", "Error ") + res.status));
    err.status = res.status;
    err.code = data && data.code;
    throw err;
  }
  return data;
}

// Photos are brought down to JPEG; a PDF is sent as it is.
async function payPrepareFile(file) {
  if (file.type === "application/pdf") {
    if (file.size > PAY_MAX_PDF) throw new Error(T("ไฟล์ PDF ใหญ่เกิน 15 MB", "The PDF is larger than 15 MB"));
    return { blob: file, type: "application/pdf" };
  }
  return { blob: await weighResizePhoto(file), type: "image/jpeg" };
}

async function payUploadFile(client, prepared, extraBody, accessToken) {
  const u = await payCallFn(Object.assign({ action: "upload_url", file_type: prepared.type }, extraBody), accessToken);
  const { error } = await client.storage.from(PAY_BUCKET)
    .uploadToSignedUrl(u.path, u.upload_token, prepared.blob, { contentType: prepared.type });
  if (error) throw new Error(T("ส่งไฟล์ไม่สำเร็จ: ", "Upload failed: ") + (error.message || error));
  await payCallFn(Object.assign({ action: "uploaded", bill_id: u.bill_id }, extraBody), accessToken);
  return u.bill_id;
}
