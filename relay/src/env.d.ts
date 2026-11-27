declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("./index");
    durableNamespaces: "Room" | "Account" | "FeedbackSubmission";
  }
  interface Env {
    ROOM: DurableObjectNamespace<import("./room").Room>;
    ACCOUNT: DurableObjectNamespace<import("./account").Account>;
    FEEDBACK: DurableObjectNamespace<import("./feedback").FeedbackSubmission>;
    /** Sends feedback mail (Email Routing). Its sender and recipient are `FEEDBACK_FROM` and `FEEDBACK_TO`. */
    FEEDBACK_MAIL?: SendEmail;
    FEEDBACK_FROM?: string;
    FEEDBACK_TO?: string;
    /** Feedback per client address and for the whole relay. */
    FEEDBACK_LIMIT?: RateLimit;
    FEEDBACK_GLOBAL_LIMIT?: RateLimit;
    /** Workers Analytics Engine; absent, nothing is counted. */
    METRICS?: AnalyticsEngineDataset;
    /** Comma- or whitespace-separated room or account IDs omitted from anonymous counts (kept in secrets). */
    METRICS_EXCLUDE_ROOMS?: string;
    METRICS_EXCLUDE_ACCOUNTS?: string;
    /** The Firebase service account's JSON key. */
    FCM_SERVICE_ACCOUNT?: string;
    FCM_PROJECT_ID?: string;
    /** The APNs auth key's `.p8` text (PKCS#8 PEM), its key ID, the team ID and the iOS app's bundle ID. */
    APNS_KEY?: string;
    APNS_KEY_ID?: string;
    APNS_TEAM_ID?: string;
    APNS_TOPIC?: string;
    GITHUB_CLIENT_ID?: string;
    GITHUB_CLIENT_SECRET?: string;
    GOOGLE_CLIENT_ID?: string;
    GOOGLE_CLIENT_SECRET?: string;
    /** Signs the relay's own OAuth `state`. */
    AUTH_STATE_SECRET?: string;
    /** The relay's https base URL, for OAuth callbacks. */
    PUBLIC_URL?: string;
  }
}

interface Env extends Cloudflare.Env {}
