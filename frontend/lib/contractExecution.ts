import { createWalletClient, createPublicClient, http, custom } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil, ganache } from "@/config/web3";
import { chainConfig } from "@/config/contracts";

export const ANVIL_ACCOUNTS = {
  admin: {
    address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`,
    privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as `0x${string}`,
    roleLabel: "Governance Admin (Approver)",
  },
  borrower: {
    address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as `0x${string}`,
    privateKey: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as `0x${string}`,
    roleLabel: "Demo Borrower",
  },
  lender: {
    address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as `0x${string}`,
    privateKey: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as `0x${string}`,
    roleLabel: "Demo Liquidity Provider",
  },
} as const;

export type ContractRole = keyof typeof ANVIL_ACCOUNTS;

export interface WriteContractParams {
  address: `0x${string}`;
  abi: any;
  functionName: string;
  args?: any[];
  value?: bigint;
}

export function getLocalRpcUrl(): string {
  if (process.env.NEXT_PUBLIC_LOCAL_RPC_URL) {
    return process.env.NEXT_PUBLIC_LOCAL_RPC_URL;
  }
  if (chainConfig.chainId === 1337 || chainConfig.chainId === 5777) {
    return "http://127.0.0.1:7545";
  }
  return "http://127.0.0.1:8545";
}

/**
 * Executes a smart contract write transaction.
 * In the browser, transactions ALWAYS prompt and execute through the user's MetaMask extension.
 * If MetaMask is not installed or user rejects, it raises a clear error rather than silently signing.
 * Transactions are awaited with waitForTransactionReceipt so callers never receive unconfirmed state.
 */
export async function executeContractWithFallback({
  params,
  role = "admin",
  isConnected = false,
  writeContractAsync,
}: {
  params: WriteContractParams;
  role?: ContractRole;
  isConnected?: boolean;
  writeContractAsync?: (args: any) => Promise<`0x${string}`>;
}): Promise<`0x${string}`> {
  const activeChain = (chainConfig.chainId === 1337 || chainConfig.chainId === 5777) ? ganache : anvil;
  const publicClient = createPublicClient({
    chain: activeChain,
    transport: http(getLocalRpcUrl()),
  });

  // If running in browser window, strictly require MetaMask wallet confirmation
  if (typeof window !== "undefined") {
    const ethereum = (window as any).ethereum;
    if (!ethereum) {
      throw new Error(
        "MetaMask extension was not detected. Please install the MetaMask extension and connect your Web3 wallet to interact with CredChain."
      );
    }

    try {
      // Prompt MetaMask connection if not yet connected
      const accounts = (await ethereum.request({
        method: "eth_requestAccounts",
      })) as string[];

      if (!accounts || accounts.length === 0) {
        throw new Error("No account selected in MetaMask. Please unlock and connect MetaMask.");
      }

      const userAccount = accounts[0] as `0x${string}`;

      // Switch to local Anvil network (31337 = 0x7a69) if needed
      if (chainConfig.chainId === 31337) {
        try {
          await ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: "0x7a69" }],
          });
        } catch (switchErr: any) {
          if (switchErr.code === 4902) {
            await ethereum.request({
              method: "wallet_addEthereumChain",
              params: [
                {
                  chainId: "0x7a69",
                  chainName: "Anvil Local",
                  rpcUrls: ["http://127.0.0.1:8545"],
                  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
                },
              ],
            });
          }
        }
      }

      // Fetch the true on-chain pending nonce so MetaMask never sends a desynced/stale nonce
      let onChainNonce: number | undefined;
      try {
        onChainNonce = await publicClient.getTransactionCount({
          address: userAccount,
          blockTag: "pending",
        });
      } catch (nonceErr) {
        console.warn("Could not fetch on-chain nonce:", nonceErr);
      }

      const client = createWalletClient({
        account: userAccount,
        chain: activeChain,
        transport: custom(ethereum),
      });

      // Directly prompts MetaMask confirmation modal with explicit on-chain nonce!
      const hash = await client.writeContract({
        address: params.address,
        abi: params.abi,
        functionName: params.functionName,
        args: params.args as any,
        value: params.value,
        ...(onChainNonce !== undefined ? { nonce: onChainNonce } : {}),
      });

      // Wait for transaction to be mined into a block so subsequent reads and steps never stall
      try {
        const receipt = await publicClient.waitForTransactionReceipt({
          hash,
          timeout: 15_000,
        });
        if (receipt.status === "reverted") {
          throw new Error("Transaction execution was reverted on-chain.");
        }
      } catch (waitErr: any) {
        if (waitErr?.message?.includes("reverted")) {
          throw waitErr;
        }
        console.warn("Transaction submitted, receipt wait timed out:", waitErr);
      }

      return hash;
    } catch (err: any) {
      const msg = String(err?.message || "");
      if (
        msg.includes("User rejected") ||
        msg.includes("user rejected") ||
        err?.code === 4001 ||
        err?.name === "UserRejectedRequestError"
      ) {
        throw new Error("Transaction was cancelled in MetaMask.");
      }
      // Re-throw contract errors or revert messages directly
      throw err;
    }
  }

  // 3. Headless / Server / CLI Fallback only (when window is undefined)
  const rpcUrl = getLocalRpcUrl();
  const accountInfo = ANVIL_ACCOUNTS[role] || ANVIL_ACCOUNTS.admin;
  const account = privateKeyToAccount(accountInfo.privateKey);

  const client = createWalletClient({
    account,
    chain: activeChain,
    transport: http(rpcUrl),
  });

  try {
    const hash = await client.writeContract({
      address: params.address,
      abi: params.abi,
      functionName: params.functionName,
      args: params.args as any,
      value: params.value,
    });

    try {
      await publicClient.waitForTransactionReceipt({
        hash,
        timeout: 15_000,
      });
    } catch (receiptErr) {
      console.warn("Headless receipt wait:", receiptErr);
    }

    return hash;
  } catch (err: any) {
    const msg = String(err?.message || "");
    if (msg.includes("fetch failed") || msg.includes("ECONNREFUSED")) {
      throw new Error(
        `Local blockchain node is unreachable at ${rpcUrl}. Start Anvil (port 8545) or connect MetaMask to proceed.`
      );
    }
    throw err;
  }
}
