/** The exact chain selected by this build, shared by read and wallet clients. */

import {defineChain} from "viem";
import {mainnet, sepolia} from "viem/chains";
import {CHAIN_ID, IS_LOCAL_FORK, RPC_URL} from "@/config/contracts";

export const LOCAL_SEPOLIA_FORK = defineChain({
  id: 31337,
  name: "Forest Road Sepolia fork",
  nativeCurrency: sepolia.nativeCurrency,
  rpcUrls: {
    default: {http: [RPC_URL]},
  },
  testnet: true,
});

export const EXPECTED_CHAIN =
  CHAIN_ID === mainnet.id ? mainnet : IS_LOCAL_FORK ? LOCAL_SEPOLIA_FORK : sepolia;
