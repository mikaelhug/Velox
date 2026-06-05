/*
 * veloxnet.h — C ABI for the velox-net Rust staticlib (host/velox-net).
 *
 * Hand-authored to match the `#[no_mangle] extern "C"` surface in
 * host/velox-net/src/lib.rs. Keep the two in lockstep. The struct layouts use C
 * rules on both sides (Rust `#[repr(C)]`), so field order/types must match exactly.
 */
#ifndef VELOXNET_H
#define VELOXNET_H

#include <stdint.h>

/* Opaque running-stack handle. */
typedef struct VeloxNet VeloxNet;

/* Static configuration. IPv4 addresses are in HOST byte order. */
typedef struct {
    uint32_t gateway_ip;   /* e.g. 0xC0A87F01 = 192.168.127.1 (this stack)        */
    uint32_t guest_ip;     /* e.g. 0xC0A87F02 = 192.168.127.2 (the guest)         */
    uint8_t  prefix_len;   /* subnet prefix, e.g. 24                              */
    uint16_t mtu;          /* link MTU, e.g. 1500                                 */
} vn_config;

/* Counter snapshot. */
typedef struct {
    uint64_t rx_frames;
    uint64_t tx_frames;
    uint64_t rx_bytes;
    uint64_t tx_bytes;
} vn_stats;

/* level: 0=err 1=warn 2=info 3=debug. msg valid only during the call. */
typedef void (*vn_log_fn)(int level, const char *msg, void *ctx);

/* Lifecycle. Takes ownership of frame_fd (closed by velox_net_stop). NULL on failure. */
VeloxNet *velox_net_start(int frame_fd, const vn_config *cfg, vn_log_fn log, void *log_ctx);
void velox_net_stop(VeloxNet *h);

/* Inbound publish (proto: 0=TCP, 1=UDP). Returns 0 on success. */
int velox_net_expose(VeloxNet *h, int proto, uint16_t host_port, uint16_t guest_port);
int velox_net_unexpose(VeloxNet *h, int proto, uint16_t host_port);

/* Copy counters into *out. Returns 0 on success, -1 on bad args. */
int velox_net_stats(const VeloxNet *h, vn_stats *out);

#endif /* VELOXNET_H */
