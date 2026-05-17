import { Types } from '@supra-labs/sdk';
import { DESNET_CONFIG, MODULE_NAMES } from './config';
import { move } from '@supra-labs/sdk';

let client: any = null;
let account: any = null;

export function getClient() {
  if (!client) {
    throw new Error('Supra client not initialized. Connect wallet first.');
  }
  return client;
}

export function getAccount() {
  if (!account) {
    throw new Error('Account not connected.');
  }
  return account;
}

export async function initClient(rpcUrl?: string) {
  const { SupraClient } = await import('@supra-labs/sdk');
  client = new SupraClient({
    rpcUrl: rpcUrl || DESNET_CONFIG.RPC_URL,
  });
  return client;
}

export async function connectWallet(): Promise<{ address: string; privateKey: string; publicKey: string }> {
  const { Account } = await import('@supra-labs/sdk');
  // Try Petra wallet or use private key
  if (typeof window !== 'undefined' && (window as any).petra) {
    const wallet = (window as any).petra;
    const response = await wallet.connect();
    account = Account.fromFullKey(response);
    return {
      address: account.address().toString(),
      privateKey: account.privateKey,
      publicKey: account.publicKey,
    };
  }
  throw new Error('No wallet found. Please install Petra wallet.');
}

export async function connectWithPrivateKey(privateKeyHex: string) {
  const { Account, AccountAddress } = await import('@supra-labs/sdk');
  account = Account.fromFullKey(`ed25519-priv-0x${privateKeyHex.replace('0x', '')}`);
  return {
    address: account.address().toString(),
    publicKey: account.publicKey,
  };
}

export async function getAccountResources(address: string): Promise<any[]> {
  const c = getClient();
  return c.getAccountResources(address);
}

export async function getAccountResource(address: string, resourceType: string): Promise<any> {
  const c = getClient();
  return c.getAccountResource(address, resourceType);
}

export async function viewFunction<T = any>(
  moduleName: string,
  functionName: string,
  typeArgs: string[] = [],
  args: any[] = []
): Promise<T> {
  const c = getClient();
  const payload: Types.ViewRequest = {
    function: `${moduleName}::${functionName}`,
    type_arguments: typeArgs,
    arguments: args,
  };
  return c.view(payload);
}

export async function submitTransaction(
  moduleName: string,
  functionName: string,
  typeArgs: string[] = [],
  args: any[] = []
): Promise<string> {
  const c = getClient();
  const acc = getAccount();
  const rawTx = await c.buildTransaction({
    sender: acc.address().toString(),
    payload: {
      type: 'entry_function_payload',
      function: `${moduleName}::${functionName}`,
      type_arguments: typeArgs,
      arguments: args,
    },
  });
  const signedTx = await c.signTransaction(acc, rawTx);
  const pendingTx = await c.submitTransaction(signedTx);
  return pendingTx.hash;
}

export async function waitForTransaction(hash: string): Promise<any> {
  const c = getClient();
  return c.waitForTransaction(hash, { timeout: 60000 });
}

// ============ VIEW FUNCTIONS ============

export async function derivePidAddress(wallet: string): Promise<string> {
  return viewFunction(MODULE_NAMES.PROFILE, 'derive_pid_address', [], [wallet]);
}

export async function profileExists(pidAddr: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.PROFILE, 'profile_exists', [], [pidAddr]);
}

export async function handleOfPid(pidAddr: string): Promise<string> {
  return viewFunction(MODULE_NAMES.PROFILE, 'handle_of', [], [pidAddr]);
}

export async function controllerOf(pidAddr: string): Promise<string> {
  return viewFunction(MODULE_NAMES.PROFILE, 'controller_of', [], [pidAddr]);
}

export async function isRegistered(handle: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.PROFILE, 'is_registered', [], [handle]);
}

export async function handleToWallet(handle: string): Promise<string> {
  return viewFunction(MODULE_NAMES.PROFILE, 'handle_to_wallet', [], [handle]);
}

export async function handleOfWallet(wallet: string): Promise<string> {
  return viewFunction(MODULE_NAMES.PROFILE, 'handle_of_wallet', [], [wallet]);
}

export async function handleFeeSupra(handleLen: number): Promise<number> {
  return viewFunction(MODULE_NAMES.PROFILE, 'handle_fee_supra', [], [handleLen]);
}

export async function mintCount(pidAddr: string): Promise<number> {
  return viewFunction(MODULE_NAMES.MINT, 'mint_count', [], [pidAddr]);
}

export async function nextSeq(pidAddr: string): Promise<number> {
  return viewFunction(MODULE_NAMES.MINT, 'next_seq', [], [pidAddr]);
}

export async function spawnCount(): Promise<number> {
  return viewFunction(MODULE_NAMES.FACTORY, 'spawn_count', [], []);
}

export async function isFactoryToken(tokenAddr: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.FACTORY, 'is_factory_token', [], [tokenAddr]);
}

export async function deriveTokenMetadataAddr(handle: string): Promise<string> {
  return viewFunction(MODULE_NAMES.FACTORY, 'derive_token_metadata_addr', [], [handle]);
}

export async function getTokenRecord(handle: string): Promise<any> {
  return viewFunction(MODULE_NAMES.FACTORY, 'get_token_record', [], [handle]);
}

export async function handleRegistered(handle: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.FACTORY, 'handle_registered', [], [handle]);
}

export async function isSynced(syncerPid: string, targetPid: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.LINK, 'is_synced', [], [syncerPid, targetPid]);
}

export async function syncCount(pidAddr: string): Promise<number> {
  return viewFunction(MODULE_NAMES.LINK, 'sync_count', [], [pidAddr]);
}

export async function syncedByCount(pidAddr: string): Promise<number> {
  return viewFunction(MODULE_NAMES.LINK, 'synced_by_count', [], [pidAddr]);
}

export async function ipoAddressOfHandle(handle: string): Promise<string> {
  return viewFunction(MODULE_NAMES.FACTORY, 'ipo_addr_of_handle', [], [handle]);
}

export async function vaultAddrOfPid(pidAddr: string): Promise<string> {
  return viewFunction(MODULE_NAMES.FACTORY, 'vault_addr_of_pid', [], [pidAddr]);
}

export async function ownerHasToken(ownerAddr: string): Promise<boolean> {
  return viewFunction(MODULE_NAMES.FACTORY, 'owner_has_token', [], [ownerAddr]);
}

export async function isPaused(): Promise<boolean> {
  return viewFunction(MODULE_NAMES.FACTORY, 'is_paused', [], []);
}

// ============ ENTRY FUNCTIONS ============

export async function registerHandle(
  handle: string,
  controllerAddr: string,
  avatarB64: string,
  bio: string,
  tokenName: string,
  tokenSymbol: string,
  tokenIconUri: string,
  tokenProjectUri: string,
  ipoTargetTvl: number,
  ipoEntryPriceX: number,
  ipoEntryPriceY: number,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.REGISTRATION,
    'register_handle',
    [],
    [
      handle,
      controllerAddr,
      avatarB64,
      bio,
      tokenName,
      tokenSymbol,
      tokenIconUri,
      tokenProjectUri,
      ipoTargetTvl.toString(),
      ipoEntryPriceX.toString(),
      ipoEntryPriceY.toString(),
    ]
  );
}

export async function registerHandleWithCreatorSeed(
  handle: string,
  controllerAddr: string,
  avatarB64: string,
  bio: string,
  tokenName: string,
  tokenSymbol: string,
  tokenIconUri: string,
  tokenProjectUri: string,
  ipoTargetTvl: number,
  ipoEntryPriceX: number,
  ipoEntryPriceY: number,
  creatorSubdomain: string,
  creatorSupraAmount: number,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.REGISTRATION,
    'register_handle_with_creator_seed',
    [],
    [
      handle,
      controllerAddr,
      avatarB64,
      bio,
      tokenName,
      tokenSymbol,
      tokenIconUri,
      tokenProjectUri,
      ipoTargetTvl.toString(),
      ipoEntryPriceX.toString(),
      ipoEntryPriceY.toString(),
      creatorSubdomain,
      creatorSupraAmount.toString(),
    ]
  );
}

export async function createMint(
  authorPid: string,
  contentKind: number,
  contentText: string,
  mentions: string[],
  tags: string[],
  tickers: string[],
  tipRecipients: string[],
  tipTokens: string[],
  tipAmounts: number[],
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.MINT,
    'create_mint',
    [],
    [
      authorPid,
      contentKind,
      contentText,
      0, 0, '', // media kind, mime, inline_data
      0, '', '', // media ref backend, blob_id, hash
      '0x0', 0, false, // parent
      '0x0', 0, false, // quote
      mentions, tags, tickers,
      tipRecipients, tipTokens, tipAmounts.map(String),
      '0x0', false, // asset master
    ]
  );
}

export async function spark(
  actorPid: string,
  targetAuthor: string,
  targetSeq: number,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PULSE,
    'spark',
    [],
    [actorPid, targetAuthor, targetSeq.toString(), '0x0']
  );
}

export async function sync(
  syncerPid: string,
  targetPid: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.LINK,
    'sync',
    [],
    [syncerPid, targetPid, '0x0']
  );
}

export async function unsync(
  syncerPid: string,
  targetPid: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.LINK,
    'unsync',
    [],
    [syncerPid, targetPid]
  );
}

export async function depositIpo(
  handle: string,
  amount: number,
  subdomain: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.IPO,
    'deposit_supra',
    [],
    [handle, amount.toString(), subdomain]
  );
}

export async function burnPosition(
  handle: string,
  subdomain: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.IPO,
    'burn_position',
    [],
    [handle, subdomain]
  );
}

export async function updateProfile(
  pidAddr: string,
  avatarBlob: string,
  bannerBlob: string,
  bio: string,
  metadataUri: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'update_metadata',
    [],
    [pidAddr, avatarBlob, bannerBlob, bio, metadataUri]
  );
}

export async function rotateController(
  pidAddr: string,
  newController: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'rotate_controller',
    [],
    [pidAddr, newController]
  );
}

export async function addSigner(
  pidAddr: string,
  pubkey: string,
  appLabel: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'add_signer',
    [],
    [pidAddr, pubkey, appLabel]
  );
}

export async function withdrawPidToken(
  pidAddr: string,
  tokenMetadataAddr: string,
  amount: number,
  recipient: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'withdraw_pid_token',
    [],
    [pidAddr, tokenMetadataAddr, amount.toString(), recipient]
  );
}

export async function attachSyncGate(
  pidAddr: string,
  targetPid: string,
  minTokenBalance: number,
  maxTokenBalance: number,
  minLpStake: number,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'attach_sync_gate',
    [],
    [pidAddr, targetPid, minTokenBalance.toString(), maxTokenBalance.toString(), minLpStake.toString()]
  );
}

export async function clearSyncGate(
  pidAddr: string,
): Promise<string> {
  return submitTransaction(
    MODULE_NAMES.PROFILE,
    'clear_sync_gate',
    [],
    [pidAddr]
  );
}
