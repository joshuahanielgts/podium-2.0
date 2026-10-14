/* Podium — where the site finds its backend.
 *
 * The key below is the *publishable* (anon) key. It is designed to sit in a browser:
 * everything it can do is decided by the row-level policies in
 * supabase/migrations/20261015000001_policies.sql.
 *
 * The service_role key is the opposite — it ignores every policy. It must NEVER
 * be put in this file, in a workflow, or anywhere the browser can reach.
 */
window.PODIUM_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabaseKey: 'sb_publishable_YOUR-ANON-KEY',
};
