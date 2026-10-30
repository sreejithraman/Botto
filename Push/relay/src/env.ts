import type { Installation } from "./installation";

export interface RelayEnv {
  INSTALLATIONS: DurableObjectNamespace<Installation>;
  REQUEST_LIMITER: RateLimit;
  ALLOWED_BUNDLE_IDS: string;
  ALLOWED_ENVIRONMENTS: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}
declare global {
  namespace Cloudflare {
    interface Env extends RelayEnv {}
    interface GlobalProps { mainModule: typeof import("./worker"); durableNamespaces: "Installation" }
  }
}
