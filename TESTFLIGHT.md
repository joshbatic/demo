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

Settings:

- **Authentication › Providers › Email:** turn it off. The app is Google and Apple only now.

Edge Functions (paste the new code into **Edge Functions › [name] › Code**, then Deploy):

- **ai-proxy:** `supabase/functions/ai-proxy/index.ts`. This replaces the current one, and adds the daily limit. Copy the current code somewhere first, just in case.
- **lyric-sync:** `supabase/functions/lyric-sync/index.ts`.

Backstop:

- **platform.openai.com › Settings › Limits:** set a monthly budget. It protects the bill even if something else goes wrong.

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
   - Bundle ID: `com.joshbatic.songpad`
   - SKU: `songpad`
2. **App Privacy.** Fill this in using the answers below. It's needed before outside testers.
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

**Feedback email:** joshuadbatic@gmail.com

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

## Later

- **Datamuse API key:** get one before 1 January 2027, or rhymes stop.
- **Artist pages** (branch `next`): run `supabase/artist-pages.sql`, add the `artist` DNS record and the Vercel domain, and add fan sign-ups to the privacy policy before they go live.
