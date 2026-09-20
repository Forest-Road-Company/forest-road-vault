import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";

// The production release gate is plain ESM because Next invokes it before TypeScript starts.
// @ts-expect-error The repository tool intentionally has no emitted declaration file.
import {verifyCuratorDeploymentBinding} from "../../../tools/curator-vault-manifest.mjs";

const PROGRAM = "HNWZdMnKZb4aVxjnF9tHvHNQobZ1fMvbF45Nx5bGsKZL";
const MINT = "HiSEcT1P1vYniRkLzJ591fy4C1SU57yfCnJCbsM8EEP1";
const SIGNATURE = "2boFC3XJL2gmfpzhnV8N8Gn1BgSFsAgqu2KhUnaJqX9wBsKczA7fr7FXV5a8PPNMeEybjzsRWKiixp35XB4fypbv";

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "frv-curator-manifest-"));
  const idlPath = join(directory, "curator-vault.idl.json");
  const idlBytes = Buffer.from(`${JSON.stringify({address: PROGRAM, instructions: []}, null, 2)}\n`);
  writeFileSync(idlPath, idlBytes);
  const elfBytes = Buffer.from("canonical release elf");
  mkdirSync(join(directory, "artifacts"));
  writeFileSync(join(directory, "artifacts", "forestroad_curator_vault.so"), elfBytes);
  const build = {
    schemaVersion: 2,
    gitCommit: "a".repeat(40),
    dirty: false,
    programId: PROGRAM,
    elfSha256: createHash("sha256").update(elfBytes).digest("hex"),
    elfBytes: elfBytes.length,
    idlSha256: createHash("sha256").update(idlBytes).digest("hex"),
    idlBytes: idlBytes.length,
    releaseBuilder: {
      solanaVerify: "0.5.0",
      solanaCli: "4.0.3",
      sbfArch: "v3",
      platformTools: "v1.57",
      baseImage: "solanafoundation/solana-verifiable-build@sha256:588d0c6f45c2faa4456c7b8279897d8af8c6cd17e9613bb8ddf622a820039eb2",
    },
  };
  const manifest = {
    cluster: "devnet",
    programId: PROGRAM,
    mint: MINT,
    build: {...build},
    deploymentBuild: {...build},
    canonicalBuildActivatedAtSlot: 123,
    buildActivations: [{build: {...build}, activatedAtSlot: 123, signature: SIGNATURE}],
    signatures: {deployProgram: SIGNATURE, canonicalBuildActivation: SIGNATURE},
  };
  writeFileSync(join(directory, "build.json"), `${JSON.stringify(build)}\n`);
  writeFileSync(join(directory, "devnet.json"), `${JSON.stringify(manifest)}\n`);
  return {build, directory, idlPath, manifest};
}

function verify(directory: string, idlPath: string) {
  return verifyCuratorDeploymentBinding({
    cluster: "devnet",
    programId: PROGRAM,
    mint: MINT,
    deploymentDirectory: directory,
    frontendIdlPath: idlPath,
  });
}

test("accepts one clean build, deployment and frontend IDL", () => {
  const f = fixture();
  try {
    assert.equal(verify(f.directory, f.idlPath).build.gitCommit, f.build.gitCommit);
  } finally {
    rmSync(f.directory, {recursive: true, force: true});
  }
});

test("rejects dirty source, substituted artifacts and an unpinned release builder", () => {
  const f = fixture();
  try {
    writeFileSync(join(f.directory, "build.json"), `${JSON.stringify({...f.build, dirty: true})}\n`);
    assert.throws(() => verify(f.directory, f.idlPath), /dirty source/);
    writeFileSync(join(f.directory, "build.json"), `${JSON.stringify(f.build)}\n`);
    writeFileSync(join(f.directory, "artifacts", "forestroad_curator_vault.so"), "substituted elf");
    assert.throws(() => verify(f.directory, f.idlPath), /build\.elfSha256/);
    writeFileSync(join(f.directory, "artifacts", "forestroad_curator_vault.so"), "canonical release elf");
    const build = {
      ...f.build,
      releaseBuilder: {...f.build.releaseBuilder, platformTools: "v1.56"},
    };
    writeFileSync(join(f.directory, "build.json"), `${JSON.stringify(build)}\n`);
    writeFileSync(join(f.directory, "devnet.json"), `${JSON.stringify({...f.manifest, build})}\n`);
    assert.throws(() => verify(f.directory, f.idlPath), /release builder/);
    const imageBuild = {
      ...f.build,
      releaseBuilder: {
        ...f.build.releaseBuilder,
        baseImage: `solanafoundation/solana-verifiable-build@sha256:${"c".repeat(64)}`,
      },
    };
    writeFileSync(join(f.directory, "build.json"), `${JSON.stringify(imageBuild)}\n`);
    writeFileSync(join(f.directory, "devnet.json"), `${JSON.stringify({...f.manifest, build: imageBuild})}\n`);
    assert.throws(() => verify(f.directory, f.idlPath), /release builder/);
  } finally {
    rmSync(f.directory, {recursive: true, force: true});
  }
});

test("rejects a substituted IDL or missing deployment signature", () => {
  const f = fixture();
  try {
    writeFileSync(f.idlPath, `${JSON.stringify({address: PROGRAM, instructions: [{name: "other"}]})}\n`);
    assert.throws(() => verify(f.directory, f.idlPath), /frontend curator vault IDL/);
    writeFileSync(f.idlPath, `${JSON.stringify({address: PROGRAM, instructions: []}, null, 2)}\n`);
    writeFileSync(
      join(f.directory, "devnet.json"),
      `${JSON.stringify({...f.manifest, signatures: {}})}\n`,
    );
    assert.throws(() => verify(f.directory, f.idlPath), /deployment signature/);
    writeFileSync(
      join(f.directory, "devnet.json"),
      `${JSON.stringify({...f.manifest, signatures: {deployProgram: SIGNATURE}})}\n`,
    );
    assert.throws(() => verify(f.directory, f.idlPath), /canonical build activation signature/);
  } finally {
    rmSync(f.directory, {recursive: true, force: true});
  }
});

test("requires the state-creating build and exact activation history", () => {
  const f = fixture();
  try {
    writeFileSync(
      join(f.directory, "devnet.json"),
      `${JSON.stringify({...f.manifest, deploymentBuild: undefined})}\n`,
    );
    assert.throws(() => verify(f.directory, f.idlPath), /state-creating build receipt/);
    writeFileSync(
      join(f.directory, "devnet.json"),
      `${JSON.stringify({...f.manifest, buildActivations: []})}\n`,
    );
    assert.throws(() => verify(f.directory, f.idlPath), /activation history/);
    const wrongActivation = [{...f.manifest.buildActivations[0], signature: "3".repeat(64)}];
    writeFileSync(
      join(f.directory, "devnet.json"),
      `${JSON.stringify({...f.manifest, buildActivations: wrongActivation})}\n`,
    );
    assert.throws(() => verify(f.directory, f.idlPath), /activation history/);
  } finally {
    rmSync(f.directory, {recursive: true, force: true});
  }
});
