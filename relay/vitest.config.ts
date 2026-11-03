import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Throwaway credentials, made for each run so no key is kept in the repository.
const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const serviceAccount = JSON.stringify({
  type: "service_account",
  client_email: "relay-test@example.test",
  private_key: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----\n`,
});
const publicKey = JSON.stringify(await crypto.subtle.exportKey("jwk", pair.publicKey));
const apnsPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const apnsPkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", apnsPair.privateKey)).toString("base64");
const apnsPublicKey = JSON.stringify(await crypto.subtle.exportKey("jwk", apnsPair.publicKey));
const stateSecret = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");

const wrangler = { configPath: "./wrangler.jsonc" };

export default defineConfig({
  test: {
    projects: [
      {
        plugins: [
          cloudflareTest({
            wrangler,
            miniflare: {
              bindings: {
                FCM_PROJECT_ID: "relay-test",
                FCM_SERVICE_ACCOUNT: serviceAccount,
                TEST_FCM_PUBLIC_JWK: publicKey,
                APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${apnsPkcs8.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`,
                APNS_KEY_ID: "KEY1234567",
                APNS_TEAM_ID: "TEAM123456",
                APNS_TOPIC: "app.example.remote",
                TEST_APNS_PUBLIC_JWK: apnsPublicKey,
                GITHUB_CLIENT_ID: "github-client-id",
                GITHUB_CLIENT_SECRET: "github-client-secret",
                GOOGLE_CLIENT_ID: "google-client-id",
                GOOGLE_CLIENT_SECRET: "google-client-secret",
                AUTH_STATE_SECRET: stateSecret,
                PUBLIC_URL: "https://relay.example.test",
              },
            },
          }),
        ],
        test: { name: "relay", include: ["test/**/*.test.ts"], exclude: ["test/unconfigured.test.ts"] },
      },
      {
        plugins: [cloudflareTest({ wrangler })],
        test: { name: "unconfigured", include: ["test/unconfigured.test.ts"] },
      },
    ],
  },
});
