import {createHash} from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const SHA256 = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const SIGNATURE = /^[1-9A-HJ-NP-Za-km-z]{64,96}$/;
const RELEASE_IMAGE = "solanafoundation/solana-verifiable-build@sha256:588d0c6f45c2faa4456c7b8279897d8af8c6cd17e9613bb8ddf622a820039eb2";

/**
 * Binds a configured Solana wallet surface to one clean program build and its deployment.
 * Paths are arguments so the release gate and the negative tests exercise the same code.
 */
export function verifyCuratorDeploymentBinding({
  cluster,
  programId,
  mint,
  deploymentDirectory,
  frontendIdlPath,
}) {
  const manifestPath = path.join(deploymentDirectory, `${cluster}.json`);
  const buildReceiptPath = path.join(deploymentDirectory, "build.json");
  const canonicalArtifactPath = path.join(deploymentDirectory, "artifacts", "forestroad_curator_vault.so");
  for (const required of [manifestPath, buildReceiptPath, canonicalArtifactPath, frontendIdlPath]) {
    if (!fs.existsSync(required)) {
      throw new Error(`${cluster} curator vault builds need the committed file ${required}`);
    }
  }

  const recorded = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const build = JSON.parse(fs.readFileSync(buildReceiptPath, "utf8"));
  const frontendIdlBytes = fs.readFileSync(frontendIdlPath);
  const frontendIdl = JSON.parse(frontendIdlBytes.toString("utf8"));
  const idlHash = createHash("sha256").update(frontendIdlBytes).digest("hex");
  const artifactBytes = fs.readFileSync(canonicalArtifactPath);
  const artifactHash = createHash("sha256").update(artifactBytes).digest("hex");

  if (recorded.cluster !== cluster || recorded.programId !== programId || recorded.mint !== mint) {
    throw new Error(`NEXT_PUBLIC_CURATOR_VAULT_* does not match ${manifestPath}`);
  }
  if (
    build.schemaVersion !== 2 ||
    build.dirty !== false ||
    build.programId !== programId ||
    !COMMIT.test(build.gitCommit ?? "") ||
    !SHA256.test(build.elfSha256 ?? "") ||
    !SHA256.test(build.idlSha256 ?? "")
  ) {
    throw new Error("curator vault build receipt is incomplete or was recorded from dirty source");
  }
  if (build.elfSha256 !== artifactHash || build.elfBytes !== artifactBytes.length) {
    throw new Error("curator vault build.elfSha256 or elfBytes does not match the canonical release artifact");
  }
  if (
    build.releaseBuilder?.solanaVerify !== "0.5.0" ||
    build.releaseBuilder?.solanaCli !== "4.0.3" ||
    build.releaseBuilder?.sbfArch !== "v3" ||
    build.releaseBuilder?.platformTools !== "v1.57" ||
    build.releaseBuilder?.baseImage !== RELEASE_IMAGE
  ) {
    throw new Error("curator vault release builder is incomplete or does not require SBF v3");
  }
  for (const field of ["gitCommit", "programId", "elfSha256", "idlSha256"]) {
    if (recorded.build?.[field] !== build[field]) {
      throw new Error(`curator vault deployment manifest build.${field} does not match deployments/build.json`);
    }
  }
  if (JSON.stringify(recorded.build) !== JSON.stringify(build)) {
    throw new Error("curator vault deployment manifest build receipt is not exact");
  }
  if (frontendIdl.address !== programId || idlHash !== build.idlSha256 || frontendIdlBytes.length !== build.idlBytes) {
    throw new Error("frontend curator vault IDL does not match the deployed program build receipt");
  }
  if (!SIGNATURE.test(recorded.signatures?.deployProgram ?? "")) {
    throw new Error("curator vault deployment manifest is missing the program deployment signature");
  }
  if (!SIGNATURE.test(recorded.signatures?.canonicalBuildActivation ?? "")) {
    throw new Error("curator vault deployment manifest is missing the canonical build activation signature");
  }
  if (
    !recorded.deploymentBuild ||
    recorded.deploymentBuild.programId !== programId ||
    !COMMIT.test(recorded.deploymentBuild.gitCommit ?? "") ||
    !SHA256.test(recorded.deploymentBuild.elfSha256 ?? "")
  ) {
    throw new Error("curator vault deployment manifest is missing the state-creating build receipt");
  }
  const activations = recorded.buildActivations;
  const latestActivation = Array.isArray(activations) ? activations.at(-1) : undefined;
  if (
    !latestActivation ||
    JSON.stringify(latestActivation.build) !== JSON.stringify(build) ||
    latestActivation.signature !== recorded.signatures.canonicalBuildActivation ||
    latestActivation.activatedAtSlot !== recorded.canonicalBuildActivatedAtSlot
  ) {
    throw new Error("curator vault deployment manifest does not preserve the current build activation history");
  }

  return {build, manifest: recorded, manifestPath};
}
