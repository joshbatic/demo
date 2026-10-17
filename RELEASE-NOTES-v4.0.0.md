# *[demo] 4.0.0

The biggest update since *[demo] began: share links anyone can open, a muse that learns how you write, live co-writing, and Ideas.

Build **7aa1b97** · branch snapshot `stable-4`

## New

- **Share links.** Each song gets a link at listen.hellodemo.app. Anyone can listen and read along in a browser, with no account.
  - Rich previews show in Messages, WhatsApp, Instagram and Facebook.
  - The lock screen and Control Center show the song's artwork, title and artist.
  - Pages are coloured from the artwork, right up behind the Dynamic Island on iOS 26.
  - "Written in *[demo]" links back to hellodemo.app.
  - Links are fast to make and update, and each co-writer gets their own.
- **A muse that learns you.**
  - It learns from the suggestions you keep, rewrite, delete and turn down ("Not this", with a reason).
  - It uses your closest lines from other songs, a per-song brief and an editable voice profile.
  - Lines writes 20 candidates, filters out stock phrases, judges them and shows the best 6.
- **Rate shares the muse's memory.**
  - It judges against your voice profile and the song brief, not a generic ideal.
  - Lines you defend with "I meant that" teach Lines and the muse your habits.
  - The Rate sheet is redesigned to match the rest of the app.
- **Live co-writing.** Edits appear almost instantly in both directions.
  - Invites arrive as a banner.
  - The collaborators list has avatars, roles and @username invites.
  - Deleted audio and files disappear for every co-writer.
  - When the owner deletes or stops sharing a song, it leaves everyone's library.
- **Ideas is back.** A quick jot for lines, ideas and concepts, in the song list and the Mac sidebar.
  - Start a song from any idea.
  - Swipe (iPhone) or hover (Mac) to delete an idea.
- **Credits.** Account shows a small discography of your finished songs.
- **Reserved usernames.** Well-known artists' and songwriters' names, and the app's own words, can't be taken. A name can be handed to its real owner.

## Changed

- **Lyric sync is rebuilt.** Songs go up in one-minute pieces, four at a time, with progress. Long tracks no longer time out.
- **MP3 always.** WAV, AIFF and FLAC uploads always become 256 kbps MP3s, including 88.2 and 96 kHz masters. The switch is gone.
- **Muse menu.** Rate lives in the Muse menu, and Share took its place in the toolbar.
- **Song brief.** "Tell the muse about this song" has a Clear button.
- **Polish.**
  - Rounded hover highlight on song and idea rows.
  - Smoother upload rows.
  - The toolbar starts clean on a new line.
  - The keyboard closes when an iPhone sheet closes.
- **Look.** New pastel default covers. The *[d] icon is rebuilt in Liquid Glass. The website is redesigned.

## Fixed

- Status lines in a song ("saving", "typing") no longer move the artwork or the lyrics.
- Co-writers can save shared songs, and audio on shared songs plays for every co-writer.
- Share links no longer get stuck on "Making the link".
- Selecting several lines on the Mac no longer fights the auto-centring.

## Security

A full review closed several gaps:

- **Co-writing.**
  - Only invited people can join a song.
  - Only owners can invite or hand a song over.
  - Live channels can be members-only.
- **Muse memory** is kept per account.
- **Sign-in links** only work for a sign-in you started.
- **Formatting and images** in songs are restricted.
- **Mac app.** It's tighter about files, the microphone and the AI key, which is now kept in the Keychain.

## Setup for this release

Run these in Supabase › SQL Editor if you haven't already, in this order:

1. `supabase/muse.sql`
2. `supabase/song-files-shared.sql`
3. `supabase/collab-hardening.sql`
4. `supabase/realtime-private.sql`, then turn off Realtime › "Allow public access"
5. `supabase/reserved-usernames.sql`

Optional: redeploy the `lyric-sync` function so lyric sync can ignore lyrics Whisper "hears" over instrumentals.
