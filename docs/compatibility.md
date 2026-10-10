# Compatibility

This page lists the xx50 models and their support status. Update this page
when a model gets a test on hardware or when the code for a model changes.

## Status values

| Status | Meaning |
|---|---|
| Tested | The system runs on this model on hardware. |
| Gap | The hardware differs from a tested model, and the code does not handle the difference. The system can start, but some parts can be wrong. |
| Not supported | The code has nothing for this model. |

## Models

The vendor kernel selects a board path from the product ID of the panel.
The board path sets the pins and the parts. The device tree of this project
holds the values of one board path.

| Model | Product ID | Vendor board path | Status | Notes |
|---|---|---|---|---|
| TSS-752 | 0x26 | `TSM750` | Tested | The device tree `imx53-crestron-tss752.dts` |
| TSW-752 | 0x3E | `TSW750` | Gap | The same SoC and display mode as the TSS-752. Other pins and parts are possible. Nobody has run the system on a TSW-752. |
| TSW-552 | not known | `TSW550` (probably) | Not supported | |
| TSW-1052 | not known | `TSW1050` (probably) | Not supported | Another touch controller, with no mainline driver. |

## Card

| Item | Status | Notes |
|---|---|---|
| SDHC card, 4 GB to 32 GB | Tested | The image needs 2.1 GiB. |
| Stock U-Boot 2009.08 | Tested | The image keeps the stock U-Boot and env of the card dump. |
