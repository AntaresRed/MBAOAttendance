/* Connection settings for the online database (see README.md).
   Leave both values empty to run in local mode, where records are saved only in this browser.

   supabaseAnonKey is the project's public "anon" / "publishable" key. It is safe to publish: what each
   signed-in person can see or change is enforced by the database. Never put the service_role / secret
   key here. */
window.INC_CONFIG = {
  supabaseUrl: "",
  supabaseAnonKey: ""
};
