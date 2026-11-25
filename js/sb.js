/* Seeds Studio ↔ Supabase bridge.
   Exposes window.SEEDS_SB with the same small db/user API the page already uses
   (doc().onSnapshot/set/update/delete, collection().onSnapshot/add, user.id/canEdit),
   plus auth helpers and the server-side gacha pull. */
(() => {
  const C = window.SEEDS_SUPABASE || {};
  if (!C.url || !C.anonKey) return; // not configured → page stays in demo mode

  const LIB = 'js/vendor/supabase.js'; // @supabase/supabase-js 2.119.0 (MIT)
  const lib = new Promise((ok, no) => {
    if (window.supabase) return ok(window.supabase);
    const s = document.createElement('script');
    s.src = LIB; s.async = true;
    s.onload = () => ok(window.supabase); s.onerror = no;
    document.head.appendChild(s);
  });
  let sb = null, session = null;
  const ready = lib.then(async L => {
    sb = L.createClient(C.url, C.anonKey);
    session = (await sb.auth.getSession()).data.session;
    sb.auth.onAuthStateChange((_e, s) => { session = s; });
    return sb;
  });

  const ms = t => (t ? Date.parse(t) : 0);
  const KEY = { players: 'id', orders: 'id', settings: 'key' };
  const FROM = {
    players: r => ({ nick: r.nick, handle: r.handle, avatar: r.avatar, createdAt: ms(r.created_at),
                     used: r.used, history: r.history || [], claimed: r.claimed }),
    orders: r => ({ client: r.client, contact: r.contact, service: r.service, price: r.price, status: r.status,
                    user: r.user_ref || '', notes: r.notes, createdAt: ms(r.created_at) }),
    settings: r => r.data
  };
  const TO = {
    orders: d => { const o = {}; for (const [k, v] of Object.entries(d)) {
      if (k === 'user') o.user_ref = v || null; else if (k !== 'createdAt') o[k] = v; } return o; }
  };
  const ok = ({ error }) => { if (error) throw error; };
  const snap = (id, data) => ({ id, exists: !!data, data: () => data, metadata: { fromCache: false, hasPendingWrites: false } });

  // initial load + refetch on every realtime change of the table
  function live(table, load, cb, err) {
    let alive = true;
    const run = () => load().then(v => alive && cb(v)).catch(e => alive && err && err(e));
    run();
    const ch = sb.channel('rt-' + table + '-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table }, run).subscribe();
    return () => { alive = false; sb.removeChannel(ch); };
  }

  const db = {
    doc(path) {
      const [t, id] = path.split('/');
      const get = async () => {
        const { data, error } = await sb.from(t).select('*').eq(KEY[t], id).maybeSingle();
        if (error) throw error;
        return snap(id, data ? FROM[t](data) : null);
      };
      return {
        onSnapshot: (cb, err) => live(t, get, cb, err),
        async set(d) {
          if (t === 'settings') return ok(await sb.from(t).upsert({ key: id, data: d }));
          if (t === 'players') return ok(await sb.from(t).update({ nick: d.nick, handle: d.handle, avatar: d.avatar }).eq('id', id));
          if (t === 'orders') return ok(await sb.from(t).upsert({ id, ...TO.orders(d) }));
        },
        async update(d) {
          if (t === 'players') {
            if ('used' in d) return ok(await sb.rpc('admin_reset_player', { p: id }));
            if ('claimed' in d) return ok(await sb.rpc('admin_set_claimed', { p: id, v: !!d.claimed }));
            const o = {}; ['nick', 'handle', 'avatar'].forEach(k => { if (k in d) o[k] = d[k]; });
            return ok(await sb.from(t).update(o).eq('id', id));
          }
          if (t === 'orders') return ok(await sb.from(t).update(TO.orders(d)).eq('id', id));
          if (t === 'settings') return ok(await sb.from(t).upsert({ key: id, data: d }));
        },
        async delete() { return ok(await sb.from(t).delete().eq(KEY[t], id)); }
      };
    },
    collection(t) {
      return {
        onSnapshot: (cb, err) => live(t, async () => {
          const { data, error } = await sb.from(t).select('*');
          if (error) throw error;
          return { docs: data.map(r => snap(r[KEY[t]], FROM[t](r))) };
        }, cb, err),
        async add(d) {
          const { data, error } = await sb.from(t).insert(TO[t] ? TO[t](d) : d).select().single();
          if (error) throw error;
          return { id: data[KEY[t]] };
        }
      };
    }
  };

  const user = {
    id: async () => session?.user?.id || null,
    canEdit: async () => { if (!session) return false; const { data } = await sb.rpc('is_admin'); return !!data; }
  };

  window.SEEDS_SB = {
    use: async n => { await ready; return n === 'db' ? db : n === 'user' ? user : null; },
    async signUp({ email, password, nick, handle, avatar }) {
      await ready;
      const { data, error } = await sb.auth.signUp({ email, password,
        options: { data: { nick, handle, avatar }, emailRedirectTo: location.origin + location.pathname + '#gacha' } });
      if (error) throw error;
      return { needsConfirm: !data.session };
    },
    async signIn(email, password) {
      await ready;
      const { error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
    },
    async signOut() { await ready; await sb.auth.signOut(); },
    async pull() {
      await ready;
      const { data, error } = await sb.rpc('pull_gacha');
      if (error) throw error;
      return data;
    }
  };
})();
