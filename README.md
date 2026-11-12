# HealthDBFix

Stops `healthd` from crash-looping on iOS 17.0 / 17.1.1 when a synced HealthKit source order (from Apple Watch or iCloud) carries an unknown data type code. Should work on iOS 15-16 as well.

- Drops source orders with invalid codes before Apple's code sees them.
- Makes `+[HKObjectType _dataTypeWithCode:expectedClass:]` return `nil` instead of raising for invalid codes.

Debug logging (file log, self-test, iCloud sync timing) is off by default; enable it with `HEALTHDBFIX_DEBUG=1`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
