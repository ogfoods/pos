// Supabase project settings: Dashboard -> Project Settings -> API.
// The anon/publishable key is safe to expose; tables are locked by RLS
// and all access goes through RPC functions in supabase/schema.sql.
window.APP_CONFIG = {
  SUPABASE_URL: "https://sprkjslljfsmzgnibdgr.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_pE2xtb_js6B0saOiqrdF9g_Tgd7W145",

  SHOP_NAME: "My Cafe",
  CURRENCY: "₹",
  // Sample UPI payee used for the payment QR. Replace with the real one.
  UPI_ID: "sample@upi",
  // Prefix added to 10-digit phone numbers for WhatsApp receipt links.
  COUNTRY_CODE: "91",
};
