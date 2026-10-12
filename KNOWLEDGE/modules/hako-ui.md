# Hako UI and design provenance

## Ownership

`ApplicationLibrary/Views/HakoStyle/` is the iPhone-only presentation boundary. `HakoPageContent` is the primary route seam. The original design source is `hako-ui@c1935cf`; the immutable `iphone-hako-ui-freeze-v1` tag points to `fc7f77b` and records a reviewed freeze. Shipping adaptation and original design source are different concepts.

## Generated and adapted material

Migration scripts mechanically rename/resolve platform conditions. A generated candidate is not automatically safe to overwrite: files can contain later manual platform repairs. The scripts' explicit replacement/hash authorization is a protection against reversing those repairs. Fork-owned adapters/navigation are not presented as original design files.

## Evidence boundary

`audit_hako_lossless_parity.py` compares designated tokens/byte-parity files and is `VERIFIED_STATIC`; `check-iphone-hako-freeze.sh` protects the frozen surface; route/boundary audits prove reachability and isolation. None yields pixel or device parity. Use `docs/APPLE-HAKO-VISUAL-ACCEPTANCE.md` for the hardware checklist; it remains `NEEDS_DEVICE` at this baseline.
