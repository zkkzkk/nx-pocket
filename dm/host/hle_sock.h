// Local network play (DM_NET=lan): the host's own sockets behind the guest's bsd socket calls (hle_sock.c), and local wireless over the LAN (hle_ldn.c).
// The hooks stay in hle_net.c / hle_offline.c / hle_misc.c and hand over here when dm_net_on(); with DM_NET unset every one of them keeps its offline answer.
#pragma once
#include <stdint.h>

int dm_net_on(void);          // DM_NET=lan (never with the deterministic clock)
int dm_net_nifm(void);        // DM_NET_NIFM=1 as well: nifm reports the LAN as an available network (off by default, so online features keep their offline branch)
int dm_net_log(void);         // DM_NET_LOG=1
// This console's own 64-bit ID, the same every run: DM_DEVICE_ID (hex) if set, else made at random once and kept in ~/Library/nxnative-device-id. Local play tells consoles
// apart by it (hle_account.c: the user's ID)
uint64_t dm_device_id(void);

// The local address the host plays on (host byte order): DM_NET_IF names the interface (lo0 is allowed, for two instances on one Mac), else the first running en* with IPv4.
// Returns 0 with no address
int dm_net_local(uint32_t *ip, uint32_t *mask);
// Broadcasts are not allowed (iOS without the multicast entitlement, or DM_NET_UNICAST=1): a broadcast goes as unicasts to the peers and the room's nodes instead
int dm_net_unicast(void);
// DM_NET_PEERS=ip[:port],…: addresses to reach without a broadcast (host byte order; port 0 = the default). Returns the count
int dm_net_peers(uint32_t *ip, uint16_t *port, int max);
// The local wireless room's member addresses (hle_ldn.c keeps it current, host byte order): a guest broadcast goes to them as unicasts while a room is up
void dm_net_set_room(const uint32_t *ip, int n);
// Whether a destination may be reached: private ranges, loopback, link-local, 100.64/10 (a VPN such as Tailscale), the peers and the room. The rest of the Internet is refused
int dm_net_allowed(uint32_t ip);

// The guest's calls (Horizon's bsd ABI: FreeBSD's values, Linux's errors). They return as the bsd service does: -1 with the (Linux) error in dm_sock_errno()
int dm_sock_errno(void);
void dm_sock_set_errno(int e);
int dm_sock_socket(int family, int type, int proto);
int dm_sock_bind(int s, const void *sa, unsigned n);
int dm_sock_connect(int s, const void *sa, unsigned n);
int dm_sock_listen(int s, int backlog);
int dm_sock_accept(int s, void *sa, unsigned *n);
int dm_sock_close(int s);
int dm_sock_shutdown(int s, int how);
int dm_sock_getsockname(int s, void *sa, unsigned *n);
int dm_sock_getpeername(int s, void *sa, unsigned *n);
int dm_sock_getsockopt(int s, int level, int opt, void *v, unsigned *n);
int dm_sock_setsockopt(int s, int level, int opt, const void *v, unsigned n);
int dm_sock_fcntl(int s, int cmd, int arg);
long dm_sock_recv(int s, void *buf, unsigned long n, int flags);
long dm_sock_recvfrom(int s, void *buf, unsigned long n, int flags, void *sa, unsigned *sn);
long dm_sock_send(int s, const void *buf, unsigned long n, int flags);
long dm_sock_sendto(int s, const void *buf, unsigned long n, int flags, const void *sa, unsigned sn);
int dm_sock_poll(void *fds, uint64_t n, int ms);
int dm_sock_select(int nfds, uint64_t *r, uint64_t *w, uint64_t *e, const int64_t *tv);
