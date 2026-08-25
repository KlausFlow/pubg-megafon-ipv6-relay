# Changelog

## v12.0.0

- Russian-first hybrid routing.
- Native MegaFon IPv6 preferred for PUBG HTTPS.
- MegaFon `64:ff9b::/96` preferred for IPv4-only HTTPS.
- Public NAT64 isolated to TCP `40002`.
- NAT64 selection ranks connection loss before median latency.
- Separate loopback address for every HTTPS hostname.
- Persistent BIFROST WebSocket with TCP keepalive.
- Automatic cleanup after relay termination.
- Diagnostic report uses the current user's Desktop path.
