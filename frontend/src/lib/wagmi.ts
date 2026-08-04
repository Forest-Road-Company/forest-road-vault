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
import {injected, walletConnect} from "wagmi/connectors";
import {CHAIN_ID, IS_LOCAL_FORK, RPC_URL} from "@/config/contracts";
import {EXPECTED_CHAIN, LOCAL_SEPOLIA_FORK} from "@/lib/chain";
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

function productionConnectors() {
  return [
    injected(),
    ...(walletConnectProjectId
      ? [
          walletConnect({
            projectId: walletConnectProjectId,
            showQrModal: true,
            customStoragePrefix: "forest-road-vault",
            metadata: {
              name: "Forest Road Vault",
              description: "On-chain access to Forest Road's private-credit vault.",
              url: "https://forestroadvault.com",
              icons: ["https://forestroadvault.com/favicon.ico"],
            },
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
        transports: {[mainnet.id]: http(RPC_URL)},
        ssr: true,
      })
    : IS_LOCAL_FORK
      ? createLocalForkConfig()
    : createConfig({
        chains: [sepolia],
        connectors: productionConnectors(),
        transports: {[sepolia.id]: http(RPC_URL || undefined)},
        ssr: true,
      });
