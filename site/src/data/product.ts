import facts from './product-facts.json';

export type ProductFacts = {
  name: string;
  storeName: string;
  appleSubtitle: string;
  shortDescription: string;
  appleKeywords: string;
  positioning: string;
  publisher: string;
  siteUrl: string;
  supportEmail: string;
  updatedAt: string;
  platforms: readonly string[];
  appStoreUrl: string;
  playStoreUrl: string;
  microsoftStoreUrl: string;
  webAppUrl: string;
  publicStatsUrl: string;
  githubUrl: string;
  license: {
    label: string;
    url: string;
  };
  encryption: {
    noteAndAttachmentCipher: string;
    deviceKeyExchange: string;
    recoveryKeyDerivation: string;
    metadataNotEncrypted: readonly string[];
    independentlyAudited: boolean;
  };
  analyticsGoals: {
    appStore: string;
    playStore: string;
    webApp: string;
    github: string;
    keepImport: string;
  };
};

export const product = facts satisfies ProductFacts;

export type Product = typeof product;
