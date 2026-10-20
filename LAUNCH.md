# Launching *[demo] on the App Store, with Pro

The app and the server are ready. Pro is sold as an App Store subscription, handled through RevenueCat. When someone subscribes, the server (`supabase/functions/revenuecat`) checks with RevenueCat and switches their account to Pro, so it works on the Mac and the web too.

Do these in order. Steps marked **(Claude)** are mine: tell me when you reach them.

## 1. Apple paperwork

1. **developer.apple.com/account:** accept any agreement shown in the banner.
2. **App Store Connect › Business:** accept the **Paid Apps Agreement**, then add your bank account and tax forms (for Australia, mainly the US W-8BEN). Subscriptions can't be bought until this shows **Active**.

If App Store Connect says your account isn't set up, wait a few hours after the agreement. If it lasts more than a day, contact Apple Developer Support.

## 2. The app and its subscriptions (App Store Connect)

1. **Apps › + › New App** (skip this if it already exists):
   - Platform: iOS
   - Name: *[demo]. If it's taken, use `*[demo] songwriting`.
   - Language: English (Australia)
   - Bundle ID: `app.hellodemo.demo`
   - SKU: `hellodemo` (only you see it; it can't be changed later)
2. **Your app › Monetization › Subscriptions:** create a group called `*[demo] Pro`, then add two subscriptions to it:

   | Reference name | Product ID | Duration | Price |
   |---|---|---|---|
   | Pro Monthly | `app.hellodemo.demo.pro.monthly` | 1 month | A$8.99 |
   | Pro Yearly | `app.hellodemo.demo.pro.yearly` | 1 year | A$69.99 |

   For each one:
   - Under **App Store Localization**, enter the display name `*[demo] Pro` and the description `Audio, stems, lyric sync, co-writing and more AI`.
   - Add an **Introductory Offer**: Free trial, 7 days, all countries.
   - Add a **Review Screenshot**. A screenshot of Account in the app is fine.
   - Leave **Availability** as all countries. Let Apple fill in the other countries' prices from the Australian one.

   Product IDs can never be changed or reused, so copy them exactly.
3. **Users and Access › Integrations › In-App Purchase:** generate a key, then download the `.p8` file. You'll upload it to RevenueCat in the next step. Keep it safe, and don't paste it into chat.

## 3. RevenueCat (revenuecat.com)

1. Create a project called `*[demo]`.
2. **Apps › + App Store:** bundle ID `app.hellodemo.demo`.
   - Upload the In-App Purchase key (`.p8`). It needs the Key ID and the Issuer ID, both shown in App Store Connect next to the key.
   - If it asks for an App-Specific Shared Secret, generate one under your app › General › App Information in App Store Connect.
3. **Products:** import both products from the App Store, or add them by product ID.
4. **Entitlements › + New:** identifier `pro`, and attach both products to it.
5. **Offerings:** keep `default` as the current offering. Add two packages:
   - **Monthly**, with the monthly product
   - **Annual**, with the yearly product
6. **Project settings › API keys:** send Claude the **public Apple key**. It starts with `appl_` and is safe to paste in chat. **(Claude)** I'll build it into the app.
7. **Integrations › Webhooks › + Add:**
   - URL: `https://cygfgurzvmbtcegkpnss.supabase.co/functions/v1/revenuecat`
   - Authorization header: make up a long random password, for example from your password manager.
   - Environment: both sandbox and production
   - Events: all
8. **(Claude)** I'll ask Supabase for two secrets, and Supabase will show you boxes to fill in, so nothing goes through chat:
   - `REVENUECAT_WEBHOOK_AUTH`: the same password as the webhook's Authorization header
   - `REVENUECAT_SECRET_KEY`: from RevenueCat › Project settings › API keys › **Secret** API key (starts `sk_`). Give it read access, or the default is fine.
9. In the webhook screen, press **Send Test Event**. It should show 200.

## 4. The purchase plugin (done on 19 Oct 2026)

Both iPhone projects already have it: Capacitor 8 with `@revenuecat/purchases-capacitor` 13.7.4. Older versions don't compile with the current Xcode. Xcode no longer lists an In-App Purchase capability, because Apple switches it on for every App ID automatically.

## 5. Test a purchase (no real money)

1. **App Store Connect › Users and Access › Sandbox › Test Accounts:** add a sandbox tester. Use a new email address that isn't an Apple ID; a `+` address of your own is fine.
2. Build to your phone from Xcode.
3. On your phone, sign in with the sandbox tester under **Settings › Developer › Sandbox Apple Account**.
4. **Preview the Free plan.** In *[demo], go to Account and turn on **Testing › Preview the Free plan**, so you see what a free user sees.
5. Tap **Yearly** and confirm. In sandbox, the 7-day trial lasts a few minutes, and renewals happen every few minutes.
6. Check these:
   - The app says "Welcome to *[demo] Pro".
   - The Account card shows Pro until a date.
   - In [developer] › Admin › Users, your plan shows Pro.
7. Tap **Manage Subscription** and cancel. Pro should switch off within about an hour, once the sandbox period runs out.
8. Delete the app, reinstall it, sign in, and tap **Restore Purchases**. Pro should come back.

## 6. Upload the build

1. Xcode › **General:** Version `4.0`. Raise **Build** by 1 for each upload.
2. Set the destination at the top to **Any iOS Device**.
3. **Product › Archive**, then **Distribute App › App Store Connect › Upload**.

## 7. The App Store listing

All of this goes on your app's version page in App Store Connect, unless it says otherwise.

**Screenshots (6.9-inch iPhone):**
- Upload `01-songs` to `08-perform`, in order.
- Add `demo-app-preview.mp4` as the App Preview.

**Subtitle:** Write songs, demos & co-write

**Promotional text:**
> Write the song, keep the demo, bring in your co-writers. Pro now open: audio, stems, lyric sync and live co-writing, with a 7-day free trial.

**Description:**
> *[demo] is a songwriting app that keeps every part of a song together: the lyrics, the demos, the stems and the people you write with.
>
> WRITE
> • Rhymes, near rhymes, phrases and synonyms for any word you tap
> • Syllable counts and a rhyme map to check your flow
> • Muse: prompts and exercises for when you're stuck, plus Lines, which suggests next lines in your own voice
> • Ideas: catch a line, a title or a hummed melody the moment it lands
>
> RECORD AND ATTACH (Pro)
> • Keep every demo, mix and voice memo on the song it belongs to
> • Attach stems, session files and chord charts (5 GB)
> • Sync your lyrics to the music and play them along, karaoke-style
>
> WRITE TOGETHER (Pro)
> • Invite co-writers by username and write together live
> • Credits and splits for every writer
>
> SHARE
> • Send any song as a link anyone can open in a browser, with your demo playing alongside the lyrics (audio with Pro)
> • Perform mode: big lyrics that scroll themselves on stage
>
> Your songs sync across iPhone, Mac and the web.
>
> *[DEMO] PRO
> Free covers writing, rhymes, ideas and a daily taste of the AI. Pro adds audio and files, synced voice memos, lyric sync, inviting co-writers, Rate, Lines and your writing voice: A$8.99 a month or A$69.99 a year, with a 7-day free trial for new subscribers. Payment is charged to your Apple ID. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period, and you can manage them in your Apple ID settings.
>
> Terms of Use: https://hellodemo.app/terms.html
> Privacy Policy: https://hellodemo.app/privacy.html

**Keywords:** `songwriting,lyrics,songwriter,rhyme,rhymes,music,stems,cowrite,collaborate,voice memo,chords,band`

**URLs and categories** (some of these are under App Information):
- **Support URL:** `https://hellodemo.app`
- **Marketing URL:** `https://hellodemo.app`
- **Privacy Policy URL:** `https://hellodemo.app/privacy.html`
- **Category:** Music. **Secondary:** Productivity.
- **Copyright:** `2026 *[demo]`

**App Privacy:** use the same answers as in TESTFLIGHT.md, plus **Purchases › Purchase History** (Linked to the user, App Functionality, not used for tracking).

**Age rating:** answer the questionnaire honestly. Users can share content with each other (co-writing and share links), and the app has AI features. It most likely comes out at 13+.

**In-App Purchases:** on the version page, under **In-App Purchases and Subscriptions**, add both subscriptions, so they're reviewed with this build. Apple rejects a first submission that leaves them out.

**App Review Information:**
- Sign-in required: yes.
- Notes:
> Sign in with Apple works with any Apple ID; no demo account is needed. Everything in the free plan works straight away. To test *[demo] Pro, open Account (top right), choose Yearly or Monthly and buy with your sandbox account; Pro switches on immediately. Restore Purchases and Manage Subscription are in Account too. Account › Delete Account deletes the account and all its data. Content reports: every share page has a Report link, and people can block anyone from inviting them in Account › Invitations.
- Contact: your name and number (Apple only), and `help@hellodemo.app`.

## 8. Launch day switches

Do these when the app is approved and you're ready to release it:

1. **[developer] › Admin › Settings › Beta Unlocks Everything: off.** Testers without Pro move to Free. If you want to thank your testers, give them free Pro under Admin › Users › Make Pro.
2. **Account › Beta Requests › Waitlist Lock: off**, so anyone can sign up.
3. **Supabase › Table Editor › signup_limit:** raise it or clear it.
4. **Supabase › Billing:** move to the Pro plan (US$25 a month). The free plan pauses after a week without activity and has only 1 GB of storage.
5. **App Store Connect:** press **Release**. **(Claude)** Then I'll update hellodemo.app with the App Store button.
6. **(Claude)** Point "Time to update" at the App Store: in `www/index.html`, `UPDATE_URL.ios` is TestFlight (`itms-beta://`) until then.

## Help desk and remote controls (in place since 19 Oct 2026)

- **Contact Support** (Account › About) files a ticket through the `support` edge function and emails ADMIN_EMAIL. Answer in [developer] › Admin › Help; replies are emailed from help@hellodemo.app and people answer to that inbox.
- **Admin › Users › someone** shows their devices, builds, sessions, usage, tickets and errors, with Pro for 30 days, Re-check Subscription, Sign Out Everywhere, Suspend and Email.
- **Admin › Settings** has a banner for everyone, Pause AI / Lyric Sync / Uploads, and a Minimum Build (older builds see "Time to update"; [developer] builds never do).
- **Admin › Debug** shows this device's state and log, with Copy Report and Send to Help Desk.
- Server side: `supabase/helpdesk.sql` (applied), `supabase/functions/support` (Verify JWT on).

## Push notifications (iPhone)

- Sent for co-writer invites and help desk replies (and from Admin › Users › someone › Notify, or Admin › Debug › Test Push).
- Apple side: a key with APNs (Keys › *[demo] Push), Push Notifications on both app IDs, and in Xcode the Push Notifications capability plus Background Modes › Remote notifications on both targets.
- Supabase secrets: `APNS_KEY` (the whole .p8 file), `APNS_KEY_ID`. Team ID defaults to KZL3T52VV3.
- Server: `supabase/push.sql` (applied), `supabase/functions/push` (Verify JWT on). Xcode builds get sandbox tokens and TestFlight/App Store builds production ones; the function works out which on the first send.
- The app asks for permission only when it makes sense: after a Contact Support message, after setting a username, or from Account › Notifications.

## Automatic notifications (supabase/notify.sql, applied 21 Oct 2026)

- Co-writing (invite accepted, a co-writer edited a shared song: once per 30 min per song), writing reminders (3+ days away, ~6pm local, at most weekly), Account & Pro (beta approved, Pro given, trial ends in 2 days, Pro ended) and share link plays (once a day per link). Each can be switched off in Account › Notifications.
- Triggers and an hourly check (`notify-hourly`) queue them in `push_outbox`; `notify-send` (every minute, only when something's waiting) has the push function send them. The token between them is in Vault (`notify_cron_token`).
- Look at what was sent: `select * from push_outbox order by id desc limit 20;`
