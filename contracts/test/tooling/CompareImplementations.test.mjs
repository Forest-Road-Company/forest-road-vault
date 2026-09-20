import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, mkdir, rm, writeFile} from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {promisify} from "node:util";
import {fileURLToPath} from "node:url";
import {test} from "node:test";

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const targets = [
  ["timelock", "Deploy.s.sol", "ForestRoadTimelock"],
  ["compliance", "ComplianceRegistry.sol", "ComplianceRegistry"],
  ["usdfr", "USDfr.sol", "USDfr"],
  ["reserves", "ReserveManager.sol", "ReserveManager"],
  ["controller", "MintRedeemController.sol", "MintRedeemController"],
  ["vault", "sUSDfr.sol", "SUSDfr"],
  ["points", "PointsModule.sol", "PointsModule"],
  ["registry", "CollateralRegistry.sol", "CollateralRegistry"],
  ["oracle", "AttestationOracle.sol", "AttestationOracle"],
  ["bridge", "ClaimBridge.sol", "ClaimBridge"],
  ["curator", "CuratorModule.sol", "CuratorModule"],
  ["waterfall", "WaterfallEngine.sol", "WaterfallEngine"],
  ["defaultManager", "DefaultManager.sol", "DefaultManager"],
  ["assessedImpairmentSource", "AssessedImpairmentSource.sol", "AssessedImpairmentSource"],
  ["queue", "RedemptionQueue.sol", "RedemptionQueue"],
  ["grove", "GroveToken.sol", "GroveToken"],
  ["sGrove", "SGrove.sol", "SGrove"],
  ["governor", "FRGovernor.sol", "FRGovernor"],
  ["votesAggregator", "GroveVotesAggregator.sol", "GroveVotesAggregator"],
  ["mtmExecutor", "MtmAtomicExecutor.sol", "MtmAtomicExecutor"],
];
const address = (value) => `0x${BigInt(value).toString(16).padStart(40, "0")}`;
const runtime = "0x600060005500";
const libraryAddress = address(900);
const linkedRuntime = `0x73${libraryAddress.slice(2)}600060005500`;
const libraryRuntime = `0x73${libraryAddress.slice(2)}301460005500`;

// Exercise the actual command using local RPC replies and synthetic artifacts. No live RPC,
// deployment manifest, credentials, transaction submission or contract deployment is used.
async function runComparison({missingKey, zeroSlot = false} = {}) {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "frv-implementation-check-"));
  const manifest = {chainId: 1337};
  const implementations = new Map();
  const code = new Map();
  let missingImplementation;
  for (const [index, [key, source, name]] of targets.entries()) {
    const instance = address(index + 100);
    let implementation = index < 18 ? address(index + 200) : instance;
    if (key === missingKey && zeroSlot) implementation = address(0);
    manifest[key] = instance;
    manifest[`impl_${key}`] = implementation;
    implementations.set(instance, implementation);
    const implementationRuntime = key === "reserves" ? linkedRuntime : runtime;
    code.set(implementation, implementationRuntime);
    if (key === missingKey) {
      missingImplementation = implementation;
      code.set(implementation, "0x");
    }
    const directory = path.join(temporary, "out", source);
    await mkdir(directory, {recursive: true});
    await writeFile(path.join(directory, `${name}.json`), JSON.stringify({
      deployedBytecode: {object: implementationRuntime, immutableReferences: {},
        linkReferences: key === "reserves" ? {
          "src/libraries/FixtureReserveLib.sol": {FixtureReserveLib: [{start: 1, length: 20}]},
        } : {}},
    }));
  }
  code.set(libraryAddress, libraryRuntime);
  const libraryDirectory = path.join(temporary, "out", "FixtureReserveLib.sol");
  await mkdir(libraryDirectory, {recursive: true});
  await writeFile(path.join(libraryDirectory, "FixtureReserveLib.json"), JSON.stringify({
    deployedBytecode: {object: libraryRuntime},
  }));
  const manifestPath = path.join(temporary, "manifest.json");
  await writeFile(manifestPath, JSON.stringify(manifest));
  const requests = [];
  const server = http.createServer(async (request, response) => {
    let input = "";
    for await (const chunk of request) input += chunk;
    const query = JSON.parse(input);
    requests.push(query);
    const {method, params = []} = query;
    let result;
    if (method === "eth_chainId") result = "0x539";
    else if (method === "eth_blockNumber") result = "0x42";
    else if (method === "eth_getCode") result = code.get(params[0].toLowerCase()) ?? "0x";
    else if (method === "eth_getStorageAt") {
      result = `0x${implementations.get(params[0].toLowerCase()).slice(2).padStart(64, "0")}`;
    } else {
      response.writeHead(400);
      response.end(JSON.stringify({error: `Unexpected test RPC method ${method}`}));
      return;
    }
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({jsonrpc: "2.0", id: query.id, result}));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const rpc = `http://127.0.0.1:${server.address().port}`;
  try {
    const options = {
      cwd: root,
      env: {...process.env, DEPLOYMENT_RPC_URL: rpc, DEPLOYMENT_MANIFEST: manifestPath,
        DEPLOYMENT_ARTIFACT_ROOT: temporary},
      timeout: 30000,
    };
    try {
      const result = await exec(process.execPath, [path.join(root, "tools/compare-sepolia-implementations.mjs")], options);
      return {...result, exitCode: 0, requests, missingImplementation};
    } catch (error) {
      assert.equal(typeof error.code, "number", "the command must terminate with an ordinary exit code");
      return {stdout: error.stdout, stderr: error.stderr, exitCode: error.code, requests, missingImplementation};
    }
  } finally {
    await new Promise((resolve) => {
      server.close(resolve);
      server.closeAllConnections();
    });
    await rm(temporary, {recursive: true, force: true});
  }
}

test("matching proxy and immutable runtimes produce all comparison rows", async () => {
  const result = await runComparison();
  assert.equal(result.exitCode, 0, result.stderr);
  assert.match(result.stdout, /Checked 18 proxies and 2 immutable contract\(s\) on chain 1337/);
  assert.equal(result.stdout.split("\n").filter((line) => /\bCURRENT\b/.test(line)).length, 20);
  assert.equal(result.stderr, "");
});

for (const zeroSlot of [false, true]) {
  test(`a ${zeroSlot ? "zero" : "codeless"} implementation reports its module and address`, async () => {
    const result = await runComparison({missingKey: "defaultManager", zeroSlot});
    assert.equal(result.exitCode, 1);
    assert.ok(result.requests.some(({method, params}) => method === "eth_getCode"
      && params[0].toLowerCase() === result.missingImplementation));
    assert.ok(result.stderr.includes(`defaultManager implementation ${result.missingImplementation} has no deployed bytecode`), result.stderr);
    assert.doesNotMatch(result.stderr, /TypeError/);
  });
}
