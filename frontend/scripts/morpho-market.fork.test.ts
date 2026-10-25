import {beforeAll, describe, expect, it} from "vitest";
import {createPublicClient, encodeFunctionData, http, parseAbi} from "viem";
import {MORPHO_MARKET, treasurySupplyCalls} from "../src/lib/morphoMarket";
import {readMorphoMarket} from "../src/lib/morphoMarketReader";
import {simulateSafeMarketCalls} from "../src/lib/morphoSafe";

// This suite only accepts an explicitly provisioned loopback Anvil. Credentials stay in its parent.
const endpoint=process.env.MORPHO_FRONTEND_TEST_RPC_URL;
if(endpoint){const u=new URL(endpoint);if(u.protocol!=="http:"||u.hostname!=="127.0.0.1"||!u.port||u.username||u.password)throw new Error("Only the disposable loopback Anvil is accepted.");}
const client=createPublicClient({transport:http(endpoint??"http://127.0.0.1:1",{retryCount:0}),cacheTime:0});
const tokenAbi=parseAbi(["function masterMinter() view returns(address)","function configureMinter(address,uint256) returns(bool)","function mint(address,uint256) returns(bool)"]);
async function local(method:string,params:unknown[]=[]){
  const r=await fetch(endpoint!,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method,params})});
  const body=await r.json();if(body.error)throw new Error(`Disposable-fork method failed: ${method}`);return body.result;
}
describe.skipIf(!endpoint)("the actual browser reader and Safe simulation on a pinned disposable fork",()=>{
  beforeAll(async()=>{
    expect(await local("web3_clientVersion")).toMatch(/anvil/i);
    expect(await client.getChainId()).toBe(1);
    await local("evm_setNextBlockTimestamp",[Math.floor(Date.now()/1000)]);await local("evm_mine");
  });
  it("reads and verifies the deployed market, decimals, Treasury and nonce",async()=>{
    const s=await readMorphoMarket(client,MORPHO_MARKET.treasury);
    expect(s.account!.usdc).toBe(0n);expect(s.account!.usdcAllowance).toBe(0n);
    expect(s.account!.safeNonce).toBe(15n);expect(s.market.totalSupplyAssets).toBe(0n);expect(s.price).toBeGreaterThan(0n);
  });
  it("refuses the unfunded Safe batch using the real simulateAndRevert response",async()=>{
    await expect(simulateSafeMarketCalls(client,MORPHO_MARKET.treasury,treasurySupplyCalls())).rejects.toThrow(/did not simulate/);
  });
  it("simulates exact 50k from a synthetically 100k-funded Safe and rolls every write back",async()=>{
    const master=await client.readContract({address:MORPHO_MARKET.params.loanToken,abi:tokenAbi,functionName:"masterMinter"});
    await local("anvil_setBalance",[master,"0xde0b6b3a7640000"]);await local("anvil_impersonateAccount",[master]);
    const data=encodeFunctionData({abi:tokenAbi,functionName:"configureMinter",args:[master,100_000_000_000n]});
    let tx=await local("eth_sendTransaction",[{from:master,to:MORPHO_MARKET.params.loanToken,data,gas:"0x1e8480"}]);
    expect((await client.waitForTransactionReceipt({hash:tx})).status).toBe("success");
    tx=await local("eth_sendTransaction",[{from:master,to:MORPHO_MARKET.params.loanToken,
      data:encodeFunctionData({abi:tokenAbi,functionName:"mint",args:[MORPHO_MARKET.treasury,100_000_000_000n]}),gas:"0x1e8480"}]);
    expect((await client.waitForTransactionReceipt({hash:tx})).status).toBe("success");
    await local("anvil_stopImpersonatingAccount",[master]);
    await simulateSafeMarketCalls(client,MORPHO_MARKET.treasury,treasurySupplyCalls());
    const s=await readMorphoMarket(client,MORPHO_MARKET.treasury);
    expect(s.account!.usdc).toBe(100_000_000_000n);expect(s.account!.usdcAllowance).toBe(0n);
    expect(s.account!.safeNonce).toBe(15n);expect(s.account!.position.supplyShares).toBe(0n);
  });
});
