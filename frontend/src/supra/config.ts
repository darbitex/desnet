export const DESNET_CONFIG = {
  // DeSNet package address on Supra
  PACKAGE_ADDRESS: '0xDADE',
  // Deployer multisig address
  ORIGIN_ADDRESS: '0xA0E1',
  // SUPRA FA metadata address (native coin on Supra)
  SUPRA_FA_METADATA: '0xa',
  // Network configuration
  NETWORK: 'testnet' as const,
  // RPC URL
  RPC_URL: 'https://fullnode.testnet.aptoslabs.com',
  // Explorer URL
  EXPLORER_URL: 'https://explorer.aptoslabs.com',
};

export const MODULE_NAMES = {
  PROFILE: `${DESNET_CONFIG.PACKAGE_ADDRESS}::profile`,
  FACTORY: `${DESNET_CONFIG.PACKAGE_ADDRESS}::factory`,
  REGISTRATION: `${DESNET_CONFIG.PACKAGE_ADDRESS}::registration`,
  MINT: `${DESNET_CONFIG.PACKAGE_ADDRESS}::mint`,
  PULSE: `${DESNET_CONFIG.PACKAGE_ADDRESS}::pulse`,
  AMM: `${DESNET_CONFIG.PACKAGE_ADDRESS}::amm`,
  IPO: `${DESNET_CONFIG.PACKAGE_ADDRESS}::ipo`,
  LP_STAKING: `${DESNET_CONFIG.PACKAGE_ADDRESS}::lp_staking`,
  LINK: `${DESNET_CONFIG.PACKAGE_ADDRESS}::link`,
  PRESS: `${DESNET_CONFIG.PACKAGE_ADDRESS}::press`,
  GOVERNANCE: `${DESNET_CONFIG.PACKAGE_ADDRESS}::governance`,
  GIVEAWAY: `${DESNET_CONFIG.PACKAGE_ADDRESS}::giveaway`,
  SUPRA_VAULT: `${DESNET_CONFIG.PACKAGE_ADDRESS}::supra_vault`,
  SUPRA_FEE_VAULT: `${DESNET_CONFIG.PACKAGE_ADDRESS}::supra_fee_vault`,
  HISTORY: `${DESNET_CONFIG.PACKAGE_ADDRESS}::history`,
  ASSETS: `${DESNET_CONFIG.PACKAGE_ADDRESS}::assets`,
  OPINION: `${DESNET_CONFIG.PACKAGE_ADDRESS}::opinion`,
  VOTER_HISTORY: `${DESNET_CONFIG.PACKAGE_ADDRESS}::voter_history`,
  LP_EMISSION: `${DESNET_CONFIG.PACKAGE_ADDRESS}::lp_emission`,
  REACTION_EMISSION: `${DESNET_CONFIG.PACKAGE_ADDRESS}::reaction_emission`,
  REFERENCE_GATE: `${DESNET_CONFIG.PACKAGE_ADDRESS}::reference_gate`,
};

export const HANDLE_PRICES_SUPRA = [
  { length: '1', price: '1,000,000', display: '1M SUPRA' },
  { length: '2', price: '100,000', display: '100K SUPRA' },
  { length: '3', price: '10,000', display: '10K SUPRA' },
  { length: '4', price: '1,000', display: '1K SUPRA' },
  { length: '5', price: '100', display: '100 SUPRA' },
  { length: '6+', price: '10', display: '10 SUPRA' },
];
