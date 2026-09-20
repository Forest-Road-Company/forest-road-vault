/**
 * Program IDL in camelCase format in order to be used in JS/TS.
 *
 * Note that this is only a type helper and is not the actual IDL. The original
 * IDL can be found at `target/idl/forestroad_curator_vault.json`.
 */
export type ForestroadCuratorVault = {
  "address": "3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh",
  "metadata": {
    "name": "forestroadCuratorVault",
    "version": "0.1.0",
    "spec": "0.1.0",
    "description": "Created with Anchor"
  },
  "instructions": [
    {
      "name": "acceptAdmin",
      "discriminator": [
        112,
        42,
        45,
        90,
        116,
        181,
        13,
        170
      ],
      "accounts": [
        {
          "name": "pendingAdmin",
          "signer": true
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "allowlist",
      "discriminator": [
        0,
        51,
        50,
        227,
        108,
        194,
        231,
        209
      ],
      "accounts": [
        {
          "name": "allowlistAuthority",
          "writable": true,
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "owner",
          "docs": [
            "later close. Only its key is used, as a PDA seed and as the position owner."
          ]
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "agreementHash",
          "type": {
            "array": [
              "u8",
              32
            ]
          }
        }
      ]
    },
    {
      "name": "cancelWithdrawal",
      "discriminator": [
        183,
        104,
        181,
        250,
        28,
        128,
        210,
        70
      ],
      "accounts": [
        {
          "name": "owner",
          "signer": true,
          "relations": [
            "position"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "closePosition",
      "discriminator": [
        123,
        134,
        81,
        0,
        49,
        68,
        98,
        98
      ],
      "accounts": [
        {
          "name": "owner",
          "writable": true,
          "signer": true,
          "relations": [
            "position"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "deposit",
      "discriminator": [
        242,
        35,
        198,
        137,
        82,
        225,
        242,
        182
      ],
      "accounts": [
        {
          "name": "owner",
          "signer": true,
          "relations": [
            "position"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "ownerAta",
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "drawToTreasury",
      "discriminator": [
        135,
        85,
        40,
        75,
        247,
        254,
        207,
        13
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "docs": [
            "The pinned destination. Not caller-chosen: rotating it is an admin act with its own event."
          ],
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "emergencyHalt",
      "discriminator": [
        182,
        75,
        142,
        253,
        96,
        137,
        255,
        67
      ],
      "accounts": [
        {
          "name": "emergencyAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "emergencyPause",
      "discriminator": [
        21,
        143,
        27,
        142,
        200,
        181,
        210,
        255
      ],
      "accounts": [
        {
          "name": "emergencyAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "fundCoupons",
      "discriminator": [
        201,
        41,
        168,
        153,
        44,
        86,
        182,
        249
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "source",
          "docs": [
            "Any token account of the right mint that the treasury authority controls."
          ],
          "writable": true
        },
        {
          "name": "destination",
          "docs": [
            "The vault (for a principal return) or the coupon pool (for funding), checked per handler."
          ],
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "initialize",
      "discriminator": [
        175,
        175,
        109,
        31,
        13,
        152,
        155,
        237
      ],
      "accounts": [
        {
          "name": "admin",
          "docs": [
            "The admin funds the accounts and holds the admin authority afterwards. It must be the",
            "program's upgrade authority: the singleton config would otherwise belong to whoever",
            "landed `initialize` first in the window between deployment and the ceremony. On mainnet",
            "the upgrade authority is the Squads multisig, which signs through its vault."
          ],
          "writable": true,
          "signer": true
        },
        {
          "name": "program",
          "address": "3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh"
        },
        {
          "name": "programData"
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "usdcMint"
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "couponAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  117,
                  112,
                  111,
                  110
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "docs": [
            "The draw destination: a token account of the right mint owned by the treasury authority,",
            "so a draw can only ever land with the party that signs draws. The admin rotates it later",
            "under the same rule."
          ]
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        },
        {
          "name": "systemProgram",
          "address": "11111111111111111111111111111111"
        }
      ],
      "args": [
        {
          "name": "params",
          "type": {
            "defined": {
              "name": "initializeParams"
            }
          }
        }
      ]
    },
    {
      "name": "payCoupon",
      "discriminator": [
        235,
        226,
        45,
        115,
        95,
        34,
        46,
        110
      ],
      "accounts": [
        {
          "name": "cranker",
          "docs": [
            "Anyone. The keeper in practice; the curator or a bystander can crank their own row."
          ],
          "signer": true
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        },
        {
          "name": "couponAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  117,
                  112,
                  111,
                  110
                ]
              }
            ]
          }
        },
        {
          "name": "ownerAta",
          "docs": [
            "The owner's own token account for the mint; the payout goes nowhere else."
          ],
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": []
    },
    {
      "name": "proposeAdmin",
      "discriminator": [
        121,
        214,
        199,
        212,
        87,
        39,
        117,
        234
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "newAdmin",
          "type": "pubkey"
        }
      ]
    },
    {
      "name": "recordLoss",
      "discriminator": [
        112,
        182,
        48,
        145,
        171,
        216,
        247,
        43
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        },
        {
          "name": "evidenceHash",
          "type": {
            "array": [
              "u8",
              32
            ]
          }
        }
      ]
    },
    {
      "name": "requestWithdrawal",
      "discriminator": [
        251,
        85,
        121,
        205,
        56,
        201,
        12,
        177
      ],
      "accounts": [
        {
          "name": "owner",
          "signer": true,
          "relations": [
            "position"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "returnPrincipal",
      "discriminator": [
        27,
        177,
        124,
        34,
        3,
        16,
        96,
        76
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        },
        {
          "name": "source",
          "writable": true
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "revokeAllowlist",
      "discriminator": [
        61,
        22,
        179,
        242,
        68,
        105,
        221,
        18
      ],
      "accounts": [
        {
          "name": "allowlistAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        }
      ],
      "args": []
    },
    {
      "name": "setAuthorities",
      "discriminator": [
        124,
        254,
        44,
        240,
        197,
        70,
        190,
        107
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "docs": [
            "Must be owned by the treasury authority being set and must not be one of the vault's own",
            "accounts, so principal can never be drawn into the coupon pool or back into the vault."
          ]
        }
      ],
      "args": [
        {
          "name": "allowlistAuthority",
          "type": "pubkey"
        },
        {
          "name": "treasuryAuthority",
          "type": "pubkey"
        },
        {
          "name": "emergencyAuthority",
          "type": "pubkey"
        }
      ]
    },
    {
      "name": "setPaused",
      "discriminator": [
        91,
        60,
        125,
        192,
        176,
        225,
        166,
        218
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "paused",
          "type": "bool"
        }
      ]
    },
    {
      "name": "setPayoutHalt",
      "discriminator": [
        171,
        26,
        40,
        193,
        153,
        104,
        95,
        137
      ],
      "accounts": [
        {
          "name": "allowlistAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "position.owner",
                "account": "position"
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "halted",
          "type": "bool"
        }
      ]
    },
    {
      "name": "setRate",
      "discriminator": [
        99,
        58,
        170,
        238,
        160,
        120,
        74,
        11
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "bps",
          "type": "u16"
        },
        {
          "name": "startTs",
          "type": "i64"
        }
      ]
    },
    {
      "name": "setTerms",
      "discriminator": [
        198,
        18,
        197,
        226,
        220,
        230,
        87,
        173
      ],
      "accounts": [
        {
          "name": "admin",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        }
      ],
      "args": [
        {
          "name": "lockSeconds",
          "type": "u64"
        },
        {
          "name": "noticeSeconds",
          "type": "u64"
        }
      ]
    },
    {
      "name": "sweepCoupons",
      "discriminator": [
        78,
        40,
        60,
        250,
        164,
        56,
        38,
        32
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "couponAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  117,
                  112,
                  111,
                  110
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "docs": [
            "The pinned destination, as for draws."
          ],
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "sweepPrincipalSurplus",
      "discriminator": [
        237,
        121,
        232,
        210,
        162,
        187,
        74,
        100
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "withdraw",
      "discriminator": [
        183,
        18,
        70,
        156,
        148,
        109,
        161,
        34
      ],
      "accounts": [
        {
          "name": "owner",
          "signer": true,
          "relations": [
            "position"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "position",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  112,
                  111,
                  115,
                  105,
                  116,
                  105,
                  111,
                  110
                ]
              },
              {
                "kind": "account",
                "path": "owner"
              }
            ]
          }
        },
        {
          "name": "vaultAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  118,
                  97,
                  117,
                  108,
                  116
                ]
              }
            ]
          }
        },
        {
          "name": "ownerAta",
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    },
    {
      "name": "withdrawUnusedCouponFunding",
      "discriminator": [
        103,
        11,
        85,
        190,
        153,
        159,
        208,
        109
      ],
      "accounts": [
        {
          "name": "treasuryAuthority",
          "signer": true,
          "relations": [
            "config"
          ]
        },
        {
          "name": "config",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  110,
                  102,
                  105,
                  103
                ]
              }
            ]
          }
        },
        {
          "name": "couponAta",
          "writable": true,
          "pda": {
            "seeds": [
              {
                "kind": "const",
                "value": [
                  99,
                  111,
                  117,
                  112,
                  111,
                  110
                ]
              }
            ]
          }
        },
        {
          "name": "treasuryAta",
          "docs": [
            "The pinned destination, as for draws."
          ],
          "writable": true
        },
        {
          "name": "tokenProgram",
          "address": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        }
      ],
      "args": [
        {
          "name": "amount",
          "type": "u64"
        }
      ]
    }
  ],
  "accounts": [
    {
      "name": "config",
      "discriminator": [
        155,
        12,
        170,
        224,
        30,
        250,
        204,
        130
      ]
    },
    {
      "name": "position",
      "discriminator": [
        170,
        188,
        143,
        228,
        122,
        64,
        247,
        208
      ]
    }
  ],
  "events": [
    {
      "name": "adminTransferAccepted",
      "discriminator": [
        79,
        229,
        204,
        202,
        134,
        43,
        177,
        26
      ]
    },
    {
      "name": "adminTransferProposed",
      "discriminator": [
        203,
        168,
        175,
        51,
        239,
        104,
        20,
        85
      ]
    },
    {
      "name": "allowlistRevoked",
      "discriminator": [
        40,
        24,
        198,
        94,
        74,
        18,
        235,
        95
      ]
    },
    {
      "name": "allowlisted",
      "discriminator": [
        141,
        198,
        9,
        101,
        232,
        45,
        76,
        217
      ]
    },
    {
      "name": "authoritiesChanged",
      "discriminator": [
        231,
        198,
        56,
        181,
        18,
        67,
        45,
        176
      ]
    },
    {
      "name": "couponFundingWithdrawn",
      "discriminator": [
        60,
        168,
        189,
        98,
        148,
        246,
        191,
        212
      ]
    },
    {
      "name": "couponPaid",
      "discriminator": [
        11,
        228,
        86,
        67,
        111,
        22,
        107,
        226
      ]
    },
    {
      "name": "couponsFunded",
      "discriminator": [
        9,
        97,
        65,
        128,
        238,
        36,
        83,
        44
      ]
    },
    {
      "name": "couponsSwept",
      "discriminator": [
        229,
        98,
        89,
        168,
        9,
        240,
        118,
        201
      ]
    },
    {
      "name": "deposited",
      "discriminator": [
        111,
        141,
        26,
        45,
        161,
        35,
        100,
        57
      ]
    },
    {
      "name": "initialized",
      "discriminator": [
        208,
        213,
        115,
        98,
        115,
        82,
        201,
        209
      ]
    },
    {
      "name": "lossRecorded",
      "discriminator": [
        206,
        157,
        36,
        201,
        68,
        101,
        194,
        248
      ]
    },
    {
      "name": "pauseChanged",
      "discriminator": [
        238,
        188,
        213,
        78,
        134,
        209,
        178,
        218
      ]
    },
    {
      "name": "payoutHaltChanged",
      "discriminator": [
        254,
        83,
        76,
        186,
        74,
        55,
        71,
        69
      ]
    },
    {
      "name": "positionClosed",
      "discriminator": [
        157,
        163,
        227,
        228,
        13,
        97,
        138,
        121
      ]
    },
    {
      "name": "principalReturned",
      "discriminator": [
        107,
        100,
        128,
        186,
        79,
        136,
        167,
        182
      ]
    },
    {
      "name": "principalSurplusSwept",
      "discriminator": [
        212,
        123,
        98,
        232,
        130,
        133,
        31,
        82
      ]
    },
    {
      "name": "rateEpochAdded",
      "discriminator": [
        207,
        130,
        161,
        34,
        225,
        1,
        194,
        225
      ]
    },
    {
      "name": "termsChanged",
      "discriminator": [
        95,
        25,
        171,
        199,
        209,
        114,
        42,
        97
      ]
    },
    {
      "name": "treasuryDraw",
      "discriminator": [
        210,
        5,
        79,
        162,
        95,
        8,
        8,
        56
      ]
    },
    {
      "name": "withdrawalCancelled",
      "discriminator": [
        119,
        175,
        207,
        80,
        186,
        237,
        229,
        9
      ]
    },
    {
      "name": "withdrawalRequested",
      "discriminator": [
        75,
        207,
        21,
        12,
        160,
        102,
        150,
        55
      ]
    },
    {
      "name": "withdrawn",
      "discriminator": [
        20,
        89,
        223,
        198,
        194,
        124,
        219,
        13
      ]
    }
  ],
  "errors": [
    {
      "code": 6000,
      "name": "notAllowlisted",
      "msg": "Wallet is not allowlisted for this vault"
    },
    {
      "code": 6001,
      "name": "paused",
      "msg": "Deposits and treasury draws are paused"
    },
    {
      "code": 6002,
      "name": "zeroAmount",
      "msg": "Amount must be greater than zero"
    },
    {
      "code": 6003,
      "name": "noticePending",
      "msg": "A withdrawal notice is pending; cancel it before changing exposure"
    },
    {
      "code": 6004,
      "name": "noNotice",
      "msg": "No withdrawal notice is pending"
    },
    {
      "code": 6005,
      "name": "locked",
      "msg": "Withdrawal is not yet eligible; wait for the lock and notice to elapse"
    },
    {
      "code": 6006,
      "name": "insufficientVaultLiquidity",
      "msg": "Vault liquidity is below the requested amount; principal must be returned first"
    },
    {
      "code": 6007,
      "name": "drawExceedsPrincipal",
      "msg": "Draw would exceed outstanding principal"
    },
    {
      "code": 6008,
      "name": "returnExceedsDrawn",
      "msg": "Return would exceed the amount drawn"
    },
    {
      "code": 6009,
      "name": "nothingDue",
      "msg": "Nothing is due for this position at this boundary"
    },
    {
      "code": 6010,
      "name": "insufficientCouponPool",
      "msg": "Coupon pool is below the amount due"
    },
    {
      "code": 6011,
      "name": "rateEpochsFull",
      "msg": "Rate epoch history is full"
    },
    {
      "code": 6012,
      "name": "rateNotForward",
      "msg": "A rate epoch must start after the previous one and not in the past"
    },
    {
      "code": 6013,
      "name": "badRate",
      "msg": "Rate must be between 1 and 10,000 basis points"
    },
    {
      "code": 6014,
      "name": "badTerms",
      "msg": "Terms must be between one day and two years"
    },
    {
      "code": 6015,
      "name": "wrongMint",
      "msg": "Token account has the wrong mint"
    },
    {
      "code": 6016,
      "name": "wrongTokenAccount",
      "msg": "Token account is not owned by the expected authority"
    },
    {
      "code": 6017,
      "name": "principalNotAtRisk",
      "msg": "Principal is not at risk under this vault's agreements"
    },
    {
      "code": 6018,
      "name": "lossExceedsPrincipal",
      "msg": "Loss exceeds the position's principal"
    },
    {
      "code": 6019,
      "name": "lossExceedsDrawn",
      "msg": "Loss exceeds the drawn amount; undrawn capital cannot be lost"
    },
    {
      "code": 6020,
      "name": "zeroHash",
      "msg": "Hash must be non-zero"
    },
    {
      "code": 6021,
      "name": "positionNotEmpty",
      "msg": "Position still holds principal, owed coupon or a notice"
    },
    {
      "code": 6022,
      "name": "overflow",
      "msg": "Arithmetic overflow"
    },
    {
      "code": 6023,
      "name": "alreadyAllowlisted",
      "msg": "Position already allowlisted"
    },
    {
      "code": 6024,
      "name": "amountExceedsPrincipal",
      "msg": "Amount exceeds the position's principal"
    },
    {
      "code": 6025,
      "name": "unauthorized",
      "msg": "Only the program's upgrade authority may initialise the vault"
    },
    {
      "code": 6026,
      "name": "rateTooFar",
      "msg": "A rate epoch may not start more than two years ahead"
    },
    {
      "code": 6027,
      "name": "zeroAuthority",
      "msg": "An authority cannot be the zero address"
    },
    {
      "code": 6028,
      "name": "payoutHalted",
      "msg": "Coupon payouts to this position are halted pending review"
    },
    {
      "code": 6029,
      "name": "sweepExceedsPool",
      "msg": "Sweep exceeds the recoverable token surplus"
    },
    {
      "code": 6030,
      "name": "wrongAssociatedTokenAccount",
      "msg": "Token account is not the owner's associated token account"
    },
    {
      "code": 6031,
      "name": "couponLiabilityReserved",
      "msg": "Coupon funds are reserved for accrued obligations"
    },
    {
      "code": 6032,
      "name": "accountingMismatch",
      "msg": "Token balances are below the program's accounted balance"
    },
    {
      "code": 6033,
      "name": "agreementChangeWithBalance",
      "msg": "An agreement hash cannot change while the position has live obligations"
    },
    {
      "code": 6034,
      "name": "positionCapitalDrawn",
      "msg": "The requested principal is deployed for this position and must be returned first"
    },
    {
      "code": 6035,
      "name": "unsupportedVersion",
      "msg": "Account layout version is not supported by this program"
    },
    {
      "code": 6036,
      "name": "notPendingAdmin",
      "msg": "Only the pending admin may accept the admin role"
    },
    {
      "code": 6037,
      "name": "vaultNotEmpty",
      "msg": "Unused coupon funding can be withdrawn only after every position is closed"
    }
  ],
  "types": [
    {
      "name": "adminTransferAccepted",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "previousAdmin",
            "type": "pubkey"
          },
          {
            "name": "admin",
            "type": "pubkey"
          }
        ]
      }
    },
    {
      "name": "adminTransferProposed",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "admin",
            "type": "pubkey"
          },
          {
            "name": "pendingAdmin",
            "type": "pubkey"
          }
        ]
      }
    },
    {
      "name": "allowlistRevoked",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "allowlisted",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "agreementHash",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "authoritiesChanged",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "allowlistAuthority",
            "type": "pubkey"
          },
          {
            "name": "treasuryAuthority",
            "type": "pubkey"
          },
          {
            "name": "emergencyAuthority",
            "type": "pubkey"
          },
          {
            "name": "treasuryAta",
            "type": "pubkey"
          }
        ]
      }
    },
    {
      "name": "config",
      "docs": [
        "Vault configuration and running totals. One per program deployment."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "version",
            "type": "u8"
          },
          {
            "name": "admin",
            "type": "pubkey"
          },
          {
            "name": "pendingAdmin",
            "type": "pubkey"
          },
          {
            "name": "allowlistAuthority",
            "type": "pubkey"
          },
          {
            "name": "treasuryAuthority",
            "type": "pubkey"
          },
          {
            "name": "emergencyAuthority",
            "docs": [
              "A hot key with one-way powers only: it may pause or halt, never clear either flag."
            ],
            "type": "pubkey"
          },
          {
            "name": "usdcMint",
            "type": "pubkey"
          },
          {
            "name": "vaultAta",
            "docs": [
              "Principal, a program-owned token account at seeds [\"vault\"]."
            ],
            "type": "pubkey"
          },
          {
            "name": "couponAta",
            "docs": [
              "Coupon pool, a program-owned token account at seeds [\"coupon\"]."
            ],
            "type": "pubkey"
          },
          {
            "name": "treasuryAta",
            "docs": [
              "Destination of treasury draws; a Forest Road token account, rotated by the admin only."
            ],
            "type": "pubkey"
          },
          {
            "name": "lockSeconds",
            "type": "u64"
          },
          {
            "name": "noticeSeconds",
            "type": "u64"
          },
          {
            "name": "dayCount",
            "type": "u8"
          },
          {
            "name": "principalAtRisk",
            "type": "bool"
          },
          {
            "name": "paused",
            "type": "bool"
          },
          {
            "name": "rateEpochs",
            "type": {
              "array": [
                {
                  "defined": {
                    "name": "rateEpoch"
                  }
                },
                16
              ]
            }
          },
          {
            "name": "rateEpochCount",
            "type": "u8"
          },
          {
            "name": "totalPrincipal",
            "type": "u64"
          },
          {
            "name": "drawn",
            "type": "u64"
          },
          {
            "name": "couponFunded",
            "type": "u64"
          },
          {
            "name": "couponPaid",
            "type": "u64"
          },
          {
            "name": "couponOwedTotal",
            "docs": [
              "Sum of every position's accrued but unpaid whole coupon units."
            ],
            "type": "u64"
          },
          {
            "name": "positions",
            "type": "u32"
          },
          {
            "name": "bump",
            "type": "u8"
          },
          {
            "name": "reserved",
            "type": {
              "array": [
                "u8",
                128
              ]
            }
          }
        ]
      }
    },
    {
      "name": "couponFundingWithdrawn",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "couponFunded",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "couponPaid",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "periodEnd",
            "type": "i64"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "couponPaid",
            "type": "u64"
          },
          {
            "name": "couponOwedAfter",
            "type": "u64"
          },
          {
            "name": "couponPayableAfter",
            "type": "u64"
          },
          {
            "name": "couponAccruedThrough",
            "type": "i64"
          },
          {
            "name": "surplusRecognized",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "couponsFunded",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "couponFunded",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "couponsSwept",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "couponFunded",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "deposited",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "principalAfter",
            "type": "u64"
          },
          {
            "name": "lockEnd",
            "type": "i64"
          },
          {
            "name": "totalPrincipal",
            "type": "u64"
          },
          {
            "name": "positionDrawn",
            "type": "u64"
          },
          {
            "name": "couponOwed",
            "type": "u64"
          },
          {
            "name": "couponPayable",
            "type": "u64"
          },
          {
            "name": "couponAccruedThrough",
            "type": "i64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "initializeParams",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "allowlistAuthority",
            "type": "pubkey"
          },
          {
            "name": "treasuryAuthority",
            "type": "pubkey"
          },
          {
            "name": "emergencyAuthority",
            "type": "pubkey"
          },
          {
            "name": "lockSeconds",
            "type": "u64"
          },
          {
            "name": "noticeSeconds",
            "type": "u64"
          },
          {
            "name": "principalAtRisk",
            "type": "bool"
          },
          {
            "name": "initialBps",
            "type": "u16"
          }
        ]
      }
    },
    {
      "name": "initialized",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "version",
            "type": "u8"
          },
          {
            "name": "admin",
            "type": "pubkey"
          },
          {
            "name": "allowlistAuthority",
            "type": "pubkey"
          },
          {
            "name": "treasuryAuthority",
            "type": "pubkey"
          },
          {
            "name": "emergencyAuthority",
            "type": "pubkey"
          },
          {
            "name": "usdcMint",
            "type": "pubkey"
          },
          {
            "name": "vaultAta",
            "type": "pubkey"
          },
          {
            "name": "couponAta",
            "type": "pubkey"
          },
          {
            "name": "treasuryAta",
            "type": "pubkey"
          },
          {
            "name": "lockSeconds",
            "type": "u64"
          },
          {
            "name": "noticeSeconds",
            "type": "u64"
          },
          {
            "name": "principalAtRisk",
            "type": "bool"
          },
          {
            "name": "initialBps",
            "type": "u16"
          }
        ]
      }
    },
    {
      "name": "lossRecorded",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "principalAfter",
            "type": "u64"
          },
          {
            "name": "positionDrawnAfter",
            "type": "u64"
          },
          {
            "name": "couponOwed",
            "type": "u64"
          },
          {
            "name": "couponPayable",
            "type": "u64"
          },
          {
            "name": "couponAccruedThrough",
            "type": "i64"
          },
          {
            "name": "evidenceHash",
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "pauseChanged",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "paused",
            "type": "bool"
          },
          {
            "name": "actor",
            "type": "pubkey"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "payoutHaltChanged",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "halted",
            "type": "bool"
          },
          {
            "name": "actor",
            "type": "pubkey"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "position",
      "docs": [
        "One curator's subscription. Non-transferable by construction: there is no instruction that",
        "changes `owner`, and no token represents it."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "version",
            "type": "u8"
          },
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "agreementHash",
            "docs": [
              "Hash of the executed agreement, set when the wallet is allowlisted."
            ],
            "type": {
              "array": [
                "u8",
                32
              ]
            }
          },
          {
            "name": "allowlisted",
            "type": "bool"
          },
          {
            "name": "lockSeconds",
            "docs": [
              "Terms snapshotted when a zero-principal position receives new principal."
            ],
            "type": "u64"
          },
          {
            "name": "noticeSeconds",
            "type": "u64"
          },
          {
            "name": "principal",
            "docs": [
              "Live principal in USDC base units."
            ],
            "type": "u64"
          },
          {
            "name": "drawn",
            "docs": [
              "Principal from this position currently deployed to the treasury."
            ],
            "type": "u64"
          },
          {
            "name": "depositedAt",
            "type": "i64"
          },
          {
            "name": "lockEnd",
            "type": "i64"
          },
          {
            "name": "noticeRequestedAt",
            "type": "i64"
          },
          {
            "name": "withdrawalEligibleAt",
            "type": "i64"
          },
          {
            "name": "couponAccruedThrough",
            "type": "i64"
          },
          {
            "name": "couponPaidThrough",
            "type": "i64"
          },
          {
            "name": "couponOwed",
            "type": "u64"
          },
          {
            "name": "couponPayable",
            "docs": [
              "Portion of `coupon_owed` earned through a completed month and payable now."
            ],
            "type": "u64"
          },
          {
            "name": "couponRemainder",
            "type": "u128"
          },
          {
            "name": "lossesRecorded",
            "type": "u64"
          },
          {
            "name": "payoutHalted",
            "docs": [
              "Set by the allowlist authority on a screening hit: the crank refuses this position while",
              "accrual continues and the amount stays owed. Withdrawals are not affected by this flag;",
              "whether they should be is counsel's question (spec section 3.4)."
            ],
            "type": "bool"
          },
          {
            "name": "bump",
            "type": "u8"
          },
          {
            "name": "reserved",
            "type": {
              "array": [
                "u8",
                64
              ]
            }
          }
        ]
      }
    },
    {
      "name": "positionClosed",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "principalReturned",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "drawnAfter",
            "type": "u64"
          },
          {
            "name": "positionDrawnAfter",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "principalSurplusSwept",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "rateEpoch",
      "docs": [
        "One rate epoch: `bps` applies from `start_ts` until the next epoch's start."
      ],
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "startTs",
            "type": "i64"
          },
          {
            "name": "bps",
            "type": "u16"
          }
        ]
      }
    },
    {
      "name": "rateEpochAdded",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "index",
            "type": "u8"
          },
          {
            "name": "startTs",
            "type": "i64"
          },
          {
            "name": "bps",
            "type": "u16"
          }
        ]
      }
    },
    {
      "name": "termsChanged",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "lockSeconds",
            "type": "u64"
          },
          {
            "name": "noticeSeconds",
            "type": "u64"
          }
        ]
      }
    },
    {
      "name": "treasuryDraw",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "drawnAfter",
            "type": "u64"
          },
          {
            "name": "positionDrawnAfter",
            "type": "u64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "withdrawalCancelled",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "withdrawalRequested",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "eligibleAt",
            "type": "i64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    },
    {
      "name": "withdrawn",
      "type": {
        "kind": "struct",
        "fields": [
          {
            "name": "owner",
            "type": "pubkey"
          },
          {
            "name": "amount",
            "type": "u64"
          },
          {
            "name": "principalAfter",
            "type": "u64"
          },
          {
            "name": "totalPrincipal",
            "type": "u64"
          },
          {
            "name": "positionDrawn",
            "type": "u64"
          },
          {
            "name": "couponOwed",
            "type": "u64"
          },
          {
            "name": "couponPayable",
            "type": "u64"
          },
          {
            "name": "couponAccruedThrough",
            "type": "i64"
          },
          {
            "name": "ts",
            "type": "i64"
          }
        ]
      }
    }
  ],
  "constants": [
    {
      "name": "accountVersion",
      "docs": [
        "Account layout understood by this program. Reserved bytes let later versions add fields",
        "without forcing every curator to exit into a replacement program first."
      ],
      "type": "u8",
      "value": "1"
    },
    {
      "name": "configSeed",
      "type": "bytes",
      "value": "[99, 111, 110, 102, 105, 103]"
    },
    {
      "name": "couponSeed",
      "type": "bytes",
      "value": "[99, 111, 117, 112, 111, 110]"
    },
    {
      "name": "dayCountActual360",
      "docs": [
        "Day-count code for Actual/360, the only convention this version implements."
      ],
      "type": "u8",
      "value": "0"
    },
    {
      "name": "maxRateBps",
      "docs": [
        "Rates are basis points on Actual/360; 100% is the ceiling, not a target."
      ],
      "type": "u16",
      "value": "10000"
    },
    {
      "name": "maxTermSeconds",
      "type": "u64",
      "value": "63072000"
    },
    {
      "name": "minTermSeconds",
      "docs": [
        "Terms bounds: one day to two years, for both the lock and the notice."
      ],
      "type": "u64",
      "value": "86400"
    },
    {
      "name": "positionSeed",
      "type": "bytes",
      "value": "[112, 111, 115, 105, 116, 105, 111, 110]"
    },
    {
      "name": "vaultSeed",
      "type": "bytes",
      "value": "[118, 97, 117, 108, 116]"
    }
  ]
};
