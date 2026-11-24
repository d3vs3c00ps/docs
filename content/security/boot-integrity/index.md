---
title: "Boot integrity"
description: "The chain from firmware to an unlocked disk: Secure Boot measures it, the TPM records it, and LUKS releases a key only when it still matches."
tags: [boot-integrity]
type: moc
status: complete
---

<!-- generated-moc -->

# Boot integrity

The chain from firmware to an unlocked disk: Secure Boot measures it, the TPM records it, and LUKS releases a key only when it still matches.


| Note | | What it covers |
| --- | --- | --- |
| [[security/boot-integrity/luks\|LUKS with TPM auto-unlock]] | how-to | Full-disk encryption that unlocks itself only on a trusted boot state — LUKS2, Clevis, PCR 7 binding, and the reseal procedure |
| [[security/boot-integrity/remote-attestation\|Remote attestation]] | concept | Proving a machine is still trustworthy to a remote party — IMA, Keylime, and extending measured boot into continuous runtime verification |
| [[security/boot-integrity/secure-boot\|UEFI Secure Boot]] | concept | The firmware chain of trust — PK, KEK, db and dbx, shim and MOK, and the 2026 Microsoft certificate rotation |
| [[security/boot-integrity/tpm\|TPM 2.0 and measured boot]] | concept | How the TPM records what ran during boot in PCRs, and releases a sealed secret only when that record still matches |

Part of [[security/index|Security]].
