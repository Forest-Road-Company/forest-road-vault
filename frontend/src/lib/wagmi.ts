/**
 * Chain-pinned Wagmi configuration. A build targets exactly one chain.
 *
 * Connected local-fork reads are deliberately routed through the active wallet
 * provider. Two independent Anvil nodes can share an ancestor and even an
 * identical tip before the first write, but they do not propagate transactions
 * to each other. Using the wallet provider for every connected read removes that
 * unprovable endpoint-identity assumption. The configured HTTP endpoint remains
 * the disconnected/server fallback only.
 */

import {createConfig, custom, fallback, http, type Config} from "wagmi";
import {injected} from "wagmi/connectors/injected";
import {walletConnect} from "wagmi/connectors/walletConnect";
import {CHAIN_ID, IS_LOCAL_FORK, RPC_URL} from "@/config/contracts";
import {appTransport} from "@/lib/appRpc";
import {EXPECTED_CHAIN, LOCAL_SEPOLIA_FORK} from "@/lib/chain";
import {walletMetadata} from "@/lib/walletMetadata";
import {mainnet, sepolia} from "wagmi/chains";

export {EXPECTED_CHAIN};

const walletConnectProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();

if (
  walletConnectProjectId &&
  !/^[0-9a-f]{32}$/i.test(walletConnectProjectId)
) {
  throw new Error(
    "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID must be a 32-character hexadecimal Reown project ID.",
  );
}

export const WALLETCONNECT_CONFIGURED = Boolean(walletConnectProjectId);

/**
 * WalletConnect's storage namespace for this site's sessions.
 *
 * WalletConnect saves a session's namespaces, including the read RPC URL Wagmi hands it (`rpcMap`),
 * and on reload rebuilds the session's read connection from that saved copy; a later configuration
 * does not replace it. The RPC proxy cutover changes that URL (from the provider's keyed URL to this
 * site's `/api/rpc`), so sessions saved under the old namespace (`forest-road-vault`) would keep
 * reading through the old key, and break once it is deleted. A new namespace means no pre-cutover
 * session is ever restored here, and an older deployment (a rollback) never restores a session made
 * on this one. The cost: each WalletConnect user reconnects once. Change it again whenever the read
 * URL changes.
 */
export const WALLETCONNECT_STORAGE_PREFIX = "forest-road-vault-rpc-proxy-2026-11";

function productionConnectors() {
  return [
    injected(),
    ...(walletConnectProjectId
      ? [
          walletConnect({
            projectId: walletConnectProjectId,
            showQrModal: true,
            customStoragePrefix: WALLETCONNECT_STORAGE_PREFIX,
            metadata: walletMetadata(),
          }),
        ]
      : []),
  ];
}

function createLocalForkConfig() {
  const configRef: {current?: Config} = {};
  const connectedWallet = custom(
    {
      async request(args: {method: string; params?: readonly unknown[]}) {
        const current = configRef.current?.state.current;
        const connection = current
          ? configRef.current?.state.connections.get(current)
          : undefined;
        if (!connection) throw new Error("No active wallet connection.");

        const provider = (await connection.connector.getProvider({
          chainId: LOCAL_SEPOLIA_FORK.id,
        })) as
          | {
              request(args: {
                method: string;
                params?: readonly unknown[];
              }): Promise<unknown>;
            }
          | undefined;
        if (!provider) throw new Error("The active wallet did not expose an RPC provider.");
        return provider.request(args);
      },
    },
    {key: "active-local-wallet", name: "Active local-fork wallet"},
  );

  const localConfig = createConfig({
    chains: [LOCAL_SEPOLIA_FORK],
    connectors: [injected()],
    transports: {
      [LOCAL_SEPOLIA_FORK.id]: fallback(
        [connectedWallet, http(RPC_URL)],
        {
          // Falling back while connected would silently split reads from
          // writes. Only disconnected/server rendering may use HTTP.
          shouldThrow: () => Boolean(configRef.current?.state.current),
        },
      ),
    },
    ssr: true,
  });
  configRef.current = localConfig;
  return localConfig;
}

export const wagmiConfig =
  CHAIN_ID === mainnet.id
    ? createConfig({
        chains: [mainnet],
        connectors: productionConnectors(),
        // Always the same-origin proxy on mainnet (contracts.ts refuses anything else).
        transports: {[mainnet.id]: appTransport()},
        ssr: true,
      })
    : IS_LOCAL_FORK
      ? createLocalForkConfig()
    : createConfig({
        chains: [sepolia],
        connectors: productionConnectors(),
        transports: {[sepolia.id]: appTransport()},
        ssr: true,
      });
