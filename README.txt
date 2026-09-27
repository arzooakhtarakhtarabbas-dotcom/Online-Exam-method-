URDU ONLINE EXAM V4
====================

Files:
- index.html      -> complete web app
- schema.sql      -> Supabase database + secure RPC functions
- README.txt      -> setup guide

SETUP
1. Create a Supabase project.
2. Open SQL Editor > New query.
3. Paste ALL of schema.sql and Run.
4. In Supabase Project Settings/API copy:
   - Project URL
   - Publishable key (older projects may call it anon key)
5. Open index.html in a text editor.
6. Replace:
   PASTE_YOUR_SUPABASE_URL
   PASTE_YOUR_SUPABASE_PUBLISHABLE_KEY
7. Upload index.html to a static host such as GitHub Pages.

IMPORTANT
- Never put a Supabase service_role/secret key in index.html.
- The SQL keeps correct answers out of the student's question response.
- Scoring and elapsed-time validation are performed by the database RPC.
- For a serious/high-stakes examination, add teacher MFA, audit logging, and a controlled server deployment.
