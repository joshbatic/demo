# *[demo] 4.0 on TestFlight

Everything in the app is ready (build **b98da9d**, version 4.0, build 1). These are the steps only you can do, in order.

## 1. Join the Apple Developer Program

- Join at developer.apple.com/programs with your Apple ID (A$149 a year). Approval can take a day or two.
- Then, in Xcode › Settings › Accounts, make sure your Apple ID shows the new paid team.

## 2. Supabase

Run these in **SQL Editor** (New query → paste → Run), in this order. All are safe to run again.

1. `supabase/muse.sql`
2. `supabase/song-files-shared.sql`
3. `supabase/collab-hardening.sql`
4. `supabase/realtime-private.sql`, then **Project Settings › Realtime › turn off "Allow public access"**
5. `supabase/reserved-usernames.sql`
6. `supabase/ai-limits.sql`: daily AI limits per account
7. `supabase/app-errors.sql`: error reports from testers
8. `supabase/delete-account.sql`: in-app account deletion (Apple requires this)
9. `supabase/signup-limit.sql`: at most 25 new accounts a day. Then **Authentication › Hooks › Add hook › Before User Created › Postgres › `public.hook_signup_limit`**. Change the number in **Table Editor › signup_limit** (0 pauses sign-ups, empty means no limit).
10. `supabase/storage-limit.sql`: 150 MB of audio and files per account for the beta. Change it in **Table Editor › storage_limit** (empty means no limit). On the free Supabase plan the whole project gets 1 GB (about 6 full accounts), so move to Pro before inviting more testers than that.
11. `supabase/user-blocks.sql`: lets people block someone from inviting them.
12. `supabase/beta-access.sql`: the beta waitlist. Then run `supabase/ai-limits.sql` and `supabase/delete-account.sql` again (both changed for it).
13. `supabase/admin-tools.sql`: the Admin sheet in [developer] (user counts, users, errors, settings).
14. `supabase/service-status.sql`: the Status tab in [developer] › Admin. Turn on **pg_cron** and **pg_net** in Database › Extensions first; the file then sets up the 5-minute schedule itself (its token lives in Supabase Vault). Deploy `supabase/functions/status` as **status**. No secrets to add. (Done for cygfgurzvmbtcegkpnss.)
15. `supabase/plans.sql`: Free and Pro. Each person's plan is decided on the server (Admin › Users can set Pro or Free; Admin › Settings › Beta Unlocks Everything keeps every tester on full access until payments go live). Run it again after `admin-tools.sql`. (Done for cygfgurzvmbtcegkpnss.)

Settings:

- **Authentication › Providers › Email:** turn it off. The app is Google and Apple only now.

Edge Functions (paste the new code into **Edge Functions › [name] › Code**, then Deploy):

- **ai-proxy:** `supabase/functions/ai-proxy/index.ts`. This replaces the current one, and adds the daily limit. Copy the current code somewhere first, just in case.
- **lyric-sync:** `supabase/functions/lyric-sync/index.ts`.

Backstop:

- **platform.openai.com › Settings › Limits:** set a monthly budget. It protects the bill even if something else goes wrong.

## 2b. Beta waitlist

How it works: people ask for a spot at hellodemo.app/beta.html. You approve or decline them in the app under **Account › Beta Requests**. Approving emails them the TestFlight link and a personal invite code. With **Waitlist Lock** on, anyone who signs in without approval sees "You're on the waitlist", and the server refuses their AI requests and uploads.

1. **The admin is dev@hellodemo.app**, added by the SQL file. To see Beta Requests, sign in to the app with an Apple ID or Google account that uses that email, and don't choose "Hide My Email". If dev@hellodemo.app doesn't have one yet, you can create a Google account with it at accounts.google.com › Create account › "Use your existing email".
2. **Resend** (resend.com):
   - **Domains › Add domain › hellodemo.app.** Add the DNS records it shows at your domain provider, then wait for "Verified".
   - **API Keys › Create** (Sending access).
3. **Supabase › Edge Functions:**
   - Create a function named **beta** with the code from `supabase/functions/beta/index.ts`, and deploy it.
   - Redeploy **ai-proxy** and **lyric-sync** too (they now respect the lock).
4. **Edge Functions › Secrets:**
   - `RESEND_API_KEY`: the key from step 2
   - `BETA_FROM`: `*[demo] <beta@hellodemo.app>`
   - `TESTFLIGHT_URL`: your public TestFlight link (step 5 below)
   - `ADMIN_EMAIL`: `dev@hellodemo.app` (where "new request" emails go)
5. **Let your current testers in** (optional), so they aren't locked out. In SQL Editor:
   `insert into public.beta_requests (email, status, user_id, decided_at) select lower(email), 'approved', id, now() from auth.users where email is not null on conflict (email) do update set status = 'approved', user_id = excluded.user_id, decided_at = now();`
6. **Turn the lock on:** Account › Beta Requests › Waitlist Lock.

If you approve someone before Resend is set up, the app copies their invite code for you, so you can send it with the TestFlight link yourself.

## 3. Try it on your phone first

Rebuild in Xcode and run through these, ideally with a second account for the co-writing step:

- Sign in with Apple, then sign out and sign in with Google.
- Ideas: type one, record a voice memo, scrub it, start a song from it.
- Add an audio version, sync the lyrics, Play with Lyrics.
- Make a share link and open it in Safari.
- Invite the second account and write together live.
- Lines, Read my song, Rate.
- Delete the second account (Account › Delete Account).

## 4. Archive and upload (Xcode)

1. Open `~/Documents/songpad-ios/ios/App/App.xcworkspace` (or `App.xcodeproj` if there's no workspace).
2. **App target › Signing & Capabilities:** set Team to your paid team.
3. **General:** Version 4.0, Build 1. Raise Build by 1 for every upload after this.
4. Set the destination at the top to **Any iOS Device (arm64)**.
5. **Product › Archive.** When the Organizer opens: **Distribute App › App Store Connect › Upload**.

## 5. App Store Connect (appstoreconnect.apple.com)

1. **Create the app.** Go to **Apps › + › New App**:
   - iOS
   - Name: *[demo] (if it's taken, try "*[demo] songwriting")
   - Primary language: English (Australia)
   - Bundle ID: `app.hellodemo.demo`
   - SKU: `hellodemo` (only you see it; it can't be changed later)
2. **App Privacy.** Fill this in using the answers below. It's needed before outside testers. Privacy Policy URL: `https://hellodemo.app/privacy.html`.
3. **TestFlight tab.**
   - The upload shows as "Processing" for 10–30 minutes.
   - The encryption question is answered automatically.
   - **Internal testing:** add yourself. There's no review, and you can install straight away.
   - **External testing:** create a group, add the build, fill in Test Information with the text below, then submit. The first build gets a short Beta App Review, usually within a day.
   - Turn on **Public Link** and send it to me. I'll put it on hellodemo.app, where the buttons still say REPLACE_ME.

## Text to paste

**Beta App Description**

> *[demo] is a songwriting app. Write lyrics with live rhymes and suggestions in your own voice, hum ideas into voice memos, attach demos and mixes, sync your lyrics to the music, co-write live with other writers, and share any song as a link anyone can open.

**What to Test**

> Thanks for testing *[demo] 4.0!
>
> Try:
> • Ideas: jot a line or tap the mic to record a melody, then start a song from it.
> • Write a song. Use the rhyme bar, and Muse › Lines for next-line ideas.
> • Details › Audio: add a recording, tap Sync Lyrics, then Play with Lyrics.
> • Share › make a link and send it to someone.
> • Details › Collaborators: invite another tester and write together.
>
> Tell us anything that feels confusing, slow or broken. Take a screenshot in the app to send feedback through TestFlight.

**Feedback email:** help@hellodemo.app

**Sign-in information (Beta App Review):** Turn off "Sign-in required" if it's offered, or write:

> Sign in with Apple works with any Apple ID. No demo account is needed.

**App Privacy answers.** Everything is "Linked to the user", none is used for tracking, and all of it is for App Functionality:

| Data type | What it is in *[demo] |
|---|---|
| Contact Info › Email Address | from Google / Apple sign-in |
| Contact Info › Name | display name |
| User Content › Audio Data | recordings and voice memos |
| User Content › Photos or Videos | profile photo, song artwork |
| User Content › Other User Content | lyrics, ideas, notes |
| Identifiers › User ID | account ID |
| Usage Data › Product Interaction | daily AI request counts |
| Diagnostics › Other Diagnostic Data | error reports |

Answer **No** to "Do you or your third-party partners use data for tracking?".

## Keeping your name private

The website, policies and TestFlight text no longer show your name or Gmail. These places would still show them, and only you can change them:

- **Your Apple developer name.** Apple shows the account holder's legal name as the seller on TestFlight and the App Store. To show "*[demo]" instead, enrol as an organisation. That needs a company (a Pty Ltd, not a sole trader ABN) and a free D-U-N-S number. Decide this before you pay, because switching later means a support request to Apple.
- **Google sign-in screen.** In Google Cloud › APIs & Services › OAuth consent screen (Branding), the support email shows to people when they sign in. It can only be your own Google address or a Google Group you manage, so make a group like hellodemo-help@googlegroups.com and choose that.
- **GitHub.** The repo is public at github.com/joshbatic/demo, and older commits carry your name. Rename your GitHub account, or move the repo to a new organisation (such as `hellodemo`). Pages and Vercel follow the move. Also run `git config --global user.name "*[demo]"` on your Mac.
- **help@hellodemo.app** has to exist. Set up free forwarding to your Gmail with Cloudflare Email Routing or an iCloud+ custom domain.

## Later

- **Datamuse API key:** get one before 1 January 2027, or rhymes stop.
- **Artist pages** (branch `next`): run `supabase/artist-pages.sql`, add the `artist` DNS record and the Vercel domain, and add fan sign-ups to the privacy policy before they go live.
