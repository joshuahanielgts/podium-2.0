# Podium — Slido-style Live Rating for Pitches

Podium is a lightweight, real-time live rating tool for college pitch competitions, hackathon demos, and presentations.

Presenters pitch on stage, the audience scans a QR code to rate **1 to 5 stars** on their phones with **zero sign-up**, and the projector displays real-time score averages, animated rating bars, and the final competition podium.

---

## The 4 Pages

| Page | Who | What it does |
|---|---|---|
| [`index.html`](index.html) | Everyone | Landing page. Enter a 6-character code to rate, or start a new session as host. |
| [`host.html`](host.html) | Coordinator (Host) | Create session, manage presentations/teams, open/stop rating, advance presentations, hide/show scores, and launch the big screen. (Google sign-in required). |
| [`screen.html?code=XXXXXX`](screen.html) | Auditorium Projector | Large QR code while waiting, live presentation name, 1-decimal average rating, total vote count, 5 animated distribution bars, and the final leaderboard podium. |
| [`rate.html?code=XXXXXX`](rate.html) | Audience (Phone) | Mobile-first rating interface. Shows current team name, 5 large thumb-friendly star buttons, and instant vote confirmation. |

---

## How It Works

```
                     ┌────────────────────────┐
                     │ Coordinator (host.html)│
                     └───────────┬────────────┘
                                 │ controls presentation & rating
                                 ▼
                     ┌────────────────────────┐
                     │   Supabase Postgres    │
                     │  (RLS + Realtime Hub)  │
                     └───────┬────────┬───────┘
          ratings broadcast  │        │  polling & stats
                             ▼        ▼
┌───────────────────────────────┐  ┌───────────────────────────────┐
│     Audience (rate.html)      │  │     Projector (screen.html)   │
│  - Silent anonymous sign-in   │  │  - Live 1-decimal average     │
│  - Tap 1 to 5 stars           │  │  - 5 animated star bars       │
│  - Change vote until closed   │  │  - Top-3 Podium Leaderboard   │
└───────────────────────────────┘  └───────────────────────────────┘
```

1. **Coordinator starts a session** at `host.html`, enters the event title and list of teams/presentations, and gets a 6-character code (e.g. `K9W4MZ`).
2. **Projector page** (`screen.html?code=K9W4MZ`) is displayed on the auditorium screen showing a large QR code.
3. **Audience scans the QR code** on their phones. They are signed in silently and anonymously in the background (no passwords or emails).
4. **Audience taps 1 to 5 stars** for the currently live presentation. They can change their rating at any time until the coordinator stops rating.
5. **Screen updates in real time** via Supabase Realtime with a 2-second polling fallback so the projector never freezes.
6. When the event concludes, the host clicks **Finish Session**, and the projector transitions into the final competition-ranked **Podium** (Gold, Silver, Bronze) with tied score handling (e.g., 1, 1, 3).

---

## Running Locally

Podium uses plain HTML, CSS, and modern JavaScript with no bundlers or build steps. Serve the repository root directly:

```bash
# From inside the podium folder
python -m http.server 8793
```

Then open `http://localhost:8793` in your browser.

- **Host console:** `http://localhost:8793/host.html`
- **Audience test:** `http://localhost:8793/rate.html?code=YOUR_CODE`
- **Projector test:** `http://localhost:8793/screen.html?code=YOUR_CODE`

---

## Supabase Backend Setup (Step by Step)

### 1. Create a Supabase Project
1. Sign in to [Supabase](https://supabase.com) (free plan).
2. Click **New Project**, name it `podium`, and pick a region closest to your campus.

### 2. Run the Database Migrations
1. Open the **SQL Editor** in your Supabase dashboard.
2. Open [`supabase/full_schema.sql`](supabase/full_schema.sql) from this repository.
3. Copy all contents, paste into the SQL editor, and click **Run**.
4. This creates:
   - `sessions`, `presentations`, `ratings`, and `rate_limits` tables.
   - Strict Row Level Security (RLS) policies and the rating eligibility trigger.
   - The security-definer RPCs (`get_session_public`, `get_stats`, `get_leaderboard`, `rate_presentation`).
   - The keep-alive `heartbeat` table.
   - Supabase Realtime publication on `sessions` and `ratings`.

### 3. Turn on Anonymous Sign-ins (Crucial for Audience)
1. In your Supabase dashboard, go to **Authentication** → **Providers**.
2. Scroll to **Anonymous Sign-ins**.
3. Toggle it **ON** and click Save.
   *(This gives every audience phone an anonymous `auth.uid()` to enforce 1 vote per phone without sign-up screens).*

### 4. Enable Google Sign-in (For Host Only)
1. In Supabase, go to **Authentication** → **Providers** → **Google** and toggle it **ON**.
2. Create OAuth credentials in [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
   - Application type: **Web application**.
   - Authorised redirect URI: Copy the callback URL from your Supabase Google provider page (`https://<project-ref>.supabase.co/auth/v1/callback`).
3. Paste the **Client ID** and **Client Secret** into Supabase and save.
4. Under **Authentication** → **URL Configuration**:
   - Set **Site URL** to your production URL (or GitHub Pages URL).
   - Add `http://localhost:8793/host.html` to **Redirect URLs** for local development.

### 5. Point the Site at Your Supabase Project
Edit `config.js` (and `config.example.js`):

```js
window.PODIUM_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabaseKey: 'sb_publishable_YOUR-ANON-KEY',
};
```
*(The publishable/anon key is public by design; all tables are protected by Postgres RLS).*

### 6. Prevent Project Pausing (GitHub Action)
Free Supabase projects pause after 7 days of inactivity. The repository includes [`.github/workflows/keep-supabase-awake.yml`](.github/workflows/keep-supabase-awake.yml), which automatically pings the heartbeat table every 3 days.

In your GitHub repository (**Settings** → **Secrets and variables** → **Actions**), add:
- `SUPABASE_URL`: `https://YOUR-PROJECT-REF.supabase.co`
- `SUPABASE_ANON_KEY`: Your publishable anon key

---

## Known Limitation

Because audience rating requires **no login** (silent anonymous sign-in for frictionless voting in an auditorium), a voter can theoretically clear their browser storage to cast a second vote. 

For college pitch fests and fast-paced hall competitions, this trade-off is intentional: removing sign-up forms maximizes audience participation. A host toggle ("Require Google sign-in to rate") can be enabled if higher scrutiny is required in the future.

---

## GitHub Repository & Deployment

- **Repository:** [https://github.com/joshuahanielgts/podium-2.0.git](https://github.com/joshuahanielgts/podium-2.0.git)
- **Deployment via GitHub Pages:**
  1. Push code to the `main` branch.
  2. Go to **Settings** → **Pages**.
  3. Source: **Deploy from a branch** → Branch: `main`, Folder: `/ (root)`.
  4. Your live app is ready at `https://<username>.github.io/<repo>/`.
