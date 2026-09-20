/* Connection settings for the online database (see README.md).

   Both values empty = local mode: no sign-in, and records are saved only in this browser.

   supabaseAnonKey is the project's public "anon" / "publishable" key. It is safe to publish: what each
   signed-in person can see or change is enforced by the database. Never put the service_role / secret
   key here. */
window.INC_CONFIG = {
  supabaseUrl: "https://ldwcgumoidfolxabwkqk.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imxkd2NndW1vaWRmb2x4YWJ3a3FrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk5MDAxNjgsImV4cCI6MjEwNTQ3NjE2OH0.W3oTVMOYI1Z9vChCEOHy_32h0U--htCL2EfF_M7Mwdg",

  /* PROTOTYPE ONLY: skip sign-in entirely. The portal signs in silently in the background and, with
     open_prototype turned on in the database, treats everyone as an admin.

     Anyone who can reach the page can then read and change every record, so use this only with sample
     data. Set it back to false, and run
         update public.app_settings set open_prototype = false;
     before any real attendance goes in. */
  prototypeNoLogin: true
};
