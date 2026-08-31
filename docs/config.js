// ----------------------------------------------------------------------------
// Fill these in from your Supabase project: Project Settings > API
// The "anon public" key is DESIGNED to be public and safe to ship in a
// front-end file like this — it cannot read or write anything the Row Level
// Security policies in sql/schema.sql don't explicitly allow. Never put the
// "service_role" key here or anywhere in this repo.
// ----------------------------------------------------------------------------
const SUPABASE_URL = "https://svbrujflslpkpiqmxolp.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_33qrEl7S8QAfFi5w2H0mXQ_a2TckrZk";

// ----------------------------------------------------------------------------
// EmailJS — sends Clément a notification email whenever a rep generates a
// quotation. Free tier, no backend needed (same reasoning as Supabase above:
// this site has no server, so anything that "sends" something has to be a
// service designed to be called straight from the browser).
//
// One-time setup at https://www.emailjs.com :
//   1. Create a free account, connect an email address to send from
//      (Email Services > Add New Service — Gmail works fine).
//   2. Email Templates > Create New Template. Use these variable names in
//      the template body so app.js can fill them in:
//        {{quote_number}} {{entity}} {{customer_name}} {{customer_company}}
//        {{total}} {{valid_until}} {{rep_name}} {{client_name}}
//      Set the "To email" field in the template to your own address.
//   3. Copy your Public Key (Account > General), Service ID, and Template ID
//      into the three values below.
// Leave these as-is (or blank) and quotation generation still works — you
// just won't get the notification email until these are filled in.
// ----------------------------------------------------------------------------
const EMAILJS_PUBLIC_KEY = "";
const EMAILJS_SERVICE_ID = "";
const EMAILJS_TEMPLATE_ID = "";
