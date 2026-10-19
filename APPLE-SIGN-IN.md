# Turning on Sign in with Apple

How it works:
- **iPhone:** Apple's own sign-in sheet (Face ID, one tap). This needs a plugin and a capability in Xcode.
- **Mac and web:** Apple's sign-in web page. This needs a Services ID and a secret in Supabase.

Everything signs in to the same *[demo] account, as long as the person uses the same Apple ID.

Your Team ID is `KZL3T52VV3`.

## 1. Apple Developer (developer.apple.com › Account › Certificates, IDs & Profiles)

This part works now. It doesn't need App Store Connect.

1. **Identifiers › App IDs › `app.hellodemo.demo`:**
   - Tick **Sign In with Apple**, click **Edit**, choose **Enable as a primary App ID**, and click Save.
   - If the App ID isn't listed, Xcode hasn't created it yet. Click **+ › App IDs › App**, enter Bundle ID `app.hellodemo.demo` (Explicit) and description `*[demo]`, then do the step above.
2. **Identifiers › `app.hellodemo.demo.dev`** (the [developer] app):
   - Tick **Sign In with Apple**, click **Edit**, choose **Group with an existing primary App ID**, pick `app.hellodemo.demo`, and click Save.
   - Grouping means one Apple ID gets one account in both apps.
3. **Identifiers › + › Services IDs:**
   - Description: `*[demo] web sign-in`
   - Identifier: `app.hellodemo.signin`
   - Click Register, then open it, tick **Sign In with Apple** and click **Configure**:
     - Primary App ID: `app.hellodemo.demo`
     - Domains: `cygfgurzvmbtcegkpnss.supabase.co`
     - Return URLs: `https://cygfgurzvmbtcegkpnss.supabase.co/auth/v1/callback`
   - Click Save, then Continue and Save again.
4. **Keys › +:**
   - Name: `*[demo] Sign in with Apple`
   - Tick **Sign In with Apple**, click **Configure**, choose `app.hellodemo.demo`, and click Save.
   - Click Continue, then Register, then **Download**.
   - You can only download the `.p8` file once, so keep it somewhere safe and don't share it.

## 2. Make the secret (Terminal, on your Mac)

```
node ~/Documents/make-apple-secret.mjs ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

Use your real file name in place of `AuthKey_XXXXXXXXXX.p8`. The script prints a long line of text. Copy it for the next step.

The secret lasts 6 months. Run the same command again before then, and paste the new one in the same place.

## 3. Supabase (supabase.com › your project › Authentication)

1. **Sign In / Providers › Apple:** turn it on, then:
   - **Client IDs:** `app.hellodemo.signin,app.hellodemo.demo,app.hellodemo.demo.dev`
   - **Secret Key:** paste the line from step 2.
   - Click Save.
2. **Sign In / Providers › Email:** turn it off. *[demo] is Apple and Google only.
3. **URL Configuration › Redirect URLs:** check that both of these are listed, and add any that are missing:
   - `demo://auth-callback`
   - `demo-dev://auth-callback`

## 4. The iPhone apps (Terminal, then Xcode)

This installs the Apple sign-in plugin and, while we're at it, the subscriptions plugin. The subscriptions plugin stays switched off until RevenueCat is ready.

```
cd ~/Documents/songpad-ios && npm install @capacitor-community/apple-sign-in@6.0.0 @revenuecat/purchases-capacitor@9.2.2 && npx cap sync ios
cd ~/Documents/songpad-ios-dev && npm install @capacitor-community/apple-sign-in@6.0.0 @revenuecat/purchases-capacitor@9.2.2 && npx cap sync ios
```

Then do this in **each** Xcode project:

1. Open the App target, then **Signing & Capabilities**.
2. Click **+ Capability** and add **Sign in with Apple**.
3. Click **+ Capability** again and add **In-App Purchase**.
4. Build to your phone.

## 5. Check it

- **iPhone:** sign out, then tap **Sign in with Apple**. Apple's sheet should slide up. Confirm with Face ID, and you're in.
- **Mac app and hellodemo.app:** Sign in with Apple opens Apple's page in the browser, then brings you back signed in.
- If you sign in with the same Apple ID everywhere, you should see the same songs.
