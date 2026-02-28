interface SlopOverlordClientConfig {
  apiBase?: string;
  accentColor?: string;
}

declare global {
  interface Window {
    __SLOPOVERLORD_CONFIG__?: SlopOverlordClientConfig;
  }
}

export {};
