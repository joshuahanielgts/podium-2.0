/* Podium — Slido-style Live Rating Database Client.
 *
 * Provides minimal, secure, and robust methods for:
 * 1. Host Coordinator: Google OAuth, session setup, presentation switcher, and live controls.
 * 2. Audience: Anonymous auth, public session lookup, and 1-5 star rating.
 * 3. Big Screen: Realtime subscriptions and stats/leaderboard retrieval.
 */

(function podiumDatabase() {
  const config = window.PODIUM_CONFIG;

  if (!config?.supabaseUrl || !config?.supabaseKey || !window.supabase) {
    console.warn('Podium: Supabase config missing or SDK not loaded.');
    window.podiumDb = null;
    return;
  }

  const client = window.supabase.createClient(config.supabaseUrl, config.supabaseKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });

  const ok = (data) => ({ data, error: null });
  const bad = (error) => ({ data: null, error: error?.message || String(error) });

  const CROCKFORD_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  function generateCode() {
    let result = '';
    const array = new Uint8Array(6);
    crypto.getRandomValues(array);
    for (let i = 0; i < 6; i++) {
      result += CROCKFORD_CHARS[array[i] % CROCKFORD_CHARS.length];
    }
    return result;
  }

  const db = {
    client,

    // ------------------------------------------------ AUTHENTICATION
    async signInHost(redirectTo) {
      const { error } = await client.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: redirectTo || window.location.href },
      });
      return error ? bad(error) : ok(true);
    },

    async signInAnonymously() {
      // If already signed in (either anonymous or Google), return current session
      const { data: sessionData } = await client.auth.getSession();
      if (sessionData?.session?.user) {
        return ok(sessionData.session.user);
      }

      const { data, error } = await client.auth.signInAnonymously();
      return error ? bad(error) : ok(data?.user || null);
    },

    async signOut() {
      const { error } = await client.auth.signOut();
      return error ? bad(error) : ok(true);
    },

    async session() {
      const { data } = await client.auth.getSession();
      return data?.session || null;
    },

    async user() {
      const sess = await db.session();
      return sess?.user || null;
    },

    onAuthStateChange(callback) {
      return client.auth.onAuthStateChange((event, session) => {
        callback(event, session);
      });
    },

    generateCode,

    // ------------------------------------------------ HOST / COORDINATOR
    async createSession({ title, college, presentationNames }) {
      const user = await db.user();
      if (!user) return bad('Host must be signed in');

      const code = generateCode();
      const { data: session, error: sessErr } = await client
        .from('sessions')
        .insert({
          code,
          host_id: user.id,
          title: title.trim(),
          college: college ? college.trim() : null,
          rating_open: false,
          show_scores: true,
          status: 'live',
        })
        .select()
        .single();

      if (sessErr) return bad(sessErr);

      // Insert presentation rows if provided
      let presentations = [];
      const names = Array.isArray(presentationNames) ? presentationNames.filter(Boolean) : [];
      if (names.length > 0) {
        const rows = names.map((name, idx) => ({
          session_id: session.id,
          name: name.trim(),
          position: idx + 1,
        }));

        const { data: presData, error: presErr } = await client
          .from('presentations')
          .insert(rows)
          .select()
          .order('position', { ascending: true });

        if (presErr) return bad(presErr);
        presentations = presData || [];

        // Set the first presentation as the active one
        if (presentations.length > 0) {
          const { error: activeErr } = await client
            .from('sessions')
            .update({ current_presentation_id: presentations[0].id })
            .eq('id', session.id);

          if (!activeErr) {
            session.current_presentation_id = presentations[0].id;
          }
        }
      }

      return ok({ session, presentations });
    },

    async getMySessions() {
      const user = await db.user();
      if (!user) return ok([]);

      const { data, error } = await client
        .from('sessions')
        .select('*, presentations(*)')
        .eq('host_id', user.id)
        .order('created_at', { ascending: false });

      return error ? bad(error) : ok(data || []);
    },

    async getHostSession(sessionId) {
      const user = await db.user();
      if (!user) return bad('Host not signed in');

      const { data: session, error: sessErr } = await client
        .from('sessions')
        .select('*')
        .eq('id', sessionId)
        .single();

      if (sessErr) return bad(sessErr);

      const { data: presentations, error: presErr } = await client
        .from('presentations')
        .select('*')
        .eq('session_id', sessionId)
        .order('position', { ascending: true });

      if (presErr) return bad(presErr);

      return ok({ session, presentations: presentations || [] });
    },

    async updateSession(sessionId, changes) {
      const { data, error } = await client
        .from('sessions')
        .update(changes)
        .eq('id', sessionId)
        .select()
        .single();

      return error ? bad(error) : ok(data);
    },

    async addPresentation(sessionId, name, position) {
      const { data, error } = await client
        .from('presentations')
        .insert({
          session_id: sessionId,
          name: name.trim(),
          position: position || 1,
        })
        .select()
        .single();

      return error ? bad(error) : ok(data);
    },

    async deletePresentation(presentationId) {
      const { error } = await client
        .from('presentations')
        .delete()
        .eq('id', presentationId);

      return error ? bad(error) : ok(true);
    },

    async reorderPresentations(sessionId, orderedIds) {
      // Update each presentation's position
      const updates = orderedIds.map((id, index) =>
        client.from('presentations').update({ position: index + 1 }).eq('id', id)
      );

      const results = await Promise.all(updates);
      const failed = results.find((r) => r.error);
      return failed ? bad(failed.error) : ok(true);
    },

    // ------------------------------------------------ PUBLIC RPCs
    async getSessionPublic(code) {
      const normCode = String(code || '').toUpperCase().trim();
      const { data, error } = await client.rpc('get_session_public', { lookup_code: normCode });
      return error ? bad(error) : ok(data);
    },

    async getStats(presentationId) {
      if (!presentationId) return ok(null);
      const { data, error } = await client.rpc('get_stats', { presentation_id: presentationId });
      return error ? bad(error) : ok(data);
    },

    async getLeaderboard(sessionCode) {
      const normCode = String(sessionCode || '').toUpperCase().trim();
      const { data, error } = await client.rpc('get_leaderboard', { session_code: normCode });
      return error ? bad(error) : ok(data || []);
    },

    async ratePresentation(presentationId, stars) {
      // Ensure user has anonymous session
      const userRes = await db.signInAnonymously();
      if (userRes.error) return bad(userRes.error);

      const { data, error } = await client.rpc('rate_presentation', {
        presentation_id: presentationId,
        stars: parseInt(stars, 10),
      });

      return error ? bad(error) : ok(data);
    },

    async getMyRating(presentationId) {
      if (!presentationId) return ok(null);
      const sess = await db.session();
      if (!sess) return ok(null);

      const { data, error } = await client.rpc('get_my_rating', { presentation_id: presentationId });
      return error ? bad(error) : ok(data?.stars || null);
    },

    // ------------------------------------------------ REALTIME HELPER
    subscribeToSession(sessionId, onSessionChange, onRatingChange) {
      const channel = client
        .channel(`session-${sessionId}`)
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'sessions', filter: `id=eq.${sessionId}` },
          (payload) => onSessionChange && onSessionChange(payload)
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'ratings', filter: `session_id=eq.${sessionId}` },
          (payload) => onRatingChange && onRatingChange(payload)
        )
        .subscribe();

      return () => {
        client.removeChannel(channel);
      };
    },
  };

  window.podiumDb = db;
})();
