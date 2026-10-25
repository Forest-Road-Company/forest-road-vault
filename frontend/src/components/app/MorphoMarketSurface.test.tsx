import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {cleanup, fireEvent, render, screen, waitFor} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {decodeFunctionData} from "viem";
import {accrueMarket, marketPositionValues, MARKET_TOKEN_ABI, MORPHO_MARKET, MORPHO_MARKET_ABI} from "@/lib/morphoMarket";
import {repaymentQuote} from "@/lib/morphoMarketActions";
import {TREASURY_PROPOSAL_KEY} from "@/lib/morphoTreasury";
import type {MorphoMarketSnapshot} from "@/lib/morphoMarketReader";
import {MorphoMarketSurface, validateAmount} from "./MorphoMarketSurface";

const WALLET = "0x1111111111111111111111111111111111111111" as const;
const HASH = `0x${"ab".repeat(32)}` as `0x${string}`;
const OWNERS = [WALLET, "0x2222222222222222222222222222222222222222", "0x3333333333333333333333333333333333333333", "0x4444444444444444444444444444444444444444"];
const h = vi.hoisted(() => ({address: undefined as `0x${string}` | undefined, chainId:1,
  safe: null as unknown, run:vi.fn(), read:vi.fn(), simulate:vi.fn(), send:vi.fn(), info:vi.fn(),
  getCode:vi.fn(), getLogs:vi.fn(), readContract:vi.fn(), switchChain:vi.fn(), lookup:vi.fn(), launch:{lending:true,borrowing:true,treasury:true}}));
vi.mock("@/config/contracts", () => ({IS_MAINNET:true,EXPLORER_BASE_URL:"https://etherscan.io"}));
vi.mock("wagmi", () => ({useAccount:()=>({address:h.address,chainId:h.chainId}),
  usePublicClient:()=>({getCode:h.getCode,getLogs:h.getLogs,readContract:h.readContract}),useSwitchChain:()=>({switchChain:h.switchChain})}));
vi.mock("./ConnectControl",()=>({ConnectControl:()=> <span>Connect wallet</span>}));
vi.mock("./useWriteFlow",()=>({useWriteFlow:()=>({status:{phase:"idle"},busy:false,run:h.run})}));
vi.mock("./useMorphoSafe",()=>({useMorphoSafe:()=>({context:h.safe,error:null})}));
vi.mock("@/lib/morphoMarketReader",()=>({readMorphoMarket:h.read}));
vi.mock("@/lib/morphoSafe",()=>({simulateSafeMarketCalls:h.simulate}));

function snapshot(wallet: `0x${string}` | undefined = h.address): MorphoMarketSnapshot {
  const market={totalSupplyAssets:100_000_000_000n,totalSupplyShares:100_000_000_000_000_000n,
    totalBorrowAssets:20_000_000n,totalBorrowShares:20_000_000_000_000n,lastUpdate:1792500000n,fee:0n};
  const position={supplyShares:1_000_000_000_000n,borrowShares:20_000_000_000_000n,collateral:100n*10n**24n};
  return {block:26234000n,blockHash:HASH,timestamp:1792500000n,readAt:Date.now(),market,projectedMarket:{...market},price:10n**18n,rate:0n,supplyRate:0n,
    issuedAt:Date.now(),expiresAt:Date.now()+300_000,projectedThrough:1792500300n,projectionSeconds:300n,
    liquidity:99_980_000_000n,account:wallet ? {wallet,position,usdc:100_000_000_000n,collateral:100n*10n**24n,
      usdcAllowance:0n,collateralAllowance:0n,values:{supplied:1_000_000n,borrowed:20_000_000n,collateralValue:100_000_000n,
        liquidationDebt:86_000_000n,liquidity:99_980_000_000n,borrowAvailable:66_000_000n,ltvBps:2_000n},safeNonce:15n} : null};
}
function renderMarket() {
  const client=new QueryClient({defaultOptions:{queries:{retry:false,retryDelay:0}}});
  return render(<QueryClientProvider client={client}><MorphoMarketSurface /></QueryClientProvider>);
}
async function amount(value="10") {fireEvent.change(await screen.findByRole("textbox",{name:"Amount in USDC"}),{target:{value}});}
function acknowledge() {fireEvent.click(screen.getByRole("checkbox",{name:/I understand/}));}
function connectSafe() {
  h.address=MORPHO_MARKET.treasury;
  h.safe={address:MORPHO_MARKET.treasury,chainId:1,threshold:2,owners:OWNERS,sdk:{safe:{getInfo:h.info},txs:{send:h.send,getBySafeTxHash:h.lookup}}};
  h.info.mockResolvedValue({chainId:1,safeAddress:MORPHO_MARKET.treasury,threshold:2,owners:OWNERS});
  h.read.mockImplementation(async()=>{const s=snapshot();s.account!.position.supplyShares=0n;return s;});
}
beforeEach(()=>{
  const records=new Map<string,string>();
  vi.stubGlobal("localStorage",{getItem:vi.fn((key:string)=>records.get(key)??null),
    setItem:vi.fn((key:string,value:string)=>records.set(key,value)),removeItem:vi.fn((key:string)=>records.delete(key)),clear:()=>records.clear()});
  h.address=WALLET;h.chainId=1;h.safe=null;h.launch={lending:true,borrowing:true,treasury:true};
  for(const m of [h.run,h.read,h.simulate,h.send,h.info,h.getCode,h.getLogs,h.readContract,h.switchChain,h.lookup])m.mockReset();
  h.read.mockImplementation(async()=>snapshot());h.getCode.mockResolvedValue(undefined);h.getLogs.mockResolvedValue([]);
  h.readContract.mockResolvedValue(15n);h.simulate.mockResolvedValue(undefined);h.send.mockResolvedValue({safeTxHash:HASH});
  h.lookup.mockResolvedValue({safeAddress:MORPHO_MARKET.treasury,txStatus:"AWAITING_CONFIRMATIONS",detailedExecutionInfo:{type:"MULTISIG",safeTxHash:HASH,nonce:15}});
  vi.stubGlobal("fetch",vi.fn(async()=>new Response(JSON.stringify(h.launch),{headers:{"content-type":"application/json"}})));
});
afterEach(()=>{cleanup();vi.unstubAllGlobals();vi.restoreAllMocks();vi.useRealTimers();});

describe("public borrowing and lending screen",()=>{
  it("does not invent a disconnected position or permit a write",async()=>{
    h.address=undefined;renderMarket();
    expect(await screen.findByText(/Connect a wallet to see your lending balance/)).toBeInTheDocument();
    expect(screen.getAllByRole("button",{name:"Lend USDC"}).at(-1)).toBeDisabled();expect(h.run).not.toHaveBeenCalled();
  });
  it("requests only the exact USDC approval from an ordinary wallet",async()=>{
    renderMarket();await amount("123.000001");acknowledge();
    const button=screen.getByRole("button",{name:"Approve USDC"});await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({address:MORPHO_MARKET.params.loanToken,functionName:"approve",args:[MORPHO_MARKET.address,123_000_001n],keepPendingUntilReceipt:true});
  });
  it("supplies for the connected wallet after an existing sufficient allowance",async()=>{
    h.read.mockImplementation(async()=>{const s=snapshot();s.account!.usdcAllowance=100_000_000_000n;return s;});
    renderMarket();await amount("25");acknowledge();
    const button=screen.getAllByRole("button",{name:"Lend USDC"}).at(-1)!;
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"supply",args:[MORPHO_MARKET.params,25_000_000n,0n,WALLET,"0x"]});
  });
  it("keeps entries closed when release status cannot be fetched",async()=>{
    vi.stubGlobal("fetch",vi.fn(async()=>new Response("unavailable",{status:503})));
    renderMarket();await amount();acknowledge();
    expect(await screen.findByText(/New positions are awaiting launch checks/)).toBeInTheDocument();
    expect(screen.getByRole("button",{name:"Approve USDC"})).toBeDisabled();expect(h.run).not.toHaveBeenCalled();
  });
  it("refuses a wallet on the wrong chain",async()=>{
    h.chainId=8453;renderMarket();await amount();acknowledge();
    expect(screen.getByRole("button",{name:"Switch to Ethereum"})).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button",{name:"Switch to Ethereum"}));
    expect(h.switchChain).toHaveBeenCalledExactlyOnceWith({chainId:1});
    expect(screen.getByRole("button",{name:"Approve USDC"})).toBeDisabled();
  });
  it("does not submit after an entry gate closes during preparation",async()=>{
    renderMarket();await amount();acknowledge();const button=screen.getByRole("button",{name:"Approve USDC"});
    await waitFor(()=>expect(button).toBeEnabled());h.launch.lending=false;fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/awaiting launch checks/);expect(h.run).not.toHaveBeenCalled();
  });
  it("repays all by debt shares instead of a stale asset amount",async()=>{
    h.read.mockImplementation(async()=>{const s=snapshot();s.account!.usdcAllowance=100_000_000_000n;return s;});
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Repay USDC"}));
    fireEvent.click(await screen.findByRole("checkbox",{name:/Repay all debt/}));
    const button=screen.getAllByRole("button",{name:"Repay USDC"}).at(-1)!;
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"repay",args:[MORPHO_MARKET.params,0n,20_000_000_000_000n,WALLET,"0x"]});
  });
  it("approves once then repays all when debt grows between reads and entries are off",async()=>{
    h.launch={lending:false,borrowing:false,treasury:false};
    let allowance=0n, interest=0n;
    h.read.mockImplementation(async()=>{
      const s=snapshot();s.rate=1_585_489_599n;s.market.totalBorrowAssets+=interest;s.market.totalSupplyAssets+=interest;
      s.projectedMarket=accrueMarket(s.market,s.rate,s.timestamp+300n);
      s.account!.values.borrowed+=interest;s.account!.usdcAllowance=allowance;s.account!.usdc=20_000_100n;return s;
    });
    h.run.mockImplementation(async request=>{
      if(request.functionName==="approve"){allowance=request.args[1];interest=1n;request.onSuccess();}
    });
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Repay USDC"}));
    fireEvent.click(await screen.findByRole("checkbox",{name:/Repay all debt/}));
    const approve=screen.getByRole("button",{name:"Approve USDC"});await waitFor(()=>expect(approve).toBeEnabled());fireEvent.click(approve);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"approve",args:[MORPHO_MARKET.address,20_020_012n]});
    const repay=await screen.findAllByRole("button",{name:"Repay USDC"});
    await waitFor(()=>expect(repay.at(-1)).toBeEnabled());fireEvent.click(repay.at(-1)!);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(2));
    expect(h.run.mock.calls[1][0]).toMatchObject({functionName:"repay",args:[MORPHO_MARKET.params,0n,20_000_000_000_000n,WALLET,"0x"]});
  });
  it("withdraws all using the newly read lending shares, not a displayed asset estimate",async()=>{
    let shares=1_000_000_000_000n;
    h.read.mockImplementation(async()=>{const s=snapshot();s.account!.position.supplyShares=shares;return s;});
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Withdraw USDC"}));
    fireEvent.click(await screen.findByRole("checkbox",{name:"Withdraw all lending shares"}));
    const button=screen.getAllByRole("button",{name:"Withdraw USDC"}).at(-1)!;
    await waitFor(()=>expect(button).toBeEnabled());shares=2_000_000_000_000n;fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"withdraw",args:[MORPHO_MARKET.params,0n,2_000_000_000_000n,WALLET,WALLET]});
  });
  it("withdraws a typed asset amount to the same wallet",async()=>{
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Withdraw USDC"}));await amount("0.5");
    const button=screen.getAllByRole("button",{name:"Withdraw USDC"}).at(-1)!;
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"withdraw",args:[MORPHO_MARKET.params,500_000n,0n,WALLET,WALLET]});
  });
  it.each(["Repay USDC","Withdraw USDC"])("Max closes %s by shares instead of leaving dust",async action=>{
    renderMarket();fireEvent.click(screen.getByRole("button",{name:action}));await screen.findByText(/Wallet:/);
    fireEvent.click(screen.getByRole("button",{name:/^max$/i}));
    expect(screen.getByRole("checkbox",{name:action==="Repay USDC"?/Repay all debt/:"Withdraw all lending shares"})).toBeChecked();
    expect(screen.getByRole("textbox",{name:"Amount in USDC"})).toBeDisabled();
  });
  it("blocks typed borrows above the buffer and shows the resulting LTV",async()=>{
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Borrow USDC"}));await amount("65");acknowledge();
    expect(await screen.findByText(/Estimated post-action LTV: 85%/)).toBeInTheDocument();
    expect(screen.getAllByRole("button",{name:"Borrow USDC"}).at(-1)).toBeDisabled();
    expect(screen.getByText(/This borrow would exceed/)).toBeInTheDocument();expect(h.run).not.toHaveBeenCalled();
  });
  it("uses a collateral Max that leaves the buffered collateral and asks for risk review",async()=>{
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Withdraw collateral"}));await screen.findByText(/Wallet:/);
    fireEvent.click(screen.getByRole("button",{name:/^max$/i}));
    expect(screen.getByRole("textbox",{name:"Amount in sUSDfr"})).toHaveValue("74.999997");
    expect(screen.getByText(/Estimated post-action LTV: 80%/)).toBeInTheDocument();
    const button=screen.getAllByRole("button",{name:"Withdraw collateral"}).at(-1)!;expect(button).toBeDisabled();acknowledge();
    await waitFor(()=>expect(button).toBeEnabled());
  });
  it("sends collateral with 24 decimals and an exact approval",async()=>{
    renderMarket();fireEvent.click(screen.getByRole("button",{name:"Add sUSDfr collateral"}));
    fireEvent.change(await screen.findByRole("textbox",{name:"Amount in sUSDfr"}),{target:{value:"1.000000000000000000000001"}});acknowledge();
    const button=screen.getByRole("button",{name:"Approve sUSDfr"});await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.run).toHaveBeenCalledTimes(1));expect(h.run.mock.calls[0][0]).toMatchObject({functionName:"approve",
      address:"0xAF559d1D59B33ca4b950AB2091372Af8a773E234",args:["0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",1_000_000_000_000_000_000_000_001n]});
  });
  it.each(["Borrow USDC", "Withdraw collateral"])("submits its own %s Max after a five-minute interest-only fresh read", async title => {
    let later = false;
    h.read.mockImplementation(async () => {
      const s = snapshot();s.rate = 4_180_000_000n;
      if (later) {s.timestamp += 300n;s.market = accrueMarket(s.market, s.rate, s.timestamp);}
      s.projectedMarket = accrueMarket(s.market, s.rate, s.timestamp + 300n);
      s.account!.values = marketPositionValues(s.market, s.account!.position, s.price);
      return s;
    });
    renderMarket();fireEvent.click(screen.getByRole("button", {name: title}));await screen.findByText(/Wallet:/);
    fireEvent.click(screen.getByRole("button", {name: /^max$/i}));acknowledge();
    const button = screen.getAllByRole("button", {name: title}).at(-1)!;
    await waitFor(() => expect(button).toBeEnabled());later = true;fireEvent.click(button);
    await waitFor(() => expect(h.run).toHaveBeenCalledTimes(1));
    expect(h.run.mock.calls[0][0].functionName).toBe(title === "Borrow USDC" ? "borrow" : "withdrawCollateral");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
  it("revalidates the live position before submitting",async()=>{
    renderMarket();await amount("10");acknowledge();const button=screen.getByRole("button",{name:"Approve USDC"});await waitFor(()=>expect(button).toBeEnabled());
    h.read.mockImplementation(async()=>{const s=snapshot();s.account!.usdc=0n;return s;});fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Insufficient USDC/);expect(h.run).not.toHaveBeenCalled();
  });
  it("refuses a contract wallet outside its Safe context",async()=>{
    h.getCode.mockResolvedValue("0x1234");renderMarket();await amount();acknowledge();const button=screen.getByRole("button",{name:"Approve USDC"});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/inside your Safe/);expect(h.run).not.toHaveBeenCalled();
  });
  it("keeps unverifiable reader data closed and provides a retry",async()=>{
    h.read.mockRejectedValue(new Error("provider failed"));renderMarket();
    const alert=await screen.findByRole("alert");expect(alert).toHaveTextContent(/No balances have been assumed/);
    const before=h.read.mock.calls.length;h.read.mockImplementation(async()=>snapshot());fireEvent.click(screen.getByRole("button",{name:"Retry"}));
    await waitFor(()=>expect(h.read.mock.calls.length).toBeGreaterThan(before));await screen.findByText(/Wallet:/);
  });
  it("keeps an old snapshot from enabling a money-moving button",async()=>{
    h.read.mockImplementation(async()=>({...snapshot(),readAt:Date.now()-31_000}));renderMarket();await amount();acknowledge();
    await screen.findByText(/Waiting for current, verified market data/);
    expect(screen.queryByText("100,000 USDC")).not.toBeInTheDocument();expect(screen.getAllByRole("button",{name:"Lend USDC"}).at(-1)).toBeDisabled();
  });
  it("shows explicit expiry and requires a refresh even if an expired read is labelled fresh", async () => {
    h.read.mockImplementation(async () => {const s = snapshot();s.issuedAt -= 300_001;s.expiresAt -= 300_001;return s;});
    renderMarket();await amount();acknowledge();
    expect(await screen.findByText(/Quote expired\. Refresh and review again before signing/)).toBeInTheDocument();
    expect(screen.getAllByRole("button", {name: "Lend USDC"}).at(-1)).toBeDisabled();
    expect(screen.getByText(/Expiry cannot cancel a wallet request or Safe proposal/)).toBeInTheDocument();
    h.read.mockImplementation(async () => snapshot());fireEvent.click(screen.getByRole("button", {name: "Refresh quote"}));
    await screen.findByText(/Quote valid for five minutes from issuance/);
    await waitFor(() => expect(screen.getByRole("button", {name: "Approve USDC"})).toBeEnabled());
    expect(h.run).not.toHaveBeenCalled();
  });
  it("refuses an EOA quote that expires while reading wallet code", async () => {
    let clock = Date.now();vi.spyOn(Date, "now").mockImplementation(() => clock);
    h.getCode.mockImplementation(async () => {clock += 300_001;return undefined;});
    renderMarket();await amount();acknowledge();const button = screen.getByRole("button", {name: "Approve USDC"});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Quote expired/);expect(h.run).not.toHaveBeenCalled();
  });
  it.each(["Repay USDC", "Borrow USDC", "Withdraw collateral"])("pins the %s quote in its final wallet guard", async title => {
    const issuedAt = Date.now();vi.spyOn(Date, "now").mockReturnValue(issuedAt);
    h.read.mockImplementation(async () => {const s = snapshot();s.account!.usdcAllowance = 100_000_000_000n;return s;});
    if (title === "Repay USDC") h.launch = {lending: false, borrowing: false, treasury: false};
    renderMarket();fireEvent.click(screen.getByRole("button", {name: title}));await screen.findByText(/Wallet:/);
    if (title === "Repay USDC") fireEvent.click(screen.getByRole("checkbox", {name: /Repay all debt/}));
    else {fireEvent.click(screen.getByRole("button", {name: /^max$/i}));acknowledge();}
    const button = screen.getAllByRole("button", {name: title}).at(-1)!;
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(() => expect(h.run).toHaveBeenCalledTimes(1));
    const guard = h.run.mock.calls[0][0].assertBeforeWallet;
    expect(guard).toBeTypeOf("function");
    vi.mocked(Date.now).mockReturnValue(issuedAt + 299_999);expect(guard).not.toThrow();
    vi.mocked(Date.now).mockReturnValue(issuedAt + 300_000);expect(guard).toThrow(/Quote expired/);
    vi.mocked(Date.now).mockReturnValue(issuedAt + 300_001);expect(guard).toThrow(/Quote expired/);
  });
});

describe("ordinary Safe batches",()=>{
  function ordinarySafe(){h.safe={address:WALLET,chainId:1,threshold:1,owners:[WALLET],sdk:{safe:{getInfo:h.info},txs:{send:h.send}}};
    h.info.mockResolvedValue({safeAddress:WALLET,chainId:1,threshold:1,owners:[WALLET]});}
  it("simulates and proposes an exact atomic approval plus supply",async()=>{
    ordinarySafe();renderMarket();await amount("25");acknowledge();
    const button=screen.getByRole("button",{name:"Review lend usdc in Safe"});await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.send).toHaveBeenCalledTimes(1));const calls=h.send.mock.calls[0][0].txs;
    expect(calls).toHaveLength(2);expect(decodeFunctionData({abi:MARKET_TOKEN_ABI,data:calls[0].data})).toEqual({functionName:"approve",args:[MORPHO_MARKET.address,25_000_000n]});
    expect(decodeFunctionData({abi:MORPHO_MARKET_ABI,data:calls[1].data})).toMatchObject({functionName:"supply",args:[MORPHO_MARKET.params,25_000_000n,0n,WALLET,"0x"]});
    expect(h.simulate.mock.invocationCallOrder[0]).toBeLessThan(h.send.mock.invocationCallOrder[0]);expect(window.localStorage.getItem(TREASURY_PROPOSAL_KEY)).toBeNull();
  });
  it("proposes a share withdrawal without an unnecessary approval",async()=>{
    ordinarySafe();renderMarket();fireEvent.click(screen.getByRole("button",{name:"Withdraw USDC"}));
    fireEvent.click(await screen.findByRole("checkbox",{name:"Withdraw all lending shares"}));
    const button=screen.getByRole("button",{name:"Review withdraw usdc in Safe"});await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.send).toHaveBeenCalledTimes(1));const calls=h.send.mock.calls[0][0].txs;expect(calls).toHaveLength(1);
    expect(decodeFunctionData({abi:MORPHO_MARKET_ABI,data:calls[0].data})).toMatchObject({functionName:"withdraw",args:[MORPHO_MARKET.params,0n,1_000_000_000_000n,WALLET,WALLET]});
  });
  it.each(["below required", "required", "approval minus one", "approval", "above approval"])("keeps the cushioned Safe repay-all approval at %s", async boundary => {
    ordinarySafe();h.launch = {lending: false, borrowing: false, treasury: false};
    const quote = repaymentQuote(snapshot(WALLET));
    const allowance = boundary === "below required" ? quote.required - 1n : boundary === "required" ? quote.required
      : boundary === "approval minus one" ? quote.approval - 1n : boundary === "approval" ? quote.approval : quote.approval + 1n;
    h.read.mockImplementation(async () => {const s = snapshot();s.account!.usdcAllowance = allowance;return s;});
    renderMarket();fireEvent.click(screen.getByRole("button", {name: "Repay USDC"}));
    fireEvent.click(await screen.findByRole("checkbox", {name: /Repay all debt/}));
    const button = screen.getByRole("button", {name: "Review repay usdc in Safe"});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(() => expect(h.send).toHaveBeenCalledTimes(1));
    const calls = h.send.mock.calls[0][0].txs;
    expect(calls).toHaveLength(allowance < quote.approval ? 2 : 1);
    if (allowance < quote.approval) expect(decodeFunctionData({abi: MARKET_TOKEN_ABI, data: calls[0].data}))
      .toEqual({functionName: "approve", args: [MORPHO_MARKET.address, quote.approval]});
    expect(decodeFunctionData({abi: MORPHO_MARKET_ABI, data: calls.at(-1).data}))
      .toMatchObject({functionName: "repay", args: [MORPHO_MARKET.params, 0n, 20_000_000_000_000n, WALLET, "0x"]});
    expect(h.run).not.toHaveBeenCalled();
  });
  it("refuses a Safe identity change after simulation",async()=>{
    ordinarySafe();h.info.mockResolvedValue({safeAddress:MORPHO_MARKET.treasury,chainId:1,threshold:2,owners:OWNERS});
    renderMarket();await amount("25");acknowledge();const button=screen.getByRole("button",{name:"Review lend usdc in Safe"});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);expect(await screen.findByRole("alert")).toHaveTextContent(/connected Safe changed/);expect(h.send).not.toHaveBeenCalled();
  });
  it.each(["Repay USDC", "Borrow USDC", "Withdraw collateral"])("refuses an expired %s Safe batch after simulation and identity checks", async title => {
    ordinarySafe();let clock = Date.now();vi.spyOn(Date, "now").mockImplementation(() => clock);
    h.info.mockImplementation(async () => {clock += 300_001;return {safeAddress: WALLET, chainId: 1, threshold: 1, owners: [WALLET]};});
    if (title === "Repay USDC") h.launch = {lending: false, borrowing: false, treasury: false};
    renderMarket();fireEvent.click(screen.getByRole("button", {name: title}));await screen.findByText(/Wallet:/);
    if (title === "Repay USDC") fireEvent.click(screen.getByRole("checkbox", {name: /Repay all debt/}));
    else {fireEvent.click(screen.getByRole("button", {name: /^max$/i}));acknowledge();}
    const button = screen.getByRole("button", {name: `Review ${title.toLowerCase()} in Safe`});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Quote expired/);
    expect(h.simulate).toHaveBeenCalledTimes(1);expect(h.info).toHaveBeenCalledTimes(1);
    expect(h.send).not.toHaveBeenCalled();expect(h.run).not.toHaveBeenCalled();
  });
  it("does not replace a handed-off Safe quote expiry with a background read", async () => {
    ordinarySafe();const issuedAt = Date.now();let clock = issuedAt;
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    renderMarket();await amount("25");acknowledge();
    const button = screen.getByRole("button", {name: "Review lend usdc in Safe"});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(() => expect(h.send).toHaveBeenCalledTimes(1));
    clock += 300_001;
    fireEvent.focus(window);
    // The one-second display clock observes expiry even though the market poll can refresh.
    await screen.findByText(/Quote expired\. Refresh and review again before signing/);
    expect(screen.getByRole("button", {name: /Awaiting Safe execution/})).toBeDisabled();
    expect(h.send).toHaveBeenCalledTimes(1);
  });
});

describe("Treasury Safe flow",()=>{
  it("requires the Safe app even when WalletConnect exposes the Treasury address",async()=>{
    h.address=MORPHO_MARKET.treasury;renderMarket();acknowledge();
    expect(await screen.findByText(/Open this page inside the Treasury Safe/)).toBeInTheDocument();
    expect(screen.getByRole("button",{name:/Review 50,000-USDC/})).toBeDisabled();expect(h.run).not.toHaveBeenCalled();
  });
  it("hands both reviewed zero-value calls to Safe only after atomic simulation",async()=>{
    connectSafe();renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await waitFor(()=>expect(h.send).toHaveBeenCalledTimes(1));
    const calls=h.send.mock.calls[0][0].txs;
    expect(calls).toHaveLength(2);
    expect(calls[0].to).toBe("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    expect(calls[1].to).toBe("0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb");
    expect(calls.map((call:{value:string})=>call.value)).toEqual(["0","0"]);
    expect(decodeFunctionData({abi:MARKET_TOKEN_ABI,data:calls[0].data})).toEqual({functionName:"approve",args:["0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",50_000_000_000n]});
    const supplied=decodeFunctionData({abi:MORPHO_MARKET_ABI,data:calls[1].data});
    expect(supplied.functionName).toBe("supply");
    expect(supplied.args).toEqual([{loanToken:"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      collateralToken:"0xAF559d1D59B33ca4b950AB2091372Af8a773E234",oracle:"0xa60a8c2824A2696D9D3ff05870cfa3c01BF9C4Eb",
      irm:"0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",lltv:860_000_000_000_000_000n},
      50_000_000_000n,0n,"0x0687a13c490B2573d4666fb3a7c21826a621215E","0x"]);
    expect(h.simulate).toHaveBeenCalledTimes(1);expect(h.simulate.mock.invocationCallOrder[0]).toBeLessThan(h.send.mock.invocationCallOrder[0]);
    expect(await screen.findByText(/Safe review returned a proposal reference/)).toBeInTheDocument();
    expect(screen.queryByText("Confirmed.")).not.toBeInTheDocument();expect(h.run).not.toHaveBeenCalled();
    expect(screen.getByRole("button",{name:/Awaiting Safe execution/})).toBeDisabled();
    expect(JSON.parse(window.localStorage.getItem(TREASURY_PROPOSAL_KEY)!)).toMatchObject({hash:HASH,nonce:"15"});
  });
  it("refuses a duplicate Treasury proposal after a reload and queries the saved hash",async()=>{
    connectSafe();let view=renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await screen.findByText(/Safe review returned a proposal reference/);view.unmount();
    view=renderMarket();acknowledge();
    await waitFor(()=>expect(h.lookup).toHaveBeenCalledWith(HASH));
    expect(await screen.findByText(/A Treasury seed proposal is already recorded/)).toBeInTheDocument();
    expect(screen.getByRole("button",{name:/Review 50,000-USDC/})).toBeDisabled();expect(h.send).toHaveBeenCalledTimes(1);
  });
  it("keeps an uncertain Safe reply locked after reload",async()=>{
    connectSafe();h.send.mockRejectedValue(new Error("Safe reply unavailable"));const view=renderMarket();acknowledge();
    const button=screen.getByRole("button",{name:/Review 50,000-USDC/});await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    await screen.findByRole("alert");view.unmount();renderMarket();acknowledge();
    expect(await screen.findByText(/The Safe reply was not recorded/)).toBeInTheDocument();
    expect(screen.getByRole("button",{name:/Review 50,000-USDC/})).toBeDisabled();expect(h.send).toHaveBeenCalledTimes(1);
  });
  it("fails closed when browser proposal storage is unavailable",async()=>{
    connectSafe();const spy=vi.spyOn(window.localStorage,"getItem").mockImplementation(()=>{throw new Error("storage unavailable");});
    try {renderMarket();acknowledge();await screen.findByText(/Treasury proposal tracking is unavailable/);
      expect(screen.getByRole("button",{name:/Review 50,000-USDC/})).toBeDisabled();expect(h.send).not.toHaveBeenCalled();
    } finally {spy.mockRestore();}
  });
  it("refuses a change away from the reviewed Treasury governance",async()=>{
    connectSafe();h.info.mockResolvedValue({chainId:1,safeAddress:MORPHO_MARKET.treasury,threshold:1,owners:OWNERS});
    renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/governance differs/);expect(h.send).not.toHaveBeenCalled();
  });
  it("does not request a Safe proposal when the batch simulation fails",async()=>{
    connectSafe();h.simulate.mockRejectedValue(new Error("The complete Safe batch did not simulate successfully."));
    renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/did not simulate/);expect(h.send).not.toHaveBeenCalled();
  });
  it("refuses the actual unfunded Treasury",async()=>{
    connectSafe();h.read.mockImplementation(async()=>{const s=snapshot();s.account!.usdc=0n;return s;});
    renderMarket();acknowledge();expect(await screen.findByText("Insufficient USDC in this wallet.")).toBeInTheDocument();
    expect(screen.getByRole("button",{name:/Review 50,000-USDC/})).toBeDisabled();expect(h.send).not.toHaveBeenCalled();
  });
  it("refuses a nonce change after simulation",async()=>{
    connectSafe();h.readContract.mockResolvedValue(16n);renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/nonce changed/);expect(h.send).not.toHaveBeenCalled();
  });
  it("rejects expiry after the Treasury nonce RPC before reserving a proposal", async () => {
    connectSafe();let clock = Date.now();vi.spyOn(Date, "now").mockImplementation(() => clock);
    h.readContract.mockImplementation(async () => {clock += 300_000;return 15n;});
    renderMarket();acknowledge();const button = screen.getByRole("button", {name: /Review 50,000-USDC/});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Quote expired/);
    expect(h.send).not.toHaveBeenCalled();expect(window.localStorage.getItem(TREASURY_PROPOSAL_KEY)).toBeNull();
  });
  it("checks expiry again after browser proposal reservation before Safe handoff", async () => {
    connectSafe();let clock = Date.now();vi.spyOn(Date, "now").mockImplementation(() => clock);
    const store = vi.mocked(window.localStorage.setItem).getMockImplementation()!;
    vi.mocked(window.localStorage.setItem).mockImplementation((key, value) => {store(key, value);clock += 300_001;});
    renderMarket();acknowledge();const button = screen.getByRole("button", {name: /Review 50,000-USDC/});
    await waitFor(() => expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Quote expired/);expect(h.send).not.toHaveBeenCalled();
    // Keep the uncertain intent fail-closed; never silently clear duplicate protection.
    expect(window.localStorage.getItem(TREASURY_PROPOSAL_KEY)).not.toBeNull();
  });
  it("refuses a second own Treasury supply even when its shares were withdrawn",async()=>{
    connectSafe();h.getLogs.mockResolvedValue([{args:{assets:50_000_000_000n,shares:50_000_000_000_000_000n}}]);
    renderMarket();acknowledge();const button=screen.getByRole("button",{name:/Review 50,000-USDC/});
    await waitFor(()=>expect(button).toBeEnabled());fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent(/already supplied/);expect(h.send).not.toHaveBeenCalled();
  });
});

describe("position limits",()=>{
  it("refuses collateral removal below the liquidation threshold",()=>{
    expect(validateAmount("withdrawCollateral",90n*10n**24n,false,snapshot(WALLET))).toMatch(/insufficient collateral/);
    expect(validateAmount("withdrawCollateral",50n*10n**24n,false,snapshot(WALLET))).toBeNull();
  });
  it("refuses borrowing above liquidity or collateral capacity",()=>{
    expect(validateAmount("borrow",100_000_000n,false,snapshot(WALLET))).toMatch(/collateral capacity/);
  });
  it("refuses share exits with no shares or insufficient market liquidity",()=>{
    const s=snapshot(WALLET);s.account!.position.supplyShares=0n;
    expect(validateAmount("withdraw",null,true,s)).toMatch(/no lending shares/);
    s.account!.position.supplyShares=1n;s.liquidity=999_999n;
    expect(validateAmount("withdraw",null,true,s)).toMatch(/enough liquidity/);
    s.liquidity=1_000_000n;expect(validateAmount("withdraw",null,true,s)).toBeNull();
  });
  it("uses shares, not an exact displayed asset amount, to close debt",()=>{
    expect(validateAmount("repay",20_000_000n,false,snapshot(WALLET))).toMatch(/Choose Repay all/);
    expect(validateAmount("repay",19_999_999n,false,snapshot(WALLET))).toBeNull();
  });
  it("refuses collateral withdrawal above 80% even when below the liquidation limit",()=>{
    expect(validateAmount("withdrawCollateral",76n*10n**24n,false,snapshot(WALLET))).toMatch(/80% LTV/);
  });
  it("checks missing accounts, empty debt, repayment balance and token-specific funds",()=>{
    const s=snapshot(WALLET);
    expect(validateAmount("supplyCollateral",101n*10n**24n,false,s)).toMatch(/Insufficient sUSDfr/);
    expect(validateAmount("withdrawCollateral",101n*10n**24n,false,s)).toMatch(/exceeds your posted collateral/);
    expect(validateAmount("withdraw",2_000_000n,false,s)).toMatch(/lending balance/);
    expect(validateAmount("supply",100_000_000_001n,false,s)).toMatch(/Insufficient USDC/);
    s.account!.usdc=19_999_999n;expect(validateAmount("repay",null,true,s)).toMatch(/five-minute interest estimate/);
    s.account!.position.borrowShares=0n;expect(validateAmount("repay",null,true,s)).toMatch(/no debt/);
    s.account=null;expect(validateAmount("supply",1n,false,s)).toMatch(/Connect your wallet/);
  });
});
