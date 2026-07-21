// One-off: generate a VAPID keypair for Web Push. No external account needed.
//   node scripts/gen-vapid.mjs
// Then:
//   • Vercel env: VITE_VAPID_PUBLIC_KEY = <public key>   (safe to expose)
//   • Supabase Edge Function secrets:
//       VAPID_PUBLIC_KEY  = <public key>
//       VAPID_PRIVATE_KEY = <private key>   (SECRET — never commit / expose)
//       VAPID_SUBJECT     = mailto:you@solarsearch.com.au
// Keep the private key out of the repo and out of the browser bundle.
import webpush from "web-push";

const keys = webpush.generateVAPIDKeys();
console.log("\nVAPID keypair generated:\n");
console.log("Public  (VITE_VAPID_PUBLIC_KEY / VAPID_PUBLIC_KEY):\n  " + keys.publicKey + "\n");
console.log("Private (VAPID_PRIVATE_KEY — keep secret):\n  " + keys.privateKey + "\n");
console.log("Set VAPID_SUBJECT to a mailto: or https: contact URL, e.g. mailto:hello@solarsearch.com.au\n");
