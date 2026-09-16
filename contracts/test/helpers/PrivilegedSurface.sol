// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

/// @title PrivilegedSurface
/// @notice AUDIT FINDING G11/G12.1 — the runtime enumerator that makes the CLAUDE.md §1.3
///         ACCESS-CONTROL invariant EXHAUSTIVE instead of a sample.
///
///         BEFORE: the only invariant-level access-control property in the repository
///         (`INV_CreditGateAndAuthorisation.invariant_INV18_noUnauthorisedStateChange`) was
///         backed by `CreditGateAuthorisationHandler._probe`, a HAND-WRITTEN table of 29
///         calldata blobs naming 25 distinct privileged functions. `src/` carries 134 role guards
///         (133 `onlyRole` modifiers plus one inline `_checkRole`), 117 of them externally
///         callable. So §1.3's "no privileged action is reachable by an unauthorized role IN ANY
///         STATE" was established for about a fifth of the privileged surface, and — worse — a NEW
///         privileged function could be added to any module tomorrow and the invariant would stay
///         green, because nothing connects the table to the code it claims to cover.
///
///         AFTER: this contract derives the surface at run time from two sources that cannot
///         drift from the deployed code, because they ARE the deployed code:
///           1. the SOURCE TEXT of every `src/*.sol` (which functions carry an `onlyRole(`
///              modifier, or an inline `_checkRole(` in the body — read after comments are
///              stripped, so NatSpec prose cannot fabricate an entry), and
///           2. the COMPILED ARTIFACT's `methodIdentifiers` (the canonical external signature of
///              every one of those functions, hence its real selector).
///         Add a privileged function and it is probed on the next run with no human step. Delete
///         one and the per-module count assertion in the consuming suite goes red so the removal
///         is deliberate. Add a whole new module with privileged functions and
///         `moduleAddress()` reverts `DRIFT` until the suite is taught where it is deployed.
///
/// @dev CALLDATA SYNTHESIS. A probe only has to reach the MODIFIER, and Solidity runs modifiers
///      after parameter decoding but before the body — so the argument VALUES are irrelevant and
///      an all-zero argument area is sufficient for every signature. `_wordCount` supplies
///      `commas + 1` head words (which over-counts nested tuples and dynamic types and never
///      under-counts) plus four words of padding; a zero offset word decodes to an empty
///      `bytes`/`string`/array rather than reverting, and Solidity ignores trailing calldata. Any
///      signature that still fails to decode surfaces as `RefusedOtherwise` in the reach ledger
///      and is visible in the report rather than being silently counted as a pass.
///
/// @dev DO NOT replace this with a static table. The static table is the defect.
abstract contract PrivilegedSurface is Test {
    struct Entry {
        address target;
        bytes4 selector;
        uint16 words;
        string module;
        string signature;
    }

    Entry[] internal surface;

    /// @dev source file base name (e.g. "sUSDfr") -> deployed address, registered by the suite.
    mapping(string => address) private _moduleAddr;
    mapping(string => bool) private _moduleKnown;
    /// @dev source file base name -> CONTRACT name, which is what Foundry names the artifact
    ///      (`out/sUSDfr.sol/SUSDfr.json`). Registered explicitly rather than inferred: deriving
    ///      it from the file name happens to work on a case-insensitive macOS filesystem and
    ///      silently breaks on Linux CI, which is exactly the class of "green locally" failure
    ///      this suite exists to prevent.
    mapping(string => string) private _artifactName;
    /// @dev module contract name -> number of distinct ROLE-GUARDED function names found in its
    ///      source, in either guard style. Exposed so a suite can pin the counts and make a
    ///      REMOVED guard loud — without that pin, deleting a guard would merely remove it from
    ///      the enumeration and every downstream assertion would still pass.
    mapping(string => uint256) internal guardedNameCount;
    /// @dev Source-derived count of functions protected by an inline caller/address guard,
    ///      including functions that inherit such a guard from a custom modifier. Kept separate
    ///      from `guardedNameCount`: these custom-error/trusted-caller gates do not necessarily
    ///      use OZ's AccessControl error and therefore cannot share the generic role probe.
    mapping(string => uint256) internal inlineCallerGuardedNameCount;
    uint256 internal totalInlineCallerGuardedNames;
    string[] internal scannedModules;

    // =====================================================================
    //  registration
    // =====================================================================

    function _registerModule(string memory sourceName, string memory contractName, address addr) internal {
        require(addr != address(0), "PrivilegedSurface: zero module address");
        _moduleAddr[sourceName] = addr;
        _artifactName[sourceName] = contractName;
        _moduleKnown[sourceName] = true;
    }

    function moduleAddress(string memory name) public view returns (address) {
        require(_moduleKnown[name], string.concat("PrivilegedSurface DRIFT: unregistered privileged module ", name));
        return _moduleAddr[name];
    }

    // =====================================================================
    //  enumeration
    // =====================================================================

    /// @notice Walks `src/`, and for every module that has at least one role-guarded function,
    ///         appends one `Entry` per guarded external selector.
    /// @dev Reverts if a module with guarded functions has not been registered — that revert is
    ///      the DRIFT GATE. It is the reason a new privileged module cannot quietly escape the
    ///      access-control invariant.
    function _buildPrivilegedSurface() internal {
        Vm.DirEntry[] memory entries = vm.readDir("src");
        for (uint256 i = 0; i < entries.length; ++i) {
            string memory path = entries[i].path;
            if (!_endsWith(path, ".sol")) continue; // skips src/interfaces, src/libraries, .DS_Store
            // Reclaim the scratch memory each module allocates (a ~40 KB source plus a
            // multi-hundred-KB compiler artifact). Solidity never frees memory, so without this
            // the enumeration accumulates ~17 MB and the QUADRATIC memory-expansion term costs
            // more than everything else combined. Everything `_scanModule` needs to keep is
            // written to STORAGE, so nothing allocated inside it outlives the call.
            uint256 freePtr;
            assembly {
                freePtr := mload(0x40)
            }
            _scanModule(path);
            assembly {
                mstore(0x40, freePtr)
            }
        }
    }

    function _scanModule(string memory path) private {
        string memory module = _contractNameOf(path);
        string memory code = _stripComments(vm.readFile(path));
        string[] memory inlineCallerGuarded = _inlineCallerGuardedFunctionNames(code);
        inlineCallerGuardedNameCount[module] = inlineCallerGuarded.length;
        totalInlineCallerGuardedNames += inlineCallerGuarded.length;
        string[] memory guarded = _guardedFunctionNames(code);
        if (guarded.length == 0) return;
        guardedNameCount[module] = guarded.length;
        scannedModules.push(module);

        address target = moduleAddress(module); // DRIFT GATE
        string memory artifact = vm.readFile(string.concat("out/", module, ".sol/", _artifactName[module], ".json"));
        string[] memory sigs = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        for (uint256 s = 0; s < sigs.length; ++s) {
            string memory sig = sigs[s];
            if (!_isOneOf(guarded, _functionNameOf(sig))) continue;
            surface.push(
                Entry({
                    target: target,
                    selector: bytes4(keccak256(bytes(sig))),
                    words: _wordCount(sig),
                    module: module,
                    signature: sig
                })
            );
        }
    }

    /// @notice All-zero calldata long enough for `entry`'s head area.
    /// @dev See the calldata-synthesis note on the contract: values never matter to a modifier.
    function _probeCalldata(Entry memory entry) internal pure returns (bytes memory data) {
        data = abi.encodePacked(entry.selector);
        for (uint256 i = 0; i < entry.words; ++i) {
            data = abi.encodePacked(data, bytes32(0));
        }
    }

    function surfaceSize() public view returns (uint256) {
        return surface.length;
    }

    function surfaceAt(uint256 i) public view returns (Entry memory) {
        return surface[i];
    }

    // =====================================================================
    //  source scanning
    // =====================================================================

    /// @dev Removes `//` and block comments, honouring string literals so a URL inside a string
    ///      cannot be mistaken for a comment. Comment stripping is what stops NatSpec prose such
    ///      as "callable only by the SERVICER_ROLE; see fund()" from injecting a phantom entry.
    function _stripComments(string memory src) internal pure returns (string memory) {
        bytes memory b = bytes(src);
        bytes memory out = new bytes(b.length);
        uint256 o;
        uint256 i;
        while (i < b.length) {
            bytes1 c = b[i];
            if (c == 0x22 || c == 0x27) {
                // string literal: copy verbatim to the matching quote
                bytes1 quote = c;
                out[o++] = c;
                ++i;
                while (i < b.length) {
                    out[o++] = b[i];
                    if (b[i] == 0x5c && i + 1 < b.length) {
                        // escape: copy the escaped char too
                        ++i;
                        if (i < b.length) out[o++] = b[i];
                        ++i;
                        continue;
                    }
                    if (b[i] == quote) {
                        ++i;
                        break;
                    }
                    ++i;
                }
                continue;
            }
            if (c == 0x2f && i + 1 < b.length && b[i + 1] == 0x2f) {
                while (i < b.length && b[i] != 0x0a) ++i;
                continue;
            }
            if (c == 0x2f && i + 1 < b.length && b[i + 1] == 0x2a) {
                i += 2;
                while (i + 1 < b.length && !(b[i] == 0x2a && b[i + 1] == 0x2f)) ++i;
                i += 2;
                out[o++] = 0x20; // keep tokens either side apart
                continue;
            }
            out[o++] = c;
            ++i;
        }
        // truncate in place rather than copying into a second array: these sources are ~40 KB
        // and Solidity's memory expansion cost is quadratic, so the copy dominated the scan.
        assembly ("memory-safe") {
            mstore(out, o)
        }
        return string(out);
    }

    /// @dev Every function this repository guards with a role check, in BOTH styles it uses:
    ///        * an `onlyRole(...)` MODIFIER in the function header, and
    ///        * an inline `_checkRole(...)` call in the function BODY.
    ///      The second style is not decoration: `USDfr.burn` is written that way, and a scan that
    ///      looked only for the modifier classified the token's burn authority as unprivileged and
    ///      quietly dropped it from an "exhaustive" surface — the same species of silent
    ///      incompleteness that finding G11/G12 is about, one level down.
    /// @dev IF A THIRD GUARD STYLE IS EVER INTRODUCED IT MUST BE ADDED HERE. The per-module count
    ///      assertions in the consuming suite are what force that conversation to happen rather
    ///      than letting the surface quietly shrink.
    function _guardedFunctionNames(string memory code) internal pure returns (string[] memory names) {
        bytes memory b = bytes(code);
        string[] memory buf = new string[](256);
        uint256 n;
        n = _collectGuarded(b, "onlyRole(", false, buf, n);
        n = _collectGuarded(b, "_checkRole(", true, buf, n);
        names = new string[](n);
        for (uint256 k = 0; k < n; ++k) {
            names[k] = buf[k];
        }
    }

    /// @dev Functions guarded by the repository's inline caller/address-check style. This is a
    ///      DRIFT census, not a generic calldata probe: trusted-caller gates use module-specific
    ///      custom errors and valid callers, so treating them as OZ `onlyRole` would be false
    ///      coverage. It recognizes direct `if (msg.sender/_msgSender() ==/!= x)` bodies and
    ///      follows any custom modifier containing the same comparison to every function that
    ///      uses it. That second limb is what brings CommitmentLedger's four `onlyManager`
    ///      functions into the runtime census rather than counting its modifier definition once.
    function _inlineCallerGuardedFunctionNames(string memory code) internal pure returns (string[] memory names) {
        bytes memory b = bytes(code);
        string[] memory buf = new string[](256);
        string[] memory modifiers = new string[](64);
        uint256 n;
        uint256 modifierCount;

        string[4] memory needles =
            ["if (msg.sender !=", "if (msg.sender ==", "if (_msgSender() !=", "if (_msgSender() =="];
        for (uint256 p = 0; p < needles.length; ++p) {
            bytes memory nd = bytes(needles[p]);
            uint256 at;
            while (true) {
                int256 found = _indexOf(b, nd, at);
                if (found < 0) break;
                at = uint256(found) + nd.length;

                string memory functionName = _enclosingFunctionName(b, uint256(found), true);
                if (bytes(functionName).length != 0 && !_isOneOf2(buf, n, functionName)) {
                    require(n < buf.length, "PrivilegedSurface: inline-guard buffer overflow");
                    buf[n++] = functionName;
                }

                string memory modifierName = _enclosingModifierName(b, uint256(found));
                if (bytes(modifierName).length != 0 && !_isOneOf2(modifiers, modifierCount, modifierName)) {
                    require(modifierCount < modifiers.length, "PrivilegedSurface: inline-modifier buffer overflow");
                    modifiers[modifierCount++] = modifierName;
                }
            }
        }

        // Resolve each guarded modifier to the functions whose headers use it. Occurrences in
        // the modifier declaration/body cannot be attributed to a function header and are
        // discarded by `_collectGuarded`.
        for (uint256 i = 0; i < modifierCount; ++i) {
            n = _collectGuarded(b, modifiers[i], false, buf, n);
        }

        names = new string[](n);
        for (uint256 i = 0; i < n; ++i) {
            names[i] = buf[i];
        }
    }

    function _collectGuarded(bytes memory b, string memory needle, bool fromBody, string[] memory buf, uint256 n)
        private
        pure
        returns (uint256)
    {
        bytes memory nd = bytes(needle);
        uint256 i;
        while (true) {
            int256 p = _indexOf(b, nd, i);
            if (p < 0) break;
            i = uint256(p) + nd.length;
            string memory name = _enclosingFunctionName(b, uint256(p), fromBody);
            if (bytes(name).length == 0) continue;
            if (!_isOneOf2(buf, n, name)) {
                require(n < buf.length, "PrivilegedSurface: guarded-name buffer overflow");
                buf[n++] = name;
            }
        }
        return n;
    }

    /// @dev Walks BACKWARD from a guard site to the `function` keyword that owns it, and returns
    ///      that function's name (empty string if the site is not inside a function header/body
    ///      that this scan should attribute).
    ///      `fromBody = true` first walks out of the enclosing body, tracking brace depth so that
    ///      an `if {...}` earlier in the same function does not end the walk prematurely. Once in
    ///      the header region, a `{`, `}` or `;` means we have run into the PREVIOUS declaration,
    ///      so the site belongs to no function header and is discarded. That separator rule is
    ///      what stops a guard being attributed to the wrong function.
    function _enclosingFunctionName(bytes memory b, uint256 pos, bool fromBody) private pure returns (string memory) {
        uint256 k = pos;
        uint256 depth;
        bool exited = !fromBody;
        uint256 fstart;
        bool matched;
        while (k > 0) {
            --k;
            bytes1 c = b[k];
            if (!exited) {
                if (c == 0x7d) {
                    ++depth;
                } else if (c == 0x7b) {
                    if (depth == 0) exited = true;
                    else --depth;
                }
                continue;
            }
            if (c == 0x7b || c == 0x7d || c == 0x3b) break;
            if (c == 0x6e && k >= 7 && _matchAt(b, k - 7, "function") && (k == 7 || !_isIdentChar(b[k - 8]))) {
                fstart = k - 7;
                matched = true;
                break;
            }
        }
        if (!matched) return "";
        return _identifierAfterFunctionKeyword(b, fstart);
    }

    /// @dev The custom modifier containing an inline caller comparison, if any.
    function _enclosingModifierName(bytes memory b, uint256 pos) private pure returns (string memory) {
        uint256 k = pos;
        uint256 depth;
        bool exited;
        uint256 start;
        bool matched;
        while (k > 0) {
            --k;
            bytes1 c = b[k];
            if (!exited) {
                if (c == 0x7d) {
                    ++depth;
                } else if (c == 0x7b) {
                    if (depth == 0) exited = true;
                    else --depth;
                }
                continue;
            }
            if (c == 0x7b || c == 0x7d || c == 0x3b) break;
            if (c == 0x72 && k >= 7 && _matchAt(b, k - 7, "modifier") && (k == 7 || !_isIdentChar(b[k - 8]))) {
                start = k - 7;
                matched = true;
                break;
            }
        }
        if (!matched) return "";
        return _identifierAfterKeyword(b, start, 8);
    }

    function _identifierAfterFunctionKeyword(bytes memory b, uint256 fstart) private pure returns (string memory) {
        return _identifierAfterKeyword(b, fstart, 8);
    }

    function _identifierAfterKeyword(bytes memory b, uint256 start, uint256 keywordLength)
        private
        pure
        returns (string memory)
    {
        uint256 q = start + keywordLength;
        if (q >= b.length || !_isSpace(b[q])) return "";
        while (q < b.length && _isSpace(b[q])) ++q;
        uint256 s = q;
        while (q < b.length && _isIdentChar(b[q])) ++q;
        if (q == s) return "";
        return string(_slice(b, s, q));
    }

    function _matchAt(bytes memory b, uint256 at, string memory word) private pure returns (bool) {
        bytes memory w = bytes(word);
        if (at + w.length > b.length) return false;
        for (uint256 j = 0; j < w.length; ++j) {
            if (b[at + j] != w[j]) return false;
        }
        return true;
    }

    // =====================================================================
    //  signature helpers
    // =====================================================================

    function _functionNameOf(string memory sig) internal pure returns (string memory) {
        bytes memory b = bytes(sig);
        uint256 i;
        while (i < b.length && b[i] != 0x28) ++i;
        return string(_slice(b, 0, i));
    }

    /// @dev `commas + 1` head words (0 for a nil argument list). Over-counts nested tuples and
    ///      dynamic types, never under-counts; four padding words absorb the rest.
    function _wordCount(string memory sig) internal pure returns (uint16) {
        bytes memory b = bytes(sig);
        uint256 open;
        while (open < b.length && b[open] != 0x28) ++open;
        if (open + 1 >= b.length) return 0;
        uint256 close = b.length;
        while (close > open && b[close - 1] != 0x29) --close;
        if (close <= open + 1) return 0; // `f()`
        uint256 commas;
        for (uint256 i = open + 1; i + 1 < close; ++i) {
            if (b[i] == 0x2c) ++commas;
        }
        return uint16(commas + 1 + 4);
    }

    // =====================================================================
    //  string primitives
    // =====================================================================

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory t = bytes(suffix);
        if (a.length < t.length) return false;
        for (uint256 i = 0; i < t.length; ++i) {
            if (a[a.length - t.length + i] != t[i]) return false;
        }
        return true;
    }

    function _contractNameOf(string memory path) internal pure returns (string memory) {
        bytes memory b = bytes(path);
        uint256 start;
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == 0x2f) start = i + 1;
        }
        return string(_slice(b, start, b.length - 4)); // drop ".sol"
    }

    function _isOneOf(string[] memory set, string memory needle) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(needle));
        for (uint256 i = 0; i < set.length; ++i) {
            if (keccak256(bytes(set[i])) == h) return true;
        }
        return false;
    }

    function _isOneOf2(string[] memory set, uint256 len, string memory needle) private pure returns (bool) {
        bytes32 h = keccak256(bytes(needle));
        for (uint256 i = 0; i < len; ++i) {
            if (keccak256(bytes(set[i])) == h) return true;
        }
        return false;
    }

    /// @dev Word-at-a-time substring search. The byte-at-a-time version cost ~500M gas across the
    ///      17 sources, which is charged once per `setUp()` and therefore once per invariant
    ///      function in the consuming suite; this keeps the exhaustive enumeration affordable
    ///      enough that nobody is tempted to replace it with the static table it exists to retire.
    /// @dev The `mload` may read up to 31 bytes past the end of `hay`'s data, which is why the
    ///      block is NOT marked memory-safe. Those bytes are always masked out before comparison,
    ///      so the result is exact; needles are asserted shorter than a word for the same reason
    ///      (a 32-byte needle would make the mask zero and match everything).
    function _indexOf(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (int256) {
        uint256 nl = needle.length;
        uint256 hl = hay.length;
        require(nl < 32, "PrivilegedSurface: needle too long");
        if (nl == 0 || hl < nl) return -1;
        bytes32 pat;
        bytes32 mask;
        assembly {
            pat := mload(add(needle, 0x20))
            mask := not(sub(shl(mul(sub(32, nl), 8), 1), 1))
        }
        pat = pat & mask;
        uint256 last = hl - nl;
        for (uint256 i = from; i <= last; ++i) {
            bytes32 chunk;
            assembly {
                chunk := mload(add(add(hay, 0x20), i))
            }
            if ((chunk & mask) == pat) return int256(i);
        }
        return -1;
    }

    function _slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = b[i];
        }
    }

    function _isSpace(bytes1 c) private pure returns (bool) {
        return c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
    }

    function _isIdentChar(bytes1 c) private pure returns (bool) {
        return
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x24;
    }
}
