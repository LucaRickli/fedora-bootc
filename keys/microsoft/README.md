# Microsoft Secure Boot certificates

The `fedora-bootc-and-microsoft` enrollment set adds these certificates to the
Key Exchange Key (KEK) and signature database (db), with Microsoft's owner GUID
`77fa9abd-0359-4d32-bd60-28f4e78f784b`
([`image/enroll.sh`](../../image/enroll.sh)):

| File                                       | Certificate                           | Trusted for                                                             |
| ------------------------------------------ | ------------------------------------- | ----------------------------------------------------------------------- |
| `KEK/microsoft-kek-ca-2011.der`            | Microsoft Corporation KEK CA 2011     | db and forbidden signature database (dbx) updates                       |
| `KEK/microsoft-kek-2k-ca-2023.der`         | Microsoft Corporation KEK 2K CA 2023  | db and dbx updates since 2023                                           |
| `db/windows-production-pca-2011.der`       | Microsoft Windows Production PCA 2011 | Windows boot manager                                                    |
| `db/windows-uefi-ca-2023.der`              | Windows UEFI CA 2023                  | Windows boot manager since 2023                                         |
| `db/microsoft-uefi-ca-2011.der`            | Microsoft Corporation UEFI CA 2011    | Other bootloaders, such as shim, and add-in card firmware (option ROMs) |
| `db/microsoft-uefi-ca-2023.der`            | Microsoft UEFI CA 2023                | Other bootloaders since 2023                                            |
| `db/microsoft-option-rom-uefi-ca-2023.der` | Microsoft Option ROM UEFI CA 2023     | Option ROMs since 2023                                                  |

The files are renamed, byte-for-byte copies of
`PreSignedObjects/{KEK,DB}/Certificates/` in
[microsoft/secureboot_objects](https://github.com/microsoft/secureboot_objects/tree/e536431f17ada6a2c9edd01595c8d99b5a6d06dc/PreSignedObjects)
at commit `e536431`. They match what `sbctl enroll-keys -m` enrolls and
Fedora's `OVMF_VARS.secboot.fd` holds.

Firmware ignores expiry, so the 2011 certificates, which expired in 2026, still
validate older option ROMs and Windows boot media.

Check the files against these hashes with `sha256sum keys/microsoft/*/*.der`:

```text
3cd3f0309edae228767a976dd40d9f4affc4fbd5218f2e8cc3c9dd97e8ac6f9d  keys/microsoft/KEK/microsoft-kek-2k-ca-2023.der
a1117f516a32cefcba3f2d1ace10a87972fd6bbe8fe0d0b996e09e65d802a503  keys/microsoft/KEK/microsoft-kek-ca-2011.der
e5be3e64c6e66a281457ecdece0d6d0787577aad2a3a0144262c10c14ba8d8f1  keys/microsoft/db/microsoft-option-rom-uefi-ca-2023.der
48e99b991f57fc52f76149599bff0a58c47154229b9f8d603ac40d3500248507  keys/microsoft/db/microsoft-uefi-ca-2011.der
f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901  keys/microsoft/db/microsoft-uefi-ca-2023.der
e8e95f0733a55e8bad7be0a1413ee23c51fcea64b3c8fa6a786935fddcc71961  keys/microsoft/db/windows-production-pca-2011.der
076f1fea90ac29155ebf77c17682f75f1fdd1be196da302dc8461e350a9ae330  keys/microsoft/db/windows-uefi-ca-2023.der
```
