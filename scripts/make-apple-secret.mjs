// Makes the "Secret Key" Supabase needs for Sign in with Apple on the web and Mac.
// Apple's secret is a signed token that lasts at most 6 months, so run this again before it runs out.
//
//   node make-apple-secret.mjs ~/Downloads/AuthKey_ABC123XYZ.p8
//
// It reads the key file on your Mac and prints the secret. Paste that into
// Supabase › Authentication › Sign In / Providers › Apple › Secret Key. Don't share the .p8 file or the secret.
import { readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";
import { basename } from "node:path";

const TEAM_ID = "KZL3T52VV3";              // your Apple Developer team
const CLIENT_ID = "app.hellodemo.signin";  // the Services ID used for web sign-in
const DAYS = 180;                          // Apple's maximum is 6 months

const file = process.argv[2];
if (!file) { console.error("Usage: node make-apple-secret.mjs /path/to/AuthKey_XXXXXXXXXX.p8"); process.exit(1); }
const keyId = process.argv[3] || (basename(file).match(/AuthKey_([A-Z0-9]+)\.p8$/) || [])[1];
if (!keyId) { console.error("Couldn't read the Key ID from the file name. Add it after the file: node make-apple-secret.mjs key.p8 ABC123XYZ"); process.exit(1); }

const b64 = (x) => Buffer.from(typeof x === "string" ? x : JSON.stringify(x)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: "ES256", kid: keyId });
const body = b64({ iss: TEAM_ID, iat: now, exp: now + DAYS * 86400, aud: "https://appleid.apple.com", sub: CLIENT_ID });
const sig = sign("sha256", Buffer.from(`${head}.${body}`), { key: createPrivateKey(readFileSync(file)), dsaEncoding: "ieee-p1363" }).toString("base64url");

console.log(`\n${head}.${body}.${sig}\n`);
console.log(`Paste the line above into Supabase › Authentication › Sign In / Providers › Apple › Secret Key.`);
console.log(`It expires on ${new Date((now + DAYS * 86400) * 1000).toDateString()}. Run this again before then.\n`);
